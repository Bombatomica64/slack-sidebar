import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Widgets

ColumnLayout {
    id: root

    property var pluginApi: null

    readonly property var defaults: pluginApi?.manifest?.metadata?.defaultSettings ?? ({})

    function initial(key, fallback) {
        return pluginApi?.pluginSettings?.[key] ?? defaults[key] ?? fallback;
    }

    property string editTokenPreference: initial("tokenPreference", "auto")
    property string editRedirectUri: initial("redirectUri", "https://localhost:3000")
    property string editIdentityUserId: initial("identityUserId", "")
    property string editSide: initial("side", "right")
    property int editPanelWidth: initial("panelWidth", 460)
    property int editPollInterval: Math.round(initial("pollInterval", 45000) / 1000)
    property int editActivePollInterval: Math.round(initial("activePollInterval", 6000) / 1000)
    property int editHistoryLimit: initial("historyLimit", 60)
    property int editMaxWatched: initial("maxWatched", 24)
    property bool editNotifyDms: initial("notifyDms", true)
    property bool editNotifyMentions: initial("notifyMentions", true)
    property bool editMarkReadOnOpen: initial("markReadOnOpen", true)

    spacing: Style.marginM

    // App credentials. These go straight to the keyring rather than into the
    // plugin's settings.json, which is plain text on disk.
    NTextInput {
        id: clientIdField
        Layout.fillWidth: true
        label: "App Client ID"
        description: "Slack app → Basic Information → App Credentials. Needed to sign in and to renew a rotating token."
        placeholderText: root.credentialsStored ? "stored in keyring — type to replace" : "1234567890.1234567890"
    }

    NTextInput {
        id: clientSecretField
        Layout.fillWidth: true
        label: "App Client Secret"
        description: "Stored in the keyring, never written to a config file."
        placeholderText: root.credentialsStored ? "stored in keyring — type to replace" : "client secret"
    }

    NTextInput {
        Layout.fillWidth: true
        label: "Redirect URL"
        description: "Register this exact value under OAuth & Permissions → Redirect URLs. It has to be a localhost address so the plugin can catch the callback itself."
        text: root.editRedirectUri
        onEditingFinished: root.editRedirectUri = text
    }

    NComboBox {
        Layout.fillWidth: true
        label: "Act as"
        description: "Which stored token to authenticate with. Keep both in the keyring and the sidebar header gets a switcher."
        model: [
            {
                key: "auto",
                name: "Prefer my account"
            },
            {
                key: "user",
                name: "My account (user token)"
            },
            {
                key: "bot",
                name: "The app (bot token)"
            }
        ]
        currentKey: root.editTokenPreference
        defaultValue: root.defaults.tokenPreference
        onSelected: key => root.editTokenPreference = key
    }

    NTextInput {
        Layout.fillWidth: true
        label: "Your Slack user ID"
        description: "Only needed with a bot token, whose auth.test reports the app's id instead of yours. Setting it keeps your own messages, unread counts and @mentions correct. Find it in Slack: profile → ⋮ → Copy member ID."
        placeholderText: "U01ABCDEFGH"
        text: root.editIdentityUserId
        onEditingFinished: root.editIdentityUserId = text
    }

    NComboBox {
        Layout.fillWidth: true
        label: "Sidebar side"
        description: "Which screen edge the chat opens against."
        model: [
            {
                key: "right",
                name: "Right"
            },
            {
                key: "left",
                name: "Left"
            }
        ]
        currentKey: root.editSide
        defaultValue: root.defaults.side
        onSelected: key => root.editSide = key
    }

    NValueSlider {
        Layout.fillWidth: true
        label: "Sidebar width"
        description: root.editPanelWidth + " px"
        from: 340
        to: 720
        stepSize: 20
        value: root.editPanelWidth
        defaultValue: root.defaults.panelWidth
        onMoved: v => root.editPanelWidth = Math.round(v)
    }

    NValueSlider {
        Layout.fillWidth: true
        label: "Background refresh"
        description: "How often watched conversations are checked for new messages."
        from: 10
        to: 600
        stepSize: 5
        text: root.editPollInterval + " s"
        value: root.editPollInterval
        defaultValue: Math.round((root.defaults.pollInterval ?? 45000) / 1000)
        onMoved: v => root.editPollInterval = Math.round(v)
    }

    NValueSlider {
        Layout.fillWidth: true
        label: "Open conversation refresh"
        description: "Poll rate for the conversation you are currently reading."
        from: 2
        to: 60
        stepSize: 1
        text: root.editActivePollInterval + " s"
        value: root.editActivePollInterval
        defaultValue: Math.round((root.defaults.activePollInterval ?? 6000) / 1000)
        onMoved: v => root.editActivePollInterval = Math.round(v)
    }

    NValueSlider {
        Layout.fillWidth: true
        label: "Messages per conversation"
        description: "How much history to load when opening a conversation."
        from: 20
        to: 200
        stepSize: 10
        text: String(root.editHistoryLimit)
        value: root.editHistoryLimit
        defaultValue: root.defaults.historyLimit
        onMoved: v => root.editHistoryLimit = Math.round(v)
    }

    NValueSlider {
        Layout.fillWidth: true
        label: "Watched conversations"
        description: "Conversations polled in the background. DMs and pinned channels come first — each one costs a Slack API call per round."
        from: 4
        to: 60
        stepSize: 2
        text: String(root.editMaxWatched)
        value: root.editMaxWatched
        defaultValue: root.defaults.maxWatched
        onMoved: v => root.editMaxWatched = Math.round(v)
    }

    NToggle {
        Layout.fillWidth: true
        label: "Notify on direct messages"
        description: "Desktop notification when a DM arrives in a conversation you are not reading."
        checked: root.editNotifyDms
        defaultValue: root.defaults.notifyDms
        onToggled: checked => root.editNotifyDms = checked
    }

    NToggle {
        Layout.fillWidth: true
        label: "Notify on mentions"
        description: "Desktop notification for @you, @here and @channel."
        checked: root.editNotifyMentions
        defaultValue: root.defaults.notifyMentions
        onToggled: checked => root.editNotifyMentions = checked
    }

    NToggle {
        Layout.fillWidth: true
        label: "Mark read on open"
        description: "Move the Slack read cursor when you open a conversation. Turn off to keep unread badges until you clear them elsewhere."
        checked: root.editMarkReadOnOpen
        defaultValue: root.defaults.markReadOnOpen
        onToggled: checked => root.editMarkReadOnOpen = checked
    }

    NText {
        Layout.fillWidth: true
        text: root.credentialsStored ? "Credentials stored — use “Sign in with Slack” from the account chip in the sidebar." : "Add the Client ID and Secret above, save, then use “Sign in with Slack” from the account chip in the sidebar."
        color: Color.mOnSurfaceVariant
        pointSize: Style.fontSizeXXS
        wrapMode: Text.WordWrap
    }

    property bool credentialsStored: false

    Process {
        id: credentialsProbe
        running: true
        command: ["bash", (root.pluginApi?.pluginDir ?? "") + "/slack.sh", "credentials"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const res = JSON.parse(String(this.text || "").trim());
                    root.credentialsStored = res.haveClientId === true && res.haveClientSecret === true;
                } catch (e) {
                    root.credentialsStored = false;
                }
            }
        }
        stderr: StdioCollector {}
    }

    Process {
        id: storeCredentials
        stderr: StdioCollector {}
        stdout: StdioCollector {
            onStreamFinished: {
                clientIdField.text = "";
                clientSecretField.text = "";
                credentialsProbe.running = true;
            }
        }
    }

    // Called by NPluginSettingsPopup when the user confirms.
    function saveSettings() {
        if (!pluginApi)
            return;

        const id = clientIdField.text.trim();
        const secret = clientSecretField.text.trim();
        if (id !== "" && secret !== "" && !storeCredentials.running) {
            storeCredentials.command = ["bash", pluginApi.pluginDir + "/slack.sh", "set-credentials", id, secret];
            storeCredentials.running = true;
        }

        pluginApi.pluginSettings.redirectUri = root.editRedirectUri.trim();
        pluginApi.pluginSettings.tokenPreference = root.editTokenPreference;
        pluginApi.pluginSettings.identityUserId = root.editIdentityUserId.trim();
        pluginApi.pluginSettings.side = root.editSide;
        pluginApi.pluginSettings.panelWidth = root.editPanelWidth;
        pluginApi.pluginSettings.pollInterval = root.editPollInterval * 1000;
        pluginApi.pluginSettings.activePollInterval = root.editActivePollInterval * 1000;
        pluginApi.pluginSettings.historyLimit = root.editHistoryLimit;
        pluginApi.pluginSettings.maxWatched = root.editMaxWatched;
        pluginApi.pluginSettings.notifyDms = root.editNotifyDms;
        pluginApi.pluginSettings.notifyMentions = root.editNotifyMentions;
        pluginApi.pluginSettings.markReadOnOpen = root.editMarkReadOnOpen;
        pluginApi.saveSettings();
    }
}
