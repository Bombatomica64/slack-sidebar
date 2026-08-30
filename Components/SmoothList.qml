pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

/**
 * A ListView tuned for a chat transcript on a high-refresh display.
 *
 * Three things make a QtQuick list stutter, and each one is answered here:
 *
 *  1. *Wheel handling.* Flickable's own wheel code moves contentY in one jump
 *     per notch, so on a 120 Hz screen a scroll is a handful of teleports with
 *     nothing drawn in between. A WheelHandler takes the event first: a
 *     touchpad's pixel deltas are applied 1:1 (that is what makes a touchpad
 *     feel attached to your fingers), while a mouse notch retargets a short
 *     animation. Successive notches re-aim the animation from wherever it is,
 *     so holding the wheel reads as one continuous glide at whatever frame
 *     rate the compositor is running.
 *
 *  2. *Delegate churn.* Creating a delegate is the expensive frame. reuseItems
 *     recycles them instead, and cacheBuffer keeps a screenful either side
 *     alive so a flick does not have to build one per frame.
 *
 *  3. *Bounds.* Rubber-banding past the end fights an animated contentY and
 *     leaves the view oscillating, so the bounds are hard.
 *
 * The scrollbar is drawn here rather than reserved from a shell widget because
 * it has to follow an animated contentY without feeding it back.
 */
