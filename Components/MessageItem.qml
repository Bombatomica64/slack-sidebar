import QtQuick
import Quickshell
import qs.Commons
import qs.Widgets
import "Mrkdwn.js" as Mrkdwn

/**
 * One message in the transcript. Consecutive messages from the same author
 * within a few minutes are grouped: only the first keeps the avatar and header,
 * the rest are indented continuations — the same shape Slack itself uses.
 *
 * Deliberately built from positioners (Column/Row/Flow) with explicit widths
 * rather than QtQuick Layouts. A Layout sizes itself from a wrapping Text whose
 * height in turn depends on the width the Layout hands it, so every delegate
 * resolved its height in two passes; in a bottom-up ListView that shifts the
 * content origin on each pass and the transcript visibly flickers while
 * scrolling. Widths here flow strictly downwards, so heights settle in one pass.
 */
Item {
    id: root

    required property var msg
    property var olderMsg: null
    property var users: ({})
    property var customEmoji: ({})
    property string meId: ""
    property bool inThread: false
    property real avatarSize: 26 * Style.uiScaleRatio

    signal threadRequested(string ts)
    signal reactionToggled(string ts, string name, bool mine)
    signal copyRequested(string text)

    readonly property bool grouped: {
        if (!olderMsg || inThread)
            return false;
        if (olderMsg.user !== msg.user || olderMsg.author !== msg.author)
            return false;
        return Math.abs(parseFloat(msg.ts) - parseFloat(olderMsg.ts)) < 300;
    }

    readonly property date stamp: new Date(parseFloat(msg.ts) * 1000)
    readonly property real topPad: grouped ? Style.marginXXS : Style.marginS
    readonly property real gutter: avatarSize + Style.marginS

    implicitHeight: topPad + column.height
    height: implicitHeight

    HoverHandler {
        id: hover
    }

    NImageRounded {
        x: 0
        y: root.topPad
        width: root.avatarSize
        height: root.avatarSize
        visible: !root.grouped
        radius: root.avatarSize / 2
        imagePath: root.msg.image || ""
        fallbackIcon: root.msg.isBot ? "robot" : "user"
        fallbackIconSize: Style.fontSizeM
    }

    Column {
        id: column

        x: root.gutter
        y: root.topPad
        width: Math.max(1, root.width - root.gutter)
        spacing: Style.marginXXS

        Row {
            visible: !root.grouped
            spacing: Style.marginXS

            NText {
                text: root.msg.author || "unknown"
                color: root.msg.mine ? Color.mPrimary : Color.mOnSurface
                font.weight: Style.fontWeightBold
                pointSize: Style.fontSizeS
                elide: Text.ElideRight
                width: Math.min(implicitWidth, column.width * 0.6)
            }

            NText {
                visible: root.msg.isBot
                text: "APP"
                color: Color.mOnSurfaceVariant
                pointSize: Style.fontSizeXXS
                font.weight: Style.fontWeightBold
            }

            NText {
                text: Qt.formatTime(root.stamp, "HH:mm")
                color: Color.mOnSurfaceVariant
                pointSize: Style.fontSizeXXS
            }
        }

        // Pre-rendered in Main.qml; assigning a ready string keeps scrolling cheap.
        NText {
            id: body

            width: column.width
            visible: text !== ""
            text: root.msg.html || ""
            richTextEnabled: true
            textFormat: Text.RichText
            color: Color.mOnSurface
            pointSize: Style.fontSizeS
            wrapMode: Text.Wrap
            elide: Text.ElideNone
            onLinkActivated: link => Quickshell.execDetached(["xdg-open", link])

            HoverHandler {
                cursorShape: body.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
            }
        }

        // Attachments (link unfurls, bot cards)
        Repeater {
            model: root.msg.attachments || []

            delegate: Item {
                required property var modelData

                width: column.width
                height: unfurl.height + Style.marginXS

                Rectangle {
                    width: Style.borderM
                    height: parent.height
                    radius: width
                    color: Color.mOutline
                }

                Column {
                    id: unfurl

                    x: Style.marginS
                    y: Style.marginXXS
                    width: parent.width - Style.marginS
                    spacing: 0

                    NText {
                        width: parent.width
                        visible: text !== ""
                        text: modelData.title || ""
                        color: Color.mSecondary
                        pointSize: Style.fontSizeXS
                        font.weight: Style.fontWeightSemiBold
                        wrapMode: Text.Wrap
                        elide: Text.ElideRight
                        maximumLineCount: 2
                    }

                    NText {
                        width: parent.width
                        visible: text !== ""
                        text: Mrkdwn.preview(modelData.text || "", root.users)
                        color: Color.mOnSurfaceVariant
                        pointSize: Style.fontSizeXS
                        wrapMode: Text.Wrap
                        elide: Text.ElideRight
                        maximumLineCount: 3
                    }
                }
            }
        }

        // Files: Slack file URLs need the token, so we link out instead of
        // trying to render them inline.
        Repeater {
            model: root.msg.files || []

            delegate: Rectangle {
                required property var modelData

                width: column.width
                height: Math.round(22 * Style.uiScaleRatio)
                radius: Style.radiusXS
                color: Color.mSurfaceVariant
                border.color: Color.mOutline
                border.width: Style.borderS

                Row {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.marginXS
                    anchors.rightMargin: Style.marginXS
                    spacing: Style.marginXS

                    NIcon {
                        icon: "paperclip"
                        color: Color.mOnSurfaceVariant
                        pointSize: Style.fontSizeS
                    }

                    NText {
                        text: modelData.name || "file"
                        color: Color.mOnSurface
                        pointSize: Style.fontSizeXS
                        elide: Text.ElideMiddle
                        width: Math.min(implicitWidth, parent.width - Style.margin2XL)
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (modelData.url)
                            Quickshell.execDetached(["xdg-open", modelData.url]);
                    }
                }
            }
        }

        Flow {
            width: column.width
            visible: (root.msg.reactions || []).length > 0
            spacing: Style.marginXXS

            Repeater {
                model: root.msg.reactions || []

                delegate: Rectangle {
                    required property var modelData

                    height: Math.round(18 * Style.uiScaleRatio)
                    width: reactionRow.width + Style.marginS
                    radius: height / 2
                    color: modelData.mine ? Qt.alpha(Color.mPrimary, 0.18) : Color.mSurfaceVariant
                    border.width: Style.borderS
                    border.color: modelData.mine ? Color.mPrimary : Color.mOutline

                    Row {
                        id: reactionRow

                        anchors.centerIn: parent
                        spacing: Style.marginXXS

                        NText {
                            text: {
                                const html = Mrkdwn.emojiHtml(modelData.name, root.customEmoji, Math.round(Style.fontSizeM * Style.uiScaleRatio));
                                return html !== null ? html : (":" + modelData.name + ":");
                            }
                            richTextEnabled: true
                            textFormat: Text.RichText
                            pointSize: Style.fontSizeXXS
                            color: Color.mOnSurface
                        }

                        NText {
                            text: String(modelData.count)
                            pointSize: Style.fontSizeXXS
                            color: modelData.mine ? Color.mPrimary : Color.mOnSurfaceVariant
                            font.weight: Style.fontWeightBold
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.reactionToggled(root.msg.ts, modelData.name, modelData.mine === true)
                    }
                }
            }
        }

        Item {
            width: column.width
            height: visible ? threadRow.height : 0
            visible: !root.inThread && (root.msg.replyCount || 0) > 0

            Row {
                id: threadRow

                spacing: Style.marginXS

                NText {
                    text: root.msg.replyCount === 1 ? "1 reply" : (root.msg.replyCount + " replies")
                    color: Color.mSecondary
                    pointSize: Style.fontSizeXXS
                    font.weight: Style.fontWeightSemiBold
                }

                NIcon {
                    icon: "chevron-right"
                    color: Color.mSecondary
                    pointSize: Style.fontSizeXS
                }
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.threadRequested(root.msg.threadTs || root.msg.ts)
            }
        }
    }

    // Hover actions float above the transcript rather than sitting in the
    // layout, so revealing them never reflows the message text.
    Row {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.rightMargin: Style.marginXS
        z: 3
        spacing: Style.marginXXS
        opacity: hover.hovered ? 1 : 0
        visible: opacity > 0

        Behavior on opacity {
            NumberAnimation {
                duration: Style.animationFast
            }
        }

        NIconButton {
            icon: "corner-up-left"
            baseSize: 20
            tooltipText: "Reply in thread"
            border.width: 0
            colorBg: Color.mSurface
            colorBgHover: Color.mHover
            colorFg: Color.mOnSurfaceVariant
            visible: !root.inThread
            onClicked: root.threadRequested(root.msg.threadTs || root.msg.ts)
        }

        NIconButton {
            icon: "clipboard"
            baseSize: 20
            tooltipText: "Copy text"
            border.width: 0
            colorBg: Color.mSurface
            colorBgHover: Color.mHover
            colorFg: Color.mOnSurfaceVariant
            onClicked: root.copyRequested(root.msg.text || "")
        }
    }
}
