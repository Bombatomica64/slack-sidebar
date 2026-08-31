import QtQuick
import qs.Common
import qs.Widgets

// One row of the conversation list: unread state, a preview of the latest
// message, and the pin that decides whether a channel is polled at all.
Rectangle {
    id: root

    property var conversation: ({})
    property var avatarMap: ({})

    signal activated
    signal pinToggled
    signal openInSlackRequested

    readonly property bool unread: (root.conversation.unread || 0) > 0
    readonly property bool mention: root.conversation.mention === true
    readonly property bool isDm: root.conversation.type === "im"

    height: 56
    radius: Theme.cornerRadius
    color: Theme.surfaceContainerHigh

    StateLayer {
        onClicked: root.activated()
    }

    Row {
        anchors.fill: parent
        anchors.leftMargin: Theme.spacingM
        anchors.rightMargin: Theme.spacingS
        spacing: Theme.spacingM

        Item {
            width: 28
            height: 28
            anchors.verticalCenter: parent.verticalCenter

            DankCircularImage {
                anchors.fill: parent
                visible: root.isDm
                imageSource: root.avatarMap[root.conversation.user] || root.conversation.image || ""
                fallbackIcon: "person"
            }

            DankIcon {
                anchors.centerIn: parent
                visible: !root.isDm
                name: root.conversation.joined === false ? "lock_open" : "tag"
                size: Theme.iconSizeSmall
                color: root.mention ? Theme.error : (root.unread ? Theme.primary : Theme.surfaceVariantText)
            }
        }

        Column {
            width: parent.width - 28 - pinButton.width - badge.width - Theme.spacingM * 3
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1

            StyledText {
                width: parent.width
                text: root.conversation.name || root.conversation.id || ""
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeMedium
                font.weight: root.unread ? Font.Bold : Font.Normal
                elide: Text.ElideRight
            }

            StyledText {
                width: parent.width
                visible: text !== ""
                text: root.conversation.latest?.text || root.conversation.topic || ""
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
                elide: Text.ElideRight
            }
        }

        Rectangle {
            id: badge
            anchors.verticalCenter: parent.verticalCenter
            visible: root.unread
            width: visible ? Math.max(18, badgeText.implicitWidth + Theme.spacingS) : 0
            height: 18
            radius: 9
            color: root.mention ? Theme.error : Theme.primary

            StyledText {
                id: badgeText
                anchors.centerIn: parent
                text: (root.conversation.unread || 0) > 99 ? "99+" : String(root.conversation.unread || 0)
                color: root.mention ? Theme.surface : Theme.primaryText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Bold
            }
        }

        DankActionButton {
            id: pinButton
            anchors.verticalCenter: parent.verticalCenter
            buttonSize: 28
            iconSize: Theme.iconSizeSmall
            iconName: root.conversation.pinned ? "keep" : "keep_off"
            iconColor: root.conversation.pinned ? Theme.primary : Theme.surfaceVariantText
            tooltipText: root.conversation.pinned ? "Stop watching" : "Watch for new messages"
            onClicked: root.pinToggled()
        }
    }
}
