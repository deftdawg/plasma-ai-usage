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

            // Process Antigravity
            var antigravityProv = Providers.parseAntigravityConfig(antigravityData)
            if (antigravityProv) {
                providersModel.append(antigravityProv)
            }

            // Process Amp
            var ampProv = Providers.parseAmpConfig(ampData)
            if (ampProv) {
                providersModel.append(ampProv)
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
        var cmd = "cat $HOME/.claude/.credentials.json 2>/dev/null; " + 
                  "echo '___SEP___'; " +
                  "cat $HOME/.antigravity/usage.json 2>/dev/null; " + 
                  "echo '___SEP___'; " +
                  "(amp usage 2>/dev/null || cat $HOME/.amp/usage.json 2>/dev/null)"
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

    // Compact representation (panel)
    compactRepresentation: Item {
        Layout.minimumWidth: usageRow.implicitWidth + Kirigami.Units.largeSpacing * 2
        Layout.minimumHeight: Kirigami.Units.iconSizes.medium
        Layout.preferredWidth: usageRow.implicitWidth + Kirigami.Units.largeSpacing * 2

        MouseArea {
            anchors.fill: parent
            onClicked: root.expanded = !root.expanded
        }

        RowLayout {
            id: usageRow
            anchors.centerIn: parent
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                source: Qt.resolvedUrl("../icons/claude.svg") // Keep claude icon or make generic
            }

            // Show summary of first provider or error
            PlasmaComponents.Label {
                visible: root.errorMsg !== ""
                text: "⚠"
                color: Kirigami.Theme.negativeTextColor
            }

            // If we have providers, show the first one's primary stat
            RowLayout {
                visible: root.errorMsg === "" && providersModel.count > 0
                spacing: Kirigami.Units.smallSpacing
                
                property var firstProvider: providersModel.count > 0 ? providersModel.get(0) : null
                property real displayUsage: {
                    if (!firstProvider) return 0
                    if (firstProvider.provider === "claude") return firstProvider.sessionUsage || 0
                    if (firstProvider.provider === "antigravity") return firstProvider.bucket1Percent || 0
                    if (firstProvider.provider === "amp") return firstProvider.freePercent || 0
                    return 0
                }
                
                Rectangle {
                    Layout.preferredWidth: 10
                    Layout.preferredHeight: 10
                    radius: 5
                    color: getUsageColor(parent.displayUsage)
                }
                PlasmaComponents.Label {
                    text: Math.round(parent.displayUsage) + "%"
                    font.bold: true
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
                        
                        UsageBar {
                            label: model.bucket1Name || "Small"
                            value: model.bucket1Percent || 0
                            subtext: (model.bucket1Used || 0) + "/" + (model.bucket1Limit || 0)
                        }
                        UsageBar {
                            label: model.bucket2Name || "Medium"
                            value: model.bucket2Percent || 0
                            subtext: (model.bucket2Used || 0) + "/" + (model.bucket2Limit || 0)
                        }
                        UsageBar {
                            label: model.bucket3Name || "Large"
                            value: model.bucket3Percent || 0
                            subtext: (model.bucket3Used || 0) + "/" + (model.bucket3Limit || 0)
                        }
                    }

                    // Amp Specific UI
                    ColumnLayout {
                        visible: model.provider === "amp"
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        UsageBar {
                            label: i18n.tr("Free Quota")
                            value: model.freePercent || 0
                            subtext: "$" + (model.freeUsed || 0).toFixed(2) + "/$" + (model.freeLimit || 0).toFixed(2)
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
    component UsageBar : ColumnLayout {
        property string label
        property real value
        property string subtext
        
        spacing: 2
        Layout.fillWidth: true
        
        RowLayout {
            Layout.fillWidth: true
            PlasmaComponents.Label { text: label; font.bold: true }
            Item { Layout.fillWidth: true }
            PlasmaComponents.Label { 
                text: Math.round(value) + "%"
                color: getUsageColor(value)
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
                color: getUsageColor(value)
            }
        }
        PlasmaComponents.Label {
            visible: subtext !== ""
            text: subtext
            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            color: Kirigami.Theme.disabledTextColor
        }
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

    Plasmoid.icon: "claude-usage"
    toolTipMainText: i18n.tr("AI Usage")
}