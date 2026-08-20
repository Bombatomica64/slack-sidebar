import QtQuick
import Quickshell
import qs.Commons
import qs.Services.UI
import qs.Widgets

NIconButton {
    id: root

    property var pluginApi: null
    property ShellScreen screen
    property string widgetId: ""
    property string section: ""
    property int sectionWidgetIndex: -1
    property int sectionWidgetsCount: 0

    readonly property var main: pluginApi?.mainInstance
    readonly property int unreadCount: main?.totalUnread ?? 0
    readonly property int mentionCount: main?.mentionCount ?? 0
    readonly property bool hasError: (main?.lastError ?? "") !== ""

    baseSize: Style.getCapsuleHeightForScreen(screen?.name)
    applyUiScale: false
    icon: "brand-slack"
    tooltipDirection: BarService.getTooltipDirection(screen?.name)
    customRadius: Style.radiusL

    tooltipText: {
        if (root.hasError)
            return "Slack: " + main.lastError;
        if (!(main?.connected ?? false))
            return "Slack: not connected";

        const list = (main?.decorated ?? []).filter(c => c.unread > 0).slice(0, 6);
        if (list.length === 0)
            return "Slack: all caught up";

        let lines = [];
        for (const c of list)
            lines.push((c.type === "channel" || c.type === "private" ? "#" : "") + c.name + " · " + c.unread + (c.mention ? " (mention)" : ""));
        if (root.unreadCount > 0 && (main?.decorated ?? []).filter(c => c.unread > 0).length > list.length)
            lines.push("…");
        return lines.join("\n");
    }

    colorBg: Style.capsuleColor
    colorFg: {
        if (root.hasError)
            return Color.mError;
        if (root.mentionCount > 0)
            return Color.mError;
        return root.unreadCount > 0 ? Color.mPrimary : Color.mOnSurfaceVariant;
    }
    colorBgHover: Color.mHover
    colorFgHover: Color.mOnHover
    colorBorder: Style.capsuleBorderColor
    colorBorderHover: Style.capsuleBorderColor

    onClicked: {
        if (pluginApi)
            pluginApi.togglePanel(screen, root);
    }

    onRightClicked: main?.refreshAll()

    Loader {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        anchors.horizontalCenterOffset: parent.baseSize / 3
        anchors.verticalCenterOffset: -parent.baseSize / 3
        z: 2
        active: root.unreadCount > 0
        sourceComponent: Rectangle {
            height: 15
            width: Math.max(15, badgeLabel.implicitWidth + 6)
            radius: height / 2
            // Mentions are the thing you actually have to act on, so they get
            // the error colour while ordinary unread stays on primary.
            color: root.mentionCount > 0 ? Color.mError : Color.mPrimary
            border.color: Color.mSurface
            border.width: Style.borderS

            NText {
                id: badgeLabel
                anchors.centerIn: parent
                text: root.unreadCount > 99 ? "99+" : String(root.unreadCount)
                color: root.mentionCount > 0 ? Color.mOnError : Color.mOnPrimary
                pointSize: Style.fontSizeXS
                font.weight: Font.Bold
            }
        }
    }

    // Quiet "something is wrong" marker when there is no badge to carry it.
    Loader {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        anchors.horizontalCenterOffset: parent.baseSize / 3
        anchors.verticalCenterOffset: -parent.baseSize / 3
        z: 2
        active: root.unreadCount === 0 && (root.hasError || !(main?.connected ?? false))
        sourceComponent: Rectangle {
            width: 7
            height: 7
            radius: width / 2
            color: Color.mError
            border.color: Color.mSurface
            border.width: Style.borderS
        }
    }
}
