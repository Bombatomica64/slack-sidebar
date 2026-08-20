import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Widgets
import "Components" as Slack

/**
 * Full-height sidebar: conversation picker slides aside to reveal the
 * transcript, with the composer pinned to the bottom.
 */
Item {
    id: root

    property var pluginApi: null
    readonly property var main: pluginApi?.mainInstance

    // ---- consumed by PluginPanelSlot / SmartPanel -------------------------
    readonly property bool allowAttach: true
    readonly property string side: main?.sidePref ?? "right"
    readonly property bool panelAnchorRight: side !== "left"
    readonly property bool panelAnchorLeft: side === "left"
    readonly property bool panelAnchorVerticalCenter: true
    // Deliberately larger than any screen: SmartPanel clamps this to the space
    // actually available, which is how the panel becomes full height.
    readonly property real contentPreferredHeight: 100000
    readonly property real contentPreferredWidth: (main?.panelWidthPref ?? 460) * Style.uiScaleRatio
    // ----------------------------------------------------------------------

    readonly property bool inChat: (main?.activeId ?? "") !== ""
    readonly property var activeConv: main?.activeConversation ?? null
    readonly property bool inThread: (main?.threadTs ?? "") !== ""

    anchors.fill: parent

    function iconFor(type) {
        if (type === "channel")
            return "hash";
        if (type === "private")
            return "lock";
        if (type === "mpim")
            return "users";
        return "user";
    }

    function copyToClipboard(text) {
        if (!text)
            return;
        // Passed as an argv element rather than interpolated into the script,
        // so message text can contain anything at all.
        Quickshell.execDetached(["sh", "-c", 'printf %s "$1" | wl-copy', "sh", text]);
    }

    NContextMenu {
        id: accountMenu
        constrainTo: root
        model: [
            {
                label: "My account",
                icon: "user",
                action: "user",
                enabled: main?.haveUserToken ?? false
            },
            {
                label: "The app",
                icon: "robot",
                action: "bot",
                enabled: main?.haveBotToken ?? false
            },
            {
                label: (main?.signingIn ?? false) ? "Waiting for Slack…" : ((main?.haveUserToken ?? false) ? "Sign in again…" : "Sign in with Slack…"),
                icon: "key",
                action: "signin",
                enabled: (main?.canSignIn ?? false) && !(main?.signingIn ?? false)
            }
        ]
        onTriggered: action => {
            if (action === "signin")
                main.signIn();
            else
                main.requestIdentity(action);
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.marginM
        spacing: Style.marginS

        // ------------------------------------------------------ header

        RowLayout {
            Layout.fillWidth: true
            spacing: Style.marginS

            NIconButton {
                visible: root.inChat
                icon: "arrow-left"
                baseSize: 26
                border.width: 0
                colorBg: "transparent"
                colorBgHover: Color.mHover
                colorFg: Color.mOnSurface
                tooltipText: "All conversations"
                onClicked: {
                    if (root.inThread)
                        main.closeThread();
                    else
                        main.closeConversation();
                }
            }

            NIcon {
                visible: !root.inChat
                icon: "brand-slack"
                color: (main?.totalUnread ?? 0) > 0 ? Color.mPrimary : Color.mOnSurfaceVariant
                pointSize: Style.fontSizeXL
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.marginXS

                    NIcon {
                        visible: root.inChat && root.activeConv !== null
                        icon: root.activeConv ? root.iconFor(root.activeConv.type) : "hash"
                        color: Color.mOnSurfaceVariant
                        pointSize: Style.fontSizeS
                    }

                    NText {
                        Layout.fillWidth: true
                        text: {
                            if (root.inThread)
                                return "Thread";
                            if (root.inChat)
                                return root.activeConv ? root.activeConv.name : main.activeId;
                            return main?.teamName !== "" ? main.teamName : "Slack";
                        }
                        color: Color.mOnSurface
                        font.weight: Style.fontWeightBold
                        pointSize: Style.fontSizeL
                        elide: Text.ElideRight
                    }
                }

                NText {
                    Layout.fillWidth: true
                    text: {
                        if (!main)
                            return "";
                        if (main.lastError !== "")
                            return main.lastError;
                        if (main.signingIn)
                            return "Approve the sign-in in your browser…";
                        if (!root.inChat && !main.haveUserToken && !main.canSignIn)
                            return "Add the app's Client ID and Secret in settings to sign in as yourself";
                        // Worth one line in the header: a token that works now but
                        // will expire unrenewably is otherwise silent until it dies.
                        if (!root.inChat && main.userTokenHint !== "")
                            return main.userTokenHint;
                        if (root.inThread)
                            return root.activeConv ? ("in " + root.activeConv.name) : "";
                        if (root.inChat)
                            return root.activeConv && root.activeConv.topic !== "" ? root.activeConv.topic : (main.meName !== "" ? ("you are " + main.meName) : "");
                        if (main.totalUnread > 0)
                            return main.totalUnread + " unread" + (main.mentionCount > 0 ? (" · " + main.mentionCount + " with mentions") : "");
                        return main.connected ? "All caught up" : "Not connected";
                    }
                    color: {
                        if ((main?.lastError ?? "") !== "")
                            return Color.mError;
                        if (main?.signingIn ?? false)
                            return Color.mSecondary;
                        if (!root.inChat && (main?.userTokenHint ?? "") !== "")
                            return Color.mTertiary;
                        return Color.mOnSurfaceVariant;
                    }
                    pointSize: Style.fontSizeXXS
                    elide: Text.ElideRight
                }
            }

            // Account chip: who we are acting as, and the way to change it.
            Rectangle {
                id: accountChip

                readonly property color accent: {
                    if (!main || !main.connected)
                        return Color.mError;
                    return main.botMode ? Color.mTertiary : Color.mPrimary;
                }

                Layout.alignment: Qt.AlignVCenter
                implicitWidth: accountRow.implicitWidth + Style.marginM
                implicitHeight: accountRow.implicitHeight + Style.marginXS
                radius: height / 2
                color: chipHover.hovered ? Color.mHover : Qt.alpha(accountChip.accent, 0.14)
                border.width: Style.borderS
                border.color: Qt.alpha(accountChip.accent, 0.5)

                Behavior on color {
                    ColorAnimation {
                        duration: Style.animationFast
                    }
                }

                HoverHandler {
                    id: chipHover
                    cursorShape: Qt.PointingHandCursor
                }

                RowLayout {
                    id: accountRow
                    anchors.centerIn: parent
                    spacing: Style.marginXXS

                    NIcon {
                        icon: (main?.botMode ?? false) ? "robot" : "user"
                        color: chipHover.hovered ? Color.mOnHover : accountChip.accent
                        pointSize: Style.fontSizeXS
                    }

                    NText {
                        text: main?.accountLabel ?? ""
                        color: chipHover.hovered ? Color.mOnHover : accountChip.accent
                        pointSize: Style.fontSizeXXS
                        font.weight: Style.fontWeightSemiBold
                    }

                    NIcon {
                        icon: "chevron-right"
                        color: chipHover.hovered ? Color.mOnHover : accountChip.accent
                        pointSize: Style.fontSizeXXS
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: accountMenu.openAtItem(accountChip, accountChip.width / 2, accountChip.height)
                }
            }

            NIconButton {
                visible: root.inChat
                icon: (root.activeConv?.pinned ?? false) ? "pinned-filled" : "pinned"
                baseSize: 26
                border.width: 0
                colorBg: "transparent"
                colorBgHover: Color.mHover
                colorFg: (root.activeConv?.pinned ?? false) ? Color.mPrimary : Color.mOnSurfaceVariant
                tooltipText: (root.activeConv?.pinned ?? false) ? "Stop watching" : "Watch for new messages"
                onClicked: main.togglePin(main.activeId)
            }

            NIconButton {
                icon: "external-link"
                baseSize: 26
                border.width: 0
                colorBg: "transparent"
                colorBgHover: Color.mHover
                colorFg: Color.mOnSurfaceVariant
                tooltipText: "Open in Slack"
                onClicked: main.openInSlack(main.activeId)
            }

            NIconButton {
                icon: "refresh"
                baseSize: 26
                border.width: 0
                colorBg: "transparent"
                colorBgHover: Color.mHover
                colorFg: Color.mOnSurfaceVariant
                enabled: !(main?.polling ?? false)
                tooltipText: (main?.lastUpdate ?? "") !== "" ? ("Refresh (last: " + main.lastUpdate + ")") : "Refresh"
                onClicked: main.refreshAll()
            }
        }

        NDivider {
            Layout.fillWidth: true
        }

        // -------------------------------------------------- sliding views

        Item {
            id: stack
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            // Conversation picker
            Item {
                id: pickerView
                width: stack.width
                height: stack.height
                x: root.inChat ? -stack.width * 0.2 : 0
                opacity: root.inChat ? 0 : 1
                visible: opacity > 0.01

                Behavior on x {
                    NumberAnimation {
                        duration: Style.animationNormal
                        easing.type: Easing.OutCubic
                    }
                }

                Behavior on opacity {
                    NumberAnimation {
                        duration: Style.animationFast
                    }
                }

                Slack.ConversationList {
                    anchors.fill: parent
                    conversations: main?.decorated ?? []
                    users: main?.userMap ?? ({})
                    activeId: main?.activeId ?? ""
                    botMode: main?.botMode ?? false
                    onConversationPicked: id => main.openConversation(id)
                    onPinToggled: id => main.togglePin(id)
                }
            }

            // Transcript + composer
            Item {
                id: chatView
                width: stack.width
                height: stack.height
                x: root.inChat ? 0 : stack.width * 0.2
                opacity: root.inChat ? 1 : 0
                visible: opacity > 0.01

                Behavior on x {
                    NumberAnimation {
                        duration: Style.animationNormal
                        easing.type: Easing.OutCubic
                    }
                }

                Behavior on opacity {
                    NumberAnimation {
                        duration: Style.animationFast
                    }
                }

                ColumnLayout {
                    anchors.fill: parent
                    spacing: Style.marginXS

                    Slack.MessageList {
                        id: transcript
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        messages: root.inThread ? (main?.threadMessages ?? []) : (main?.activeMessages ?? [])
                        users: main?.userMap ?? ({})
                        customEmoji: main?.customEmoji ?? ({})
                        avatarMap: main?.avatarMap ?? ({})
                        meId: main?.meId ?? ""
                        readCursor: root.inThread ? "" : (main?.activeReadCursor ?? "")
                        inThread: root.inThread
                        loading: root.inThread ? (main?.threadLoading ?? false) : (main?.activeLoading ?? false)
                        emptyText: {
                            if (root.inThread)
                                return "No replies yet";
                            if (main?.activeNeedsJoin ?? false)
                                return "Join this channel to read it";
                            return "No messages in this conversation yet";
                        }
                        onThreadRequested: ts => main.openThread(ts)
                        onReactionToggled: (ts, name, mine) => main.toggleReaction(ts, name, mine)
                        onCopyRequested: text => root.copyToClipboard(text)
                    }

                    // Public channel you are not in yet: joining is visible to
                    // the channel, so it is an explicit button, never implicit.
                    Rectangle {
                        Layout.fillWidth: true
                        visible: main?.activeNeedsJoin ?? false
                        implicitHeight: joinCol.implicitHeight + Style.margin2M
                        radius: Style.radiusM
                        color: Color.mSurfaceVariant
                        border.color: Color.mOutline
                        border.width: Style.borderS

                        ColumnLayout {
                            id: joinCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Style.marginM
                            anchors.rightMargin: Style.marginM
                            spacing: Style.marginS

                            NText {
                                Layout.fillWidth: true
                                text: (main?.botMode ?? false) ? "This app has not joined this channel yet. Slack won't return its history until it does — and joining shows up in the channel." : "You are not in this channel yet. Join to read and post."
                                color: Color.mOnSurfaceVariant
                                pointSize: Style.fontSizeXS
                                wrapMode: Text.WordWrap
                            }

                            NButton {
                                Layout.alignment: Qt.AlignLeft
                                icon: (main?.joining ?? false) ? "loader-2" : "plus"
                                text: (main?.joining ?? false) ? "Joining…" : ((main?.botMode ?? false) ? "Join as app" : "Join channel")
                                enabled: !(main?.joining ?? false)
                                onClicked: main.joinConversation(main.activeId)
                            }
                        }
                    }

                    Slack.Composer {
                        id: composer
                        visible: !(main?.activeNeedsJoin ?? false)
                        Layout.fillWidth: true
                        busy: main?.sending ?? false
                        errorText: main?.sendError ?? ""
                        placeholder: {
                            if (root.inThread)
                                return "Reply in thread";
                            if (!root.activeConv)
                                return "Message";
                            return "Message " + (root.activeConv.type === "im" ? root.activeConv.name : "#" + root.activeConv.name);
                        }
                        onSubmitted: text => {
                            transcript.stickToLatest = true;
                            main.send(text);
                        }
                    }
                }
            }
        }
    }

    // Give the composer focus when a conversation opens, and the search field
    // when we come back out to the list.
    onInChatChanged: {
        if (root.inChat)
            Qt.callLater(composer.focusInput);
    }
}
