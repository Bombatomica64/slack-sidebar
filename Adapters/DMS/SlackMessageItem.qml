import QtQuick
import Quickshell
import qs.Common
import qs.Widgets
import "../../Components/Mrkdwn.js" as Mrkdwn

// One message in the transcript, in DMS's own primitives. The Noctalia panel
// draws the same thing with NText/NImageRounded, which cannot be imported here,
// so this mirrors Components/MessageItem.qml rather than reusing it.
Column {
    id: root

    property var msg: ({})
    property bool grouped: false
    property string dayLabel: ""
    property bool unreadMark: false
    property var customEmoji: ({})
    property var avatarMap: ({})
    property var unfurls: ({})
    property bool inThread: false

    signal threadRequested(string ts)
    signal reactionToggled(string ts, string name, bool mine)

    readonly property date stamp: new Date(parseFloat(root.msg.ts || 0) * 1000)
    readonly property real avatarSize: 28
    readonly property real gutter: avatarSize + Theme.spacingS

    // Previews in the order Slack shows them: what Slack unfurled itself first,
    // then anything we crawled for the links it left alone.
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
                image: att.image || ""
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

    function _open(url) {
        if (url)
            Quickshell.execDetached(["xdg-open", url]);
    }

    spacing: Theme.spacingXS
    topPadding: root.grouped ? 0 : Theme.spacingXS

    // ------------------------------------------------------------- dividers

    Item {
        width: parent.width
        height: root.dayLabel !== "" ? 24 : 0
        visible: root.dayLabel !== ""

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 1
            color: Theme.outlineVariant
        }

        Rectangle {
            anchors.centerIn: parent
            width: dayText.implicitWidth + Theme.spacingM * 2
            height: 20
            radius: 10
            color: Theme.surfaceContainerHigh

            StyledText {
                id: dayText
                anchors.centerIn: parent
                text: root.dayLabel
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Bold
            }
        }
    }

    Item {
        width: parent.width
        height: root.unreadMark ? 18 : 0
        visible: root.unreadMark

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 1
            color: Theme.error
        }

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            width: newText.implicitWidth + Theme.spacingS * 2
            height: 16
            radius: 8
            color: Theme.error

            StyledText {
                id: newText
                anchors.centerIn: parent
                text: "new"
                color: Theme.surface
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Bold
            }
        }
    }

    // -------------------------------------------------------------- message

    Row {
        width: parent.width
        spacing: Theme.spacingS

        Item {
            width: root.avatarSize
            height: root.grouped ? 1 : root.avatarSize

            DankCircularImage {
                anchors.fill: parent
                visible: !root.grouped
                // Prefer the mirrored file: a local avatar cannot pop in late
                // the way a network fetch does while scrolling.
                imageSource: root.avatarMap[root.msg.user] || root.msg.image || ""
                fallbackIcon: root.msg.isBot ? "smart_toy" : "person"
            }
        }

        Column {
            width: parent.width - root.gutter
            spacing: Theme.spacingXS

            Row {
                spacing: Theme.spacingXS
                visible: !root.grouped

                StyledText {
                    text: root.msg.author || "unknown"
                    color: root.msg.mine ? Theme.primary : Theme.surfaceText
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Bold
                }

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.msg.isBot === true
                    width: appTag.implicitWidth + Theme.spacingXS * 2
                    height: 14
                    radius: 4
                    color: Theme.surfaceContainerHighest

                    StyledText {
                        id: appTag
                        anchors.centerIn: parent
                        text: "APP"
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall - 2
                        font.weight: Font.Bold
                    }
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Qt.formatDateTime(root.stamp, "HH:mm")
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall - 1
                }
            }

            StyledText {
                width: parent.width
                visible: text !== ""
                text: root.msg.html || root.msg.text || ""
                textFormat: Text.RichText
                // Native rendering leaves a rich text document on its own
                // default colour; Noctalia's NText flips the same switch
                // behind its richTextEnabled flag.
                renderType: Text.QtRendering
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeMedium
                wrapMode: Text.Wrap
                elide: Text.ElideNone
                onLinkActivated: link => root._open(link)

                HoverHandler {
                    cursorShape: parent.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
                }
            }

            // ---------------------------------------------------------- files

            Repeater {
                model: root.msg.files || []

                Rectangle {
                    required property var modelData
                    width: parent.width
                    height: 32
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingS

                        DankIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "attach_file"
                            size: Theme.iconSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.min(implicitWidth, parent.parent.width - 60)
                            text: modelData.name || "file"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeSmall
                            elide: Text.ElideRight
                        }
                    }

                    StateLayer {
                        tooltipText: modelData.url || ""
                        onClicked: root._open(modelData.url)
                    }
                }
            }

            // ---------------------------------------------------- link cards

            Repeater {
                model: root.cards

                Rectangle {
                    required property var modelData
                    width: parent.width
                    height: cardColumn.implicitHeight + Theme.spacingS * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh
                    border.width: 1
                    border.color: Theme.outlineVariant

                    Column {
                        id: cardColumn
                        x: Theme.spacingS
                        y: Theme.spacingS
                        width: parent.width - Theme.spacingS * 2
                        spacing: 2

                        StyledText {
                            width: parent.width
                            visible: text !== ""
                            text: modelData.site || ""
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall - 1
                            elide: Text.ElideRight
                        }

                        StyledText {
                            width: parent.width
                            visible: text !== ""
                            text: modelData.title || ""
                            color: Theme.primary
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Bold
                            elide: Text.ElideRight
                        }

                        StyledText {
                            width: parent.width
                            visible: text !== ""
                            text: modelData.description || ""
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                            wrapMode: Text.Wrap
                            elide: Text.ElideRight
                            maximumLineCount: 3
                        }

                        CachingImage {
                            width: parent.width
                            height: visible ? 120 : 0
                            visible: (modelData.image || "") !== ""
                            imagePath: modelData.image || ""
                            fillMode: Image.PreserveAspectCrop
                        }
                    }

                    StateLayer {
                        tooltipText: modelData.url || ""
                        onClicked: root._open(modelData.url)
                    }
                }
            }

            // ------------------------------------------------------ reactions

            Flow {
                width: parent.width
                spacing: Theme.spacingXS
                visible: (root.msg.reactions || []).length > 0

                Repeater {
                    model: root.msg.reactions || []

                    Rectangle {
                        required property var modelData
                        width: reactionRow.implicitWidth + Theme.spacingS * 2
                        height: 22
                        radius: 11
                        color: modelData.mine ? Theme.primarySelected : Theme.surfaceContainerHigh
                        border.width: modelData.mine ? 1 : 0
                        border.color: Theme.primary

                        Row {
                            id: reactionRow
                            anchors.centerIn: parent
                            spacing: 3

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: {
                                    const html = Mrkdwn.emojiHtml(modelData.name, root.customEmoji, Theme.fontSizeSmall + 2);
                                    return html !== null ? html : (":" + modelData.name + ":");
                                }
                                textFormat: Text.RichText
                                renderType: Text.QtRendering
                                color: Theme.surfaceText
                                font.pixelSize: Theme.fontSizeSmall
                            }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: String(modelData.count)
                                color: modelData.mine ? Theme.primary : Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Bold
                            }
                        }

                        StateLayer {
                            cornerRadius: 11
                            tooltipText: ":" + modelData.name + ":"
                            onClicked: root.reactionToggled(root.msg.ts, modelData.name, modelData.mine === true)
                        }
                    }
                }
            }

            // -------------------------------------------------------- replies

            Rectangle {
                visible: !root.inThread && (root.msg.replyCount || 0) > 0
                width: repliesText.implicitWidth + Theme.spacingM * 2
                height: visible ? 24 : 0
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh

                StyledText {
                    id: repliesText
                    anchors.centerIn: parent
                    text: (root.msg.replyCount || 0) === 1 ? "1 reply" : ((root.msg.replyCount || 0) + " replies")
                    color: Theme.primary
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Bold
                }

                StateLayer {
                    onClicked: root.threadRequested(root.msg.ts)
                }
            }
        }
    }
}
