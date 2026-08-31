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

            headerActions: Component {
                Row {
                    spacing: Theme.spacingXS

                    // Pinning decides whether a channel is polled at all, so it
                    // belongs next to the conversation it acts on.
                    DankActionButton {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: slack.activeId !== ""
                        buttonSize: 28
                        iconName: (slack.activeConversation?.pinned ?? false) ? "keep" : "keep_off"
                        iconColor: (slack.activeConversation?.pinned ?? false) ? Theme.primary : Theme.surfaceVariantText
                        tooltipText: (slack.activeConversation?.pinned ?? false) ? "Stop watching" : "Watch for new messages"
                        onClicked: slack.togglePin(slack.activeId)
                    }

                    DankActionButton {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: slack.connected
                        buttonSize: 28
                        iconName: "open_in_new"
                        iconColor: Theme.surfaceVariantText
                        tooltipText: "Open in Slack"
                        onClicked: slack.openInSlack(slack.activeId)
                    }

                    // Only worth offering when a second identity is stored.
                    DankActionButton {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: slack.haveUserToken && slack.haveBotToken
                        buttonSize: 28
                        iconName: slack.botMode ? "smart_toy" : "person"
                        iconColor: Theme.surfaceVariantText
                        tooltipText: slack.botMode ? "Acting as the app - switch to you" : "Acting as you - switch to the app"
                        onClicked: slack.requestIdentity(slack.botMode ? "user" : "bot")
                    }

                    DankActionButton {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: slack.connected
                        buttonSize: 28
                        iconName: "refresh"
                        iconColor: Theme.surfaceVariantText
                        enabled: !slack.polling
                        tooltipText: slack.lastUpdate !== "" ? ("Refresh (last: " + slack.lastUpdate + ")") : "Refresh"
                        onClicked: slack.refreshAll()
                    }
                }
            }

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

                        StyledText {
                            anchors.centerIn: parent
                            text: slack.haveClientId && slack.haveClientSecret ? "Sign in with Slack" : "Save credentials"
                            color: Theme.primaryText
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Bold
                        }

                        StateLayer {
                            stateColor: Theme.primaryText
                            disabled: popout.clientId === "" || popout.clientSecret === "" || !slack.agentReady
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
                        color: Theme.surfaceContainerHigh

                        StyledText {
                            anchors.centerIn: parent
                            text: slack.signingIn ? "Waiting for Slack…" : "Sign in with stored credentials"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                        }

                        StateLayer {
                            disabled: slack.signingIn
                            onClicked: slack.signIn()
                        }
                    }
                }
            }

            Component {
                id: conversationView

                DankListView {
                    clip: true
                    spacing: Theme.spacingXS
                    model: slack.decorated

                    delegate: SlackConversationRow {
                        required property var modelData

                        width: ListView.view.width
                        conversation: modelData
                        avatarMap: slack.avatarMap
                        onActivated: slack.openConversation(modelData.id)
                        onPinToggled: slack.togglePin(modelData.id)
                    }
                }
            }

            Component {
                id: transcriptView

                Item {
                    id: transcriptRoot

                    // Anchored rather than stacked in a Column: the message
                    // list has to take the space the fixed rows leave, and a
                    // height derived from its own y in a positioner loops.

                        // Back to the conversation list, or out of a thread to
                        // the conversation it belongs to.
                        Item {
                            id: backRow
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.right: parent.right
                            height: 28

                            Row {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingXS

                                DankIcon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: "chevron_left"
                                    size: Theme.iconSizeSmall
                                    color: Theme.primary
                                }

                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: slack.threadTs !== "" ? "Thread" : "Conversations"
                                    color: Theme.primary
                                    font.pixelSize: Theme.fontSizeMedium
                                }
                            }

                            StateLayer {
                                onClicked: {
                                    if (slack.threadTs !== "")
                                        slack.closeThread();
                                    else
                                        slack.closeConversation();
                                }
                            }
                        }

                        // A public channel that has not been joined is listed
                        // for browsing, but Slack refuses its history.
                        Rectangle {
                            id: joinBanner
                            anchors.top: backRow.bottom
                            anchors.topMargin: visible ? Theme.spacingS : 0
                            anchors.left: parent.left
                            anchors.right: parent.right
                            visible: slack.activeNeedsJoin
                            height: visible ? 40 : 0
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh

                            Row {
                                anchors.centerIn: parent
                                spacing: Theme.spacingS

                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: slack.joining ? "Joining…" : "Join this channel to read it"
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                }

                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: joinText.implicitWidth + Theme.spacingM * 2
                                    height: 26
                                    radius: Theme.cornerRadius
                                    color: Theme.primary

                                    StyledText {
                                        id: joinText
                                        anchors.centerIn: parent
                                        text: "Join"
                                        color: Theme.primaryText
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Bold
                                    }

                                    StateLayer {
                                        stateColor: Theme.primaryText
                                        disabled: slack.joining
                                        onClicked: slack.joinConversation(slack.activeId)
                                    }
                                }
                            }
                        }

                        SlackMessageList {
                            anchors.top: joinBanner.bottom
                            anchors.topMargin: Theme.spacingS
                            anchors.bottom: composer.top
                            anchors.bottomMargin: Theme.spacingS
                            anchors.left: parent.left
                            anchors.right: parent.right
                            messages: slack.threadTs !== "" ? slack.threadMessages : slack.activeMessages
                            inThread: slack.threadTs !== ""
                            readCursor: slack.activeReadCursor
                            loading: slack.threadTs !== "" ? slack.threadLoading : slack.activeLoading
                            hasMore: slack.threadTs === "" && slack.activeHasMore
                            loadingOlder: slack.loadingOlder
                            customEmoji: slack.customEmoji
                            avatarMap: slack.avatarMap
                            unfurls: slack.unfurls
                            sessionKey: slack.activeId + "/" + slack.threadTs
                            emptyText: slack.activeNeedsJoin ? "Join the channel to read it" : "No messages yet"
                            onLoadOlderRequested: slack.loadOlder()
                            onThreadRequested: ts => slack.openThread(ts)
                            onReactionToggled: (ts, name, mine) => slack.toggleReaction(ts, name, mine)
                        }

                        Row {
                            id: composer
                            anchors.bottom: parent.bottom
                            anchors.left: parent.left
                            anchors.right: parent.right
                            height: 44
                            spacing: Theme.spacingS

                            DankTextField {
                                id: messageField
                                width: parent.width - sendButton.width - parent.spacing
                                placeholderText: slack.threadTs !== "" ? "Reply in thread" : ("Message " + (slack.activeConversation?.name || "Slack"))
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

                                DankIcon {
                                    anchors.centerIn: parent
                                    name: "send"
                                    color: Theme.primaryText
                                    size: Theme.iconSizeSmall
                                }

                                StateLayer {
                                    stateColor: Theme.primaryText
                                    disabled: messageField.text.trim() === "" || slack.sending
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
