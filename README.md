# Slack (Noctalia plugin)

A Slack chat in a full-height Noctalia sidebar: conversation list with unread
badges and previews, transcript with threads and reactions, and a composer that
posts back to Slack. Shaped after the sidebar-chat layout in
[end-4/dots-hyprland](https://github.com/end-4/dots-hyprland) — the conversation
picker slides aside to reveal the transcript, and the composer stays pinned to
the bottom.

## Install

Requires **noctalia-shell 4.x** (developed against 4.7.7) and `curl`, `jq`,
`secret-tool`, `python3`. Optional: `wl-copy` for the copy action, `notify-send`
for notifications, `openssl` for the sign-in callback's local certificate.

```sh
git clone https://github.com/Bombatomica64/slack-sidebar.git ~/.config/noctalia/plugins/slack
```

Then enable **Slack** in Noctalia's Settings → Plugins, and add its widget to the
bar. The directory name must be `slack`, matching the `id` in `manifest.json`.

While hacking on it, turn on the per-plugin hot reload (the bug icon on the
plugin card) — it only appears when the shell runs with `NOCTALIA_DEBUG=1`.
Without it, disabling and re-enabling the plugin will *not* pick up your edits:
Noctalia only busts Qt's component cache from its own reload path, so you would
keep loading the previously compiled QML.

## Setup

Tokens live only in the OS keyring; nothing is written to a config file.

```sh
secret-tool store --label="Slack User Token" service slack-agents account user-token
secret-tool store --label="Slack Bot Token"  service slack-agents account bot-token   # optional
```

Signing in happens in the plugin — there is no code to copy anywhere:

1. Slack app → **Basic Information → App Credentials**: put the **Client ID** and
   **Client Secret** into the plugin settings and save. They go to the keyring,
   never to `settings.json`.
2. Slack app → **OAuth & Permissions → Redirect URLs**: register the plugin's
   **Redirect URL** (default `https://localhost:3000`) and Save.
3. Sidebar → click the account chip → **Sign in with Slack**.

`oauth-login.py` then serves that redirect on loopback, opens the browser, and
receives the callback itself: it verifies `state`, exchanges the code, and stores
the access and refresh tokens. Because Slack treats a loopback redirect as a
non-web URI it requires PKCE, so the flow always sends `code_challenge` (S256)
and the matching `code_verifier`. The listener speaks TLS using a self-signed
certificate generated once into the cache dir — the browser will warn about it
the first time, which is expected for a certificate that never leaves the
machine.

Scopes requested:

| Scope | Needed for |
| --- | --- |
| `channels:history`, `groups:history`, `im:history`, `mpim:history` | reading messages |
| `channels:read`, `groups:read`, `im:read`, `mpim:read` | listing conversations |
| `users:read` | names and avatars |
| `chat:write` | sending |
| `reactions:write` | toggling reactions |
| `channels:write`, `groups:write`, `im:write`, `mpim:write` | pushing your read cursor back to Slack (optional) |

### Token rotation

Apps with rotation enabled issue `xoxe.xoxp-…` access tokens that expire (~12h)
plus a refresh token, rather than a permanent `xoxp-…`. Both prefixes are
recognised. Signing in stores the refresh token alongside the access
token, and `slack.sh` renews it by itself when Slack answers `token_expired` — under `flock`, so concurrent calls rotate it
once rather than racing.

If a rotating token is stored *without* a refresh token it works until it
expires and then stops. The sidebar header says so while that is true, and
signing in again fixes it.

### Bot tokens

A bot token (`xoxb-…`) works, with limits that are worth knowing because they are
Slack's, not this plugin's. Measured against a real workspace:

| | Bot token | User token |
| --- | --- | --- |
| Public channels | all of them are listed, but reading one requires joining it (`conversations.history` → `not_in_channel`), and the join is visible in the channel | the ones you're in, no join needed |
| Your 1:1 DMs with colleagues | **not possible** — the only DMs a bot sees are DMs with the app itself | yes |
| Search | **not possible** — `search.messages` rejects bot tokens (`not_allowed_token_type`) even with `search:read.*` granted | yes |
| Sending | posts as the app, with an APP badge | posts as you |
| Read state | the app's own cursor | yours, shared with every Slack client |

### Two identities side by side

Both tokens can live in the keyring at once. The sidebar header carries an
account chip — a glyph, the account name, and a chevron — and clicking it opens a
chooser with **My account** and **The app**. An identity with no stored token is
greyed out, and picking it reports why in the header subtitle instead of saving a
preference that cannot work. **Act as** in the plugin settings sets the default.

The two are genuinely separate identities, so each keeps its own conversation
list, user cache and read cursors (`cursors-user.json` vs `cursors-bot.json`).
Switching clears the view and reloads rather than showing one identity's unread
counts against the other's conversations.

Set **Your Slack user ID** in the plugin settings when using a bot token.
`auth.test` reports the *app's* user id, so without it your own messages are
attributed to a stranger, they inflate the unread count, and `@you` never
matches. With it set, both identities count as "you".

## How unread is computed

Slack's `conversations.info` returns `unread_count`/`last_read` for DMs but not
reliably for channels, so unread is computed locally: `slack.sh` keeps a read
cursor per conversation in `${XDG_STATE_HOME:-~/.local/state}/noctalia-slack/cursors.json`
and counts anything newer that isn't yours. Every few minutes `sync-read`
reconciles those cursors with Slack's own read state, so reading a channel on
your phone still clears the badge here.

Only *watched* conversations are polled in the background: all DMs, plus any
channel you pin (the pin button in the list or the header), capped by the
**Watched conversations** setting. Each watched conversation costs one API call
per round, so the cap is the knob that controls API traffic. The conversation
you have open is polled faster, on its own timer.

## Layout

- **Bar widget** — unread count; badge turns to the error colour when any
  watched conversation mentions you. Right-click refreshes.
- **Conversation list** — search, unread badges, last-message previews, pin
  toggles. Ordered mentions → unread → pinned → most recent.
- **Transcript** — grouped consecutive messages, day separators, a "new" marker
  at your read cursor, reactions (click to toggle), thread reply counts, file
  links, link unfurls. Hover a message for *reply in thread* and *copy*.
- **Composer** — Enter sends, Shift+Enter adds a line, grows to six lines.
- **Notifications** — for DMs and mentions, announcing the newest genuinely
  *unread* message (never your own reply sitting on top of it) with the sender's
  profile picture as the icon. Avatars are mirrored to
  `~/.cache/noctalia-slack/avatars/` and passed as the `image-path` hint, since
  notification daemons want a real file; the same local files are used in the
  transcript so an avatar cannot pop in late while scrolling.

Message text is rendered through `Components/Mrkdwn.js`: mentions, channel
links, URLs, `*bold*`, `_italic_`, `~strike~`, inline code, fenced blocks,
blockquotes and `:emoji:`.

### Emoji

- **Standard shortcodes** resolve from a curated table of ~165 common codes
  (`:tada:`, `:joy:`, `:thumbsup:`…). Anything outside it stays as literal
  `:text:`. Noctalia's own 1870-entry emoji dataset is deliberately *not* used as
  a fallback: it is keyed by CLDR description (`face_with_tears_of_joy`) rather
  than Slack shortcode (`joy`), and testing it against known-correct codes
  resolved only 77 of 164 — 12 of those to the wrong glyph.
- **Custom workspace emoji** work. `slack.sh emoji` mirrors them from
  `emoji.list` into `~/.cache/noctalia-slack/emoji-img/` once and renders them
  inline as local images, including one level of `alias:` indirection. Remote
  URLs are not used directly because Qt rich text loads them unreliably.
- Shortcodes inside `` `code` `` and fenced blocks are left as text, not
  substituted.

## Files

| File | Role |
| --- | --- |
| `slack.sh` | all Slack access; every subcommand prints one JSON object |
| `oauth-login.py` | OAuth2 sign-in: loopback callback listener, PKCE, token storage |
| `Main.qml` | state, polling cadence, notifications |
| `Panel.qml` | the sidebar shell and view switching |
| `BarWidget.qml` | bar entry and unread badge |
| `Settings.qml` | side, width, intervals, notification toggles |
| `Components/` | `ConversationList`, `MessageList`, `MessageItem`, `Composer`, `Mrkdwn.js` |

`slack.sh` is usable on its own:

```sh
./slack.sh me
./slack.sh list                      # joined conversations + browsable public channels
./slack.sh --me U01ABCDEFGH history C0123 30   # attribute messages to a given account
./slack.sh join C0123
./slack.sh poll C0123,D0456
./slack.sh replies C0123 1787123637.474259
./slack.sh send C0123 "hello"
./slack.sh read C0123 1787123637.474259
./slack.sh react C0123 1787123637.474259 thumbsup
./slack.sh --token bot me            # force an identity
./slack.sh tokens                    # which identities are available
./slack.sh emoji                     # sync custom workspace emoji
./slack.sh avatars                   # mirror profile pictures locally
./slack.sh credentials               # is the app able to sign in / renew?
./oauth-login.py https://localhost:3000   # the sign-in flow, standalone
./slack.sh reset            # drop the conversation/user/identity caches
```

Requires `curl`, `jq`, `secret-tool`; `wl-copy` for the copy action and
`notify-send` for notifications.
