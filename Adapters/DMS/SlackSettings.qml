import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "slackSidebar"

    StyledText {
        width: parent.width
        text: "Slack Sidebar"
        color: Theme.surfaceText
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
    }

    StyledText {
        width: parent.width
        text: "Client credentials are secrets and are never stored in DMS settings. Enter them in the Slack popout; slack-agent writes them directly to the OS keyring."
        color: Theme.surfaceTextSecondary
        font.pixelSize: Theme.fontSizeSmall
        wrapMode: Text.WordWrap
    }

    SelectionSetting {
        settingKey: "tokenPreference"
        label: "Act as"
        description: "Choose which keyring token the sidebar uses"
        defaultValue: "auto"
        options: [
            { label: "Automatic", value: "auto" },
            { label: "My account", value: "user" },
            { label: "The app", value: "bot" }
        ]
    }

    StringSetting {
        settingKey: "identityUserId"
        label: "Your Slack user ID"
        description: "Required only when acting as a bot, so your messages and mentions are identified correctly"
        placeholder: "U0123456789"
        defaultValue: ""
    }

    SliderSetting {
        settingKey: "pollInterval"
        label: "Background polling"
        description: "How often watched conversations are checked"
        defaultValue: 45000
        minimum: 15000
        maximum: 300000
        unit: "ms"
    }

    SliderSetting {
        settingKey: "maxWatched"
        label: "Watched conversations"
        description: "Maximum number of pinned channels and DMs checked each round"
        defaultValue: 24
        minimum: 1
        maximum: 80
    }

    ToggleSetting {
        settingKey: "notifyDms"
        label: "DM notifications"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "notifyMentions"
        label: "Mention notifications"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "markReadOnOpen"
        label: "Mark read when opened"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "linkPreviews"
        label: "Link previews"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "archiveMessages"
        label: "Encrypted local archive"
        description: "Keep every message seen in the SQLCipher archive; its key remains in Secret Service"
        defaultValue: true
    }
}
