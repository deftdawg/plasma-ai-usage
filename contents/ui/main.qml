import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support
import "Providers.js" as Providers

PlasmoidItem {
    id: root

    // Translations
    Translations {
        id: i18n
        currentLanguage: Plasmoid.configuration.language || "system"
    }

    property string lastUpdate: ""
    property string errorMsg: ""
    property bool isLoading: false
    property string claudeToken: ""
    property var cachedAntigravity: null
    property string haPublishStatus: "disabled"  // "disabled", "success", "error"
    property bool haDialogVisible: false
    property bool showResetTimeToggle: false  // Alternates on refresh for 0% display
    property string jsonFilePublishStatus: "disabled"  // "disabled", "success", "error"

    // Model to store provider data
    ListModel {
        id: providersModel
    }

    readonly property string usageApiUrl: "https://api.anthropic.com/api/oauth/usage"

    // Data source for reading credentials files
    Plasma5Support.DataSource {
        id: fileReader
        engine: "executable"
        connectedSources: []

        onNewData: function(sourceName, data) {
            var stdout = data["stdout"] || ""
            disconnectSource(sourceName)

            console.log("AI Usage: Got data, length:", stdout.length)
            
            providersModel.clear()
            
            var parts = stdout.split("___SEP___")
            var claudeData = parts[0] ? parts[0].trim() : ""
            var antigravityData = parts[1] ? parts[1].trim() : ""
            var ampData = parts[2] ? parts[2].trim() : ""

            // Process Claude
            var claudeProv = Providers.parseClaudeCredentials(claudeData)
            if (claudeProv) {
                // Initialize with basic data, fetch details later
                claudeProv.sessionUsage = 0
                claudeProv.weeklyUsage = 0
                claudeProv.sonnetUsage = 0
                claudeProv.opusUsage = 0
                claudeProv.sessionReset = ""
                claudeProv.weeklyReset = ""
                
                providersModel.append(claudeProv)
                root.claudeToken = claudeProv.token
                fetchClaudeUsage()
            }

            // Process Amp
            var ampProv = Providers.parseAmpConfig(ampData)
            if (ampProv) {
                // Track 24h free-quota reset window for percent-based Amp Free
                ampProv = Providers.applyAmpResetTracking(ampProv, Plasmoid.configuration)
                providersModel.append(ampProv)
            }

            // Process Antigravity
            var antigravityProv = Providers.parseAntigravityConfig(antigravityData)
            console.log("AI Usage: Antigravity parsed, error=", antigravityProv ? antigravityProv.error : "null provider")
            
            // Helper to get cached data if valid
            var getCached = function() {
                if (root.cachedAntigravity && (new Date().getTime() - root.cachedAntigravity.timestamp < 3600000)) {
                    return root.cachedAntigravity
                }
                return null
            }
            
            if (antigravityProv) {
                if (!antigravityProv.error) {
                    // Update cache
                    root.cachedAntigravity = antigravityProv
                    root.cachedAntigravity.timestamp = new Date().getTime()
                    antigravityProv.lastCacheTime = "" // No error, no cache time shown
                    console.log("AI Usage: Antigravity running, cached")
                } else {
                    // Error reported by script
                    console.log("AI Usage: Antigravity error detected:", antigravityProv.error)
                    var cached = getCached()
                    if (cached) {
                        // Use cache but keep error
                        console.log("AI Usage: Using cached data with error overlay")
                        antigravityProv = Object.assign({}, cached) // Shallow copy
                        antigravityProv.error = "Not Running"
                        antigravityProv.timestamp = cached.timestamp // Preserve timestamp
                        antigravityProv.lastCacheTime = Qt.formatTime(new Date(cached.timestamp), "hh:mm:ss")
                    } else {
                        console.log("AI Usage: No cache available")
                        antigravityProv.lastCacheTime = ""
                    }
                }
            } else {
                // Parse failed (e.g. script failed silently)
                var cached = getCached()
                if (cached) {
                    antigravityProv = Object.assign({}, cached)
                    antigravityProv.error = "Not Running"
                    antigravityProv.timestamp = cached.timestamp
                    antigravityProv.lastCacheTime = Qt.formatTime(new Date(cached.timestamp), "hh:mm:ss")
                } else {
                    // No cache, force default error state
                    antigravityProv = {
                        provider: "antigravity",
                        name: "Antigravity",
                        icon: "antigravity.svg",
                        error: "Not Running",
                        valid: true,
                        isRemaining: true,
                        lastCacheTime: "",
                        bucketsJson: JSON.stringify([
                            { name: "Claude / OpenAI", percent: -1, used: "N/A", limit: "N/A", reset: "" },
                            { name: "Gemini Pro", percent: -1, used: "N/A", limit: "N/A", reset: "" },
                            { name: "Gemini Flash", percent: -1, used: "N/A", limit: "N/A", reset: "" }
                        ])
                    }
                }
            }
            
            if (antigravityProv) {
                console.log("AI Usage: Appending antigravity, error=", antigravityProv.error, "lastCacheTime=", antigravityProv.lastCacheTime)
                providersModel.append(antigravityProv)
            }
            
            if (providersModel.count === 0) {
                root.errorMsg = i18n.tr("No accounts found")
            } else {
                root.errorMsg = ""
            }
            
            root.lastUpdate = Qt.formatTime(new Date(), "hh:mm:ss")
            root.isLoading = false
            root.showResetTimeToggle = !root.showResetTimeToggle
            
            // Publish to Home Assistant if enabled
            publishToHomeAssistant()
            
            // Publish to JSON file if enabled
            publishToJsonFile()
        }
    }

    // Data source for writing/deleting the JSON status file
    Plasma5Support.DataSource {
        id: fileWriter
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            disconnectSource(sourceName)
        }
    }

    function loadCredentials() {
        root.isLoading = true
        root.errorMsg = ""
        // Read all config files separated by a delimiter
        // Try 'amp usage' command first, then fallback to JSON file
        // Try 'python3 contents/ui/antigravity.py' for Antigravity, fallback to JSON
        var pyScript = Qt.resolvedUrl("antigravity.py").toString().replace("file://", "")
        var cmd = "cat $HOME/.claude/.credentials.json 2>/dev/null; " + 
                  "echo '___SEP___'; " + 
                  "(python3 \"" + pyScript + "\" 2>/dev/null || cat $HOME/.antigravity/usage.json 2>/dev/null); " + 
                  "echo '___SEP___'; " + 
                  "(amp usage 2>/dev/null || ~/.amp/bin/amp usage 2>/dev/null || cat $HOME/.amp/usage.json 2>/dev/null); " + 
                  "# " + new Date().getTime()
        
        console.log("AI Usage Command:", cmd)
        fileReader.connectSource(cmd)
    }

    function fetchClaudeUsage() {
        if (!root.claudeToken) return

        var xhr = new XMLHttpRequest()
        xhr.open("GET", usageApiUrl)
        xhr.setRequestHeader("Authorization", "Bearer " + root.claudeToken)
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("anthropic-beta", "oauth-2025-04-20")

        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                if (xhr.status === 200) {
                    try {
                        var data = JSON.parse(xhr.responseText)
                        var fiveHour = data.five_hour || {}
                        var sevenDay = data.seven_day || {}
                        var sevenDaySonnet = data.seven_day_sonnet || {}
                        var sevenDayOpus = data.seven_day_opus || {}

                        // Find Claude item in model and update it
                        for (var i = 0; i < providersModel.count; i++) {
                            if (providersModel.get(i).provider === "claude") {
                                providersModel.setProperty(i, "sessionUsage", fiveHour.utilization || 0)
                                providersModel.setProperty(i, "weeklyUsage", sevenDay.utilization || 0)
                                providersModel.setProperty(i, "sonnetUsage", sevenDaySonnet ? (sevenDaySonnet.utilization || 0) : 0)
                                providersModel.setProperty(i, "opusUsage", sevenDayOpus ? (sevenDayOpus.utilization || 0) : 0)
                                
                                if (fiveHour.resets_at) {
                                    providersModel.setProperty(i, "sessionReset", Qt.formatTime(new Date(fiveHour.resets_at), "hh:mm"))
                                }
                                if (sevenDay.resets_at) {
                                    providersModel.setProperty(i, "weeklyReset", Qt.formatDateTime(new Date(sevenDay.resets_at), "MMM d, hh:mm"))
                                }
                                break
                            }
                        }
                    } catch (e) {
                        console.log("Claude Usage: JSON parse error:", e)
                    }
                } else {
                     console.log("Claude Usage: API error:", xhr.status)
                }
            }
        }
        xhr.send()
    }

    function refresh() {
        loadCredentials()
    }

    function publishToHomeAssistant() {
        if (!Plasmoid.configuration.haEnabled) {
            root.haPublishStatus = "disabled"
            return
        }
        
        var sensorUri = Plasmoid.configuration.haSensorUri
        var accessToken = Plasmoid.configuration.haAccessToken
        
        if (!sensorUri || !accessToken) {
            root.haPublishStatus = "error"
            console.log("HA Publish: Missing sensor URI or access token")
            return
        }
        
        // Build provider data for the sensor attributes
        var providers = []
        for (var i = 0; i < providersModel.count; i++) {
            var p = providersModel.get(i)
            var providerData = {
                name: p.name,
                provider: p.provider
            }
            
            if (p.provider === "claude") {
                providerData.session_usage = p.sessionUsage || 0
                providerData.weekly_usage = p.weeklyUsage || 0
                providerData.sonnet_usage = p.sonnetUsage || 0
                providerData.opus_usage = p.opusUsage || 0
            } else if (p.provider === "antigravity") {
                providerData.buckets = getBuckets(p.bucketsJson)
                providerData.error = p.error || ""
            } else if (p.provider === "amp") {
                providerData.active_plan = p.activePlanName || ""
                providerData.active_remaining = p.activeRemaining || 0
                providerData.active_is_percent = p.activeIsPercent !== false
                providerData.active_is_credits = p.activeIsCredits || false
                providerData.active_remaining_percent = p.activeRemainingPercent !== undefined ? p.activeRemainingPercent : -1
                providerData.reset_countdown = p.resetCountdown || ""
                providerData.reset_compact = p.resetCompact || ""
                providerData.has_active_countdown = p.hasActiveCountdown || false
                providerData.credit_balance = p.creditBalance || 0
                providerData.plans = buildAmpPlansExport(p)
                // Free upcoming reset (within 6h, Free not active) — tray green bracket
                providerData.free_upcoming_reset = p.showFreeUpcoming ? (p.freeUpcomingCompact || "") : ""
                providerData.show_free_upcoming = p.showFreeUpcoming || false
                // Legacy fields
                providerData.free_used = p.freeUsed || 0
                providerData.free_limit = p.freeLimit || 0
                providerData.free_is_percent = p.freeIsPercent || false
                providerData.free_resets = p.freeResets || ""
            }
            
            providers.push(providerData)
        }
        
        var payload = {
            state: root.errorMsg ? "error" : "ok",
            attributes: {
                friendly_name: "AI Usage Applet",
                providers: providers,
                last_updated: new Date().toISOString()
            }
        }
        
        var xhr = new XMLHttpRequest()
        xhr.open("POST", sensorUri)
        xhr.setRequestHeader("Authorization", "Bearer " + accessToken)
        xhr.setRequestHeader("Content-Type", "application/json")
        
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                if (xhr.status === 200 || xhr.status === 201) {
                    root.haPublishStatus = "success"
                    console.log("HA Publish: Success")
                } else {
                    root.haPublishStatus = "error"
                    console.log("HA Publish: Failed with status", xhr.status, xhr.responseText)
                }
            }
        }
        
        xhr.send(JSON.stringify(payload))
    }

    function publishToJsonFile() {
        if (!Plasmoid.configuration.jsonFileEnabled) {
            root.jsonFilePublishStatus = "disabled"
            return
        }
        
        var providers = []
        for (var i = 0; i < providersModel.count; i++) {
            var p = providersModel.get(i)
            var providerData = {
                name: p.name,
                provider: p.provider
            }
            
            if (p.provider === "claude") {
                var sessionUsage = p.sessionUsage || 0
                var weeklyUsage = p.weeklyUsage || 0
                providerData.session_remaining = Math.round(100 - sessionUsage)
                providerData.weekly_remaining = Math.round(100 - weeklyUsage)
                providerData.sonnet_remaining = Math.round(100 - (p.sonnetUsage || 0))
                providerData.opus_remaining = Math.round(100 - (p.opusUsage || 0))
                providerData.session_reset = p.sessionReset || ""
                providerData.weekly_reset = p.weeklyReset || ""
            } else if (p.provider === "antigravity") {
                var buckets = getBuckets(p.bucketsJson)
                for (var b = 0; b < buckets.length; b++) {
                    buckets[b].percent_remaining = buckets[b].percent !== undefined ? Math.round(buckets[b].percent) : -1
                    delete buckets[b].percent
                }
                providerData.buckets = buckets
                providerData.error = p.error || ""
            } else if (p.provider === "amp") {
                providerData.active_plan = p.activePlanName || ""
                providerData.active_remaining = p.activeIsPercent
                    ? Math.round(p.activeRemaining || 0)
                    : (p.activeRemaining || 0)
                providerData.active_is_percent = p.activeIsPercent !== false
                providerData.active_is_credits = p.activeIsCredits || false
                providerData.active_remaining_percent = p.activeRemainingPercent !== undefined ? p.activeRemainingPercent : -1
                providerData.reset_countdown = p.resetCountdown || ""
                providerData.reset_compact = p.resetCompact || ""
                providerData.has_active_countdown = p.hasActiveCountdown || false
                providerData.credit_balance = p.creditBalance || 0
                // Multi-plan export: name, remaining quota, reset time
                providerData.plans = buildAmpPlansExport(p)
                // Free upcoming reset (within 6h, Free not active) — tray green bracket
                // e.g. "MW 44% 19d (2¼h)" → free_upcoming_reset = "2¼h"
                providerData.free_upcoming_reset = p.showFreeUpcoming ? (p.freeUpcomingCompact || "") : ""
                providerData.show_free_upcoming = p.showFreeUpcoming || false
                // Legacy fields for older consumers
                var freeUsed = p.freeUsed || 0
                var freeLimit = p.freeLimit || 0
                providerData.free_used = freeUsed
                providerData.free_limit = freeLimit
                providerData.free_is_percent = p.freeIsPercent || false
                providerData.free_remaining = Math.round(freeLimit > 0 ? ((freeLimit - freeUsed) / freeLimit * 100) : 0)
                providerData.free_resets = p.freeResets || ""
            }
            
            providers.push(providerData)
        }
        
        var payload = {
            state: root.errorMsg ? "error" : "ok",
            providers: providers,
            last_updated: new Date().toISOString()
        }
        
        var json = JSON.stringify(payload)
        var b64 = Qt.btoa(json)
        var cmd = "mkdir -p $HOME/.cache && echo " + b64 + " | base64 -d > $HOME/.cache/ai-usage-status.json"
        fileWriter.connectSource(cmd + " # " + new Date().getTime())
        root.jsonFilePublishStatus = "success"
        console.log("JSON File: Published to ~/.cache/ai-usage-status.json")
    }

    function deleteJsonFile() {
        var cmd = "rm -f $HOME/.cache/ai-usage-status.json"
        fileWriter.connectSource(cmd + " # " + new Date().getTime())
        root.jsonFilePublishStatus = "disabled"
        console.log("JSON File: Deleted ~/.cache/ai-usage-status.json")
    }

    function formatResetTime(resetTimeStr) {
        if (!resetTimeStr) return ""
        
        var resetDate = new Date(resetTimeStr)
        var now = new Date()
        var diffMs = resetDate.getTime() - now.getTime()
        
        if (diffMs <= 0) return i18n.tr("Resetting...")
        
        var diffDays = Math.floor(diffMs / (1000 * 60 * 60 * 24))
        var diffHours = Math.floor((diffMs % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60))
        var diffMins = Math.floor((diffMs % (1000 * 60 * 60)) / (1000 * 60))
        var timeLeft = diffDays > 0 ? "<b>" + diffDays + "d</b> " + diffHours + "h " + diffMins + "m" : (diffHours > 0 ? diffHours + "h " + diffMins + "m" : diffMins + "m")
        var resetTimeFormatted = Qt.formatDateTime(resetDate, "MMM d, h:mm ap")
        
        return timeLeft + " " + i18n.tr("remaining") + " | " + i18n.tr("Reset:") + " " + resetTimeFormatted
    }

    function getLargestResetComponent(resetTimeStr) {
        if (!resetTimeStr) return ""
        
        var resetDate = new Date(resetTimeStr)
        var now = new Date()
        var diffMs = resetDate.getTime() - now.getTime()
        
        if (diffMs <= 0) return "0m"
        
        var diffDays = Math.floor(diffMs / (1000 * 60 * 60 * 24))
        var diffHours = Math.floor((diffMs % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60))
        var diffMins = Math.floor((diffMs % (1000 * 60 * 60)) / (1000 * 60))
        var diffSecs = Math.floor((diffMs % (1000 * 60)) / 1000)
        
        if (diffDays > 0) return diffDays + "d"
        if (diffHours > 0) return diffHours + "h"
        if (diffMins > 0) return diffMins + "m"
        return diffSecs + "s"
    }

    function getBuckets(jsonStr) {
        try { return JSON.parse(jsonStr || "[]"); }
        catch (e) { return []; }
    }

    function getAmpPlans(provider) {
        if (!provider) return []
        // Prefer multi-plan JSON; fall back to synthesizing from legacy fields
        var plans = getBuckets(provider.plansJson)
        if (plans.length > 0) return plans
        var legacy = []
        if (provider.freeLimit > 0 || provider.freeIsPercent) {
            var rem = provider.freeIsPercent
                ? (provider.freePercent !== undefined ? provider.freePercent : (provider.freeLimit - provider.freeUsed))
                : (provider.freeLimit > 0 ? ((provider.freeLimit - provider.freeUsed) / provider.freeLimit * 100) : 0)
            legacy.push({
                name: "Free",
                kind: "free",
                shortLabel: "free",
                remaining: rem,
                remainingIsPercent: true,
                resetLabel: provider.freeResets || "",
                resetCompact: provider.resetCompact || "",
                resetCountdown: provider.resetCountdown || "",
                hasActiveCountdown: provider.hasActiveCountdown || false,
                resetMsLeft: provider.resetMsLeft !== undefined ? provider.resetMsLeft : -1
            })
        }
        if (provider.creditBalance !== undefined && provider.creditBalance !== null) {
            legacy.push({
                name: "Credits",
                kind: "credits",
                shortLabel: "",
                remaining: provider.creditBalance || 0,
                remainingIsPercent: false,
                resetLabel: "",
                resetCompact: "",
                resetCountdown: ""
            })
        }
        return legacy
    }

    /** Build JSON-export shape for Amp plans: name, remaining, reset */
    function buildAmpPlansExport(provider) {
        var plans = getAmpPlans(provider)
        var out = []
        for (var i = 0; i < plans.length; i++) {
            var pl = plans[i]
            var entry = {
                name: pl.name || "",
                remaining: pl.remainingIsPercent === false
                    ? (pl.remaining || 0)
                    : Math.round(pl.remaining || 0),
                remaining_is_percent: pl.remainingIsPercent !== false,
                remaining_percent: pl.remainingPercent !== undefined ? pl.remainingPercent : -1,
                reset: pl.resetCountdown || pl.resetCompact || pl.resetLabel || ""
            }
            if (pl.otherRemaining !== undefined && pl.otherRemaining >= 0)
                entry.other_remaining = Math.round(pl.otherRemaining)
            if (pl.orbRemaining !== undefined && pl.orbRemaining >= 0)
                entry.orb_remaining = Math.round(pl.orbRemaining)
            out.push(entry)
        }
        return out
    }

    function getProviderTooltipText(provider) {
        if (!provider) return ""
        
        if (provider.provider === "amp") {
            return getAmpTooltipText(provider)
        }
        
        if (provider.provider === "antigravity") {
            var buckets = getBuckets(provider.bucketsJson)
            var parts = []
            for (var i = 0; i < buckets.length; i++) {
                var b = buckets[i]
                parts.push(b.name + ": " + Math.round(b.percent || 0) + "%")
            }
            return parts.join(" | ")
        }
        
        // Claude fallback
        return i18n.tr("Session (5hr)") + ": " + Math.round(provider.sessionUsage||0) + "% | " + i18n.tr("Weekly (7day)") + ": " + Math.round(provider.weeklyUsage||0) + "%"
    }

    function getAmpTooltipText(provider) {
        if (!provider) return ""
        var plans = getAmpPlans(provider)
        if (plans.length === 0) {
            // Last-resort legacy single-line tooltip
            if (provider.activeIsCredits || (provider.creditBalance > 0 && !provider.freeIsPercent))
                return i18n.tr("Credit Balance:") + " $" + (provider.creditBalance || 0).toFixed(2)
            return Math.round(provider.activeRemaining || 0) + "% " + i18n.tr("remaining")
        }

        var parts = []
        for (var i = 0; i < plans.length; i++) {
            var pl = plans[i]
            var label = pl.name || ("Plan " + (i + 1))
            var remStr
            if (pl.kind === "credits") {
                remStr = "$" + Number(pl.remaining || 0).toFixed(2)
            } else if (pl.remainingIsPercent === false) {
                remStr = "⚡$" + Number(pl.remaining || 0).toFixed(2)
                if (pl.orbRemaining >= 0)
                    remStr += " + 🔮" + Math.round(pl.orbRemaining) + "%"
            } else if (pl.otherRemaining >= 0 && pl.orbRemaining >= 0) {
                // ⚡ agent (other) + 🔮 orb
                remStr = "⚡" + Math.round(pl.otherRemaining) + "% + 🔮" + Math.round(pl.orbRemaining) + "%"
            } else {
                remStr = "⚡" + Math.round(pl.remaining || 0) + "%"
            }
            var resetStr = pl.resetCountdown || pl.resetCompact || pl.resetLabel || ""
            var piece = label + ": " + remStr
            if (resetStr) piece += " (" + i18n.tr("Resets:") + " " + resetStr + ")"
            // Mark the active plan
            if (provider.activePlanName && pl.name === provider.activePlanName)
                piece = "▶ " + piece
            parts.push(piece)
        }
        // Free upcoming within 6h while on another plan
        if (provider.showFreeUpcoming && provider.freeUpcomingCompact) {
            parts.push(i18n.tr("Free resets in:") + " " + provider.freeUpcomingCompact)
        }
        return parts.join(" | ")
    }

    // Color for Amp countdown time: >=12h green, >=6h yellow, <6h red
    function getAmpTimeColor(msLeft) {
        if (msLeft < 0) return Kirigami.Theme.disabledTextColor
        var hoursLeft = msLeft / 3600000
        if (hoursLeft >= 12) return Kirigami.Theme.positiveTextColor
        if (hoursLeft >= 6) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.negativeTextColor
    }

    // Color for Amp remaining % (same scheme as the free-quota bar)
    function getAmpRemainingColor(remainingPct) {
        if (remainingPct > 50) return Kirigami.Theme.positiveTextColor
        if (remainingPct > 20) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.negativeTextColor
    }

    // Compact representation (panel)
    compactRepresentation: Item {
        Layout.minimumWidth: compactRow.implicitWidth + Kirigami.Units.largeSpacing * 2
        Layout.minimumHeight: Kirigami.Units.iconSizes.medium
        Layout.preferredWidth: compactRow.implicitWidth + Kirigami.Units.largeSpacing * 2

        // IMPORTANT: Do NOT add custom ToolTip components here that could block mouse clicks.
        // The tooltip is handled at the plasmoid level via toolTipMainText/toolTipSubText
        // properties (see bottom of file). If custom tooltips are ever added, they MUST be
        // offset so they don't appear directly under the mouse cursor, otherwise users
        // won't be able to click on the widget while hovering.
        MouseArea {
            id: compactMouseArea
            anchors.fill: parent
            onClicked: root.expanded = !root.expanded
        }

        RowLayout {
            id: compactRow
            anchors.centerIn: parent
            spacing: Kirigami.Units.smallSpacing

            // Empty/Error State
            RowLayout {
                visible: providersModel.count === 0
                spacing: Kirigami.Units.smallSpacing
                
                Kirigami.Icon {
                    Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                    source: Qt.resolvedUrl("../icons/claude.svg")
                }
                
                PlasmaComponents.Label {
                    visible: root.errorMsg !== ""
                    text: "⚠"
                    color: Kirigami.Theme.negativeTextColor
                }
            }

            // Providers List
            Repeater {
                model: providersModel
                delegate: RowLayout {
                    spacing: Kirigami.Units.smallSpacing
                    
                    // Separator
                    PlasmaComponents.Label {
                        visible: index > 0
                        text: "|"
                        opacity: 0.5
                        color: Kirigami.Theme.disabledTextColor
                    }

                    Kirigami.Icon {
                        Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                        Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                        source: model.icon ? Qt.resolvedUrl("../icons/" + model.icon) : ""
                    }

                    property bool isAmp: model.provider === "amp"
                    property bool isAntigravity: model.provider === "antigravity"
                    property bool isRemainingMode: model.isRemaining === true
                    
                    // Parse buckets for antigravity
                    property var antigravityBuckets: isAntigravity ? getBuckets(model.bucketsJson) : []
                    property real firstBucketPercent: antigravityBuckets.length > 0 ? (antigravityBuckets[0].percent !== undefined ? antigravityBuckets[0].percent : -1) : -1
                    property string firstBucketReset: antigravityBuckets.length > 0 ? (antigravityBuckets[0].reset || "") : ""
                    
                    // Amp active plan (first plan with remaining > 0; Free → MW/GW → Credits)
                    property real ampRemainingPct: {
                        if (!isAmp) return 0
                        if (model.activeRemainingPercent !== undefined && model.activeRemainingPercent >= 0)
                            return model.activeRemainingPercent
                        if (model.activeIsPercent !== false && !model.activeIsCredits)
                            return model.activeRemaining || 0
                        return 0
                    }
                    // Plan tag: "free" / "MW" / "GW" — hidden for credits ($ is enough)
                    property string ampPlanTag: {
                        if (!isAmp) return ""
                        if (model.activeIsCredits) return ""
                        return model.activePlanShort || ""
                    }
                    property bool ampShowPlanTag: isAmp && ampPlanTag !== ""
                    property bool ampShowCountdown: isAmp && model.resetCompact && model.resetCompact !== ""
                    // Free upcoming reset within 6h while on MW/GW/credits: green "(2¼h)"
                    property bool ampShowFreeUpcoming: isAmp && model.showFreeUpcoming && model.freeUpcomingCompact
                    property string ampFreeUpcomingText: ampShowFreeUpcoming
                        ? ("(" + (model.freeUpcomingCompact || "") + ")")
                        : ""
                    
                    property real displayValue: {
                        if (isAmp) {
                            if (model.activeIsCredits)
                                return model.activeRemaining || model.creditBalance || 0
                            if (model.activeIsPercent !== false)
                                return model.activeRemaining || 0
                            return model.activeRemaining || model.creditBalance || 0
                        }
                        if (isAntigravity) return firstBucketPercent !== -1 ? firstBucketPercent : 0
                        return model.sessionUsage || 0
                    }
                    
                    property string displayText: {
                        if (isAmp) {
                            if (model.activeIsCredits || model.activeIsPercent === false)
                                return "$" + Number(displayValue).toFixed(2)
                            return Math.round(displayValue) + "%"
                        }
                        if (isAntigravity && firstBucketPercent === -1) return "?%"
                        if (isAntigravity && Math.round(firstBucketPercent) === 0 && root.showResetTimeToggle && firstBucketReset) {
                            return getLargestResetComponent(firstBucketReset)
                        }
                        return Math.round(displayValue) + "%"
                    }
                    
                    property color displayColor: {
                        if (isAmp) {
                            if (model.activeIsCredits)
                                return Kirigami.Theme.neutralTextColor
                            return getAmpRemainingColor(ampRemainingPct)
                        }
                        if (isAntigravity && isRemainingMode) {
                             if (firstBucketPercent === -1) return Kirigami.Theme.disabledTextColor
                             if (displayValue > 50) return Kirigami.Theme.positiveTextColor
                             if (displayValue > 20) return Kirigami.Theme.neutralTextColor
                             return Kirigami.Theme.negativeTextColor
                        }
                        return getUsageColor(displayValue)
                    }
                    
                    // Dot for non-Amp (Claude/Antigravity legacy)
                    Rectangle {
                        visible: !parent.isAmp && !(parent.isAntigravity && parent.isRemainingMode)
                        Layout.preferredWidth: 10
                        Layout.preferredHeight: 10
                        radius: 5
                        color: parent.displayColor
                    }
                    
                    // Amp plan indicator: free / MW / GW (credits identified by $ amount)
                    PlasmaComponents.Label {
                        visible: parent.ampShowPlanTag
                        text: parent.ampPlanTag
                        color: Kirigami.Theme.disabledTextColor
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        font.bold: true
                    }
                    
                    // Amp remaining % or $ credits — color by remaining quota
                    PlasmaComponents.Label {
                        text: parent.displayText
                        color: (parent.isAmp || (parent.isAntigravity && parent.isRemainingMode)) ? parent.displayColor : Kirigami.Theme.textColor
                        font.bold: true
                    }
                    
                    // Amp reset time next to amount
                    // e.g. "free 88% 4h" | "MW 100% 1mo" | "$175.38 (6d)" (credits: soonest sub/free reset)
                    PlasmaComponents.Label {
                        visible: parent.ampShowCountdown
                        text: {
                            var t = model.resetCompact || ""
                            if (!t) return ""
                            // Credits: parenthesize soonest subscription/free reset
                            if (model.activeIsCredits) return "(" + t + ")"
                            return t
                        }
                        color: model.hasActiveCountdown
                               ? getAmpTimeColor(model.resetMsLeft)
                               : Kirigami.Theme.disabledTextColor
                        font.bold: true
                    }
                    
                    // Free upcoming reset within 6h (green): "MW 44% 19d (2¼h)"
                    PlasmaComponents.Label {
                        visible: parent.ampShowFreeUpcoming
                        text: parent.ampFreeUpcomingText
                        color: Kirigami.Theme.positiveTextColor
                        font.bold: true
                    }
                }
            }
        }
    }

    // Full representation (popup)
    fullRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 16
        Layout.minimumHeight: Kirigami.Units.gridUnit * 20
        Layout.preferredWidth: Kirigami.Units.gridUnit * 18
        Layout.preferredHeight: Kirigami.Units.gridUnit * 24

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.mediumSpacing

            // Header
            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents.Label {
                    text: i18n.tr("AI Usage")
                    font.bold: true
                    font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 1.3
                }
                Item { Layout.fillWidth: true }
                PlasmaComponents.Label {
                    text: root.lastUpdate
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.disabledTextColor
                }
            }

            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Kirigami.Theme.disabledTextColor
                opacity: 0.3
            }

            // Providers List
            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: providersModel
                spacing: Kirigami.Units.largeSpacing

                delegate: ColumnLayout {
                    width: ListView.view.width
                    spacing: Kirigami.Units.smallSpacing

                    // Provider Header
                    RowLayout {
                        Layout.fillWidth: true
                        
                        Kirigami.Icon {
                            Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                            Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                            source: model.icon ? Qt.resolvedUrl("../icons/" + model.icon) : ""
                            visible: model.icon !== undefined
                        }
                        
                        PlasmaComponents.Label {
                            text: model.name
                            font.bold: true
                            font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 1.1
                        }
                        
                        Item { Layout.fillWidth: true }
                        
                        // Error message/status (right-aligned)
                        PlasmaComponents.Label {
                            visible: model.provider === "antigravity" && model.error && model.error !== ""
                            text: {
                                var msg = i18n.tr("Not Running")
                                if (model.lastCacheTime && model.lastCacheTime !== "") {
                                    msg += "\n" + i18n.tr("Last Updated at") + " " + model.lastCacheTime
                                }
                                return msg
                            }
                            color: Kirigami.Theme.negativeTextColor
                            font.italic: true
                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                            lineHeight: 0.9
                            horizontalAlignment: Text.AlignRight
                        }
                        
                        Rectangle {
                            visible: model.plan !== undefined
                            Layout.preferredWidth: planLabel.implicitWidth + Kirigami.Units.smallSpacing * 2
                            Layout.preferredHeight: planLabel.implicitHeight + Kirigami.Units.smallSpacing
                            radius: 3
                            color: Kirigami.Theme.highlightColor
                            PlasmaComponents.Label {
                                id: planLabel
                                anchors.centerIn: parent
                                text: model.plan || ""
                                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                color: Kirigami.Theme.highlightedTextColor
                            }
                        }
                    }

                    // Claude Specific UI
                    ColumnLayout {
                        visible: model.provider === "claude"
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        UsageBar {
                            label: i18n.tr("Session")
                            value: model.sessionUsage || 0
                            subtext: model.sessionReset ? i18n.tr("Resets:") + " " + model.sessionReset : ""
                        }
                        UsageBar {
                            label: i18n.tr("Weekly")
                            value: model.weeklyUsage || 0
                            subtext: model.weeklyReset ? i18n.tr("Resets:") + " " + model.weeklyReset : ""
                        }
                        
                        // Models
                        RowLayout {
                            visible: (model.sonnetUsage || 0) > 0 || (model.opusUsage || 0) > 0
                            Layout.fillWidth: true
                            PlasmaComponents.Label { text: "Sonnet: " + Math.round(model.sonnetUsage||0) + "%"; font.pixelSize: Kirigami.Theme.smallFont.pixelSize }
                            Item { Layout.fillWidth: true }
                            PlasmaComponents.Label { text: "Opus: " + Math.round(model.opusUsage||0) + "%"; font.pixelSize: Kirigami.Theme.smallFont.pixelSize }
                        }
                    }

                    // Antigravity Specific UI
                    ColumnLayout {
                        id: antigravityLayout
                        visible: model.provider === "antigravity"
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        
                        property var bucketsList: getBuckets(model.bucketsJson)
                        property bool isRemainingMode: model.isRemaining === true

                        Repeater {
                            model: antigravityLayout.bucketsList
                            delegate: UsageBar {
                                required property var modelData
                                required property int index
                                
                                property real bucketPercent: modelData.percent !== undefined ? modelData.percent : -1
                                
                                label: modelData.name || ("Bucket " + (index + 1))
                                value: bucketPercent !== -1 ? bucketPercent : 0
                                valueText: bucketPercent !== -1 ? (Math.round(bucketPercent) + "%") : "?%"
                                customColor: {
                                    if (antigravityLayout.isRemainingMode && bucketPercent > 50) return Kirigami.Theme.positiveTextColor
                                    if (antigravityLayout.isRemainingMode && bucketPercent > 20) return Kirigami.Theme.neutralTextColor
                                    if (antigravityLayout.isRemainingMode && bucketPercent !== -1) return Kirigami.Theme.negativeTextColor
                                    return Kirigami.Theme.disabledTextColor
                                }
                                subtext: {
                                    if (antigravityLayout.isRemainingMode && modelData.reset && modelData.reset !== "" && bucketPercent >= 0) {
                                        return formatResetTime(modelData.reset)
                                    }
                                    if (modelData.limit === "N/A") return ""
                                    return (modelData.used || 0) + "/" + (modelData.limit || 0)
                                }
                                tooltipSuffix: antigravityLayout.isRemainingMode ? i18n.tr("remaining") : i18n.tr("used")
                            }
                        }
                    }

                    // Amp Specific UI — one row per plan (Free / Megawatt / Gigawatt / Credits)
                    ColumnLayout {
                        id: ampLayout
                        visible: model.provider === "amp"
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        property var ampPlansList: getAmpPlans(model)
                        property string ampActiveName: model.activePlanName || ""

                        Repeater {
                            model: ampLayout.ampPlansList
                            delegate: ColumnLayout {
                                required property var modelData
                                required property int index
                                Layout.fillWidth: true
                                spacing: 2

                                property bool isCredits: modelData.kind === "credits"
                                property bool isActive: ampLayout.ampActiveName !== "" && modelData.name === ampLayout.ampActiveName
                                property real remPct: {
                                    if (isCredits) return 0
                                    if (modelData.remainingPercent !== undefined && modelData.remainingPercent >= 0)
                                        return modelData.remainingPercent
                                    if (modelData.remainingIsPercent !== false)
                                        return modelData.remaining || 0
                                    return 0
                                }
                                property string valueLabel: {
                                    if (isCredits)
                                        return "$" + Number(modelData.remaining || 0).toFixed(2)
                                    var agent
                                    if (modelData.remainingIsPercent === false)
                                        agent = "$" + Number(modelData.remaining || 0).toFixed(2)
                                    else if (modelData.otherRemaining >= 0)
                                        agent = Math.round(modelData.otherRemaining) + "%"
                                    else
                                        agent = Math.round(modelData.remaining || 0) + "%"
                                    // Dual pool: ⚡ agent + 🔮 orb percent (orb is popup-only)
                                    if (modelData.orbRemaining >= 0)
                                        return "⚡" + agent + " + 🔮" + Math.round(modelData.orbRemaining) + "%"
                                    return "⚡" + agent
                                }
                                property string resetText: modelData.resetCountdown || modelData.resetCompact || modelData.resetLabel || ""

                                // Credits: simple balance row (no progress bar)
                                RowLayout {
                                    visible: isCredits
                                    Layout.fillWidth: true
                                    PlasmaComponents.Label {
                                        text: (isActive ? "▶ " : "") + (modelData.name === "Credits" ? i18n.tr("Credit Balance:") : (modelData.name || i18n.tr("Credit Balance:")))
                                        font.bold: isActive
                                    }
                                    Item { Layout.fillWidth: true }
                                    PlasmaComponents.Label {
                                        text: valueLabel
                                        font.bold: true
                                        color: Kirigami.Theme.neutralTextColor
                                    }
                                }

                                // Free / subscription: remaining bar
                                UsageBar {
                                    visible: !isCredits
                                    label: (isActive ? "▶ " : "") + (modelData.name || ("Plan " + (index + 1)))
                                    value: remPct
                                    valueText: valueLabel
                                    customColor: {
                                        if (remPct > 50) return Kirigami.Theme.positiveTextColor
                                        if (remPct > 20) return Kirigami.Theme.neutralTextColor
                                        return Kirigami.Theme.negativeTextColor
                                    }
                                    subtext: {
                                        if (!resetText) return ""
                                        if (modelData.hasActiveCountdown && modelData.resetCountdown)
                                            return i18n.tr("Resets in:") + " " + modelData.resetCountdown
                                        return i18n.tr("Resets:") + " " + resetText
                                    }
                                    tooltipSuffix: i18n.tr("remaining")
                                    tooltipText: {
                                        var t = (modelData.name || "") + ": " + valueLabel + " " + i18n.tr("remaining")
                                        if (resetText) t += " (" + i18n.tr("Resets:") + " " + resetText + ")"
                                        return t
                                    }
                                }
                            }
                        }
                    }
                    
                    // Separator between items
                    Rectangle {
                        Layout.fillWidth: true
                        height: 1
                        color: Kirigami.Theme.disabledTextColor
                        opacity: 0.1
                        visible: index < providersModel.count - 1
                    }
                }
            }

            // Button row: HA button on left, Refresh on right
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                
                // Home Assistant Button
                Item {
                    id: haButtonContainer
                    width: refreshButton.height
                    height: refreshButton.height
                    
                    Rectangle {
                        id: haButton
                        anchors.fill: parent
                        radius: 4
                        color: haMouseArea.pressed ? Kirigami.Theme.highlightColor : (haMouseArea.containsMouse ? Kirigami.Theme.hoverColor : Kirigami.Theme.backgroundColor)
                        border.width: 2
                        border.color: {
                            if (!Plasmoid.configuration.haEnabled) 
                                return Kirigami.Theme.disabledTextColor
                            if (root.haPublishStatus === "success") 
                                return Kirigami.Theme.positiveTextColor
                            if (root.haPublishStatus === "error") 
                                return Kirigami.Theme.negativeTextColor
                            return Kirigami.Theme.disabledTextColor
                        }
                        
                        Kirigami.Icon {
                            anchors.centerIn: parent
                            width: Kirigami.Units.iconSizes.smallMedium
                            height: Kirigami.Units.iconSizes.smallMedium
                            source: Qt.resolvedUrl("../icons/home-assistant.svg")
                            color: Kirigami.Theme.textColor
                            isMask: true
                        }
                    }
                    
                    MouseArea {
                        id: haMouseArea
                        anchors.fill: parent
                        z: 100
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        
                        onClicked: {
                            console.log("HA Button clicked!")
                            root.haDialogVisible = true
                        }
                        
                        PlasmaComponents.ToolTip {
                            text: haButtonContainer.tooltipText
                            visible: haMouseArea.containsMouse
                        }
                    }
                    
                    property string tooltipText: {
                        var prefix = i18n.tr("Home Assistant") + ": "
                        if (!Plasmoid.configuration.haEnabled)
                            return prefix + i18n.tr("Publishing disabled")
                        if (root.haPublishStatus === "success")
                            return prefix + i18n.tr("Publishing enabled") + " - " + i18n.tr("Connection successful")
                        if (root.haPublishStatus === "error")
                            return prefix + i18n.tr("Publishing enabled") + " - " + i18n.tr("Connection failed")
                        return prefix + i18n.tr("Publishing enabled")
                    }
                }
                
                // JSON File Export Toggle Button
                Item {
                    id: jsonButtonContainer
                    width: refreshButton.height
                    height: refreshButton.height
                    
                    Rectangle {
                        id: jsonButton
                        anchors.fill: parent
                        radius: 4
                        color: jsonMouseArea.pressed ? Qt.darker(Kirigami.Theme.backgroundColor, 1.5) : (jsonMouseArea.containsMouse ? Qt.darker(Kirigami.Theme.backgroundColor, 1.3) : "#000000")
                        border.width: 2
                        border.color: {
                            if (!Plasmoid.configuration.jsonFileEnabled)
                                return Kirigami.Theme.disabledTextColor
                            if (root.jsonFilePublishStatus === "success")
                                return Kirigami.Theme.positiveTextColor
                            if (root.jsonFilePublishStatus === "error")
                                return Kirigami.Theme.negativeTextColor
                            return Kirigami.Theme.disabledTextColor
                        }
                        
                        Kirigami.Icon {
                            anchors.centerIn: parent
                            width: Kirigami.Units.iconSizes.smallMedium
                            height: Kirigami.Units.iconSizes.smallMedium
                            source: Qt.resolvedUrl("../icons/json-file.svg")
                            color: Plasmoid.configuration.jsonFileEnabled ? "#f5a623" : Kirigami.Theme.disabledTextColor
                            isMask: true
                        }
                    }
                    
                    MouseArea {
                        id: jsonMouseArea
                        anchors.fill: parent
                        z: 100
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        
                        onClicked: {
                            Plasmoid.configuration.jsonFileEnabled = !Plasmoid.configuration.jsonFileEnabled
                            if (Plasmoid.configuration.jsonFileEnabled) {
                                publishToJsonFile()
                            } else {
                                deleteJsonFile()
                            }
                        }
                        
                        PlasmaComponents.ToolTip {
                            text: jsonButtonContainer.tooltipText
                            visible: jsonMouseArea.containsMouse
                        }
                    }
                    
                    property string tooltipText: {
                        if (!Plasmoid.configuration.jsonFileEnabled)
                            return i18n.tr("JSON file export disabled")
                        return i18n.tr("JSON file export enabled") + " (~/.cache/ai-usage-status.json)"
                    }
                }
                
                Item { Layout.fillWidth: true }
                
                PlasmaComponents.Button {
                    id: refreshButton
                    icon.name: "view-refresh"
                    text: i18n.tr("Refresh")
                    onClicked: refresh()
                }
            }
        }
        
        // Home Assistant Configuration Dialog (overlay)
        Loader {
            id: haDialogLoader
            anchors.fill: parent
            z: 1000
            active: root.haDialogVisible
            sourceComponent: Component {
                Item {
                    id: dialogOverlay
                    anchors.fill: parent
                    
                    // Semi-transparent backdrop
                    Rectangle {
                        anchors.fill: parent
                        color: "#80000000"
                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.haDialogVisible = false
                        }
                    }
                    
                    // Dialog box
                    Rectangle {
                        id: dialogBox
                        anchors.centerIn: parent
                        width: Math.min(parent.width - Kirigami.Units.largeSpacing * 4, Kirigami.Units.gridUnit * 22)
                        height: dialogContent.implicitHeight + Kirigami.Units.largeSpacing * 2
                        radius: 8
                        color: Kirigami.Theme.backgroundColor
                        border.color: Kirigami.Theme.disabledTextColor
                        border.width: 1
                        
                        ColumnLayout {
                            id: dialogContent
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.largeSpacing
                            spacing: Kirigami.Units.mediumSpacing
                            
                            // Header
                            PlasmaComponents.Label {
                                text: i18n.tr("Configure Home Assistant")
                                font.bold: true
                                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 1.2
                            }
                            
                            Rectangle {
                                Layout.fillWidth: true
                                height: 1
                                color: Kirigami.Theme.disabledTextColor
                                opacity: 0.3
                            }
                            
                            // Toggle
                            RowLayout {
                                Layout.fillWidth: true
                                PlasmaComponents.Label {
                                    text: i18n.tr("Publish to Home Assistant")
                                }
                                Item { Layout.fillWidth: true }
                                PlasmaComponents.Switch {
                                    id: haDialogToggle
                                    checked: Plasmoid.configuration.haEnabled
                                    onCheckedChanged: Plasmoid.configuration.haEnabled = checked
                                }
                            }
                            
                            // Sensor URI
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                PlasmaComponents.Label {
                                    text: i18n.tr("Sensor URI")
                                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                }
                                PlasmaComponents.TextField {
                                    id: haDialogUri
                                    Layout.fillWidth: true
                                    text: Plasmoid.configuration.haSensorUri
                                    enabled: haDialogToggle.checked
                                    onTextChanged: Plasmoid.configuration.haSensorUri = text
                                    placeholderText: "http://homeassistant.local:8123/api/states/sensor.ai_usage_applet"
                                }
                            }
                            
                            // Access Token
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                PlasmaComponents.Label {
                                    text: i18n.tr("Access Token")
                                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                }
                                PlasmaComponents.TextField {
                                    id: haDialogToken
                                    Layout.fillWidth: true
                                    text: Plasmoid.configuration.haAccessToken
                                    enabled: haDialogToggle.checked
                                    onTextChanged: Plasmoid.configuration.haAccessToken = text
                                    echoMode: TextInput.Password
                                    placeholderText: "Long-lived access token"
                                }
                            }
                            
                            // Get Token link
                            PlasmaComponents.Label {
                                text: "<a href='https://my.home-assistant.io/redirect/profile_security/'>" + i18n.tr("Get Token") + "</a>"
                                textFormat: Text.RichText
                                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                onLinkActivated: function(link) { Qt.openUrlExternally(link) }
                                
                                MouseArea {
                                    anchors.fill: parent
                                    acceptedButtons: Qt.NoButton
                                    cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor
                                }
                            }
                            
                            Rectangle {
                                Layout.fillWidth: true
                                height: 1
                                color: Kirigami.Theme.disabledTextColor
                                opacity: 0.3
                            }
                            
                            // Buttons
                            RowLayout {
                                Layout.fillWidth: true
                                
                                PlasmaComponents.Button {
                                    text: i18n.tr("Test Connection")
                                    enabled: haDialogToggle.checked && haDialogUri.text && haDialogToken.text
                                    onClicked: {
                                        testResultIcon.visible = false
                                        publishToHomeAssistant()
                                        testResultTimer.start()
                                    }
                                }
                                
                                // Test result indicator
                                Kirigami.Icon {
                                    id: testResultIcon
                                    width: Kirigami.Units.iconSizes.small
                                    height: Kirigami.Units.iconSizes.small
                                    visible: false
                                    source: root.haPublishStatus === "success" ? "checkmark" : "dialog-error"
                                    color: root.haPublishStatus === "success" ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.negativeTextColor
                                }
                                
                                // Timer to show result then hide after 5 seconds
                                Timer {
                                    id: testResultTimer
                                    interval: 500  // Check every 500ms if result is ready
                                    repeat: true
                                    onTriggered: {
                                        if (root.haPublishStatus === "success" || root.haPublishStatus === "error") {
                                            testResultIcon.visible = true
                                            repeat = false
                                            hideResultTimer.start()
                                            stop()
                                        }
                                    }
                                }
                                
                                Timer {
                                    id: hideResultTimer
                                    interval: 5000
                                    onTriggered: {
                                        testResultIcon.visible = false
                                        testResultTimer.repeat = true
                                    }
                                }
                                
                                Item { Layout.fillWidth: true }
                                
                                PlasmaComponents.Button {
                                    text: i18n.tr("Cancel")
                                    onClicked: root.haDialogVisible = false
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    
    // Reusable Usage Bar Component
    component UsageBar : Item {
        property string label
        property real value
        property string subtext
        property string valueText: Math.round(value) + "%"
        property color customColor: "transparent"
        property string tooltipSuffix: i18n.tr("used")
        property string tooltipText: Math.round(value) + "% " + tooltipSuffix
        
        Layout.fillWidth: true
        implicitHeight: mainLayout.implicitHeight
        
        readonly property color effectiveColor: customColor != "transparent" ? customColor : getUsageColor(value)
        
        ColumnLayout {
            id: mainLayout
            anchors.fill: parent
            spacing: 2
            
            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents.Label { text: label; font.bold: true }
                Item { Layout.fillWidth: true }
                PlasmaComponents.Label { 
                    text: valueText
                    color: effectiveColor
                    font.bold: true
                }
            }
            Rectangle {
                Layout.fillWidth: true
                height: 8
                radius: 4
                color: Kirigami.Theme.backgroundColor
                border.color: Kirigami.Theme.disabledTextColor
                border.width: 1
                Rectangle {
                    width: parent.width * Math.min(value / 100, 1)
                    height: parent.height
                    radius: 4
                    color: effectiveColor
                }
            }
            PlasmaComponents.Label {
                visible: subtext !== ""
                text: subtext
                textFormat: Text.StyledText
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                color: Kirigami.Theme.disabledTextColor
            }
        }
    }

    Timer {
        id: refreshTimer
        // Amp usage lookups are limited (~60/hour). Never poll faster than 65s.
        interval: Math.max(65000, (Plasmoid.configuration.refreshInterval || 1) * 60000)
        running: true
        repeat: true
        onTriggered: loadCredentials()
    }

    function getUsageColor(percent) {
        if (percent < 50) return Kirigami.Theme.positiveTextColor
        if (percent < 80) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.negativeTextColor
    }

    Component.onCompleted: {
        loadCredentials()
    }

    Plasmoid.icon: "widget"
    
    // IMPORTANT: These plasmoid-level tooltip properties are handled by the Plasma shell
    // and appear offset from the widget. Do NOT replace with custom ToolTip components
    // that could block mouse clicks on the compact representation.
    toolTipMainText: i18n.tr("AI Usage")
    toolTipSubText: {
        var tooltips = []
        for (var i = 0; i < providersModel.count; i++) {
            var p = providersModel.get(i)
            if (p) {
                tooltips.push(p.name + ": " + getProviderTooltipText(p))
            }
        }
        return tooltips.length > 0 ? tooltips.join("\n") : ""
    }
}
