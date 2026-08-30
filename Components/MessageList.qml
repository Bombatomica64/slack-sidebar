pragma ComponentBehavior: Bound

import QtQuick
import QtQml.Models
import QtQuick.Layouts
import qs.Commons
import qs.Widgets

/**
 * The transcript.
 *
 * Messages arrive newest-first (that is what conversations.history returns) and
 * are reversed here so the view runs oldest -> newest, top to bottom. A
 * bottom-up ListView looks like the natural fit for a chat, but it puts the
 * content origin at a negative value, which every piece of scroll arithmetic
 * downstream then has to special-case. Ordinary top-down order keeps that
 * arithmetic honest, and "newest at the bottom" becomes just positioning at the
 * end.
 *
 * The model is a ListModel that is *diffed*, not replaced. The old code handed
 * the view a fresh JS array on every poll, which destroys and rebuilds every
 * delegate: a few hundred text layouts, several times a minute, on the GUI
 * thread. That is what the flicker and the lost scroll position were. Now a
 * poll that changed nothing does nothing, and a poll that appended one message
 * appends one row.
 *
 * Everything a delegate needs is computed here, once, into the row object:
 * grouping, day separators and the unread marker all depend on a message's
 * neighbours, and working that out inside a delegate binding means redoing it
 * every time the row is recycled.
 */
