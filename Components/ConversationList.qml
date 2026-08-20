pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Widgets
import "Mrkdwn.js" as Mrkdwn

/**
 * Sidebar conversation picker: search box on top, everything else below,
 * ordered by the model (mentions, then unread, then pinned, then recency).
 */
Item {
    id: root

    property var conversations: []
    property var users: ({})
    property string activeId: ""
    property bool botMode: false
    property alias filter: search.text

    signal conversationPicked(string id)
    signal pinToggled(string id)

    readonly property var visibleConversations: {
        const needle = search.text.trim().toLowerCase();
        if (needle === "")
            return conversations;
        return conversations.filter(c => c.name.toLowerCase().indexOf(needle) >= 0);
    }

    function focusSearch() {
        search.inputItem.forceActiveFocus();
    }

    function iconFor(type) {
        if (type === "channel")
            return "hash";
        if (type === "private")
            return "lock";
        if (type === "mpim")
            return "users";
        return "user";
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Style.marginS

        NTextInput {
            id: search
            Layout.fillWidth: true
            placeholderText: "Search conversations"
            inputIconName: "search"
            fontSize: Style.fontSizeS
        }

        NBox {
            Layout.fillWidth: true
            Layout.fillHeight: true

            NListView {
                id: list
                anchors.fill: parent
                anchors.margins: Style.marginXS
                model: root.visibleConversations
                spacing: Style.marginXXS
                showGradientMasks: false

                delegate: Rectangle {
                    id: row

                    required property var modelData

                    width: list.availableWidth
                    height: 44 * Style.uiScaleRatio
                    radius: Style.radiusS
                    color: {
                        if (row.modelData.id === root.activeId)
                            return Qt.alpha(Color.mPrimary, 0.16);
                        if (rowHover.hovered)
                            return Color.mSurfaceVariant;
                        return "transparent";
                    }

                    readonly property bool hasUnread: (row.modelData.unread || 0) > 0
                    readonly property bool unjoined: row.modelData.joined === false

                    HoverHandler {
                        id: rowHover
                        cursorShape: Qt.PointingHandCursor
                    }

                    Behavior on color {
                        ColorAnimation {
                            duration: Style.animationFast
                        }
                    }

                    // Declared before the content so interactive children above
                    // it (the pin button) get the click first.
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.conversationPicked(row.modelData.id)
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Style.marginS
                        anchors.rightMargin: Style.marginXS
                        spacing: Style.marginS

                        // DM avatar where we have one, glyph for channels
                        Item {
                            Layout.preferredWidth: 24 * Style.uiScaleRatio
                            Layout.preferredHeight: 24 * Style.uiScaleRatio

                            NImageRounded {
                                anchors.fill: parent
                                visible: (row.modelData.image || "") !== ""
                                radius: width / 2
                                imagePath: row.modelData.image || ""
                                fallbackIcon: "user"
                                fallbackIconSize: Style.fontSizeS
                            }

                            NIcon {
                                anchors.centerIn: parent
                                visible: (row.modelData.image || "") === ""
                                icon: root.iconFor(row.modelData.type)
                                color: row.hasUnread ? Color.mPrimary : Color.mOnSurfaceVariant
                                pointSize: Style.fontSizeM
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Style.marginXXS

                                NText {
                                    Layout.fillWidth: true
                                    text: (row.unjoined ? "#" : "") + (row.modelData.name || row.modelData.id)
                                    color: row.hasUnread ? Color.mOnSurface : Color.mOnSurfaceVariant
                                    opacity: row.unjoined ? 0.65 : 1.0
                                    font.weight: row.hasUnread ? Style.fontWeightBold : Style.fontWeightMedium
                                    pointSize: Style.fontSizeS
                                    elide: Text.ElideRight
                                }

                                NText {
                                    visible: row.modelData.latest !== null && row.modelData.latestTs > 0
                                    text: {
                                        if (!row.modelData.latest)
                                            return "";
                                        const d = new Date(row.modelData.latestTs * 1000);
                                        const now = new Date();
                                        if (d.toDateString() === now.toDateString())
                                            return Qt.formatTime(d, "HH:mm");
                                        return Qt.formatDate(d, "d MMM");
                                    }
                                    color: Color.mOnSurfaceVariant
                                    pointSize: Style.fontSizeXXS
                                }
                            }

                            NText {
                                Layout.fillWidth: true
                                visible: text !== ""
                                opacity: row.unjoined ? 0.65 : 1.0
                                text: {
                                    const latest = row.modelData.latest;
                                    if (row.unjoined)
                                        return "not joined" + (row.modelData.members > 0 ? (" · " + row.modelData.members + " members") : "");
                                    if (!latest)
                                        return row.modelData.topic ? Mrkdwn.preview(row.modelData.topic, root.users) : "";
                                    const who = latest.mine ? "You" : latest.author;
                                    return who + ": " + Mrkdwn.preview(latest.text, root.users);
                                }
                                color: Color.mOnSurfaceVariant
                                pointSize: Style.fontSizeXXS
                                elide: Text.ElideRight
                            }
                        }

                        // Unread badge, or the pin toggle on hover
                        Item {
                            Layout.preferredWidth: 22 * Style.uiScaleRatio
                            Layout.preferredHeight: 22 * Style.uiScaleRatio

                            Rectangle {
                                anchors.centerIn: parent
                                visible: row.hasUnread && !rowHover.hovered
                                width: Math.max(16 * Style.uiScaleRatio, badge.implicitWidth + Style.marginXS)
                                height: 16 * Style.uiScaleRatio
                                radius: height / 2
                                color: row.modelData.mention ? Color.mError : Color.mPrimary

                                NText {
                                    id: badge
                                    anchors.centerIn: parent
                                    text: row.modelData.unread > 99 ? "99+" : String(row.modelData.unread)
                                    color: row.modelData.mention ? Color.mOnError : Color.mOnPrimary
                                    pointSize: Style.fontSizeXXS
                                    font.weight: Style.fontWeightBold
                                }
                            }

                            NIcon {
                                anchors.centerIn: parent
                                visible: !rowHover.hovered && !row.hasUnread && row.modelData.pinned
                                icon: "pinned-filled"
                                color: Color.mOnSurfaceVariant
                                pointSize: Style.fontSizeXS
                            }

                            NIconButton {
                                anchors.centerIn: parent
                                visible: rowHover.hovered && !row.unjoined
                                icon: row.modelData.pinned ? "pinned-filled" : "pinned"
                                baseSize: 20
                                border.width: 0
                                colorBg: "transparent"
                                colorBgHover: Color.mHover
                                colorFg: row.modelData.pinned ? Color.mPrimary : Color.mOnSurfaceVariant
                                tooltipText: row.modelData.pinned ? "Stop watching" : "Watch for new messages"
                                onClicked: root.pinToggled(row.modelData.id)
                            }
                        }
                    }
                }
            }

            ColumnLayout {
                anchors.centerIn: parent
                width: parent.width * 0.8
                spacing: Style.marginXS
                visible: root.visibleConversations.length === 0

                NText {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: root.conversations.length === 0 ? (root.botMode ? "No conversations this app can see" : "No conversations yet") : "Nothing matches that search"
                    color: Color.mOnSurfaceVariant
                    pointSize: Style.fontSizeXS
                    wrapMode: Text.WordWrap
                }
            }
        }
    }
}
