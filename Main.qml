import QtQuick
import Quickshell
import qs.Commons
import "Core" as Core

// Noctalia entry point. The Slack state itself lives in Core/SlackState.qml;
// this file translates Noctalia's plugin API and theme into the host-neutral
// contract used by the core.
Core.SlackState {
    id: root

    property var pluginApi: null

    platformAdapter: QtObject {
        readonly property var settings: root.pluginApi?.pluginSettings || ({})
        readonly property var defaults: root.pluginApi?.manifest?.metadata?.defaultSettings || ({})
        readonly property string pluginDir: root.pluginApi?.pluginDir || (Quickshell.env("HOME") + "/.config/noctalia/plugins/slack")
        readonly property string cacheDir: {
            const override = Quickshell.env("XDG_CACHE_HOME");
            return (override && override !== "" ? override : Quickshell.env("HOME") + "/.cache") + "/slack-sidebar";
        }
        readonly property bool panelVisible: (root.pluginApi?.panelOpenScreen ?? null) !== null

        function setSetting(key, value) {
            if (!root.pluginApi)
                return;
            root.pluginApi.pluginSettings[key] = value;
            root.pluginApi.saveSettings();
        }
    }

    renderPalette: ({
        link: Color.mSecondary,
        mention: Color.mSecondary,
        mentionSelf: Color.mPrimary,
        code: Color.mTertiary,
        quote: Color.mOnSurfaceVariant,
        muted: Color.mOnSurfaceVariant
    })
    fixedFontFamily: Settings.data.ui.fontFixed
    renderedEmojiSize: Math.round(Style.fontSizeL * Style.uiScaleRatio)
}
