import QtQuick
import qs.Common
import qs.Widgets

// Transcript for DMS. Mirrors Components/MessageList.qml: the source is
// newest-first, the view is oldest-first, and grouping, day separators and the
// unread rule are decided once here rather than in a delegate binding.
Item {
    id: root

    property var messages: []
    property var customEmoji: ({})
    property var avatarMap: ({})
    property var unfurls: ({})
    property string readCursor: ""
    property bool inThread: false
    property bool loading: false
    property bool hasMore: false
    property bool loadingOlder: false
    property string emptyText: "No messages yet"

    // Changes when the view is showing a different conversation or thread, so
    // scroll position starts at the bottom instead of wherever you last were.
    property string sessionKey: ""

    signal loadOlderRequested
    signal threadRequested(string ts)
    signal reactionToggled(string ts, string name, bool mine)

    // False as soon as the reader scrolls back, so a poll landing mid-read
    // never yanks them to the bottom. Reaching the bottom re-arms it.
    property bool stickToLatest: true

    function _dayLabel(stamp) {
        const today = new Date();
        if (stamp.toDateString() === today.toDateString())
            return "Today";
        const yesterday = new Date();
        yesterday.setDate(today.getDate() - 1);
        if (stamp.toDateString() === yesterday.toDateString())
            return "Yesterday";
        return Qt.formatDate(stamp, "ddd d MMM");
    }

    readonly property var rows: {
        const source = root.messages || [];
        const out = [];
        const cursor = root.readCursor === "" ? 0 : parseFloat(root.readCursor);
        let seenUnread = false;

        // Source is newest-first; walk it backwards to get oldest-first.
        for (let i = source.length - 1; i >= 0; --i) {
            const msg = source[i];
            const older = i + 1 < source.length ? source[i + 1] : null;
            const stamp = new Date(parseFloat(msg.ts) * 1000);
            const startsNewDay = !older || stamp.toDateString() !== new Date(parseFloat(older.ts) * 1000).toDateString();

            let grouped = false;
            if (older && !root.inThread && older.user === msg.user && older.author === msg.author)
                grouped = Math.abs(parseFloat(msg.ts) - parseFloat(older.ts)) < 300;
            // A day separator or the unread rule breaks a group: a continuation
            // under a divider reads as an orphan.
            if (startsNewDay)
                grouped = false;

            let unreadMark = false;
            if (!seenUnread && !root.inThread && cursor > 0 && !msg.mine && parseFloat(msg.ts) > cursor) {
                unreadMark = true;
                seenUnread = true;
                grouped = false;
            }

            out.push({
                msg: msg,
                grouped: grouped,
                dayLabel: startsNewDay ? root._dayLabel(stamp) : "",
                unreadMark: unreadMark
            });
        }
        return out;
    }

    onSessionKeyChanged: {
        root.stickToLatest = true;
        Qt.callLater(() => list.positionViewAtEnd());
    }

    StyledText {
        anchors.centerIn: parent
        visible: root.rows.length === 0
        text: root.loading ? "Loading…" : root.emptyText
        color: Theme.surfaceVariantText
        font.pixelSize: Theme.fontSizeMedium
    }

    DankListView {
        id: list

        anchors.fill: parent
        clip: true
        spacing: Theme.spacingXS
        model: root.rows
        cacheBuffer: 400

        onCountChanged: {
            if (root.stickToLatest)
                Qt.callLater(() => list.positionViewAtEnd());
        }

        onMovementEnded: root.stickToLatest = list.atYEnd

        // Older history lives above the first row, so asking for it is what
        // reaching the top means.
        onAtYBeginningChanged: {
            if (list.atYBeginning && root.hasMore && !root.loadingOlder && list.count > 0)
                root.loadOlderRequested();
        }

        header: Item {
            width: list.width
            height: root.hasMore || root.loadingOlder ? 36 : 0
            visible: height > 0

            Rectangle {
                anchors.centerIn: parent
                width: olderText.implicitWidth + Theme.spacingL * 2
                height: 26
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh

                StyledText {
                    id: olderText
                    anchors.centerIn: parent
                    text: root.loadingOlder ? "Loading older messages…" : "Load older messages"
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                StateLayer {
                    disabled: root.loadingOlder
                    onClicked: root.loadOlderRequested()
                }
            }
        }

        delegate: SlackMessageItem {
            required property var modelData

            width: list.width
            msg: modelData.msg
            grouped: modelData.grouped
            dayLabel: modelData.dayLabel
            unreadMark: modelData.unreadMark
            customEmoji: root.customEmoji
            avatarMap: root.avatarMap
            unfurls: root.unfurls
            inThread: root.inThread
            onThreadRequested: ts => root.threadRequested(ts)
            onReactionToggled: (ts, name, mine) => root.reactionToggled(ts, name, mine)
        }
    }

    // Coming back to the newest message after scrolling away.
    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.spacingS
        visible: !root.stickToLatest && list.count > 0
        width: 32
        height: 32
        radius: 16
        color: Theme.primary

        DankIcon {
            anchors.centerIn: parent
            name: "arrow_downward"
            size: Theme.iconSizeSmall
            color: Theme.primaryText
        }

        StateLayer {
            cornerRadius: 16
            stateColor: Theme.primaryText
            tooltipText: "Jump to latest"
            onClicked: {
                root.stickToLatest = true;
                list.positionViewAtEnd();
            }
        }
    }
}