Item {
    id: root

    property alias model: view.model
    property alias delegate: view.delegate
    property alias spacing: view.spacing
    property alias cacheBuffer: view.cacheBuffer
    property alias count: view.count
    property alias contentHeight: view.contentHeight
    property alias contentY: view.contentY
    property alias originY: view.originY
    property alias header: view.header
    property alias footer: view.footer
    property alias interactive: view.interactive
    readonly property var listView: view

    // Kept as a property rather than a hardcoded number so a caller with its own
    // padding can widen the gutter.
    property real scrollbarWidth: Math.round(4 * Style.uiScaleRatio)
    property real scrollbarMargin: Math.round(3 * Style.uiScaleRatio)
    property bool reserveScrollbarSpace: true
    // One notch of a mouse wheel, before the Shift multiplier.
    property real wheelStep: Math.round(110 * Style.uiScaleRatio)
    property int wheelDuration: 130

    readonly property real availableWidth: Math.max(1, width - (reserveScrollbarSpace ? scrollbarWidth + scrollbarMargin * 2 : 0))
    readonly property bool scrollable: view.contentHeight > view.height + 1
    readonly property real maxContentY: Math.max(view.originY, view.originY + view.contentHeight - view.height)
    readonly property bool dragging: view.dragging || barArea.pressed
    readonly property bool flicking: view.flicking || glide.running
    readonly property bool moving: view.moving || glide.running || barArea.pressed
    // Two pixels of slack: contentHeight is a float and can settle a hair short
    // of the arithmetic, which would leave "at the end" permanently false.
    readonly property bool atEnd: !scrollable || view.contentY >= root.maxContentY - 2
    readonly property bool atBeginning: !scrollable || view.contentY <= view.originY + 2

    signal scrolledByUser

    function positionViewAtEnd() {
        glide.stop();
        view.positionViewAtEnd();
    }

    function positionViewAtBeginning() {
        glide.stop();
        view.positionViewAtBeginning();
    }

    function positionViewAtIndex(index, mode) {
        glide.stop();
        view.positionViewAtIndex(index, mode);
    }

    function itemAtIndex(index) {
        return view.itemAtIndex(index);
    }

    function indexAt(x, y) {
        return view.indexAt(x, y);
    }

    function cancelScroll() {
        glide.stop();
        view.cancelFlick();
    }

    function scrollTo(y, animated) {
        const target = Math.max(view.originY, Math.min(y, root.maxContentY));
        glide.stop();
        view.cancelFlick();
        if (animated === false) {
            view.contentY = target;
            return;
        }
        glide.from = view.contentY;
        glide.to = target;
        glide.start();
    }

    function _clamp(y) {
        return Math.max(view.originY, Math.min(y, root.maxContentY));
    }

    function _onWheel(ev) {
        if (!root.scrollable) {
            ev.accepted = false;
            return;
        }
        root.scrolledByUser();
        barFade.restart();

        // A touchpad (and a high-resolution wheel) sends pixels. Follow them
        // exactly: any smoothing here reads as lag.
        if (ev.pixelDelta.y !== 0) {
            glide.stop();
            view.cancelFlick();
            view.contentY = root._clamp(view.contentY - ev.pixelDelta.y);
            ev.accepted = true;
            return;
        }
        if (ev.angleDelta.y === 0) {
            ev.accepted = false;
            return;
        }
        const step = root.wheelStep * ((ev.modifiers & Qt.ShiftModifier) ? 3 : 1);
        // Aim from where the current glide is headed, not from where it is, so
        // a fast series of notches adds up instead of cancelling itself.
        const from = glide.running ? glide.to : view.contentY;
        root.scrollTo(from - (ev.angleDelta.y / 120) * step, true);
        ev.accepted = true;
    }

    NumberAnimation {
        id: glide

        target: view
        property: "contentY"
        duration: root.wheelDuration
        easing.type: Easing.OutCubic
    }

    ListView {
        id: view

        anchors.fill: parent
        anchors.rightMargin: root.reserveScrollbarSpace ? root.scrollbarWidth + root.scrollbarMargin * 2 : 0
        clip: true

        // Rebuilding a delegate is the expensive frame; recycling one is not.
        reuseItems: true
        // Roughly two screenfuls either side. Larger buffers do not scroll any
        // better, they just move the cost into one longer hitch when the view
        // is first filled.
        cacheBuffer: 1600

        boundsBehavior: Flickable.StopAtBounds
        boundsMovement: Flickable.StopAtBounds
        flickDeceleration: 4200
        maximumFlickVelocity: 6500
        // Whole-pixel content positions quantise motion to the delegate grid,
        // which is exactly the micro-judder we are trying to remove.
        pixelAligned: false
        synchronousDrag: true

        // Wheel events reach a handler before the Flickable's own wheelEvent, so
        // declaring this is what replaces Flickable's stepping behaviour.
        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: ev => root._onWheel(ev)
        }

        onDraggingChanged: {
            if (!dragging)
                return;
            // A finger on the list wins over an in-flight wheel glide; leaving
            // both running makes the content fight itself.
            glide.stop();
            root.scrolledByUser();
        }
        onFlickStarted: root.scrolledByUser()
        onMovementStarted: barFade.restart()
    }

    // ------------------------------------------------------------- scrollbar

    Timer {
        id: barFade
        interval: 1100
    }

    Item {
        id: barTrack

        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.rightMargin: root.scrollbarMargin
        width: root.scrollbarWidth
        visible: root.scrollable
        opacity: (barFade.running || barArea.containsMouse || barArea.pressed || root.moving) ? 1 : 0

        Behavior on opacity {
            NumberAnimation {
                duration: Style.animationNormal
                easing.type: Easing.OutCubic
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: Qt.alpha(Color.mOutline, 0.25)
        }

        Rectangle {
            id: handle

            readonly property real span: Math.max(0, barTrack.height - height)
            readonly property real scrollable: Math.max(1, view.contentHeight - view.height)

            x: 0
            width: parent.width
            height: Math.max(Math.round(28 * Style.uiScaleRatio), barTrack.height * Math.min(1, view.height / Math.max(1, view.contentHeight)))
            y: handle.span * Math.max(0, Math.min(1, (view.contentY - view.originY) / handle.scrollable))
            radius: width / 2
            color: (barArea.pressed || barArea.containsMouse) ? Color.mPrimary : Qt.alpha(Color.mOnSurfaceVariant, 0.55)

            Behavior on color {
                ColorAnimation {
                    duration: Style.animationFast
                }
            }
        }

        MouseArea {
            id: barArea

            // A four-pixel bar is not a four-pixel target: widen the hit area
            // without widening the thing that is drawn.
            anchors.fill: parent
            anchors.margins: -Math.round(6 * Style.uiScaleRatio)
            hoverEnabled: true
            preventStealing: true

            property real grabOffset: 0

            function _seek(y) {
                if (handle.span <= 0)
                    return;
                const ratio = Math.max(0, Math.min(1, (y - barArea.grabOffset) / handle.span));
                root.scrollTo(view.originY + ratio * handle.scrollable, false);
            }

            onPressed: mouse => {
                root.scrolledByUser();
                const local = mouse.y + anchors.margins;
                if (local >= handle.y && local <= handle.y + handle.height) {
                    barArea.grabOffset = local - handle.y;
                } else {
                    // Clicking the track centres the handle where you clicked,
                    // which is what every other scrollbar does.
                    barArea.grabOffset = handle.height / 2;
                    barArea._seek(local);
                }
            }
            onPositionChanged: mouse => {
                if (barArea.pressed)
                    barArea._seek(mouse.y + anchors.margins);
            }
            onWheel: ev => root._onWheel(ev)
        }
    }
}
