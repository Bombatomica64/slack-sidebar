import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Widgets

/**
 * The transcript.
 *
 * Messages arrive newest-first (that is what conversations.history returns) and
 * are reversed here so the view runs oldest -> newest, top to bottom.
 *
 * A bottom-up ListView looks like the natural fit for a chat, but NListView's
 * scroll maths assumes the content origin is zero: clampScrollY() clamps
 * contentY to [0, contentHeight - height]. Under BottomToTop the origin is
 * negative, so every wheel event was clamped back to 0 and the view snapped
 * instead of scrolling. Ordinary top-down order keeps that maths valid, and
 * "newest at the bottom" becomes just positioning at the end.
 */
Item {
    id: root

    property var messages: []
    property var users: ({})
    property var customEmoji: ({})
    property string meId: ""
    property string readCursor: ""
    property bool inThread: false
    property bool loading: false
    property string emptyText: "No messages yet"

    signal threadRequested(string ts)
    signal reactionToggled(string ts, string name, bool mine)
    signal copyRequested(string text)

    // Oldest first, for a top-down view.
    readonly property var ordered: (messages || []).slice().reverse()

    // Set false as soon as the reader scrolls back, so a poll landing mid-read
    // never yanks them to the bottom. The jump button puts it back.
    property bool stickToLatest: true

    function jumpToLatest() {
        root.stickToLatest = true;
        list.positionViewAtEnd();
    }

    onOrderedChanged: if (root.stickToLatest)
        Qt.callLater(list.positionViewAtEnd)

    NListView {
        id: list

        anchors.fill: parent
        model: root.ordered
        spacing: 0
        reserveScrollbarSpace: true
        showGradientMasks: false
        // Generous cache: delegates destroyed and rebuilt mid-scroll are what
        // read as text blanking out, so keep more of them alive.
        cacheBuffer: 2400

        onDraggingChanged: if (dragging)
            root.stickToLatest = false
        onFlickingChanged: if (flicking)
            root.stickToLatest = false

        delegate: Column {
            id: cell

            required property var modelData
            required property int index

            width: list.availableWidth
            spacing: 0

            // Top-down order: the neighbour above is the older message.
            readonly property var olderMsg: index > 0 ? root.ordered[index - 1] : null
            readonly property date stamp: new Date(parseFloat(modelData.ts) * 1000)

            readonly property string dayLabelText: {
                const today = new Date();
                const yesterday = new Date();
                yesterday.setDate(today.getDate() - 1);
                if (cell.stamp.toDateString() === today.toDateString())
                    return "Today";
                if (cell.stamp.toDateString() === yesterday.toDateString())
                    return "Yesterday";
                return Qt.formatDate(cell.stamp, "ddd d MMM");
            }

            readonly property bool startsNewDay: {
                if (!cell.olderMsg)
                    return true;
                return cell.stamp.toDateString() !== new Date(parseFloat(cell.olderMsg.ts) * 1000).toDateString();
            }

            readonly property bool firstUnread: {
                if (root.inThread || root.readCursor === "" || cell.modelData.mine)
                    return false;
                const cursor = parseFloat(root.readCursor);
                if (parseFloat(cell.modelData.ts) <= cursor)
                    return false;
                return !cell.olderMsg || parseFloat(cell.olderMsg.ts) <= cursor;
            }

            // Date separator
            Item {
                width: cell.width
                height: visible ? Math.round(22 * Style.uiScaleRatio) : 0
                visible: cell.startsNewDay

                NDivider {
                    anchors.verticalCenter: parent.verticalCenter
                }

                Rectangle {
                    anchors.centerIn: parent
                    width: dayLabel.implicitWidth + Style.marginM
                    height: dayLabel.implicitHeight + Style.marginXXS
                    radius: height / 2
                    color: Color.mSurface

                    NText {
                        id: dayLabel

                        anchors.centerIn: parent
                        text: cell.dayLabelText
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
                visible: cell.firstUnread

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
                    width: newLabel.implicitWidth + Style.marginS
                    height: newLabel.implicitHeight + Style.marginXXS
                    radius: height / 2
                    color: Color.mError

                    NText {
                        id: newLabel

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
                msg: cell.modelData
                olderMsg: cell.olderMsg
                users: root.users
                customEmoji: root.customEmoji
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
        visible: root.ordered.length === 0

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
        visible: !root.stickToLatest && root.ordered.length > 0
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
