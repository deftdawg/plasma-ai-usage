/*
    SPDX-FileCopyrightText: 2025 izll
    SPDX-License-Identifier: GPL-3.0-or-later
*/

import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: configPage

    property string cfg_language
    property int cfg_refreshInterval
    property bool cfg_haEnabled
    property string cfg_haSensorUri
    property string cfg_haAccessToken

    // Translation helper
    Translations {
        id: trans
        currentLanguage: cfg_language || "system"
    }

    function tr(text) { return trans.tr(text); }

    readonly property var languageValues: [
        "system", "en_US", "hu_HU", "de_DE", "fr_FR", "es_ES",
        "it_IT", "pt_BR", "ru_RU", "pl_PL", "nl_NL", "tr_TR",
        "ja_JP", "ko_KR", "zh_CN", "zh_TW"
    ]

    readonly property var languageNames: [
        tr("System default"), "English", "Magyar", "Deutsch",
        "Français", "Español", "Italiano", "Português (Brasil)",
        "Русский", "Polski", "Nederlands", "Türkçe",
        "日本語", "한국어", "简体中文", "繁體中文"
    ]

    Kirigami.FormLayout {
        QQC2.ComboBox {
            id: languageCombo
            Kirigami.FormData.label: tr("Language:")

            model: languageNames
            currentIndex: languageValues.indexOf(cfg_language)

            onActivated: index => {
                cfg_language = languageValues[index]
            }
        }

        RowLayout {
            Kirigami.FormData.label: tr("Refresh interval:")

            QQC2.SpinBox {
                id: refreshSpinBox
                from: 1
                to: 999
                stepSize: 1
                value: cfg_refreshInterval

                onValueChanged: {
                    cfg_refreshInterval = value
                }
            }

            QQC2.Label {
                text: tr("minutes")
            }
        }

        // Home Assistant Section
        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: tr("Home Assistant")
        }

        QQC2.Switch {
            id: haEnabledSwitch
            Kirigami.FormData.label: tr("Publish to Home Assistant")
            checked: cfg_haEnabled
            onCheckedChanged: cfg_haEnabled = checked
        }

        QQC2.TextField {
            id: haSensorUriField
            Kirigami.FormData.label: tr("Sensor URI")
            Layout.fillWidth: true
            enabled: haEnabledSwitch.checked
            text: cfg_haSensorUri
            onTextChanged: cfg_haSensorUri = text
            placeholderText: "http://homeassistant.local:8123/api/states/sensor.ai_usage_applet"
        }

        QQC2.TextField {
            id: haAccessTokenField
            Kirigami.FormData.label: tr("Access Token")
            Layout.fillWidth: true
            enabled: haEnabledSwitch.checked
            text: cfg_haAccessToken
            onTextChanged: cfg_haAccessToken = text
            echoMode: TextInput.Password
            placeholderText: tr("Long-lived access token")
        }

        RowLayout {
            Kirigami.FormData.label: " "
            
            QQC2.Label {
                text: "<a href='https://my.home-assistant.io/redirect/profile_security/'>" + tr("Get Token") + "</a>"
                textFormat: Text.RichText
                onLinkActivated: function(link) { Qt.openUrlExternally(link) }
                
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor
                }
            }
        }
    }
}
