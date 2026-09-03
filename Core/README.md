# Shell adapter contract

`SlackState.qml` contains the Slack agent lifecycle, polling and conversation
state. It deliberately knows nothing about a shell's plugin API or theme.

Each host entry point supplies `platformAdapter` with:

| Member | Type | Purpose |
| --- | --- | --- |
| `settings` | object | Live settings map |
| `defaults` | object | Default values for missing settings |
| `pluginDir` | string | Directory containing the Makefile and sources |
| `cacheDir` | string | Host-selected agent/cache directory |
| `panelVisible` | bool | Whether fast active-conversation polling should run |
| `setSetting(key, value)` | function | Persist one setting atomically |

The host also provides `renderPalette`, `fixedFontFamily`, and
`renderedEmojiSize`. Shell-specific views should use native controls and theme
tokens, while binding to the public properties and methods on `SlackState`.

The Noctalia implementation is the root `Main.qml`. DMS, end-4 and Caelestia
adapters should depend on this contract rather than emulating Noctalia's
`pluginApi`.
