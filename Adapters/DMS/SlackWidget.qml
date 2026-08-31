import QtQuick
import Quickshell
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "../../Core" as Core

PluginComponent {
    id: root

    layerNamespacePlugin: "slack-sidebar"
    popoutWidth: 520
    popoutHeight: 680

    readonly property var defaults: ({
        pollInterval: 45000,
        activePollInterval: 6000,
        syncInterval: 300000,
        historyLimit: 60,
        maxWatched: 24,
        notifyDms: true,
        notifyMentions: true,
        markReadOnOpen: true,
        linkPreviews: true,
        archiveMessages: true,
        pinned: [],
        identityUserId: "",
        tokenPreference: "auto"
    })

    Core.SlackState {
        id: slack

        platformAdapter: QtObject {
            readonly property var settings: root.pluginData || ({})
            readonly property var defaults: root.defaults
            readonly property string pluginDir: root.pluginService?.getPluginPath("slackSidebar") || "."
            readonly property string cacheDir: {
                const override = Quickshell.env("XDG_CACHE_HOME");
                return (override && override !== "" ? override : Quickshell.env("HOME") + "/.cache") + "/slack-sidebar";
            }
            // DMS does not currently expose PluginPopout visibility through
            // PluginComponent's public API. Keep active polling enabled while
            // this widget instance exists; switch to the public signal when
            // one is added upstream.
            readonly property bool panelVisible: true

            function setSetting(key, value) {
                root.pluginService?.savePluginData("slackSidebar", key, value);
            }
        }

        renderPalette: ({
            link: Theme.secondary,
            mention: Theme.secondary,
            mentionSelf: Theme.primary,
            code: Theme.tertiary,
            quote: Theme.surfaceVariantText,
            muted: Theme.surfaceVariantText
        })
        fixedFontFamily: "monospace"
        renderedEmojiSize: Theme.fontSizeLarge
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS

            DankIcon {
                name: "chat"
                color: slack.mentionCount > 0 ? Theme.error : (slack.totalUnread > 0 ? Theme.primary : Theme.surfaceVariantText)
                size: Theme.iconSizeSmall
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: slack.totalUnread > 0
                text: slack.totalUnread > 99 ? "99+" : String(slack.totalUnread)
                color: slack.mentionCount > 0 ? Theme.error : Theme.primary
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Bold
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DankIcon {
                name: "chat"
                color: slack.mentionCount > 0 ? Theme.error : (slack.totalUnread > 0 ? Theme.primary : Theme.surfaceVariantText)
                size: Theme.iconSizeSmall
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                visible: slack.totalUnread > 0
                text: slack.totalUnread > 99 ? "99+" : String(slack.totalUnread)
                color: slack.mentionCount > 0 ? Theme.error : Theme.primary
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Bold
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: slack.activeId === "" ? "Slack" : slack.activeConversation?.name || "Slack"
            detailsText: slack.lastError !== "" ? slack.lastError : (slack.connected ? (slack.teamName + " · " + slack.accountLabel) : "Not connected")
            showCloseButton: true

            property string clientId: ""
            property string clientSecret: ""

            Item {
                width: parent.width
                implicitHeight: root.popoutHeight - popout.headerHeight - popout.detailsHeight - Theme.spacingXL

                Loader {
                    anchors.fill: parent
                    // PopoutComponent gives its own header and details a
                    // spacingS gutter but adds none for plugin content, so
                    // without this the transcript sits flush on the edge.
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    sourceComponent: !slack.connected ? setupView : (slack.activeId === "" ? conversationView : transcriptView)
                }
            }

            Component {
                id: setupView

                Column {
                    spacing: Theme.spacingM

                    StyledText {
                        width: parent.width
                        text: slack.agentBuilding ? "Building slack-agent…" : "Connect your Slack app"
                        color: Theme.surfaceText
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.Bold
                    }

                    StyledText {
                        width: parent.width
                        text: "Credentials go directly to Secret Service through libsecret and are never saved in DMS settings."
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                        wrapMode: Text.WordWrap
                    }

                    DankTextField {
                        id: clientIdField
                        width: parent.width
                        placeholderText: "Slack Client ID"
                        onTextChanged: popout.clientId = text
                    }

                    DankTextField {
                        id: clientSecretField
                        width: parent.width
                        placeholderText: "Slack Client Secret"
                        echoMode: TextInput.Password
                        onTextChanged: popout.clientSecret = text
                    }

                    Rectangle {
                        width: parent.width
                        height: 44
                        radius: Theme.cornerRadius
                        color: Theme.primary
                        opacity: popout.clientId !== "" && popout.clientSecret !== "" && slack.agentReady ? 1 : 0.45

                        // Theme.primaryHover is a 12% tint meant to sit over a
                        // surface, not to replace a filled button's own colour.
                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: Theme.withAlpha(Theme.primaryText, connectArea.containsMouse ? 0.12 : 0)
                        }

                        StyledText {
                            anchors.centerIn: parent
                            text: slack.haveClientId && slack.haveClientSecret ? "Sign in with Slack" : "Save credentials"
                            color: Theme.primaryText
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Bold
                        }

                        MouseArea {
                            id: connectArea
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: popout.clientId !== "" && popout.clientSecret !== "" && slack.agentReady
                            onClicked: {
                                slack.storeCredentials(popout.clientId, popout.clientSecret);
                                clientIdField.text = "";
                                clientSecretField.text = "";
                                popout.clientId = "";
                                popout.clientSecret = "";
                            }
                        }
                    }

                    Rectangle {
                        visible: slack.canSignIn
                        width: parent.width
                        height: 44
                        radius: Theme.cornerRadius
                        color: signInArea.containsMouse ? Theme.primaryHover : Theme.surfaceContainerHigh

                        StyledText {
                            anchors.centerIn: parent
                            text: slack.signingIn ? "Waiting for Slack…" : "Sign in with stored credentials"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                        }

                        MouseArea {
                            id: signInArea
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: !slack.signingIn
                            onClicked: slack.signIn()
                        }
                    }
                }
            }

            Component {
                id: conversationView

                ListView {
                    clip: true
                    spacing: Theme.spacingXS
                    model: slack.decorated

                    delegate: Rectangle {
                        required property var modelData
                        width: ListView.view.width
                        height: 58
                        radius: Theme.cornerRadius
                        color: rowArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

                        Row {
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingM

                            DankIcon {
                                name: modelData.type === "im" ? "person" : "tag"
                                color: modelData.mention ? Theme.error : (modelData.unread > 0 ? Theme.primary : Theme.surfaceVariantText)
                                size: Theme.iconSizeSmall
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Column {
                                width: parent.width - 90
                                anchors.verticalCenter: parent.verticalCenter

                                StyledText {
                                    width: parent.width
                                    text: modelData.name
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: modelData.unread > 0 ? Font.Bold : Font.Normal
                                    elide: Text.ElideRight
                                }

                                StyledText {
                                    width: parent.width
                                    text: modelData.latest?.text || modelData.topic || ""
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                    elide: Text.ElideRight
                                }
                            }

                            StyledText {
                                visible: modelData.unread > 0
                                text: String(modelData.unread)
                                color: modelData.mention ? Theme.error : Theme.primary
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Bold
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        MouseArea {
                            id: rowArea
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: slack.openConversation(modelData.id)
                        }
                    }
                }
            }

            Component {
                id: transcriptView

                Column {
                    spacing: Theme.spacingS

                    Rectangle {
                        width: parent.width
                        height: 36
                        color: "transparent"

                        StyledText {
                            text: "‹  Conversations"
                            color: Theme.primary
                            font.pixelSize: Theme.fontSizeMedium
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: slack.closeConversation()
                        }
                    }

                    ListView {
                        width: parent.width
                        height: parent.height - composer.height - 48
                        clip: true
                        spacing: Theme.spacingM
                        model: slack.activeMessages
                        verticalLayoutDirection: ListView.BottomToTop

                        delegate: Column {
                            required property var modelData
                            width: ListView.view.width
                            spacing: Theme.spacingXS

                            StyledText {
                                width: parent.width
                                text: modelData.author || slack.userMap[modelData.user]?.realName || slack.userMap[modelData.user]?.name || "unknown"
                                color: modelData.mine ? Theme.primary : Theme.surfaceText
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Bold
                            }

                            StyledText {
                                width: parent.width
                                text: modelData.html || modelData.text || ""
                                textFormat: Text.RichText
                                // StyledText renders natively, and native
                                // rendering leaves a rich text document on its
                                // own default colour - black on a dark popout.
                                // Noctalia's NText flips the same switch behind
                                // its richTextEnabled flag.
                                renderType: Text.QtRendering
                                color: Theme.surfaceText
                                font.pixelSize: Theme.fontSizeMedium
                                wrapMode: Text.Wrap
                                // StyledText elides by default, which truncates
                                // a wrapped message instead of growing.
                                elide: Text.ElideNone
                                onLinkActivated: link => Qt.openUrlExternally(link)
                            }
                        }
                    }

                    Row {
                        id: composer
                        width: parent.width
                        height: 44
                        spacing: Theme.spacingS

                        DankTextField {
                            id: messageField
                            width: parent.width - sendButton.width - parent.spacing
                            placeholderText: "Message " + (slack.activeConversation?.name || "Slack")
                            onAccepted: {
                                if (slack.send(text))
                                    text = "";
                            }
                        }

                        Rectangle {
                            id: sendButton
                            width: 48
                            height: parent.height
                            radius: Theme.cornerRadius
                            color: Theme.primary
                            opacity: messageField.text.trim() !== "" && !slack.sending ? 1 : 0.45

                            Rectangle {
                                anchors.fill: parent
                                radius: parent.radius
                                color: Theme.withAlpha(Theme.primaryText, sendArea.containsMouse ? 0.12 : 0)
                            }

                            DankIcon {
                                anchors.centerIn: parent
                                name: "send"
                                color: Theme.primaryText
                                size: Theme.iconSizeSmall
                            }

                            MouseArea {
                                id: sendArea
                                anchors.fill: parent
                                hoverEnabled: true
                                enabled: messageField.text.trim() !== "" && !slack.sending
                                onClicked: {
                                    if (slack.send(messageField.text))
                                        messageField.text = "";
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