Item {
    id: root

    property var messages: []
    property var users: ({})
    property var customEmoji: ({})
    property var avatarMap: ({})
    property var unfurls: ({})
    property string meId: ""
    property string readCursor: ""
    property bool inThread: false
    property bool loading: false
    property string emptyText: "No messages yet"

    // Changes when the view is showing a different conversation or thread.
    // Scroll state is per-conversation: coming back to the list and opening
    // something else should start at the bottom, not wherever you were.
    property string sessionKey: ""

    signal threadRequested(string ts)
    signal reactionToggled(string ts, string name, bool mine)
    signal copyRequested(string text)

    // Set false as soon as the reader scrolls back, so a poll landing mid-read
    // never yanks them to the bottom. Reaching the bottom again re-arms it,
    // which is what Slack does too.
    property bool stickToLatest: true

    readonly property bool showJumpButton: !stickToLatest && !list.atEnd && rows.count > 0

    function jumpToLatest() {
        root.stickToLatest = true;
        list.positionViewAtEnd();
    }

    // ------------------------------------------------------------ row model

    // ts -> message. The model itself holds nothing but strings and booleans,
    // because ListModel turns a nested JS object into its own value types on
    // the way in and hands back something that is no longer the object you put
    // there. Keeping the messages beside the model in a plain JS map sidesteps
    // that entirely, and because the key is the timestamp it never goes stale
    // the way an index would.
    property var messageByKey: ({})

    // What a delegate binds to for the one frame between the map being replaced
    // and its row being removed.
    readonly property var blankMessage: ({
            ts: "0",
            author: "",
            html: "",
            mine: false,
            isBot: false,
            reactions: [],
            files: [],
            attachments: [],
            links: [],
            replyUsers: [],
            replyCount: 0
        })

    ListModel {
        id: rows
    }

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

    // Everything a delegate draws goes into this string, so a row whose
    // signature is unchanged can keep the delegate it already has.
    function _signature(msg, grouped, dayLabel, unreadMark) {
        return [msg.html || "", msg.author || "", msg.replyCount || 0, JSON.stringify(msg.reactions || []), JSON.stringify(msg.files || []), JSON.stringify(msg.attachments || []), JSON.stringify(msg.links || []), grouped, dayLabel, unreadMark].join("");
    }

    function _buildRows() {
        const source = root.messages || [];
        const out = [];
        const byKey = ({});
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
            // A day separator or an unread rule between two messages breaks the
            // group: a continuation under a divider reads as an orphan.
            if (startsNewDay)
                grouped = false;

            let unreadMark = false;
            if (!seenUnread && !root.inThread && cursor > 0 && !msg.mine && parseFloat(msg.ts) > cursor) {
                unreadMark = true;
                seenUnread = true;
                grouped = false;
            }

            const dayLabel = startsNewDay ? root._dayLabel(stamp) : "";
            const key = String(msg.ts);
            byKey[key] = msg;
            out.push({
                key: key,
                sig: root._signature(msg, grouped, dayLabel, unreadMark),
                grouped: grouped,
                dayLabel: dayLabel,
                unreadMark: unreadMark
            });
        }
        root.messageByKey = byKey;
        return out;
    }

    // Bring the model in line with `next` by touching only what actually moved.
    function _sync(next) {
        const alive = ({});
        for (const row of next)
            alive[row.key] = true;

        // Messages that fell out of the history window, or were deleted.
        for (let i = rows.count - 1; i >= 0; --i)
            if (!alive[rows.get(i).key])
                rows.remove(i);

        for (let i = 0; i < next.length; ++i) {
            if (i >= rows.count) {
                rows.append(next[i]);
                continue;
            }
            const cur = rows.get(i);
            if (cur.key !== next[i].key)
                rows.insert(i, next[i]);
            else if (cur.sig !== next[i].sig)
                rows.set(i, next[i]);
        }
        while (rows.count > next.length)
            rows.remove(rows.count - 1);
    }

    // Removing rows above the viewport shifts everything under them, which
    // reads as the transcript jumping while you are trying to read it. Note
    // where the topmost visible message sits, and put it back afterwards.
    function _captureAnchor() {
        if (root.stickToLatest || rows.count === 0)
            return null;
        const index = list.indexAt(1, list.contentY + 1);
        if (index < 0 || index >= rows.count)
            return null;
        const item = list.itemAtIndex(index);
        if (!item)
            return null;
        return {
            key: rows.get(index).key,
            offset: item.y - list.contentY
        };
    }

    function _restoreAnchor(anchor) {
        if (!anchor)
            return;
        for (let i = 0; i < rows.count; ++i) {
            if (rows.get(i).key !== anchor.key)
                continue;
            const item = list.itemAtIndex(i);
            if (item)
                list.scrollTo(item.y - anchor.offset, false);
            return;
        }
    }

    function _refresh() {
        const anchor = root._captureAnchor();
        root._sync(root._buildRows());
        if (root.stickToLatest)
            Qt.callLater(list.positionViewAtEnd);
        else
            root._restoreAnchor(anchor);
    }

    onMessagesChanged: _refresh()
    onReadCursorChanged: _refresh()
    onInThreadChanged: _refresh()

    onSessionKeyChanged: {
        rows.clear();
        root.stickToLatest = true;
        list.scrollTo(0, false);
        _refresh();
    }

    Component.onCompleted: _refresh()

    // ----------------------------------------------------------------- view

    SmoothList {
        id: list

        anchors.fill: parent
        model: rows
        spacing: 0
        reserveScrollbarSpace: true

        onScrolledByUser: root.stickToLatest = false
        // Scrolling back down to the bottom means you have caught up, so start
        // following again rather than making you press the jump button.
        onAtEndChanged: if (list.atEnd)
            root.stickToLatest = true

        delegate: Column {
            id: cell

            required property string key
            required property bool grouped
            required property string dayLabel
            required property bool unreadMark

            readonly property var msg: root.messageByKey[cell.key] || root.blankMessage

            width: list.availableWidth
            spacing: 0

            // Date separator
            Item {
                width: cell.width
                height: visible ? Math.round(22 * Style.uiScaleRatio) : 0
                visible: cell.dayLabel !== ""

                NDivider {
                    anchors.verticalCenter: parent.verticalCenter
                }

                Rectangle {
                    anchors.centerIn: parent
                    width: dayText.implicitWidth + Style.marginM
                    height: dayText.implicitHeight + Style.marginXXS
                    radius: height / 2
                    color: Color.mSurface

                    NText {
                        id: dayText

                        anchors.centerIn: parent
                        text: cell.dayLabel
                        color: Color.mOnSurfaceVariant
                        pointSize: Style.fontSizeXXS
                        font.weight: Style.fontWeightSemiBold
                    }
                }
            }

            // Unread marker
            Item {
                width: cell.width
                height: visible ? Math.round(20 * Style.uiScaleRatio) : 0
                visible: cell.unreadMark

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: Style.borderS
                    color: Color.mError
                }

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    width: newText.implicitWidth + Style.marginS
                    height: newText.implicitHeight + Style.marginXXS
                    radius: height / 2
                    color: Color.mError

                    NText {
                        id: newText

                        anchors.centerIn: parent
                        text: "new"
                        color: Color.mOnError
                        pointSize: Style.fontSizeXXS
                        font.weight: Style.fontWeightBold
                    }
                }
            }

            MessageItem {
                width: cell.width
                msg: cell.msg
                grouped: cell.grouped
                users: root.users
                customEmoji: root.customEmoji
                avatarMap: root.avatarMap
                unfurls: root.unfurls
                meId: root.meId
                inThread: root.inThread
                onThreadRequested: ts => root.threadRequested(ts)
                onReactionToggled: (ts, name, mine) => root.reactionToggled(ts, name, mine)
                onCopyRequested: text => root.copyRequested(text)
            }
        }
    }

    // Empty / loading states
    ColumnLayout {
        anchors.centerIn: parent
        width: parent.width * 0.7
        spacing: Style.marginS
        visible: rows.count === 0

        NIcon {
            Layout.alignment: Qt.AlignHCenter
            icon: root.loading ? "loader-2" : "messages"
            color: Color.mOnSurfaceVariant
            pointSize: Style.fontSizeXXXL
        }

        NText {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: root.loading ? "Loading..." : root.emptyText
            color: Color.mOnSurfaceVariant
            pointSize: Style.fontSizeS
            wrapMode: Text.WordWrap
        }
    }

    // Jump back to the newest message
    NIconButton {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.marginS
        visible: root.showJumpButton
        icon: "arrow-down"
        baseSize: 26
        tooltipText: "Jump to latest"
        colorBg: Color.mPrimary
        colorFg: Color.mOnPrimary
        colorBgHover: Color.mSecondary
        colorFgHover: Color.mOnSecondary
        onClicked: root.jumpToLatest()
    }
}
