pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Commons
import qs.Widgets
import "Mrkdwn.js" as Mrkdwn

/**
 * One message in the transcript. Consecutive messages from the same author
 * within a few minutes are grouped: only the first keeps the avatar and header,
 * the rest are indented continuations, the same shape Slack itself uses.
 * Whether this message is a continuation is decided in MessageList, which can
 * see its neighbours; here it is just a flag.
 *
 * Deliberately built from positioners (Column/Row/Flow) with explicit widths
 * rather than QtQuick Layouts. A Layout sizes itself from a wrapping Text whose
 * height in turn depends on the width the Layout hands it, so every delegate
 * resolved its height in two passes, and a list of two-pass delegates cannot
 * scroll smoothly: contentHeight moves under the view while it is drawing.
 * Widths here flow strictly downwards, so heights settle in one pass.
 *
 * The body stays Text.RichText rather than the much cheaper Text.StyledText,
 * because StyledText's <font> understands colour and size but not face, and
 * losing the monospace font on every code span is a worse trade than the
 * layout it saves. The rendering cost is paid once per delegate now that the
 * list diffs its model instead of rebuilding it.
 */
Item {
    id: root

    required property var msg
    property bool grouped: false
    property var users: ({})
    property var customEmoji: ({})
    property var avatarMap: ({})
    property var unfurls: ({})
    property string meId: ""
    property bool inThread: false
    property real avatarSize: 26 * Style.uiScaleRatio

    signal threadRequested(string ts)
    signal reactionToggled(string ts, string name, bool mine)
    signal copyRequested(string text)

    readonly property date stamp: new Date(parseFloat(msg.ts) * 1000)
    readonly property real topPad: grouped ? Style.marginXXS : Style.marginS
    readonly property real gutter: avatarSize + Style.marginS

    // Previews, in the order Slack shows them: whatever Slack unfurled itself
    // first, then anything we crawled for links it left alone. Capped, because
    // a message with a dozen links should not become a wall of cards.
    readonly property var cards: {
        const out = [];
        for (const att of (root.msg.attachments || [])) {
            if (!att.title && !att.text && !att.image)
                continue;
            out.push({
                url: att.url || att.fromUrl || "",
                site: att.site || att.author || "",
                title: att.title || "",
                description: att.previewText || "",
                image: att.image || "",
                icon: att.siteIcon || "",
                color: att.color || ""
            });
            if (out.length >= 3)
                return out;
        }
        for (const link of (root.msg.links || [])) {
            const card = root.unfurls[link];
            if (!card)
                continue;
            out.push(card);
            if (out.length >= 3)
                return out;
        }
        return out;
    }

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
        // Prefer the mirrored file: a local avatar cannot pop in late the way a
        // network fetch does while scrolling.
        imagePath: root.avatarMap[root.msg.user] || root.msg.image || ""
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

        // Link previews: Slack's own unfurls and the ones the agent crawled.
        Repeater {
            model: root.cards

            delegate: LinkCard {
                required property var modelData

                width: column.width
                card: modelData
            }
        }

        // Files: Slack file URLs need the token, so we link out instead of
        // trying to render them inline.
        Repeater {
            model: root.msg.files || []

            delegate: Rectangle {
                id: fileRow

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
                        text: fileRow.modelData.name || "file"
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
                        if (fileRow.modelData.url)
                            Quickshell.execDetached(["xdg-open", fileRow.modelData.url]);
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
                    id: reaction

                    required property var modelData

                    height: Math.round(18 * Style.uiScaleRatio)
                    width: reactionRow.width + Style.marginS
                    radius: height / 2
                    color: reaction.modelData.mine ? Qt.alpha(Color.mPrimary, 0.18) : Color.mSurfaceVariant
                    border.width: Style.borderS
                    border.color: reaction.modelData.mine ? Color.mPrimary : Color.mOutline

                    Row {
                        id: reactionRow

                        anchors.centerIn: parent
                        spacing: Style.marginXXS

                        NText {
                            text: {
                                const html = Mrkdwn.emojiHtml(reaction.modelData.name, root.customEmoji, Math.round(Style.fontSizeM * Style.uiScaleRatio));
                                return html !== null ? html : (":" + reaction.modelData.name + ":");
                            }
                            richTextEnabled: true
                            textFormat: Text.RichText
                            pointSize: Style.fontSizeXXS
                            color: Color.mOnSurface
                        }

                        NText {
                            text: String(reaction.modelData.count)
                            pointSize: Style.fontSizeXXS
                            color: reaction.modelData.mine ? Color.mPrimary : Color.mOnSurfaceVariant
                            font.weight: Style.fontWeightBold
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.reactionToggled(root.msg.ts, reaction.modelData.name, reaction.modelData.mine === true)
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

                Repeater {
                    model: (root.msg.replyUsers || []).slice(0, 3)

                    delegate: NImageRounded {
                        required property var modelData

                        width: Math.round(14 * Style.uiScaleRatio)
                        height: width
                        radius: width / 2
                        // Ids, not URLs: the mirrored avatar beats a network
                        // fetch here for the same reason it does above.
                        imagePath: root.avatarMap[modelData] || (root.users[modelData] ? (root.users[modelData].image || "") : "")
                        fallbackIcon: "user"
                        fallbackIconSize: Style.fontSizeXXS
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                NText {
                    text: root.msg.replyCount === 1 ? "1 reply" : (root.msg.replyCount + " replies")
                    color: Color.mSecondary
                    pointSize: Style.fontSizeXXS
                    font.weight: Style.fontWeightSemiBold
                    anchors.verticalCenter: parent.verticalCenter
                }

                NIcon {
                    icon: "chevron-right"
                    color: Color.mSecondary
                    pointSize: Style.fontSizeXS
                    anchors.verticalCenter: parent.verticalCenter
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
