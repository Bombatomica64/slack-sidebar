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
dms plugins enable slackSidebar
```

Add **Slack Sidebar** to DankBar in DMS settings. The first open builds
`slack-agent` into `${XDG_CACHE_HOME:-~/.cache}/slack-sidebar`; the same clang,
Qt, libsecret and OpenSSL development packages listed in the root README are
required unless a release binary has been installed there.

Open the popout to enter the Slack Client ID and Client Secret. Those fields are
ephemeral: the widget passes them to `slack-agent set-credentials`, which stores
them in Secret Service, and clears the fields immediately. Non-secret behavior
settings use DMS's native plugin settings page.

Developed against DMS 1.5's plugin contract (`PluginComponent`,
`PluginSettings`, `pluginService.getPluginPath` and `savePluginData`).
