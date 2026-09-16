# Slack (Noctalia v5 plugin)

A Slack chat in a full-height Noctalia sidebar: conversation list with unread
badges, avatars and previews, transcript with threads and reactions, and a
composer that posts back to Slack.

This is the **Noctalia v5 Luau** plugin (`plugin_api = 9`), plugin id
`lollo/slack`. v5 replaced the QML plugin system outright, so the QML entry
points this repository used to ship stopped being loaded at all; `Main.qml`,
`Panel.qml`, `BarWidget.qml`, `Settings.qml`, `Components/` and `manifest.json`
are gone and `plugin.toml` + `service.luau` / `panel.luau` / `widget.luau` took
their place. The compiled `slack-agent` helper under `native/` is unchanged —
every Slack call still goes through it.

> **Running Noctalia 4.x?** This commit does not work on it. The last QML
> version of the plugin is commit
> [`57cd1f3`](https://github.com/Bombatomica64/slack-sidebar/commit/57cd1f3),
> the tip of `master` before the port. Check that out (or tag it) and follow its
> own README; it will not receive further changes.

## Install

Requires **noctalia-shell 5.x** (developed against 5.1.0). The helper needs
`libsecret`, OpenSSL, SQLCipher and Qt 6 at runtime; optionally `wl-copy` for
the copy action and `xdg-open` for links.

### From a release (nothing to build)

Each release ships the whole plugin with the helper already inside it, so
extracting it is the entire install:

```sh
tar -xzf slack-plugin-x86_64-linux-gnu.tar.gz -C ~/.local/share/noctalia/plugins
noctalia msg config-reload
noctalia msg plugins enable lollo/slack
```

Check it against the published `.sha256` first if you like. The archive's top
directory is `slack`. Under v5 the plugin **id** comes from `plugin.toml`
(`lollo/slack`) rather than from the directory name, but the directory is still
what `noctalia.pluginDir()` resolves to — and that is where the plugin looks for
`bin/slack-agent` — so keep it.

The published binaries are built against **glibc 2.39**, so they run on Debian 13
and newer, Arch, Ubuntu 24.04 and newer, and Fedora 40 and newer. Anything older
— Debian 12, for one — has to build from a clone, which has no such floor.

### From a clone

Clone anywhere and symlink it into the plugins directory, or clone straight into
it:

```sh
git clone https://github.com/Bombatomica64/slack-sidebar.git ~/src/slack-sidebar
ln -s ~/src/slack-sidebar ~/.local/share/noctalia/plugins/slack
cd ~/src/slack-sidebar && make install     # builds the helper into bin/
noctalia msg config-reload
noctalia msg plugins enable lollo/slack
```

Then add the **Slack** widget to a bar in Noctalia's settings.

`make install` puts the helper where the plugin looks for it —
`${XDG_DATA_HOME:-~/.local/share}/noctalia/plugins/slack/bin/slack-agent`,
which is `noctalia.pluginDir() .. "/bin/slack-agent"`. Override the destination
with `make install PREFIX=/somewhere/else` (the binary lands in
`$PREFIX/bin/`). Unlike v4, **the plugin does not build the helper for you on
first start**: a missing or unrunnable binary is reported in the panel header
and nothing else happens. Each release also ships the bare `slack-agent` binary
on its own, for a machine whose compiler is too old — drop it into
`<plugin dir>/bin/`.

Toolchain for building it:

| | |
| --- | --- |
| Debian / Ubuntu | `apt install make cmake ninja-build clang qt6-base-dev libsecret-1-dev libssl-dev libsqlcipher-dev` |
| Arch | `pacman -S make cmake ninja clang qt6-base libsecret openssl sqlcipher` |
| Fedora | `dnf install make cmake ninja-build clang qt6-qtbase-devel libsecret-devel openssl-devel sqlcipher-devel` |

**clang 17 or newer**, and **CMake 3.28+ with Ninja**, which is the floor for
building C++20 modules. gcc cannot build this — see
[Modules](#modules-and-the-compiler-floor-they-cost) for the details.

### Reloading while hacking

`.luau` edits hot-reload on save. `plugin.toml` edits do **not**: a changed
manifest needs the plugin re-enabled, because `noctalia msg config-reload`
does not re-register panel ids.

```sh
noctalia msg plugins disable lollo/slack && noctalia msg plugins enable lollo/slack
```

## Setup

Tokens live only in the OS keyring (read and written through libsecret);
nothing is written to a config file.

Unlike v4 there is no sign-in UI in the plugin — the v5 port does not ship a
credentials form or a browser handoff, so the two steps that need one are done
from a terminal with the helper directly:

1. Slack app → **Basic Information → App Credentials**:

   ```sh
   ~/.local/share/noctalia/plugins/slack/bin/slack-agent set-credentials <client-id> <client-secret>
   ```

   They go to the keyring, never to a settings file.
2. Slack app → **OAuth & Permissions → Redirect URLs**: register
   `https://localhost:3000`, exactly, and Save. It is not configurable — the
   agent can only answer the callback on loopback, and a value that has to
   match on both sides is not worth a text field to get wrong.
3. Sign in:

   ```sh
   ~/.local/share/noctalia/plugins/slack/bin/slack-agent signin
   ```

`slack-agent signin` serves that redirect on loopback, opens the browser, and
receives the callback itself: it verifies `state`, exchanges the code, and stores
the access and refresh tokens. Because Slack treats a loopback redirect as a
non-web URI it requires PKCE, so the flow always sends `code_challenge` (S256)
and the matching `code_verifier`. The listener speaks TLS using a self-signed
certificate generated once into the cache dir — the browser will warn about it
the first time, which is expected for a certificate that never leaves the
machine.

When the session later expires and cannot be renewed the panel header says so;
re-run `slack-agent signin`. The plugin will not reopen the sign-in by itself the
way v4 did.

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
token, and the agent renews it by itself when Slack answers `token_expired` — under `flock`, so concurrent calls rotate it
once rather than racing.

If a rotating token is stored *without* a refresh token it works until it
expires and then stops. The sidebar header says so while that is true.

When Slack does reject the credentials and renewal is impossible, every
subcommand reports `needsSignIn: true` and the plugin reopens the sign-in by
itself (at most once every two minutes). That needs the Client ID and Secret in
the keyring — without them it cannot re-authenticate unattended, and the header
says so instead.

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

Both tokens can live in the keyring at once. Which one is used is the
`token_preference` setting (`user` / `bot` / `auto`); changing it restarts the
service. The v4 account chip that switched identity from the panel at runtime is
not ported — there is one identity per session, chosen in the settings.

The two are genuinely separate identities, so each keeps its own conversation
list, user cache and read cursors (`cursors-user.json` vs `cursors-bot.json`).
Switching clears the view and reloads rather than showing one identity's unread
counts against the other's conversations.

Set `identity_user_id` in the plugin settings when using a bot token.
`auth.test` reports the *app's* user id, so without it your own messages are
attributed to a stranger, they inflate the unread count, and `@you` never
matches. With it set, both identities count as "you".

## How it works

Nothing here talks to Slack. Every Slack call goes through the **compiled
`slack-agent` helper**, copied unchanged from the v4 tree into `bin/slack-agent`
and resolved at runtime via `noctalia.pluginDir()`. The helper prints exactly one
JSON object per invocation; the service shells out with `noctalia.runAsync`,
decodes the object, and publishes the result to `noctalia.state`.

Credentials, the OAuth refresh token, the encrypted local archive and the read
cursors all still live inside the helper (keyring + `~/.cache/noctalia-slack`).
The port did not touch any of that.

Three entries, three Luau VMs:

| Entry | File | Role |
| --- | --- | --- |
| service | `service.luau` | Owns every `slack-agent` invocation, the polling loop, read-state sync and desktop notifications. Publishes `slack_status` and `slack_active`; consumes `slack_command`. |
| widget | `widget.luau` | Bar glyph + unread count, tinted when unread. Click toggles the panel, right-click forces a refresh, middle-click marks the open conversation read. |
| panel | `panel.luau` | Conversation list → transcript → thread, master/detail in one column. Posts intents to `slack_command`. |

Subcommands used: `credentials` (startup probe), `me`, `list`, `poll`,
`history`, `replies`, `send`, `read`, `react`, `join`, `sync-read`, `avatars`.
Global flags
`--token`, `--me` and `--no-archive` are built from the settings exactly as the
v4 `_run()` did.

## Settings

Intervals are **seconds** here; v4 stored milliseconds. The defaults are the
user's live v4 values converted:

| v5 setting | v4 setting | Default |
| --- | --- | --- |
| `poll_interval` | `pollInterval` 45000 | 45 s |
| `active_poll_interval` | `activePollInterval` 6000 | 6 s |
| `sync_interval` | `syncInterval` 300000 | 300 s |
| `history_limit` | `historyLimit` | 60 |
| `max_watched` | `maxWatched` | 48 |
| `side` | `side` | `right` |
| `notify_dms` / `notify_mentions` | same | true |
| `mark_read_on_open` | `markReadOnOpen` | true |
| `archive_messages` | `archiveMessages` | true |
| `identity_user_id` | `identityUserId` | `U0AGP9EAM0D` |
| `token_preference` | `tokenPreference` | `bot` |

Widget-level: `show_count`, `glyph_color`, `unread_color`.

`max_watched` is 48, not the v4 16: only a **joined** conversation has a read
cursor, and in this workspace almost all of the unread sits in `#channels`
rather than DMs. The service watches every joined conversation (the open one and
pinned ones first), so the cap has to clear the joined count.

### Panel geometry

The panel is a full-height sidebar docked to a screen edge:

```toml
[[panel]]
id = "sidebar"        # position = "center_right"
[[panel]]
id = "sidebar_left"   # position = "center_left"
```

Both blocks run the same `panel.luau`. A panel **cannot resize or move itself** —
`width`/`height`/`position` are read once from the manifest — so there is no
`panel_width` setting: edit `width = 500` in `plugin.toml` and re-enable the
plugin. The `side` setting picks which of the two ids the bar widget toggles.
`position = "center_left"` was verified against the installed 5.1.0 shell (the
panel manager registers and opens `lollo/slack:sidebar_left`).

Neither `dismiss_on_outside_click` (API 8) nor `keyboard_focus` (API 10) is set,
which is what keeps `plugin_api` at 9 — nothing here needs more. Both were tried
and both looked like they made the panel self-dismiss shortly after opening, but
that observation is confounded: panels open on the **focused** output, and focus
was moving between monitors during the test. Re-add them if you want
click-outside-to-close.

The **pinned channel list is runtime state, not a setting**: it is persisted as
JSON in `noctalia.pluginDataDir()/pinned.json` and toggled from the panel header.

## Dropped or changed features

Listed because they exist in v4 and do not exist here.

* **`panelWidth` setting** — dropped, see *Panel geometry* above. `side` is kept
  and is implemented as two `[[panel]]` blocks.
* **The `unfurl` subcommand** — not called. Slack's own unfurls *are* rendered:
  `attachments[]` become bordered cards showing site / title / description. What
  is dropped is the v4 behaviour of crawling links Slack did not unfurl, and the
  card preview *image* (one `noctalia.download` per link, for a thumbnail in a
  500px column, is not worth it).
* **Avatars in notifications** — dropped. Conversation rows and message rows do
  show avatars, read from the helper's own cache (`avatars` returns
  `userId -> local file`, already downloaded into `~/.cache/noctalia-slack`), with
  `noctalia.download` of the `list` row's `image` URL into
  `pluginDataDir()/avatars/` as the fallback. But `noctalia.notify(title, body)`
  takes no icon argument, so notifications stay iconless.
* **Custom emoji rendering** — dropped. The `emoji` subcommand is not called;
  reactions render as `:name: count` text, and `:shortcodes:` in message bodies
  stay literal.
* **In-plugin OAuth sign-in and credential entry** — dropped. v4 had a Settings
  page with Client ID/Secret fields and a `signin` button driving a loopback
  OAuth flow. That needs a secret-safe form and a browser handoff; here the
  service only reports "session expired" and you re-run `slack-agent signin`
  from a terminal. `set-credentials` / `signin` / `tokens` are never invoked.
* **Identity switching from the panel** — dropped. v4 had an account chip that
  switched user/bot token at runtime and flushed all state. Here
  `token_preference` is a normal setting; changing it restarts the service.
* **Rich mrkdwn** — simplified but faithful. The text pipeline is a port of v4's
  `Components/Mrkdwn.js` (read it at the pre-port commit `57cd1f3`): one generic `<...>` entity pass (`<@U…>`/`<@U…|label>`
  against the helper's user map, `<#C…|name>`, `<!here>`/`<!channel>`/
  `<!subteam^S…|@group>`, `<url|label>`, `mailto:`), then `&lt;`/`&gt;`/`&amp;`/
  `&quot;`/`&#39;` decoding, then `:shortcode:` → unicode from the same emoji
  table v4 used. Conversation previews additionally run v4's `preview()`:
  fences dropped, `*_~` and backticks stripped, whitespace collapsed, and the
  `You: ` / `Author: ` prefix. **Previews are rendered before they are
  truncated** — truncating the raw text cut `<https://…|label>` entities in half
  and left the angle brackets on screen.
  Bold/italic/code/blockquote markers are left as literal characters in message
  *bodies* (`ui.label` has no rich text; `ui.markdown` is API 21 and Slack
  mrkdwn is not Markdown).
* **Archive-first loading** — dropped. v4 ran `archive` to paint the transcript
  from the local store before the network answered. Here `history` is the only
  read path; the archive is still written (unless `archive_messages` is off).
* **Message ordering** — changed. Messages render **newest-first (top)**. The
  declarative `ui.scroll` has no scroll-to-bottom, so the newest message is put
  where it is guaranteed to be on screen.
* **Emoji picker** — not ported. Existing reactions can be toggled by clicking
  them; a single quick `👍` button adds `thumbsup`. There is no way to add an
  arbitrary emoji.
* **File attachments** — messages list each file's name next to a paperclip
  glyph; files are not previewed or downloadable.
* **Self-building helper** — dropped. v4 probed three locations and ran `make` to
  build the agent into the cache. Here the binary is shipped in `bin/` and a
  failed `credentials` probe just reports "helper not runnable".

## Ported

Bar widget with unread count and tint; the polling loop with separate idle and
active intervals; read-state sync; DM/group-DM and mention notifications honoring
`notify_dms` / `notify_mentions` (with the v4 "first poll is not news" rule);
conversation list ordered mentions → unread → pinned → recency, with a filter
box; pinning; per-conversation avatars and unread/mention badges; message history with paging (`Load older`);
mark-read on open; sending messages; threads (open a thread, read replies, reply
into it); reaction toggling; joining an unjoined public channel; opening a
conversation in the Slack desktop app.

## The local archive

Every message the plugin sees is kept in an encrypted SQLite database on this
machine — from opening a conversation, from a thread, and from the background
poll, so a conversation nobody opens still accumulates.

It exists because Slack forgets. A free workspace hides history past ninety
days, a deleted message simply stops appearing, and leaving a company ends your
access to everything you wrote there. Past that window this file is the only
copy, which is why it is **append-only**: nothing here deletes a message, and
`slack-agent reset` clears the caches but deliberately leaves the archive alone.

It is also what makes opening a conversation instant — the transcript is read
from disk before the network call is out the door — and what makes the sidebar
readable with no network at all.

| | |
| --- | --- |
| Where | `~/.local/state/noctalia-slack/archive-{user,bot}.db`, mode 0600, one per identity |
| Encryption | SQLCipher, transparent at the page level — no message text, author or even the SQLite header is readable on disk |
| Key | 32 random bytes in the keyring as `archive-key`, created on first use |
| Off switch | the `archive_messages` setting, or `--no-archive` |

### Messages change, so revisions are kept

People edit messages on Slack. An archive that overwrote the previous text would
quietly lose what was actually said at the time, so a message whose *text*
changes keeps its old version in a `revisions` table — `slack-agent
archive-revisions <channel> <ts>` reads them back. Reactions and reply counts
churn on every poll and are not edits; those update in place without making a
revision.

### The key, and getting it back

The key exists in exactly one place. Lose the keyring entry and the archive is
unreadable, so there is a way to write it down:

```sh
slack-agent archive-key            # print it
slack-agent archive-key <hex>      # put it back, on a new machine
```

Anyone holding that key can read the archive, so treat it as you would the
token.

Both of those work with **no Slack token at all**, as does reading the archive
itself:

```sh
slack-agent --identity user archive C0123 50
slack-agent --identity user archive-stats
```

That is deliberate. Needing a working Slack token to reach your own decryption
key would be exactly backwards, and the case the archive most exists for —
having left the workspace — is the case where no token works any more.

### Worth knowing

- It grows without bound. That is the point of an archive rather than a cache,
  but it means the file wants backing up. It lives in `state/`, not `cache/`, so
  a backup tool that skips caches still catches it.
- A message deleted on Slack stays here. Detecting an upstream deletion is not
  reliably possible, and keeping it is the behaviour an archive should have
  anyway.

## How unread is computed

Slack's `conversations.info` returns `unread_count`/`last_read` for DMs but not
reliably for channels, so unread is computed locally: the agent keeps a read
cursor per conversation in `${XDG_STATE_HOME:-~/.local/state}/noctalia-slack/cursors.json`
and counts anything newer that isn't yours. Every few minutes `sync-read`
reconciles those cursors with Slack's own read state, so reading a channel on
your phone still clears the badge here.

Only *watched* conversations are polled in the background: all DMs, plus any
channel you pin (the pin button in the list or the header), capped by the
`max_watched` setting. Each watched conversation costs one API call
per round, so the cap is the knob that controls API traffic. The conversation
you have open is polled faster, on its own timer.

## Link previews

Slack unfurls some links itself and sends the result in `attachments`, and those
are drawn as cards in the panel. The **crawling** side — `slack-agent unfurl`,
which fetches a page Slack did not unfurl and reads its metadata — is still part
of the helper and still tested and fuzzed, but the v5 plugin never calls it. What
follows documents the helper; it is what you get if you run `unfurl` yourself,
and it is what the fuzz and address-guard tests protect.

### What the helper fetches

`slack-agent unfurl` fetches each `<https://…>` a message carries, reads its
OpenGraph/Twitter-card metadata, mirrors the preview image and favicon into
`~/.cache/noctalia-slack/unfurl-img/`, and caches the card in
`~/.cache/noctalia-slack/unfurl/` for a week (six hours for a page that failed,
so a flaky host is retried but a dead link is not re-fetched every poll).

What is and is not fetched:

- **http and https only**, and only to a public host. Literal loopback, link-local,
  private-range and `*.internal`/`*.local` addresses are refused, so a pasted
  `http://127.0.0.1:8080/shutdown` or a cloud metadata URL is never visited.
  This is a check on the address as written — it does not defend against a public
  hostname that resolves to a private one.
- Redirects are followed at most four times and stay on http(s); the response is
  capped and the whole fetch times out in twelve seconds.
- Only the links Slack itself renders as links (its `<…>` entity form) are
  crawled, at most 24 per call and 3 previews per message. Addresses are judged
  with `QHostAddress` rather than by prefix matching, so a literal loopback,
  link-local, site-local, multicast or broadcast address is refused whatever
  form it is written in.
- The fetch is a plain unauthenticated GET from your machine, exactly as if you
  had opened the link — the page learns your IP, and nothing else.

### The HTML parser

Reading metadata out of arbitrary HTML in an unknown encoding is the one part of
this plugin that is not a good fit for shell: quoted, unquoted and bare
attributes, comment and `<script>` skipping, entity decoding, cp1252 pages, and
truncation that does not cut a UTF-8 character in half. `native/html_meta.cppm`
does it in a single pass — C++26, built with clang or gcc at whatever standard
the toolchain accepts, `c++2c` first.

It is a hand-written scanner rather than a call into an HTML5 parser, and that
is a deliberate trade rather than an oversight. A real parser (lexbor, gumbo)
builds a DOM for a document we only ever ask nine questions about, and neither
is packaged on Debian or Ubuntu — lexbor is not there at all, gumbo has been
unmaintained since 2016 — so using one would mean vendoring a whole HTML5
implementation into a plugin people install by cloning. The scanner is ~250
lines, never allocates a tree, and is fuzzed. If it ever needs to answer
questions about the document *body*, that trade flips and a library wins.

It is part of `slack-agent`, so it is built with everything else.

## Building

```sh
make                 # build the helper into build/
make test            # unit tests
make fuzz            # fuzz the parser (clang only; FUZZ_TIME=300 for longer)
make coverage        # what the tests reach, and what they do not
make check           # what CI gates on: strict warnings, tests, sanitizers, Luau parse
make luau            # parse and compile every .luau entry point
make install         # install the agent where the plugin looks for it
make print-config    # which compiler, standard and version were chosen
```

The build system of record is `CMakeLists.txt`; the `Makefile` is a thin shim
over it, kept because the plugin builds its own helper on first run with a
single command. CMake directly, if you prefer:

```sh
cmake -S . -B build -G Ninja -DSLACK_STRICT=ON
cmake --build build
ctest --test-dir build --output-on-failure
cmake --build build --target install
```

Ninja is not optional and the configure step says so: module builds need
dependency scanning, and only the Ninja generator can express the dynamic
dependencies that produces.

| Knob | CMake option | Effect |
| --- | --- | --- |
| `CXX=g++-14` | `CMAKE_CXX_COMPILER` | pick a compiler (default: `clang++` if installed) |
| `OPT=-O0` | `CMAKE_CXX_FLAGS` | optimisation level |
| `BUILD_TYPE=Debug` | `CMAKE_BUILD_TYPE` | default `RelWithDebInfo` — `-O2` with debug info |
| `STRICT=1` | `SLACK_STRICT` | `-Werror` |
| `SANITIZE=1` | `SLACK_SANITIZE` | AddressSanitizer + UndefinedBehaviorSanitizer (clang only, see below) |
| `PORTABLE=1` | `SLACK_PORTABLE` | static libstdc++/libgcc, for release artifacts |
| `ALLOW_GCC=1` | `SLACK_ALLOW_GCC` | lift the clang-only gate and try gcc anyway |

### Why CMake, for nine files

The earlier build was a hand-written Makefile, on the reasoning that a generator
writing a build system for a handful of translation units is machinery nobody
wants to review. Two things about modules made that wrong.

A binary module interface records the configuration it was compiled under, and a
consumer compiled under a different one is rejected — not with a flag mismatch
warning but with `POSIX thread support was disabled in precompiled file`,
followed by every name in the module failing to resolve. The Makefile's `.pcm`
rules depended on their sources and nothing else, so a `.pcm` left over from a
build with different flags was silently reused, and the error pointed at the
importer rather than at the stale file. CMake tracks what each BMI was built
with and rebuilds it when that changes.

The second is the import graph. The Makefile listed it by hand — eight
dependency lines that were a copy of the truth, maintained by hand, and wrong
the moment an `import` was added. CMake runs `clang-scan-deps` over the sources
and orders the build from what is actually written in them.

### Modules, and the compiler floor they cost

Our own code is **C++20 named modules** (`native/*.cppm`), not header/source
pairs: one file per component instead of two that have to be kept in step, and
nothing escapes one but what `export` names. Qt, libsecret and OpenSSL come in
as ordinary `#include`s inside each module's global module fragment — Qt does
not ship as modules, and will not while it still supports header-only use.

That costs a compiler floor, and the floor turned out to be **clang only**:

| | |
| --- | --- |
| clang 17+ | works |
| gcc 13 | *segfaults* compiling a four-line program that imports a module and uses `std::string` at `-O2`. Still the default on Ubuntu 24.04 LTS. |
| gcc 14 | internal compiler error on this code under every flag combination tried — `gen_enumeration_type_die` (dwarf2out.cc) with debug info, `nothrow_spec_p` (cp/except.cc) without it |
| gcc 15 | fails — 15.3.0 against Qt 6.8.2, measured in CI |
| gcc 16 | **does not crash — it diagnoses**, and it is right to |

That last one changes the diagnosis. gcc 16.2.0 says:

```
qbytearrayalgorithms.h:80: error: 'QtPrivate::toIntegral<...>'
  exposes TU-local entity '...::<lambda()>'
```

which is [basic.link]/17: a module interface may not expose a TU-local entity,
and a lambda in the global module fragment is one. Qt's headers are full of
them. So the honest statement is **not** "gcc cannot compile modules" — it is
that **putting Qt in a module's global module fragment is ill-formed**, gcc 16
is the first compiler to enforce it, and clang has no such check at all (clang
18 accepts a minimal repro silently, and has no flag to turn one on).

This build therefore rests on clang's leniency rather than on being correct. It
works, and will keep working until clang implements that rule. The fix, if it is
ever wanted, is to keep Qt out of module interface units entirely — which means
the Qt-facing code stops being modules and goes back to headers and sources,
leaving `html.cppm` (which touches no Qt, and conforms) as the only module. CI keeps asking
anyway: the non-blocking `gcc-modules-probe` job builds in the official
`gcc:latest` container with `ALLOW_GCC=1` (which lifts the build's gate) and
writes the verdict, with the version it actually got, into the run summary. It
tracks `latest` rather than a pinned major precisely so it cannot go quietly
stale — the first version of this job was pinned to 15 and was already a release
behind. The gcc module build rules are kept for that day.

Three consequences worth knowing:

- The standard library still comes in by `#include`, in the module's global
  module fragment. `import std;` needs gcc 15 or libc++'s prebuilt std module,
  and neither is a thing this plugin can require.
- **In a file that imports the module, `#include` directives must come first.**
  gcc (13 and 14 alike) does not reconcile a std header included in the importer
  with the same header pulled in by the module's global module fragment, and
  reports every entity in it as a redefinition. Includes first, imports second.
- **`-Wmissing-declarations` is clang-only.** It exists to catch a function in a
  `.cpp` that should have been `static`, and gcc applies it to module interface
  units too, where every exported definition *is* its declaration.
- **`QStringLiteral` cannot be used in a module purview here.** It expands to a
  call to `QtPrivate::qMakeStringPrivate`, which Qt declares `static` — a
  TU-local entity, and a module interface may not expose one. It compiles in a
  module that imports nothing and stops compiling the moment that module gains
  an import, so rather than leave a landmine, nothing uses it: string constants
  go through `slack::util::qs()`.

If your compiler cannot build it the plugin cannot run at all — every Slack call
goes through this binary — so the build refuses with a message naming what does
work, and each release ships a prebuilt `slack-agent` to drop into
`<plugin dir>/bin/`.

One more rule worth knowing, since breaking it is silent until it is not:
exported functions in these modules are deliberately **not `inline`**. An
exported inline function may not name a TU-local entity, and most of them call
helpers from an anonymous namespace; each module is a single translation unit,
so `inline` was buying nothing anyway. gcc diagnoses this, clang does not.

### Coverage

`make coverage` builds both test binaries with clang's source-based
instrumentation, runs them, and prints llvm-cov's table followed by the list of
modules under `COVERAGE_FLOOR` (25%) line coverage. A line-by-line HTML report
lands in `build/cov/html/`. CI runs it on every push and puts the table in the
run summary.

Nothing fails for a low number — the point is that the gap is visible and
therefore a decision. As it stands the parser is well covered and most of the
agent is not:

| | line coverage |
| --- | --- |
| `html.cppm` | 94% |
| `util.cppm` | 33% |
| `commands.cppm` | 8% |
| `api.cppm` | 7% |
| `net.cppm` | 5% |
| `store.cppm` | 1% |
| `keyring.cppm`, `oauth.cppm` | 0% |

Most of that is honest: those modules are mostly HTTP calls, keyring access and
an OAuth flow, none of which belong in a unit test. What *was* worth testing is
the pure logic, and `native/tests/agent_test.cpp` now covers it — the address
guard especially, which is the piece deciding whether this machine fetches a URL
somebody pasted into a chat.

### Fuzzing

The parser reads bytes chosen by whoever owns the page behind a pasted link, so
it is fuzzed with libFuzzer under ASan and UBSan, over a small checked-in corpus
in `native/tests/corpus/`. The target asserts the parser's *contract*, not just
"did not crash": every field it returns is valid UTF-8, capped fields respect
their caps, and every URL it emits starts with a lowercase `http://` or
`https://`.

That has been worth it. Four bugs so far, none of which anyone had thought to
write a test for — non-UTF-8 bytes escaping into the result from a page with an
unrecognised charset; the fix for that one breaking the length cap, because
scrubbing after truncating turns one byte into three; a URL with an accepted
scheme but no authority (`https:nonsense`) passing as fetchable; and a
mixed-case scheme reaching a downstream guard that only compares lowercase.
Each is now also a unit test.

The warning set is `-Wall -Wextra -Wpedantic` plus the conversion, shadow,
old-style-cast and cast-alignment families — the ones that matter when the input
is attacker-shaped bytes and every other line is an index or a shift — with
`-D_GLIBCXX_ASSERTIONS`, `_FORTIFY_SOURCE` and a stack protector always on.

`-Werror` is deliberately **not** the default. A compiler newer than any given
commit will eventually invent a warning, and that must not be the thing that
stops someone's link previews from building on first use. CI turns it on; your
machine does not.

## CI

`.github/workflows/ci.yml` runs on every push and pull request:

| Job | What it gates |
| --- | --- |
| `native` | builds and runs the tests with `-Werror`, then checks the agent answers with no keyring and refuses a loopback URL |
| `gcc-modules-probe` | **non-blocking.** Builds in the official `gcc:latest` container, so every push re-asks whether gcc can compile this yet. The answer lands in the run summary. |
| `sanitizers` | the same tests under ASan + UBSan (clang) |
| `fuzz` | two minutes of libFuzzer over the parser, uploading any crashing input as an artifact |
| `coverage` | llvm-cov over both test binaries; table in the run summary, HTML report as an artifact. Reports, never gates. |
| `luau` | `luau-compile --null` over every `.luau` file — a parse-and-compile gate |
| `plugin` | every `getConfig` key has a `[[setting]]` in `plugin.toml`, every entry point file exists, every `tr()` key resolves in `translations/en.json` and nothing in it is orphaned |

The `luau` job replaced a `qml` job that parsed every `.qml` with `qmlformat`,
for the same reason it existed: a syntax error in an entry point is otherwise
invisible until the shell quietly declines to load the plugin. It is
`luau-compile`, not `luau-analyze` — the shell injects `noctalia`, `ui`, `panel`
and `widget` as globals and calls `onOpen`/`update`/`onClick` itself, so an
analyze pass with no definitions file reports nothing but unknown globals and
unused functions. Luau is not packaged on the runner, so the job takes the
`luau-ubuntu.zip` from the luau-lang/luau releases.

The `plugin` job is the v5 shape of the old manifest check. `plugin.toml` is the
only place a setting gets a default and a label, and `translations/en.json` the
only place a `tr()` key resolves, so a key present in one and not the other is a
setting that reads back `nil` or a label that renders as its own key — both of
which otherwise only show up at runtime, in the panel. The accessors are
discovered rather than listed: a local function that passes its own first
parameter straight to `noctalia.getConfig` or `noctalia.tr` counts as one, so
`cfgInt("poll_interval", 45)` is checked like a direct call.

`.github/workflows/release.yml` runs on a `v*` tag: it checks the tag matches the
`version` in `plugin.toml`, builds with static libstdc++, verifies the binary
runs and links no libstdc++ dynamically, and attaches both the bare binary and a
`slack/` tarball (`plugin.toml`, the `.luau` files, `translations/`, `LICENSE`,
`README.md` and `bin/slack-agent`) to the release, each with a `sha256`.

## Files

| File | Role |
| --- | --- |
| `plugin.toml` | manifest: id, settings, widget, the two panels, the service |
| `service.luau` | every `slack-agent` invocation, polling, read sync, notifications |
| `panel.luau` | the sidebar: conversation list, transcript, threads, composer |
| `widget.luau` | bar entry, unread count and tint |
| `translations/en.json` | every string the three entries render |
| `native/agent_main.cpp` | `slack-agent`: subcommand dispatch |
| `native/api.cppm` | Slack Web API, token selection and rotation |
| `native/store.cppm` | conversation, user and read-cursor caches |
| `native/archive.cppm` | the encrypted message archive |
| `native/commands.cppm` | one function per subcommand |
| `native/oauth.cppm` | OAuth2 sign-in: loopback TLS listener, PKCE, token storage |
| `native/net.cppm` | HTTP on Qt Network, several requests in flight at once |
| `native/keyring.cppm` | the OS keyring, through libsecret |
| `native/util.cppm` | paths, atomic writes, the JSON output contract |
| `native/html.cppm` | HTML metadata parser behind the link previews |
| `native/tests/` | unit tests for the parser and the agent's pure logic, the fuzz target and its corpus |
| `CMakeLists.txt` | builds all of the above; see **Building** |
| `Makefile` | a shim over CMake; `make install` puts the helper in `bin/` |

read exit codes or stderr.

```sh
agent=~/.local/share/noctalia/plugins/slack/bin/slack-agent

$agent me
$agent list                     # joined conversations + browsable public channels
$agent --me U01ABCDEFGH history C0123 30   # attribute messages to a given account
$agent join C0123
$agent poll C0123,D0456
$agent replies C0123 1787123637.474259
$agent send C0123 "hello"
$agent read C0123 1787123637.474259
$agent react C0123 1787123637.474259 thumbsup
$agent --token bot me           # force an identity
$agent tokens                   # which identities are available
$agent emoji                    # sync custom workspace emoji
$agent avatars                  # mirror profile pictures locally
$agent archive C0123 50          # read the local archive instead of Slack
$agent archive-revisions C0123 1787123637.474259
$agent archive-stats             # how much has been kept, and where
$agent archive-key               # print the archive key, or pass one to restore
$agent unfurl https://example.com/a https://example.com/b
$agent credentials              # is the app able to sign in / renew?
$agent signin https://localhost:3000
$agent reset                    # drop the conversation/user/identity caches

curl -sL https://example.com | $agent parse-html https://example.com   # the parser alone
```
