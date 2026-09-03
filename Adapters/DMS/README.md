# DankMaterialShell

DMS has a supported third-party widget API, so this integration is a native
DankBar widget/popout rather than a patch to the shell.

## Install for development

Clone the whole repository into DMS's plugin directory; the root `plugin.json`
points at `Adapters/DMS/SlackWidget.qml` while the widget imports the shared
`Core/SlackState.qml` and native agent sources.

```sh
git clone https://github.com/Bombatomica64/slack-sidebar.git \
  ~/.config/DankMaterialShell/plugins/slack-sidebar
```

There is no `dms plugins enable` subcommand (DMS 1.5 has browse, install, list,
uninstall and update); enable the plugin from **DMS Settings → Plugins**, which
writes `"slackSidebar": {"enabled": true}` into `plugin_settings.json`. Then add
**Slack Sidebar** to DankBar in DMS settings.

The first open builds `slack-agent` into `${XDG_CACHE_HOME:-~/.cache}/slack-sidebar`;
the clang, CMake, Qt, libsecret, OpenSSL and SQLCipher development packages
listed in the root README are required unless a release binary has been
installed there.

Open the popout to enter the Slack Client ID and Client Secret. Those fields are
ephemeral: the widget passes them to `slack-agent set-credentials`, which stores
them in Secret Service, and clears the fields immediately. Non-secret behavior
settings use DMS's native plugin settings page.

While iterating on the QML, `dms ipc call plugin-scan reload slackSidebar`
reloads the widget. It busts Qt's component cache only for the plugin's own
files, so a change under `Core/` needs the shell restarted to be picked up.

## Files

| File | Role |
| --- | --- |
| `SlackWidget.qml` | Bar pill, popout shell, header actions, setup and composer |
| `SlackConversationRow.qml` | One conversation: unread badge, preview, pin |
| `SlackMessageList.qml` | Grouping, day separators, unread rule, scrollback |
| `SlackMessageItem.qml` | One message: avatar, author, body, files, cards, reactions, replies |
| `SlackSettings.qml` | The native DMS settings page |

`Components/` cannot be shared with this adapter: those files are built from
Noctalia's `NText`/`NImageRounded` and `qs.Commons`, so the view is
reimplemented here against DMS's `StyledText`, `DankIcon`, `DankListView`,
`DankCircularImage`, `DankActionButton` and `StateLayer`. Only `Mrkdwn.js`, which
is plain JavaScript, is used by both.

## Theme note

Use the colour names DMS itself uses — `surfaceText`, `surfaceVariantText`,
`primaryText`. The Material-style aliases (`onSurface`, `onSurfaceVariant`,
`onPrimary`) do not resolve here and render black. For rich text, set
`renderType: Text.QtRendering`: `StyledText` renders natively by default, which
leaves an HTML document on its own default colour.

Developed against DMS 1.5's plugin contract (`PluginComponent`,
`PluginSettings`, `PopoutComponent`, `pluginService.getPluginPath` and
`savePluginData`).
