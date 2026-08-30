pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Commons
import qs.Widgets

/**
 * A link preview, shaped after Slack's own unfurl: a coloured rule down the
 * left, then service name, title, description and picture.
 *
 * Fed either by Slack (message.attachments, when Slack unfurled the link for
 * us) or by `slack.sh unfurl`, which crawls the page itself. Both arrive in the
 * same shape, so this component does not know or care which produced it.
 *
 * Every image path is a local file mirrored by slack.sh: a remote source would
 * decode on the render thread mid-scroll and pop in a frame or two later, which
 * is exactly the kind of hitch the transcript is trying to avoid.
 */
Item {
    id: root

    // {url, site, title, description, image, icon, color, author, footer}
    required property var card
    property real maxImageHeight: Math.round(160 * Style.uiScaleRatio)

    readonly property string cardUrl: card.url || ""
    readonly property string siteText: card.site || ""
    readonly property string titleText: card.title || ""
    readonly property string bodyText: card.description || ""
    readonly property string imagePath: card.image || ""
    readonly property string iconPath: card.icon || ""

    // Slack sends "good"/"warning"/"danger" or a bare hex triple. The literal
    // colours are honoured because they are the sender's choice, not ours; with
    // nothing to honour the rule takes the theme's accent.
    readonly property color accent: {
        const raw = String(root.card.color || "");
        if (raw === "good")
            return "#2eb67d";
        if (raw === "warning")
            return "#ecb22e";
        if (raw === "danger")
            return Color.mError;
        if (/^#?[0-9a-fA-F]{6}$/.test(raw))
            return Qt.color(raw.charAt(0) === "#" ? raw : "#" + raw);
        return Color.mSecondary;
    }

    readonly property bool hasImage: imagePath !== "" && preview.status === Image.Ready

    // slack.sh mirrors crawled images to disk, but Slack's own unfurls arrive as
    // CDN URLs it has already made public, so both shapes have to work.
    function sourceFor(path) {
        if (!path)
            return "";
        return /^https?:\/\//i.test(path) ? path : "file://" + path;
    }

    implicitHeight: body.implicitHeight + Style.marginXS
    height: implicitHeight

    Rectangle {
        x: 0
        y: 0
        width: Style.borderM
        height: root.height - Style.marginXS
        radius: width
        color: root.accent
    }

    Column {
        id: body

        x: Style.marginS
        width: Math.max(1, root.width - Style.marginS)
        spacing: Style.marginXXS

        // Service line: favicon + site name, the way Slack labels an unfurl.
        Row {
            width: parent.width
            spacing: Style.marginXXS
            visible: root.siteText !== ""

            Image {
                width: Math.round(12 * Style.uiScaleRatio)
                height: width
                visible: root.iconPath !== "" && status === Image.Ready
                source: root.sourceFor(root.iconPath)
                asynchronous: true
                cache: true
                fillMode: Image.PreserveAspectFit
                sourceSize.width: Math.round(24 * Style.uiScaleRatio)
                sourceSize.height: Math.round(24 * Style.uiScaleRatio)
                anchors.verticalCenter: parent.verticalCenter
            }

            NText {
                text: root.siteText
                color: Color.mOnSurfaceVariant
                pointSize: Style.fontSizeXXS
                font.weight: Style.fontWeightSemiBold
                elide: Text.ElideRight
                width: Math.min(implicitWidth, body.width)
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        NText {
            width: parent.width
            visible: text !== ""
            text: root.titleText
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
            text: root.bodyText
            color: Color.mOnSurfaceVariant
            pointSize: Style.fontSizeXS
            wrapMode: Text.Wrap
            elide: Text.ElideRight
            maximumLineCount: 3
        }

        // Picture last, and only once it has actually decoded — reserving space
        // for an image that never arrives leaves a hole in the transcript.
        Item {
            width: parent.width
            height: root.hasImage ? preview.height + Style.marginXXS : 0
            visible: root.hasImage
            clip: true

            Image {
                id: preview

                width: parent.width
                height: Math.min(root.maxImageHeight, parent.width * (implicitHeight > 0 && implicitWidth > 0 ? implicitHeight / implicitWidth : 0.5))
                source: root.sourceFor(root.imagePath)
                asynchronous: true
                cache: true
                fillMode: Image.PreserveAspectCrop
                // Decoding a 4000px hero image to draw it 400px wide is a frame
                // we do not need to spend.
                sourceSize.width: Math.round(720 * Style.uiScaleRatio)
                mipmap: true
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        enabled: root.cardUrl !== ""
        onClicked: Quickshell.execDetached(["xdg-open", root.cardUrl])
    }
}
