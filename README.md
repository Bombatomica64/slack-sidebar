# Slack (Noctalia plugin)

A Slack chat in a full-height Noctalia sidebar: conversation list with unread
badges and previews, transcript with threads and reactions, and a composer that
posts back to Slack. Shaped after the sidebar-chat layout in
[end-4/dots-hyprland](https://github.com/end-4/dots-hyprland) — the conversation
picker slides aside to reveal the transcript, and the composer stays pinned to
the bottom.

## Install

Requires **noctalia-shell 4.x** (developed against 4.7.7).

All Slack access goes through `slack-agent`, a compiled binary the plugin builds
for itself on first run, so the machine needs a toolchain:

| | |
| --- | --- |
| Debian / Ubuntu | `apt install make clang qt6-base-dev libsecret-1-dev libssl-dev libsqlcipher-dev` |
| Arch | `pacman -S make clang qt6-base libsecret openssl sqlcipher` |
| Fedora | `dnf install make clang qt6-qtbase-devel libsecret-devel openssl-devel sqlcipher-devel` |

**clang 17 or newer.** gcc cannot build this — see
[Modules](#modules-and-the-compiler-floor-they-cost) for the details.
Optional at runtime: `wl-copy` for the copy action, `notify-send` for
notifications, `xdg-open` to open links and the sign-in page.

```sh
git clone https://github.com/Bombatomica64/slack-sidebar.git ~/.config/noctalia/plugins/slack
```

Then enable **Slack** in Noctalia's Settings → Plugins, and add its widget to the
bar. The directory name must be `slack`, matching the `id` in `manifest.json`.

The first time the plugin starts it runs `make install` for you, into
`~/.cache/noctalia-slack/bin/`, and says so in the header while it does. If that
fails the header explains what is missing; `make` in the plugin directory shows
the real error. If you would rather not build anything, each release also ships
a prebuilt `slack-agent` — drop it in that directory.

While hacking on it, turn on the per-plugin hot reload (the bug icon on the
plugin card) — it only appears when the shell runs with `NOCTALIA_DEBUG=1`.
Without it, disabling and re-enabling the plugin will *not* pick up your edits:
Noctalia only busts Qt's component cache from its own reload path, so you would
keep loading the previously compiled QML.

## Setup

Tokens live only in the OS keyring (read and written through libsecret);
nothing is written to a config file. You do not have to put them there yourself
— signing in does it.

Signing in happens in the plugin — there is no code to copy anywhere:

1. Slack app → **Basic Information → App Credentials**: put the **Client ID** and
   **Client Secret** into the plugin settings and save. They go to the keyring,
   never to `settings.json`.
2. Slack app → **OAuth & Permissions → Redirect URLs**: register the plugin's
   **Redirect URL** (default `https://localhost:3000`) and Save.
3. Sidebar → click the account chip → **Sign in with Slack**.

`slack-agent signin` then serves that redirect on loopback, opens the browser, and
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
| Off switch | **Keep a local archive** in the plugin settings, or `--no-archive` |

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
**Watched conversations** setting. Each watched conversation costs one API call
per round, so the cap is the knob that controls API traffic. The conversation
you have open is polled faster, on its own timer.

## Layout

- **Bar widget** — unread count; badge turns to the error colour when any
  watched conversation mentions you. Right-click refreshes.
- **Conversation list** — search, unread badges, last-message previews, pin
  toggles. Ordered mentions → unread → pinned → most recent.
- **Transcript** — grouped consecutive messages, day separators, a "new" marker
  at your read cursor, reactions (click to toggle), thread reply counts with the
  repliers' faces, file links, and link previews. Hover a message for *reply in
  thread* and *copy*.
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
- **Custom workspace emoji** work. `slack-agent emoji` mirrors them from
  `emoji.list` into `~/.cache/noctalia-slack/emoji-img/` once and renders them
  inline as local images, including one level of `alias:` indirection. Remote
  URLs are not used directly because Qt rich text loads them unreliably.
- Shortcodes inside `` `code` `` and fenced blocks are left as text, not
  substituted.

## Link previews

Slack unfurls some links itself and sends the result in `attachments`; those are
drawn as-is. Every other `<https://…>` in a message is crawled here:
`slack-agent unfurl` fetches the page and reads its OpenGraph/Twitter-card
metadata, mirrors the preview image and favicon into
`~/.cache/noctalia-slack/unfurl-img/`, and caches the card in
`~/.cache/noctalia-slack/unfurl/` for a week (six hours for a page that failed,
so a flaky host is retried but a dead link is not re-fetched every poll). Turn
it off with **Link previews** in the plugin settings.

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
make check           # what CI gates on: strict warnings, tests, sanitizers, QML parse
make install         # install the agent where the plugin looks for it
make print-config    # which compiler, standard and version were chosen
```

Plain GNU make, no CMake: the native side is three translation units, and a
generator that writes a build system to build three files is machinery nobody
wants to review.

| Knob | Effect |
| --- | --- |
| `CXX=g++-14` | pick a compiler (default: `clang++` if installed) |
| `OPT=-O0` | optimisation level (use this, not `CXXFLAGS=`, which would drop `-std`) |
| `STRICT=1` | `-Werror` |
| `SANITIZE=1` | AddressSanitizer + UndefinedBehaviorSanitizer (clang only, see below) |
| `PORTABLE=1` | static libstdc++/libgcc, for release artifacts |

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
`gcc:latest` container with `ALLOW_GCC=1` (which lifts the Makefile's gate) and
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
`~/.cache/noctalia-slack/bin/`.

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
| `gcc-modules-probe` | **non-blocking.** Installs gcc 15 and tries the build, so every push re-asks whether gcc can compile this yet. The answer lands in the run summary. |
| `sanitizers` | the same tests under ASan + UBSan (clang) |
| `fuzz` | two minutes of libFuzzer over the parser, uploading any crashing input as an artifact |
| `coverage` | llvm-cov over both test binaries; table in the run summary, HTML report as an artifact. Reports, never gates. |
| `qml` | parses every `.qml` with `qmlformat` |
| `plugin` | every setting `Settings.qml` saves has a default in `manifest.json`, every manifest entry point exists, and no QML still reaches for the retired scripts |

The QML job is a *parse* gate, not a lint. `qmllint` would be better, but it
cannot resolve Noctalia's `qs.Commons` and `qs.Widgets` modules, so every run
would be drowned in unresolved-import warnings. Parsing still catches the class
of error that otherwise shows up as a silently blank sidebar.

`.github/workflows/release.yml` runs on a `v*` tag: it checks the tag matches
`manifest.json`, builds with static libstdc++, verifies the binary runs, and
attaches it to the release with a `sha256`. Since the plugin cannot work without
the binary, that artifact is the escape hatch for a machine whose compiler is
too old — drop it into `~/.cache/noctalia-slack/bin/` and the plugin will use
it.

## Scrolling

The transcript is built to hold a steady frame at 120 Hz.

- **The model is diffed, not replaced.** A poll re-delivers the same sixty
  messages every few seconds; handing a fresh array to a ListView destroys and
  rebuilds every delegate, which is what used to make the transcript flicker and
  lose your place. `MessageList.qml` now updates only the rows that actually
  changed — an unchanged poll does nothing at all.
- **Delegates are recycled** (`reuseItems`) with about two screenfuls cached
  either side, so a flick does not have to build a delegate per frame.
- **Wheel events bypass Flickable's own stepping.** `Components/SmoothList.qml`
  takes them first: a touchpad's pixel deltas are applied 1:1, and a mouse notch
  aims a short animation that later notches re-aim rather than restart. Content
  positions are left sub-pixel, because snapping them to whole pixels quantises
  the motion.
- **Message text is rendered once.** Slack mrkdwn is turned into rich text in
  `Main.qml` and memoised by message text, so a poll only renders what is new,
  and grouping, day separators and the unread rule are computed with the row
  rather than in a delegate binding that would be redone on every recycle.
- **Scroll position is held across updates.** Following the newest message
  re-arms itself when you scroll back to the bottom, and when older messages
  fall out of the history window while you are reading, the topmost visible
  message is pinned where it was instead of jumping.

## Files

| File | Role |
| --- | --- |
| `native/agent_main.cpp` | `slack-agent`: subcommand dispatch |
| `native/api.cppm` | Slack Web API, token selection and rotation |
| `native/store.cppm` | conversation, user and read-cursor caches |
| `native/archive.cppm` | the encrypted message archive |
| `native/commands.cppm` | one function per subcommand |
| `native/oauth.cppm` | OAuth2 sign-in: loopback TLS listener, PKCE, token storage |
| `native/net.cppm` | HTTP on Qt Network, several requests in flight at once |
| `native/keyring.cppm` | the OS keyring, through libsecret |
| `native/util.cppm` | paths, atomic writes, the JSON output contract |
| `Main.qml` | state, polling cadence, notifications |
| `Panel.qml` | the sidebar shell and view switching |
| `BarWidget.qml` | bar entry and unread badge |
| `Settings.qml` | side, width, intervals, notification toggles |
| `native/html.cppm` | HTML metadata parser behind the link previews |
| `native/tests/` | unit tests for the parser and the agent's pure logic, the fuzz target and its corpus |
| `Makefile` | builds all of the above; see **Building** |
| `Components/` | `ConversationList`, `MessageList`, `MessageItem`, `SmoothList`, `LinkCard`, `Composer`, `Mrkdwn.js` |

`slack-agent` is usable on its own. Every subcommand prints one JSON object and
exits 0; errors are `{"ok":false,"error":"..."}`, so nothing downstream has to
read exit codes or stderr.

```sh
agent=~/.cache/noctalia-slack/bin/slack-agent

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
