# Shell integrations

The integrations are intentionally separate from `Core/`:

- `Noctalia` is provided by the repository's root entry points.
- `DMS` should be a native DMS plugin (`plugin.json`, bar pill/popout and
  settings entry points) using `PluginComponent` and `pluginData`.
- `end-4` currently has no stable third-party plugin ABI; its adapter is an
  overlay module for `modules/sidebarLeft` and must document the supported
  upstream revision.
- `Caelestia` does not yet wire third-party plugins into the shell UI; its
  adapter is an overlay for `modules/sidebar` until that public API exists.

Do not copy Slack state or agent logic into an adapter. Each integration owns
only persistence, lifecycle, shell-native theming and presentation.
