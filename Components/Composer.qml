import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Widgets

/**
 * Message composer. Enter sends, Shift+Enter adds a line, and the field grows
 * with the draft up to a few lines before it starts scrolling.
 */
Item {
    id: root

    property string placeholder: "Message"
    property bool busy: false
    property bool canSend: true
    property string errorText: ""
    property int maxLines: 6

    property alias text: input.text

    signal submitted(string text)

    readonly property real lineHeight: input.font.pixelSize * 1.45
    readonly property real fieldHeight: Math.min(Math.max(root.lineHeight + Style.margin2S, input.implicitHeight + Style.margin2S), root.lineHeight * root.maxLines + Style.margin2S)

    implicitHeight: column.implicitHeight
    height: implicitHeight

    function focusInput() {
        input.forceActiveFocus();
    }

    function submit() {
        const body = input.text.trim();
        if (body === "" || root.busy || !root.canSend)
            return;
        root.submitted(body);
        input.clear();
    }

    ColumnLayout {
        id: column
        width: parent.width
        spacing: Style.marginXXS

        NText {
            Layout.fillWidth: true
            visible: root.errorText !== ""
            text: root.errorText
            color: Color.mError
            pointSize: Style.fontSizeXXS
            wrapMode: Text.WordWrap
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Style.marginXS

            Rectangle {
                id: frame
                Layout.fillWidth: true
                implicitHeight: root.fieldHeight
                radius: Style.iRadiusM
                color: Color.mSurface
                border.width: Style.borderS
                border.color: input.activeFocus ? Color.mSecondary : Color.mOutline

                Behavior on border.color {
                    ColorAnimation {
                        duration: Style.animationFast
                    }
                }

                Behavior on implicitHeight {
                    NumberAnimation {
                        duration: Style.animationFaster
                        easing.type: Easing.OutCubic
                    }
                }

                // Panels are layer-shell surfaces: without an explicit capture
                // here, clicks and wheel events leak through to whatever is
                // behind the panel instead of landing in the field.
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                    preventStealing: true
                    cursorShape: Qt.IBeamCursor
                    onPressed: mouse => {
                        mouse.accepted = true;
                        input.forceActiveFocus();
                    }
                }

                Flickable {
                    id: flick
                    anchors.fill: parent
                    anchors.margins: Style.marginS
                    clip: true
                    contentWidth: width
                    contentHeight: input.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: contentHeight > height

                    TextArea.flickable: TextArea {
                        id: input

                        width: flick.width
                        placeholderText: root.placeholder
                        placeholderTextColor: Qt.alpha(Color.mOnSurfaceVariant, 0.6)
                        color: Color.mOnSurface
                        selectByMouse: true
                        wrapMode: TextArea.Wrap
                        background: null
                        topPadding: 0
                        bottomPadding: 0
                        leftPadding: 0
                        rightPadding: 0
                        enabled: root.canSend
                        // Settings.data is an untyped JsonObject, so qmllint cannot see
                        // into it; ui.fontDefault is a real Noctalia setting.
                        // qmllint disable missing-property
                        font.family: Settings.data.ui.fontDefault
                        // qmllint enable missing-property
                        font.pointSize: Style.fontSizeS * Style.uiScaleRatio

                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                if (event.modifiers & Qt.ShiftModifier)
                                    return; // let the newline through
                                event.accepted = true;
                                root.submit();
                            }
                        }
                    }

                    ScrollBar.vertical: ScrollBar {
                        policy: flick.interactive ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                    }
                }
            }

            NIconButton {
                icon: root.busy ? "loader-2" : "send"
                baseSize: 30
                enabled: !root.busy && root.canSend && input.text.trim() !== ""
                tooltipText: root.canSend ? "Send (Enter)" : "Read-only"
                colorBg: input.text.trim() !== "" ? Color.mPrimary : Color.mSurfaceVariant
                colorFg: input.text.trim() !== "" ? Color.mOnPrimary : Color.mOnSurfaceVariant
                colorBgHover: Color.mSecondary
                colorFgHover: Color.mOnSecondary
                onClicked: root.submit()
            }
        }

        NText {
            Layout.fillWidth: true
            visible: input.text.indexOf("\n") >= 0 || input.text.length > 120
            text: "Enter sends · Shift+Enter for a new line"
            color: Color.mOnSurfaceVariant
            pointSize: Style.fontSizeXXS
        }
    }
}
