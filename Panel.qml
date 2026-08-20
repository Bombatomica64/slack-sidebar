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
    readonly property string side: root.main?.sidePref ?? "right"
    readonly property bool panelAnchorRight: side !== "left"
    readonly property bool panelAnchorLeft: side === "left"
    readonly property bool panelAnchorVerticalCenter: true
    // Deliberately larger than any screen: SmartPanel clamps this to the space
    // actually available, which is how the panel becomes full height.
    readonly property real contentPreferredHeight: 100000
    readonly property real contentPreferredWidth: (root.main?.panelWidthPref ?? 460) * Style.uiScaleRatio
    // ----------------------------------------------------------------------

    readonly property bool inChat: (root.main?.activeId ?? "") !== ""
    readonly property var activeConv: root.main?.activeConversation ?? null
    readonly property bool inThread: (root.main?.threadTs ?? "") !== ""

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
                enabled: root.main?.haveUserToken ?? false
            },
            {
                label: "The app",
                icon: "robot",
                action: "bot",
                enabled: root.main?.haveBotToken ?? false
            },
            {
                label: (root.main?.signingIn ?? false) ? "Waiting for Slack…" : ((root.main?.haveUserToken ?? false) ? "Sign in again…" : "Sign in with Slack…"),
                icon: "key",
                action: "signin",
                enabled: (root.main?.canSignIn ?? false) && !(root.main?.signingIn ?? false)
            }
        ]
        onTriggered: action => {
            if (action === "signin")
                root.main.signIn();
            else
                root.main.requestIdentity(action);
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
                        root.main.closeThread();
                    else
                        root.main.closeConversation();
                }
            }

            NIcon {
                visible: !root.inChat
                icon: "brand-slack"
                color: (root.main?.totalUnread ?? 0) > 0 ? Color.mPrimary : Color.mOnSurfaceVariant
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
                                return root.activeConv ? root.activeConv.name : root.main.activeId;
                            return root.main?.teamName !== "" ? root.main.teamName : "Slack";
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
                        if (!root.main)
                            return "";
                        if (root.main.lastError !== "")
                            return root.main.lastError;
                        if (root.main.signingIn)
                            return "Approve the sign-in in your browser…";
                        if (!root.inChat && !root.main.haveUserToken && !root.main.canSignIn)
                            return "Add the app's Client ID and Secret in settings to sign in as yourself";
                        // Worth one line in the header: a token that works now but
                        // will expire unrenewably is otherwise silent until it dies.
                        if (!root.inChat && root.main.userTokenHint !== "")
                            return root.main.userTokenHint;
                        if (root.inThread)
                            return root.activeConv ? ("in " + root.activeConv.name) : "";
                        if (root.inChat)
                            return root.activeConv && root.activeConv.topic !== "" ? root.activeConv.topic : (root.main.meName !== "" ? ("you are " + root.main.meName) : "");
                        if (root.main.totalUnread > 0)
                            return root.main.totalUnread + " unread" + (root.main.mentionCount > 0 ? (" · " + root.main.mentionCount + " with mentions") : "");
                        return root.main.connected ? "All caught up" : "Not connected";
                    }
                    color: {
                        if ((root.main?.lastError ?? "") !== "")
                            return Color.mError;
                        if (root.main?.signingIn ?? false)
                            return Color.mSecondary;
                        if (!root.inChat && (root.main?.userTokenHint ?? "") !== "")
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
                    if (!root.main || !root.main.connected)
                        return Color.mError;
                    return root.main.botMode ? Color.mTertiary : Color.mPrimary;
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
                        icon: (root.main?.botMode ?? false) ? "robot" : "user"
                        color: chipHover.hovered ? Color.mOnHover : accountChip.accent
                        pointSize: Style.fontSizeXS
                    }

                    NText {
                        text: root.main?.accountLabel ?? ""
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
                onClicked: root.main.togglePin(root.main.activeId)
            }

            NIconButton {
                icon: "external-link"
                baseSize: 26
                border.width: 0
                colorBg: "transparent"
                colorBgHover: Color.mHover
                colorFg: Color.mOnSurfaceVariant
                tooltipText: "Open in Slack"
                onClicked: root.main.openInSlack(root.main.activeId)
            }

            NIconButton {
                icon: "refresh"
                baseSize: 26
                border.width: 0
                colorBg: "transparent"
                colorBgHover: Color.mHover
                colorFg: Color.mOnSurfaceVariant
                enabled: !(root.main?.polling ?? false)
                tooltipText: (root.main?.lastUpdate ?? "") !== "" ? ("Refresh (last: " + root.main.lastUpdate + ")") : "Refresh"
                onClicked: root.main.refreshAll()
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
                    conversations: root.main?.decorated ?? []
                    users: root.main?.userMap ?? ({})
                    activeId: root.main?.activeId ?? ""
                    botMode: root.main?.botMode ?? false
                    onConversationPicked: id => root.main.openConversation(id)
                    onPinToggled: id => root.main.togglePin(id)
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
                        messages: root.inThread ? (root.main?.threadMessages ?? []) : (root.main?.activeMessages ?? [])
                        users: root.main?.userMap ?? ({})
                        customEmoji: root.main?.customEmoji ?? ({})
                        avatarMap: root.main?.avatarMap ?? ({})
                        meId: root.main?.meId ?? ""
                        readCursor: root.inThread ? "" : (root.main?.activeReadCursor ?? "")
                        inThread: root.inThread
                        loading: root.inThread ? (root.main?.threadLoading ?? false) : (root.main?.activeLoading ?? false)
                        emptyText: {
                            if (root.inThread)
                                return "No replies yet";
                            if (root.main?.activeNeedsJoin ?? false)
                                return "Join this channel to read it";
                            return "No messages in this conversation yet";
                        }
                        onThreadRequested: ts => root.main.openThread(ts)
                        onReactionToggled: (ts, name, mine) => root.main.toggleReaction(ts, name, mine)
                        onCopyRequested: text => root.copyToClipboard(text)
                    }

                    // Public channel you are not in yet: joining is visible to
                    // the channel, so it is an explicit button, never implicit.
                    Rectangle {
                        Layout.fillWidth: true
                        visible: root.main?.activeNeedsJoin ?? false
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
                                text: (root.main?.botMode ?? false) ? "This app has not joined this channel yet. Slack won't return its history until it does — and joining shows up in the channel." : "You are not in this channel yet. Join to read and post."
                                color: Color.mOnSurfaceVariant
                                pointSize: Style.fontSizeXS
                                wrapMode: Text.WordWrap
                            }

                            NButton {
                                Layout.alignment: Qt.AlignLeft
                                icon: (root.main?.joining ?? false) ? "loader-2" : "plus"
                                text: (root.main?.joining ?? false) ? "Joining…" : ((root.main?.botMode ?? false) ? "Join as app" : "Join channel")
                                enabled: !(root.main?.joining ?? false)
                                onClicked: root.main.joinConversation(root.main.activeId)
                            }
                        }
                    }

                    Slack.Composer {
                        id: composer
                        visible: !(root.main?.activeNeedsJoin ?? false)
                        Layout.fillWidth: true
                        busy: root.main?.sending ?? false
                        errorText: root.main?.sendError ?? ""
                        placeholder: {
                            if (root.inThread)
                                return "Reply in thread";
                            if (!root.activeConv)
                                return "Message";
                            return "Message " + (root.activeConv.type === "im" ? root.activeConv.name : "#" + root.activeConv.name);
                        }
                        onSubmitted: text => {
                            transcript.stickToLatest = true;
                            root.main.send(text);
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
