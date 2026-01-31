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
                providersModel.append(ampProv)
            }

            // Process Antigravity
            var antigravityProv = Providers.parseAntigravityConfig(antigravityData)
            if (antigravityProv) {
                providersModel.append(antigravityProv)
            }
            
            if (providersModel.count === 0) {
                root.errorMsg = i18n.tr("No accounts found")
            } else {
                root.errorMsg = ""
            }
            
            root.lastUpdate = Qt.formatTime(new Date(), "hh:mm:ss")
            root.isLoading = false
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
                  "(amp usage 2>/dev/null || ~/.amp/bin/amp usage 2>/dev/null || cat $HOME/.amp/usage.json 2>/dev/null)"
        
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

    function getProviderTooltipText(provider) {
        if (!provider) return ""
        
        if (provider.provider === "amp") {
            return getAmpTooltipText(provider)
        }
        
        if (provider.provider === "antigravity") {
            var p1 = Math.round(provider.bucket1Percent || 0)
            var p2 = Math.round(provider.bucket2Percent || 0)
            var p3 = Math.round(provider.bucket3Percent || 0)
            var debug = " [Raw: " + provider.bucket1Percent + ", " + provider.bucket2Percent + ", " + provider.bucket3Percent + " | isRem: " + provider.isRemaining + "]"
            return provider.bucket1Name + ": " + p1 + "% | " + provider.bucket2Name + ": " + p2 + "% | " + provider.bucket3Name + ": " + p3 + "%" + debug
        }
        
        // Claude fallback
        return i18n.tr("Session (5hr)") + ": " + Math.round(provider.sessionUsage||0) + "% | " + i18n.tr("Weekly (7day)") + ": " + Math.round(provider.weeklyUsage||0) + "%"
    }

    function getAmpTooltipText(provider) {
        if (!provider) return ""
        var remainingPercent = provider.freeLimit > 0 ? ((provider.freeLimit - provider.freeUsed) / provider.freeLimit * 100) : 0
        var base = Math.round(remainingPercent) + "% " + i18n.tr("remaining")
        
        if (provider.rechargeRate > 0 && provider.freeUsed > 0) {
            var hours = provider.freeUsed / provider.rechargeRate
            var target = new Date(new Date().getTime() + hours * 3600000)
            var timeStr = Qt.formatTime(target, "h:mm ap").toLowerCase()
            return base + " (" + i18n.tr("used") + " $" + provider.freeUsed.toFixed(2) + "/$" + provider.rechargeRate.toFixed(2) + "/h -> " + Math.round(hours) + "h -> ~" + timeStr + ")"
        }
        return base
    }

    // Compact representation (panel)
    compactRepresentation: Item {
        Layout.minimumWidth: compactRow.implicitWidth + Kirigami.Units.largeSpacing * 2
        Layout.minimumHeight: Kirigami.Units.iconSizes.medium
        Layout.preferredWidth: compactRow.implicitWidth + Kirigami.Units.largeSpacing * 2

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
                    
                    property real displayValue: {
                        if (isAmp) {
                            if (model.freeLimit > 0 && model.freeUsed < model.freeLimit) {
                                return Math.floor(model.freeLimit - model.freeUsed)
                            } else {
                                return Math.floor(model.creditBalance || 0)
                            }
                        }
                        if (isAntigravity) return model.bucket1Percent || 0
                        return model.sessionUsage || 0
                    }
                    
                    property string displayText: {
                        if (isAmp) return "$" + displayValue
                        return Math.round(displayValue) + "%"
                    }
                    
                    property color displayColor: {
                        if (isAmp) {
                            if (model.freeLimit > 0 && model.freeUsed < model.freeLimit) {
                                return Kirigami.Theme.positiveTextColor
                            } else {
                                return Kirigami.Theme.neutralTextColor
                            }
                        }
                        if (isAntigravity && isRemainingMode) {
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
                    
                    PlasmaComponents.Label {
                        text: parent.displayText
                        color: (parent.isAmp || (parent.isAntigravity && parent.isRemainingMode)) ? parent.displayColor : Kirigami.Theme.textColor
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
                        visible: model.provider === "antigravity"
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        
                        // Error message if process not found
                        PlasmaComponents.Label {
                            visible: model.error !== undefined
                            text: i18n.tr("Antigravity needs to be running to gather model usage, please start it.")
                            color: Kirigami.Theme.neutralTextColor
                            font.italic: true
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                        }

                        ColumnLayout {
                            visible: model.error === undefined
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            UsageBar {
                                label: model.bucket1Name || "Small"
                                value: model.bucket1Percent || 0
                                customColor: (model.isRemaining && model.bucket1Percent > 50) ? Kirigami.Theme.positiveTextColor : ((model.isRemaining && model.bucket1Percent > 20) ? Kirigami.Theme.neutralTextColor : (model.isRemaining ? Kirigami.Theme.negativeTextColor : "transparent"))
                                subtext: (model.isRemaining && model.bucket1Reset) ? formatResetTime(model.bucket1Reset) : ((model.bucket1Limit === "N/A") ? "" : ((model.bucket1Used || 0) + "/" + (model.bucket1Limit || 0)))
                                tooltipSuffix: model.isRemaining ? i18n.tr("remaining") : i18n.tr("used")
                            }
                            UsageBar {
                                label: model.bucket2Name || "Medium"
                                value: model.bucket2Percent || 0
                                customColor: (model.isRemaining && model.bucket2Percent > 50) ? Kirigami.Theme.positiveTextColor : ((model.isRemaining && model.bucket2Percent > 20) ? Kirigami.Theme.neutralTextColor : (model.isRemaining ? Kirigami.Theme.negativeTextColor : "transparent"))
                                subtext: (model.isRemaining && model.bucket2Reset) ? formatResetTime(model.bucket2Reset) : ((model.bucket2Limit === "N/A") ? "" : ((model.bucket2Used || 0) + "/" + (model.bucket2Limit || 0)))
                                tooltipSuffix: model.isRemaining ? i18n.tr("remaining") : i18n.tr("used")
                            }
                            UsageBar {
                                label: model.bucket3Name || "Large"
                                value: model.bucket3Percent || 0
                                customColor: (model.isRemaining && model.bucket3Percent > 50) ? Kirigami.Theme.positiveTextColor : ((model.isRemaining && model.bucket3Percent > 20) ? Kirigami.Theme.neutralTextColor : (model.isRemaining ? Kirigami.Theme.negativeTextColor : "transparent"))
                                subtext: (model.isRemaining && model.bucket3Reset) ? formatResetTime(model.bucket3Reset) : ((model.bucket3Limit === "N/A") ? "" : ((model.bucket3Used || 0) + "/" + (model.bucket3Limit || 0)))
                                tooltipSuffix: model.isRemaining ? i18n.tr("remaining") : i18n.tr("used")
                            }
                            UsageBar {
                                visible: false // Hidden for now
                                label: model.bucket4Name || "Image"
                                value: model.bucket4Percent || 0
                                customColor: (model.isRemaining && model.bucket4Percent > 50) ? Kirigami.Theme.positiveTextColor : ((model.isRemaining && model.bucket4Percent > 20) ? Kirigami.Theme.neutralTextColor : (model.isRemaining ? Kirigami.Theme.negativeTextColor : "transparent"))
                                subtext: (model.isRemaining && model.bucket4Reset) ? formatResetTime(model.bucket4Reset) : ((model.bucket4Limit === "N/A") ? "" : ((model.bucket4Used || 0) + "/" + (model.bucket4Limit || 0)))
                                tooltipSuffix: model.isRemaining ? i18n.tr("remaining") : i18n.tr("used")
                            }
                        }
                    }

                    // Amp Specific UI
                    ColumnLayout {
                        visible: model.provider === "amp"
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        UsageBar {
                            label: i18n.tr("Free Quota")
                            property real remainingPercent: model.freeLimit > 0 ? ((model.freeLimit - model.freeUsed) / model.freeLimit * 100) : 0
                            value: remainingPercent
                            valueText: "$" + (model.freeLimit - model.freeUsed).toFixed(2) + "/$" + (model.freeLimit || 0).toFixed(2)
                            customColor: remainingPercent > 50 ? Kirigami.Theme.positiveTextColor : (remainingPercent > 20 ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.negativeTextColor)
                            subtext: model.freeResets ? i18n.tr("Replenishes:") + " " + model.freeResets : ""
                            
                            tooltipText: getAmpTooltipText(model)
                        }
                        
                        RowLayout {
                            Layout.fillWidth: true
                            PlasmaComponents.Label {
                                text: i18n.tr("Credit Balance:")
                            }
                            Item { Layout.fillWidth: true }
                            PlasmaComponents.Label {
                                text: "$" + (model.creditBalance || 0).toFixed(2)
                                font.bold: true
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

            PlasmaComponents.Button {
                Layout.alignment: Qt.AlignRight
                icon.name: "view-refresh"
                text: i18n.tr("Refresh")
                onClicked: refresh()
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
        
        MouseArea {
            id: hoverArea
            anchors.fill: parent
            hoverEnabled: true
        }
        
        PlasmaComponents.ToolTip.visible: hoverArea.containsMouse
        PlasmaComponents.ToolTip.text: tooltipText
    }

    Timer {
        id: refreshTimer
        interval: (Plasmoid.configuration.refreshInterval || 1) * 60000
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