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
    // There is history before the oldest row, and whether we are fetching it.
    property bool hasMore: false
    property bool loadingOlder: false
    property string emptyText: "No messages yet"

    // Free text to narrow the transcript down to. Only what has been loaded is
    // searched: the rest of the history lives on Slack's servers, and paging it
    // all in to answer a keystroke would be a lot of requests for a sidebar.
    property string filter: ""
    readonly property bool filtering: filter.trim() !== ""
    readonly property int matchCount: rows.count

    // Changes when the view is showing a different conversation or thread.
    // Scroll state is per-conversation: coming back to the list and opening
    // something else should start at the bottom, not wherever you were.
    property string sessionKey: ""

    signal loadOlderRequested()
    signal threadRequested(string ts)
    signal reactionToggled(string ts, string name, bool mine)
    signal copyRequested(string text)

    // Set false as soon as the reader scrolls back, so a poll landing mid-read
    // never yanks them to the bottom. Reaching the bottom again re-arms it,
    // which is what Slack does too.
    property bool stickToLatest: true

    readonly property bool showJumpButton: !stickToLatest && !list.atEnd && rows.count > 0

    function _maybeLoadOlder() {
        // While filtering the view is a result list, not a transcript: reaching
        // its top means the results ran out, not the history.
        if (root.hasMore && !root.loadingOlder && !root.filtering && rows.count > 0)
            root.loadOlderRequested();
    }

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

    // The raw text rather than the rendered HTML: markup a reader never sees
    // should not be matchable, and `<@U024BE7LH>` is not what they typed.
    function _matches(msg, needle) {
        if ((msg.text || "").toLowerCase().indexOf(needle) >= 0)
            return true;
        if ((msg.author || "").toLowerCase().indexOf(needle) >= 0)
            return true;
        for (const file of (msg.files || []))
            if ((file.name || "").toLowerCase().indexOf(needle) >= 0)
                return true;
        for (const att of (msg.attachments || []))
            if ((att.title || "").toLowerCase().indexOf(needle) >= 0 || (att.text || "").toLowerCase().indexOf(needle) >= 0)
                return true;
        return false;
    }

    function _buildRows() {
        const needle = root.filter.trim().toLowerCase();
        const source = needle === "" ? (root.messages || []) : (root.messages || []).filter(m => root._matches(m, needle));
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

            // Results are not neighbours, so nothing about them may be inferred
            // from the row above: every hit carries its own author and time.
            let grouped = false;
            if (needle === "" && older && !root.inThread && older.user === msg.user && older.author === msg.author)
                grouped = Math.abs(parseFloat(msg.ts) - parseFloat(older.ts)) < 300;
            // A day separator or an unread rule between two messages breaks the
            // group: a continuation under a divider reads as an orphan.
            if (startsNewDay)
                grouped = false;

            let unreadMark = false;
            if (needle === "" && !seenUnread && !root.inThread && cursor > 0 && !msg.mine && parseFloat(msg.ts) > cursor) {
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
        let index = -1;
        for (const probe of [1, 48, 120]) {
            index = list.indexAt(1, list.contentY + probe);
            if (index >= 0)
                break;
        }
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

    // A different set of rows entirely: keeping the old scroll offset would
    // land somewhere arbitrary, so show the most recent matches, and on the way
    // back out the bottom of the transcript.
    onFilterChanged: {
        root.stickToLatest = true;
        _refresh();
    }

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

        // Reaching the top asks for the previous page, the way Slack does.
        // `scrollable` matters: without it a conversation too short to scroll
        // is permanently "at the beginning" and would page itself to the start
        // of time on its own.
        onAtBeginningChanged: if (list.atBeginning && list.scrollable)
            root._maybeLoadOlder()

        // A flick can cross the top and settle before atBeginning changes.
        onMovingChanged: if (!list.moving && list.atBeginning && list.scrollable)
            root._maybeLoadOlder()

        // The rows below shift down when a page is prepended; MessageList's
        // anchor logic is what keeps the reader's place while that happens.
        header: Component {
            Item {
                width: list.availableWidth
                height: visible ? Math.round(30 * Style.uiScaleRatio) : 0
                visible: (root.hasMore || root.loadingOlder) && !root.filtering

                NText {
                    anchors.centerIn: parent
                    text: root.loadingOlder ? "Loading earlier messages…" : "Earlier messages"
                    color: Color.mOnSurfaceVariant
                    pointSize: Style.fontSizeXXS
                }

                // A button as well as the automatic load: a conversation whose
                // history is shorter than the viewport never reaches the top.
                MouseArea {
                    anchors.fill: parent
                    enabled: root.hasMore && !root.loadingOlder
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: root.loadOlderRequested()
                }
            }
        }
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
            icon: root.loading ? "loader-2" : (root.filtering ? "search" : "messages")
            color: Color.mOnSurfaceVariant
            pointSize: Style.fontSizeXXXL
        }

        NText {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: {
                if (root.loading)
                    return "Loading...";
                if (root.filtering)
                    return root.messages.length === 0 ? root.emptyText : "Nothing loaded matches that";
                return root.emptyText;
            }
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
