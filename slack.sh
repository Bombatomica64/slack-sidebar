#!/usr/bin/env bash
# Backend for the Noctalia Slack plugin.
#
# Every subcommand prints a single JSON object on stdout and exits 0 — errors are
# reported as {"ok":false,"error":"..."} so the QML side never has to care about
# exit codes or stderr.
#
# Auth: a Slack *user* token (xoxp-...) read fresh from the keyring on every call
# and never written to disk.
#
#   secret-tool store --label="Slack User Token" service slack-agents account user-token
#
# Required user scopes:
#   channels:history groups:history im:history mpim:history
#   channels:read    groups:read    im:read    mpim:read
#   users:read chat:write reactions:write
#   channels:write groups:write im:write mpim:write   (optional, for read receipts)
#
# Unread counts are computed locally against a persisted read cursor per
# conversation, because conversations.info only reports unread_count/last_read
# for DMs — never for channels. `sync-read` reconciles those cursors with
# Slack's own read state so reading on another device still clears the badge.

set -uo pipefail

# A bot token's auth.test reports the *app's* user id, not yours, which would
# make your own messages look like someone else's and stop @you from matching.
# `--me <id>` names the human account so "mine", unread and mentions stay right.
ME_OVERRIDE=""
# auto | user | bot — which keyring entry to authenticate as. The two tokens are
# genuinely different identities (different visible conversations, different read
# state), so each gets its own caches further down.
TOKEN_PREF="auto"
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --me)
      ME_OVERRIDE="${2:-}"
      # `shift 2` fails outright when the value is missing, which would leave
      # $1 untouched and spin this loop forever.
      shift
      [[ $# -gt 0 ]] && shift
      ;;
    --token)
      TOKEN_PREF="${2:-auto}"
      shift
      [[ $# -gt 0 ]] && shift
      ;;
    *) shift ;;
  esac
done

API="https://slack.com/api"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/noctalia-slack"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/noctalia-slack"
CONVOS_TTL=3600
ME_TTL=86400
MAX_PARALLEL=6
# Link previews are shared by both identities — a page's title does not depend
# on which token asked for it — so they live outside the per-identity caches.
UNFURL_DIR="$CACHE_DIR/unfurl"
UNFURL_ASSETS="$CACHE_DIR/unfurl-img"
UNFURL_TTL=604800        # a good page: a week
UNFURL_FAIL_TTL=21600    # a 404 or a timeout: retry in six hours
UNFURL_MAX_BYTES=1048576
ASSET_MAX_BYTES=4000000
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36"

mkdir -p "$STATE_DIR" "$CACHE_DIR" 2>/dev/null
chmod 700 "$STATE_DIR" "$CACHE_DIR" 2>/dev/null

# Set when Slack rejects the credentials and renewing them is not possible, so
# the UI can offer to sign in again instead of just showing a red line.
AUTH_DEAD=false

is_auth_error() {
  case "$1" in
    token_expired|token_revoked|invalid_auth|account_inactive|not_authed) return 0 ;;
    *) return 1 ;;
  esac
}

# fail <message> [slack-error-code]
fail() {
  local needs=false
  if [[ "$AUTH_DEAD" == true ]] || { [[ -n "${2:-}" ]] && is_auth_error "$2"; }; then
    needs=true
  fi
  jq -n --arg e "$1" --argjson needsSignIn "$needs" '{ok:false, error:$e, needsSignIn:$needsSignIn}'
  exit 0
}

need() { command -v "$1" >/dev/null 2>&1 || fail "missing dependency: $1"; }
need curl; need jq; need secret-tool

# ---------------------------------------------------------------- auth + http

# Prefer a user token (xoxp/xoxc) wherever one exists; fall back to a bot token
# so the plugin still works — in bot mode there are no DMs, no cross-device read
# state, and messages post as the app rather than as you. TOKEN_KIND is reported
# by `me` so the UI can say so out loud instead of silently showing nothing.
lookup_token() { secret-tool lookup service slack-agents account "$1" 2>/dev/null || true; }

# Apps with token rotation enabled issue "xoxe.xoxp-…" access tokens (and
# "xoxe-…" refresh tokens) instead of a permanent "xoxp-…".
kind_of() {
  case "$1" in
    xoxe.xoxp-*)   printf user ;;
    xoxe.xoxb-*)   printf bot ;;
    xoxp-*|xoxc-*) printf user ;;
    xoxb-*)        printf bot ;;
    *)             printf unknown ;;
  esac
}

is_rotating() { [[ "$1" == xoxe.* ]]; }

# Which keyring entries hold a usable token of each kind, so the UI can offer a
# switch only when there is something to switch to.
HAVE_USER=false
HAVE_BOT=false
for account in user-token bot-token; do
  candidate="$(lookup_token "$account")"
  [[ -n "$candidate" ]] || continue
  case "$(kind_of "$candidate")" in
    user) HAVE_USER=true ;;
    bot)  HAVE_BOT=true ;;
  esac
done

TOKEN=""
TOKEN_KIND="none"
pick_token() {
  local want="$1" account candidate
  for account in user-token bot-token; do
    candidate="$(lookup_token "$account")"
    [[ -n "$candidate" ]] || continue
    if [[ "$(kind_of "$candidate")" == "$want" ]]; then
      TOKEN="$candidate"; TOKEN_KIND="$want"; return 0
    fi
  done
  return 1
}

# The confusing case: the app has User Token Scopes configured, so it looks done,
# but the keyring still holds the bot token string. Scopes describe what a token
# may do; the xoxb-/xoxp- prefix decides *whose* identity it is, and no amount of
# user scopes turns a bot token into a user one.
user_token_hint() {
  local stored; stored="$(lookup_token user-token)"
  if [[ -n "$stored" ]] && is_rotating "$stored" && [[ -z "$(lookup_token user-refresh-token)" ]]; then
    printf 'the stored user token rotates (xoxe.) but no refresh token is saved, so it will stop working when it expires — sign in again from the account chip'
    return
  fi
  if [[ -z "$stored" ]]; then
    printf 'no user token stored — run: secret-tool store --label="Slack User Token" service slack-agents account user-token'
  elif [[ "$(kind_of "$stored")" == "bot" ]]; then
    printf 'the "user-token" keyring entry contains a bot token (xoxb-). Configuring User Token Scopes is not enough: reinstall the app, then copy the separate "User OAuth Token" (xoxp-) from OAuth & Permissions'
  elif [[ "$(kind_of "$stored")" == "unknown" ]]; then
    printf 'the "user-token" keyring entry is not a recognisable Slack token (expected xoxp- or xoxe.xoxp-)'
  fi
  # A usable, renewable token prints nothing.
}

case "$TOKEN_PREF" in
  user) pick_token user || fail "$(user_token_hint)" ;;
  bot)  pick_token bot  || fail "no bot token (xoxb-) in keyring" ;;
  *)    pick_token user || pick_token bot || true ;;
esac

if [[ -z "$TOKEN" ]]; then
  # Nothing recognisable; fall back to whatever is stored so the error names it.
  for account in user-token bot-token; do
    TOKEN="$(lookup_token "$account")"
    [[ -n "$TOKEN" ]] && { TOKEN_KIND="$(kind_of "$TOKEN")"; break; }
  done
fi
[[ -n "$TOKEN" ]] || fail "no Slack token in keyring — run: secret-tool store --label='Slack User Token' service slack-agents account user-token"

# Per-identity state. A bot and a user token see different conversations and keep
# different read cursors, so sharing one cache between them would show the wrong
# list and the wrong unread counts after a switch.
CURSOR_FILE="$STATE_DIR/cursors-$TOKEN_KIND.json"
CONVOS_CACHE="$CACHE_DIR/conversations-$TOKEN_KIND.json"
USERS_CACHE="$CACHE_DIR/users-$TOKEN_KIND.json"
ME_CACHE="$CACHE_DIR/me-$TOKEN_KIND.json"

# One-time carry-over from the pre-split layout.
for pair in "$STATE_DIR/cursors.json:$CURSOR_FILE" "$CACHE_DIR/users.json:$USERS_CACHE"; do
  legacy="${pair%%:*}"; current="${pair##*:}"
  [[ -s "$legacy" && ! -e "$current" ]] && cp -n "$legacy" "$current" 2>/dev/null
done
true

REFRESH_LOCK="$STATE_DIR/refresh.lock"

_do_refresh() { # _do_refresh <token-we-started-with>
  local started="$1" rt cid cs resp new_at new_rt
  # Another process may have rotated it while we waited for the lock.
  [[ "$(lookup_token user-token)" != "$started" ]] && return 0

  rt="$(lookup_token user-refresh-token)"
  cid="$(secret-tool lookup service slack-agents account client-id 2>/dev/null || true)"
  cs="$(secret-tool lookup service slack-agents account client-secret 2>/dev/null || true)"
  [[ -n "$rt" && -n "$cid" && -n "$cs" ]] || return 1

  resp="$(curl -sS --max-time 25 "$API/oauth.v2.access" \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "refresh_token=$rt" \
    --data-urlencode "client_id=$cid" \
    --data-urlencode "client_secret=$cs" 2>/dev/null)"
  [[ "$(jq -r '.ok // false' <<<"$resp")" == "true" ]] || return 1

  # Rotation responses put the new pair either at the top level or under
  # authed_user, depending on which token type was refreshed.
  new_at="$(jq -r '.access_token // .authed_user.access_token // ""' <<<"$resp")"
  new_rt="$(jq -r '.refresh_token // .authed_user.refresh_token // ""' <<<"$resp")"
  [[ -n "$new_at" ]] || return 1

  printf '%s' "$new_at" | secret-tool store --label="Slack User Token" service slack-agents account user-token
  [[ -n "$new_rt" ]] && printf '%s' "$new_rt" | secret-tool store --label="Slack User Refresh Token" service slack-agents account user-refresh-token
  return 0
}

refresh_user_token() {
  local started="$TOKEN" current
  if command -v flock >/dev/null 2>&1; then
    ( flock -w 30 9 || exit 1; _do_refresh "$started" ) 9>"$REFRESH_LOCK"
  else
    _do_refresh "$started"
  fi
  current="$(lookup_token user-token)"
  if [[ -n "$current" && "$current" != "$started" ]]; then
    TOKEN="$current"
    return 0
  fi
  return 1
}

# api <GET|POST> <method> [key=value ...]
# Retries once on ratelimited/5xx. Always emits a JSON object.
api() {
  local verb="$1" method="$2"; shift 2
  local args=() kv attempt resp
  for kv in "$@"; do args+=(--data-urlencode "$kv"); done

  for attempt in 1 2; do
    if [[ "$verb" == "GET" ]]; then
      resp="$(curl -sS --max-time 25 --get "$API/$method" \
        -H "Authorization: Bearer $TOKEN" "${args[@]}" 2>/dev/null)"
    else
      resp="$(curl -sS --max-time 25 "$API/$method" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/x-www-form-urlencoded; charset=utf-8" \
        "${args[@]}" 2>/dev/null)"
    fi

    if ! jq -e . >/dev/null 2>&1 <<<"$resp"; then
      [[ $attempt -eq 1 ]] && { sleep 2; continue; }
      jq -n --arg m "$method" '{ok:false, error:("no response from " + $m)}'
      return
    fi
    case "$(jq -r '.error // ""' <<<"$resp")" in
      ratelimited)
        [[ $attempt -eq 1 ]] && { sleep 3; continue; } ;;
      token_expired|token_revoked|invalid_auth|account_inactive|not_authed)
        # Rotating tokens expire on a timer; renew once and retry the call.
        if [[ $attempt -eq 1 ]] && is_rotating "$TOKEN" && refresh_user_token; then
          continue
        fi
        # Renewal is impossible (no refresh token, or not a rotating token):
        # the session is genuinely dead. Drop the cached identity so `me` stops
        # cheerfully reporting a signed-in user from 24h-old data.
        AUTH_DEAD=true
        rm -f "$ME_CACHE" 2>/dev/null ;;
    esac
    printf '%s' "$resp"
    return
  done
}

# Abort the *script* when a response is not ok. Must run in the caller's shell:
# calling fail() inside "$(...)" would only exit the subshell.
require_ok() { # require_ok <response> <method>
  local resp="$1" method="$2" err
  [[ "$(jq -r '.ok // false' <<<"$resp")" == "true" ]] && return 0
  err="$(jq -r '.error // "unknown slack error"' <<<"$resp")"
  if is_auth_error "$err"; then
    rm -f "$ME_CACHE" 2>/dev/null
  fi
  fail "$err ($method)" "$err"
}

fresh() { # fresh <file> <ttl-seconds>
  local f="$1" ttl="$2" age
  [[ -s "$f" ]] || return 1
  age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
  (( age < ttl ))
}

atomic_write() { # atomic_write <file>  (content on stdin)
  local f="$1" tmp
  tmp="$(mktemp "${f}.XXXXXX")" || return 1
  cat >"$tmp" && mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# ------------------------------------------------------------------ identity

load_me() {
  if fresh "$ME_CACHE" "$ME_TTL" && [[ "$(jq -r '.tokenKind // ""' "$ME_CACHE")" == "$TOKEN_KIND" ]]; then
    cat "$ME_CACHE"; return
  fi
  local resp; resp="$(api GET auth.test)"
  if [[ "$(jq -r '.ok // false' <<<"$resp")" == "true" ]]; then
    jq --arg kind "$TOKEN_KIND" --argjson haveUser "$HAVE_USER" --argjson haveBot "$HAVE_BOT" \
      --arg hint "$(user_token_hint)" \
      '{ok:true, userId:.user_id, user:.user, team:.team, teamId:.team_id, url:.url,
         tokenKind:$kind, haveUserToken:$haveUser, haveBotToken:$haveBot, userTokenHint:$hint}' \
      <<<"$resp" | atomic_write "$ME_CACHE"
    cat "$ME_CACHE"
  else
    local err; err="$(jq -r '.error // "auth.test failed"' <<<"$resp")"
    local needs=false
    is_auth_error "$err" && needs=true
    jq -n --arg e "$err" --arg kind "$TOKEN_KIND" --argjson needsSignIn "$needs" \
      --argjson haveUser "$HAVE_USER" --argjson haveBot "$HAVE_BOT" \
      '{ok:false, error:$e, needsSignIn:$needsSignIn, tokenKind:$kind, haveUserToken:$haveUser, haveBotToken:$haveBot}'
  fi
}

token_user_id() { jq -r '.userId // ""' <<<"$(load_me)"; }

# The identity to attribute messages and mentions to.
me_id() {
  if [[ -n "$ME_OVERRIDE" ]]; then printf '%s' "$ME_OVERRIDE"; else token_user_id; fi
}

# Everything that counts as "you": the override and the token's own identity, so
# messages this app posted on your behalf are not shown as somebody else's.
mine_ids() {
  local tok; tok="$(token_user_id)"
  jq -n -c --arg a "$ME_OVERRIDE" --arg b "$tok" '[$a, $b] | map(select(. != "")) | unique'
}

# --------------------------------------------------------------- user lookup

users_cache_read() { [[ -s "$USERS_CACHE" ]] && cat "$USERS_CACHE" || echo '{}'; }

# resolve_users <json-array-of-ids>  -> merged id->profile map, cache updated
resolve_users() {
  local ids_json="$1" cache missing id tmpdir n=0
  cache="$(users_cache_read)"
  missing="$(jq -c --argjson have "$cache" \
    '[ .[] | select(. != null and . != "") | select($have[.] == null) ] | unique' <<<"$ids_json")"

  if [[ "$(jq 'length' <<<"$missing")" -gt 0 ]]; then
    tmpdir="$(mktemp -d)"
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      api GET users.info "user=$id" >"$tmpdir/$id.json" &
      (( ++n % MAX_PARALLEL == 0 )) && wait
    done < <(jq -r '.[]' <<<"$missing" | head -60)
    wait
    cache="$(jq -s --argjson cache "$cache" '
      reduce .[] as $r ($cache;
        if ($r.ok // false) and ($r.user.id // null) != null then
          .[$r.user.id] = {
            name: ($r.user.profile.display_name // "" | if . == "" then ($r.user.real_name // $r.user.name) else . end),
            realName: ($r.user.real_name // $r.user.name // ""),
            image: ($r.user.profile.image_48 // $r.user.profile.image_72 // ""),
            isBot: ($r.user.is_bot // false)
          }
        else . end)' "$tmpdir"/*.json 2>/dev/null || printf '%s' "$cache")"
    rm -rf "$tmpdir"
    atomic_write "$USERS_CACHE" <<<"$cache"
  fi
  printf '%s' "$cache"
}

# ------------------------------------------------------------------- cursors

cursors_read() { [[ -s "$CURSOR_FILE" ]] && cat "$CURSOR_FILE" || echo '{}'; }

cursor_set() { # cursor_set <channel> <ts>
  local cur; cur="$(cursors_read)"
  jq --arg c "$1" --arg t "$2" '
    if (.[$c] // "0") | tonumber < ($t | tonumber) then .[$c] = $t else . end
  ' <<<"$cur" | atomic_write "$CURSOR_FILE"
}

# ------------------------------------------------------------- conversations

fetch_conversations() {
  local cursor="" page=0 all='[]' resp
  while (( page < 4 )); do
    resp="$(api GET users.conversations \
      "types=public_channel,private_channel,im,mpim" \
      "exclude_archived=true" "limit=200" "cursor=$cursor")"
    [[ "$(jq -r '.ok // false' <<<"$resp")" == "true" ]] || {
      jq -n --arg e "$(jq -r '.error // "users.conversations failed"' <<<"$resp")" '{ok:false, error:$e}'
      return
    }
    all="$(printf '%s\n%s\n' "$all" "$(jq -c '.channels' <<<"$resp")" | jq -s '.[0] + .[1]')"
    cursor="$(jq -r '.response_metadata.next_cursor // ""' <<<"$resp")"
    [[ -z "$cursor" ]] && break
    (( page++ ))
  done

  # users.conversations only covers what the caller is already in. Public
  # channels are listed separately so the picker can browse the whole workspace;
  # reading one still requires joining it (conversations.history returns
  # not_in_channel otherwise), which is why `joined` is surfaced to the UI.
  local public='[]' pcursor="" ppage=0 presp
  while (( ppage < 4 )); do
    presp="$(api GET conversations.list \
      "types=public_channel" "exclude_archived=true" "limit=1000" "cursor=$pcursor")"
    [[ "$(jq -r '.ok // false' <<<"$presp")" == "true" ]] || break
    public="$(printf '%s\n%s\n' "$public" "$(jq -c '.channels' <<<"$presp")" | jq -s '.[0] + .[1]')"
    pcursor="$(jq -r '.response_metadata.next_cursor // ""' <<<"$presp")"
    [[ -z "$pcursor" ]] && break
    (( ppage++ ))
  done

  local joined_ids
  joined_ids="$(jq -c '[ .[].id ]' <<<"$all")"
  all="$(jq -c -s --argjson joined "$joined_ids" '
    .[0] + [ .[1][] | . as $c | select(($joined | index($c.id)) == null) | $c + {_unjoined: true} ]
  ' <(jq -c '.' <<<"$all") <(jq -c '.' <<<"$public"))"

  local ids users
  ids="$(jq -c '[ .[] | select(.is_im == true) | .user ]' <<<"$all")"
  users="$(resolve_users "$ids")"

  jq -c --argjson users "$users" '{
    ok: true,
    conversations: [ .[] |
      {
        id: .id,
        type: (if .is_im then "im" elif .is_mpim then "mpim" elif .is_private then "private" else "channel" end),
        name: (
          if .is_im then ($users[.user].name // .user // "unknown")
          elif .is_mpim then (.purpose.value // .name // .id | sub("^mpdm-";"") | sub("-1$";"") | gsub("--";", "))
          else (.name // .id) end
        ),
        user: (.user // ""),
        image: (if .is_im then ($users[.user].image // "") else "" end),
        topic: (.topic.value // ""),
        members: (.num_members // 0),
        joined: ((._unjoined // false) | not)
      }
    ] | sort_by((.joined | not), .type == "channel", (.name | ascii_downcase))
  }' <<<"$all"
}

load_conversations() { # load_conversations [force]
  if [[ "${1:-}" != "force" ]] && fresh "$CONVOS_CACHE" "$CONVOS_TTL"; then
    cat "$CONVOS_CACHE"; return
  fi
  local out; out="$(fetch_conversations)"
  if [[ "$(jq -r '.ok // false' <<<"$out")" == "true" ]]; then
    atomic_write "$CONVOS_CACHE" <<<"$out"
    printf '%s' "$out"
  elif [[ -s "$CONVOS_CACHE" ]]; then
    # Serving the cached list is fine, but if the reason we could not refresh is
    # that the credentials are dead, say so rather than looking healthy.
    local err; err="$(jq -r '.error' <<<"$out")"
    if is_auth_error "$err"; then
      jq -c --arg e "$err" '.stale = true | .warning = $e | .needsSignIn = true' "$CONVOS_CACHE"
    else
      jq -c --arg e "$err" '.stale = true | .warning = $e' "$CONVOS_CACHE"
    fi
  else
    printf '%s' "$out"
  fi
}

# ------------------------------------------------------------------ messages

# Shapes raw Slack messages into what the UI consumes. Reads {messages:[...]}
# on stdin, needs the user map as $users and own id as $me.
shape_messages() {
  local users="$1" me="$2" mine="$3"
  jq -c --argjson users "$users" --arg me "$me" --argjson mine "$mine" '[
    .messages[]? | select(.subtype == null or (.subtype | IN("bot_message","thread_broadcast","me_message","file_share"))) |
    {
      ts: .ts,
      user: (.user // .bot_id // ""),
      author: (
        if (.user // "") != "" then ($users[.user].name // .username // .user)
        else (.username // .bot_profile.name // "bot") end
      ),
      image: (if (.user // "") != "" then ($users[.user].image // "") else (.bot_profile.icons.image_48 // "") end),
      mine: ((.user // "") as $u | ($mine | index($u)) != null),
      text: (.text // ""),
      subtype: (.subtype // ""),
      edited: (.edited != null),
      threadTs: (.thread_ts // ""),
      replyCount: (.reply_count // 0),
      replyUsers: [ (.reply_users // [])[] ],
      isBot: ((.bot_id // "") != "" and (.user // "") == ""),
      reactions: [ (.reactions // [])[] | {name: .name, count: .count, mine: ([ (.users // [])[] ] | any(. as $u | ($mine | index($u)) != null))} ],
      files: [ (.files // [])[] | {name: (.name // .title // "file"), url: (.permalink // ""), type: (.filetype // "")} ],
      attachments: [ (.attachments // [])[] | {
        title: (.title // ""),
        text: (.text // .fallback // ""),
        url: (.title_link // .original_url // .from_url // ""),
        fromUrl: (.from_url // .original_url // ""),
        site: (.service_name // ""),
        siteIcon: (.service_icon // ""),
        author: (.author_name // ""),
        image: (.image_url // .thumb_url // ""),
        footer: (.footer // ""),
        color: (.color // "")
      } ]
    }
  ]'
}

collect_user_ids() { jq -c '[ .messages[]? | (.user // empty), ((.reactions // [])[].users // [])[] ] | unique'; }

cmd_history() {
  local channel="${1:?channel required}" limit="${2:-50}" resp users me
  resp="$(api GET conversations.history "channel=$channel" "limit=$limit" "inclusive=true")"
  require_ok "$resp" conversations.history
  me="$(me_id)"
  users="$(resolve_users "$(collect_user_ids <<<"$resp")")"
  jq -n \
    --argjson messages "$(shape_messages "$users" "$me" "$(mine_ids)" <<<"$resp")" \
    --argjson users "$users" \
    --arg cursor "$(jq -r --arg c "$channel" '.[$c] // ""' <<<"$(cursors_read)")" \
    --argjson more "$(jq '.has_more // false' <<<"$resp")" \
    '{ok:true, messages:$messages, users:$users, readCursor:$cursor, hasMore:$more}'
}

cmd_replies() {
  local channel="${1:?channel required}" thread="${2:?thread_ts required}" resp users me
  resp="$(api GET conversations.replies "channel=$channel" "ts=$thread" "limit=100")"
  require_ok "$resp" conversations.replies
  me="$(me_id)"
  users="$(resolve_users "$(collect_user_ids <<<"$resp")")"
  jq -n --argjson messages "$(shape_messages "$users" "$me" "$(mine_ids)" <<<"$resp")" --argjson users "$users" \
    '{ok:true, messages:($messages | sort_by(.ts | tonumber) | reverse), users:$users}'
}

# --------------------------------------------------------------------- poll

cmd_poll() {
  local ids_csv="${1:-}" me cur tmpdir id n=0
  [[ -n "$ids_csv" ]] || { jq -n '{ok:true, conversations:{}}'; return; }
  me="$(me_id)"
  mine="$(mine_ids)"
  cur="$(cursors_read)"
  tmpdir="$(mktemp -d)"

  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    {
      local resp
      resp="$(api GET conversations.history "channel=$id" "limit=20")"
      jq -c --arg id "$id" '{id:$id, ok:(.ok // false), error:(.error // ""), messages:(.messages // [])}' \
        <<<"$resp" >"$tmpdir/$id.json"
    } &
    (( ++n % MAX_PARALLEL == 0 )) && wait
  done < <(tr ',' '\n' <<<"$ids_csv")
  wait

  local users
  users="$(resolve_users "$(jq -s -c '[ .[].messages[]? | .user // empty ] | unique' "$tmpdir"/*.json 2>/dev/null || echo '[]')")"

  jq -s -c --argjson cursors "$cur" --argjson users "$users" --arg me "$me" --argjson mine "$mine" '
    {
      ok: true,
      me: $me,
      needsSignIn: ([ .[] | .error ] | any(. as $e | ["token_expired","token_revoked","invalid_auth","account_inactive","not_authed"] | index($e) != null)),
      conversations: (
        reduce .[] as $c ({};
          ($cursors[$c.id] // "0") as $cursor
          | ( [ $c.messages[] | select((.ts | tonumber) > ($cursor | tonumber)) | select((.user // "") as $u | ($mine | index($u)) == null) ] ) as $new
          | ( [ $c.messages[] | select(.subtype == null or .subtype == "bot_message" or .subtype == "file_share" or .subtype == "thread_broadcast") ] | first ) as $latest
          | .[$c.id] = {
              ok: $c.ok,
              error: $c.error,
              unread: ($new | length),
              mention: ([ $new[] | select((.text // "") | test("<@" + $me + ">|<!here>|<!channel>|<!everyone>")) ] | length > 0),
              cursor: $cursor,
              latest: (if $latest == null then null else {
                ts: $latest.ts,
                author: (if ($latest.user // "") != "" then ($users[$latest.user].name // $latest.username // "someone") else ($latest.username // "bot") end),
                mine: (($mine | index($latest.user // "")) != null),
                text: ($latest.text // "" | gsub("\\s+"; " ") | .[0:140])
              } end),
              # The newest message that is actually unread. `latest` can be your
              # own reply, which must never be what a notification announces.
              latestUnread: (($new | first) as $u | if $u == null then null else {
                ts: $u.ts,
                user: ($u.user // ""),
                author: (if ($u.user // "") != "" then ($users[$u.user].name // $u.username // "someone") else ($u.username // "bot") end),
                text: ($u.text // "" | gsub("\\s+"; " ") | .[0:140])
              } end)
            })
      )
    }' "$tmpdir"/*.json 2>/dev/null || jq -n '{ok:false, error:"poll produced no data"}'
  rm -rf "$tmpdir"
}

# Reconcile local cursors with Slack's own read state (cross-device sync).
cmd_sync_read() {
  local ids_csv="${1:-}" tmpdir id n=0
  [[ -n "$ids_csv" ]] || { jq -n '{ok:true, cursors:{}}'; return; }
  tmpdir="$(mktemp -d)"
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    api GET conversations.info "channel=$id" >"$tmpdir/$id.json" &
    (( ++n % MAX_PARALLEL == 0 )) && wait
  done < <(tr ',' '\n' <<<"$ids_csv")
  wait

  local merged
  merged="$(jq -s -c --argjson cursors "$(cursors_read)" '
    reduce .[] as $r ($cursors;
      if ($r.ok // false) and (($r.channel.last_read // "") != "") then
        ($r.channel.id) as $id
        | if ((.[$id] // "0") | tonumber) < (($r.channel.last_read) | tonumber)
          then .[$id] = $r.channel.last_read else . end
      else . end)' "$tmpdir"/*.json 2>/dev/null || cursors_read)"
  rm -rf "$tmpdir"
  atomic_write "$CURSOR_FILE" <<<"$merged"
  jq -n --argjson c "$merged" '{ok:true, cursors:$c}'
}

# ------------------------------------------------------------------- actions

cmd_send() {
  local channel="${1:?channel required}" text="${2:?text required}" thread="${3:-}"
  local args=("channel=$channel" "text=$text" "unfurl_links=true" "unfurl_media=true")
  [[ -n "$thread" ]] && args+=("thread_ts=$thread")
  local resp; resp="$(api POST chat.postMessage "${args[@]}")"
  if [[ "$(jq -r '.ok // false' <<<"$resp")" == "true" ]]; then
    local ts; ts="$(jq -r '.ts' <<<"$resp")"
    cursor_set "$channel" "$ts"
    jq -n --arg ts "$ts" '{ok:true, ts:$ts}'
  else
    fail "$(jq -r '.error // "chat.postMessage failed"' <<<"$resp")"
  fi
}

cmd_read() {
  local channel="${1:?channel required}" ts="${2:?ts required}"
  cursor_set "$channel" "$ts"
  local resp; resp="$(api POST conversations.mark "channel=$channel" "ts=$ts")"
  jq -n --argjson marked "$(jq '.ok // false' <<<"$resp")" \
        --arg err "$(jq -r '.error // ""' <<<"$resp")" \
    '{ok:true, marked:$marked, markError:$err}'
}

# Custom workspace emoji. Slack serves these as images, so they are mirrored into
# the cache once and referenced as file:// URLs — remote images in Qt rich text
# are unreliable, local ones are not.
EMOJI_TTL=86400

cmd_emoji() {
  local list_cache="$CACHE_DIR/emoji-$TOKEN_KIND.json"
  local img_dir="$CACHE_DIR/emoji-img"
  mkdir -p "$img_dir" 2>/dev/null

  if ! fresh "$list_cache" "$EMOJI_TTL"; then
    local resp; resp="$(api GET emoji.list)"
    if [[ "$(jq -r '.ok // false' <<<"$resp")" == "true" ]]; then
      jq -c '.emoji // {}' <<<"$resp" | atomic_write "$list_cache"
    fi
  fi
  [[ -s "$list_cache" ]] || { jq -n '{ok:true, emoji:{}, aliases:{}}'; return; }

  local raw; raw="$(cat "$list_cache")"

  # Mirror any image-backed emoji we do not already have, capped so a workspace
  # with thousands does not stall the first refresh.
  local n=0 name url ext target
  while IFS=$'\t' read -r name url; do
    [[ -z "$name" || -z "$url" ]] && continue
    ext="${url##*.}"
    case "$ext" in png|gif|jpg|jpeg|webp) ;; *) ext="png" ;; esac
    target="$img_dir/$name.$ext"
    [[ -s "$target" ]] && continue
    curl -sf --max-time 15 -o "$target" "$url" &
    (( ++n % MAX_PARALLEL == 0 )) && wait
    (( n >= 400 )) && break
  done < <(jq -r 'to_entries[] | select(.value | startswith("alias:") | not) | "\(.key)\t\(.value)"' <<<"$raw")
  wait

  # Map name -> local file, following one level of alias.
  jq -n -c --argjson raw "$raw" --arg dir "$img_dir" '
    ($raw | with_entries(select(.value | startswith("alias:") | not))) as $direct
    | {
        ok: true,
        emoji: ( $direct | with_entries({ key: .key, value: ($dir + "/" + .key + "." + (.value | split(".") | last | if . == "png" or . == "gif" or . == "jpg" or . == "jpeg" or . == "webp" then . else "png" end)) }) ),
        aliases: ( $raw | with_entries(select(.value | startswith("alias:"))) | with_entries({ key: .key, value: (.value | ltrimstr("alias:")) }) )
      }'
}

# Profile pictures, mirrored locally. Notification daemons want a real file for
# the image-path hint, and local files also spare the UI a network fetch per row.
cmd_avatars() {
  local img_dir="$CACHE_DIR/avatars"
  mkdir -p "$img_dir" 2>/dev/null

  local raw; raw="$(users_cache_read)"
  local n=0 id url ext target
  while IFS=$'\t' read -r id url; do
    [[ -z "$id" || -z "$url" ]] && continue
    ext="${url##*.}"
    case "$ext" in png|gif|jpg|jpeg|webp) ;; *) ext="png" ;; esac
    target="$img_dir/$id.$ext"
    [[ -s "$target" ]] && continue
    curl -sf --max-time 15 -o "$target" "$url" &
    (( ++n % MAX_PARALLEL == 0 )) && wait
    (( n >= 200 )) && break
  done < <(jq -r 'to_entries[] | select((.value.image // "") != "") | "\(.key)\t\(.value.image)"' <<<"$raw")
  wait

  jq -n -c --argjson raw "$raw" --arg dir "$img_dir" '{
    ok: true,
    avatars: (
      $raw
      | with_entries(select((.value.image // "") != ""))
      | with_entries({
          key: .key,
          value: ($dir + "/" + .key + "." + (
            .value.image | split("?")[0] | split(".") | last
            | if . == "png" or . == "gif" or . == "jpg" or . == "jpeg" or . == "webp" then . else "png" end))
        })
    )
  }'
}

# ---------------------------------------------------------- link previews

# A message full of links must not become a message full of processes, and a
# preview must never become a way to make this machine fetch something it
# should not. Everything below is built around those two rules.

UNFURL_BIN="$CACHE_DIR/bin/slack-unfurl"
UNFURL_SRC_DIR="$SCRIPT_DIR/native"
UNFURL_BUILD_LOG="$CACHE_DIR/bin/build.log"

# The newest of the native sources, so "is the binary stale?" stays right when
# only the header changed.
newest_unfurl_source() {
  local src newest=""
  for src in "$UNFURL_SRC_DIR"/*.cpp "$UNFURL_SRC_DIR"/*.hpp; do
    [[ -f "$src" ]] || continue
    [[ -z "$newest" || "$src" -nt "$newest" ]] && newest="$src"
  done
  [[ -n "$newest" ]] || return 1
  printf '%s' "$newest"
}

# Built on demand rather than at install time: the plugin is cloned, not
# packaged, and a compiler is not a dependency — when there is none, or the
# build fails, the shell fallback below still produces a card.
build_unfurl_helper() {
  [[ -f "$UNFURL_SRC_DIR/html_meta.cpp" ]] || return 1
  mkdir -p "$CACHE_DIR/bin" 2>/dev/null || return 1

  # The Makefile owns the flag set and picks the newest standard the compiler
  # admits to, so prefer it. Build outside the clone: the plugin directory is
  # somebody's checkout, not a scratch space.
  if command -v make >/dev/null 2>&1; then
    if make -C "$SCRIPT_DIR" --no-print-directory \
         PREFIX="$CACHE_DIR" BUILDDIR="$CACHE_DIR/build" install \
         >>"$UNFURL_BUILD_LOG" 2>&1 && [[ -x "$UNFURL_BIN" ]]; then
      return 0
    fi
  fi

  # No make: reproduce just enough of it by hand. C++26 is what the source
  # targets; the older standards are here so a 2023-vintage toolchain still
  # gets the fast parser.
  local cxx std tmp="$UNFURL_BIN.$$"
  for cxx in clang++ g++ c++; do
    command -v "$cxx" >/dev/null 2>&1 || continue
    for std in c++2c c++23 c++2b c++20; do
      if "$cxx" "-std=$std" -O2 -o "$tmp" \
           "$UNFURL_SRC_DIR/html_meta.cpp" "$UNFURL_SRC_DIR/unfurl_main.cpp" \
           >>"$UNFURL_BUILD_LOG" 2>&1; then
        mv -f "$tmp" "$UNFURL_BIN" && return 0
      fi
    done
  done
  rm -f "$tmp" 2>/dev/null
  return 1
}

# Rebuild when a source is newer than the binary; remember a failure against
# that source's timestamp so a machine with no compiler does not retry the build
# on every single link.
ensure_unfurl_helper() {
  local newest
  newest="$(newest_unfurl_source)" || return 1
  [[ -x "$UNFURL_BIN" && ! "$newest" -nt "$UNFURL_BIN" ]] && return 0
  local marker="$CACHE_DIR/bin/.build-failed"
  if [[ -f "$marker" && ! "$newest" -nt "$marker" ]]; then
    return 1
  fi
  if build_unfurl_helper; then
    rm -f "$marker" 2>/dev/null
    return 0
  fi
  mkdir -p "$CACHE_DIR/bin" 2>/dev/null
  : >"$marker" 2>/dev/null
  return 1
}

hash_of() { # hash_of <string>
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha1sum | cut -c1-40
  elif command -v md5sum >/dev/null 2>&1; then
    printf '%s' "$1" | md5sum | cut -c1-32
  else
    printf '%s' "$1" | cksum | tr -d ' '
  fi
}

# Only public http(s) may be crawled. A colleague pasting
# http://127.0.0.1:8080/shutdown must not make this machine visit it, and the
# same goes for cloud metadata endpoints and anything on the LAN.
url_is_crawlable() { # url_is_crawlable <url>
  local url="$1" rest host
  case "$url" in
    http://*)  rest="${url#http://}" ;;
    https://*) rest="${url#https://}" ;;
    *) return 1 ;;
  esac
  host="${rest%%/*}"; host="${host%%\?*}"; host="${host%%#*}"
  host="${host##*@}"          # strip userinfo
  host="${host%%:*}"          # strip port (IPv6 literals are rejected below anyway)
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  [[ -n "$host" ]] || return 1
  case "$host" in
    localhost|*.localhost|*.local|*.internal|*.home.arpa|*.onion) return 1 ;;
    127.*|10.*|0.*|169.254.*|192.168.*|100.64.*) return 1 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;;
  esac
  # Everything left has to look like a dotted public name. This is what rejects
  # the rest of the awkward cases without needing a pattern each: a bare
  # hostname (instance-data), a bracketed IPv6 literal (stripping the port left
  # "["), an unbracketed one (stripping the port left nothing), and the cloud
  # metadata names, which the *.internal rule above already covers.
  [[ "$host" == *.* ]] || return 1
  return 0
}

# Pull the fields out of an HTML page with grep/sed when the compiled helper is
# unavailable. Deliberately modest — first match wins, only the entities that
# actually show up in titles are decoded — but it keeps previews working on a
# machine with no compiler.
unfurl_fallback() { # unfurl_fallback <url> <final-url> <body-file>
  local url="$1" final="$2" file="$3" head
  # Comments first: a page that keeps an old <meta> commented out would
  # otherwise win, because grep cannot see that it is commented out.
  head="$(head -c 262144 "$file" | tr '\n' ' ' | sed -E ':a; s/<!--[^-]*(-[^-]+)*-->//g; ta')"
  local title='' desc='' image='' site=''
  _meta() { # _meta <property-or-name>
    printf '%s' "$head" \
      | grep -o -i -E "<meta[^>]+(property|name)=[\"']?$1[\"']?[^>]*>" \
      | head -n1 \
      | grep -o -i -E "content=\"[^\"]*\"|content='[^']*'|content=[^ >]+" \
      | head -n1 | sed -E "s/^content=[\"']?//; s/[\"']$//"
  }
  title="$(_meta 'og:title')"
  [[ -z "$title" ]] && title="$(_meta 'twitter:title')"
  [[ -z "$title" ]] && title="$(printf '%s' "$head" | grep -o -i -E '<title[^>]*>[^<]*' | head -n1 | sed -E 's/^<title[^>]*>//')"
  desc="$(_meta 'og:description')"
  [[ -z "$desc" ]] && desc="$(_meta 'description')"
  image="$(_meta 'og:image')"
  site="$(_meta 'og:site_name')"
  unset -f _meta

  # The curly quotes below are the replacement text for &#8217;/&#8216;, not
  # stray shell quoting, which is what shellcheck sees them as.
  # shellcheck disable=SC1112
  local decode='s/&amp;/\&/g; s/&quot;/"/g; s/&#0*39;/'"'"'/g; s/&apos;/'"'"'/g; s/&lt;/</g; s/&gt;/>/g; s/&nbsp;/ /g; s/&hellip;/…/g; s/&mdash;/—/g; s/&ndash;/–/g; s/&#8217;/’/g; s/&#8216;/‘/g'
  title="$(printf '%s' "$title" | sed -E "$decode" | tr -s ' ' | sed -E 's/^ +| +$//g' | cut -c1-300)"
  desc="$(printf '%s' "$desc" | sed -E "$decode" | tr -s ' ' | sed -E 's/^ +| +$//g' | cut -c1-600)"
  # Resolve the relative-URL shapes that actually occur; anything cleverer is
  # what the compiled helper is for.
  local scheme_host; scheme_host="$(printf '%s' "$final" | sed -E 's#^(https?://[^/]+).*#\1#')"
  case "$image" in
    ''|http://*|https://*) ;;
    //*) image="${final%%:*}:$image" ;;
    /*)  image="$scheme_host$image" ;;
    *)   image="${final%/*}/$image" ;;
  esac
  [[ -z "$site" ]] && site="$(printf '%s' "$scheme_host" | sed -E 's#^https?://##; s/^www\.//')"

  jq -n --arg url "$url" --arg final "$final" --arg title "$title" --arg desc "$desc" \
        --arg image "$image" --arg site "$site" \
    '{ok:true, url:$url, finalUrl:$final, canonical:$final, site:$site, title:$title,
      description:$desc, image:$image, icon:"", kind:""}'
}

# Mirror a preview image next to the JSON. Qt loads a remote image happily
# enough, but a local file cannot pop in late while the transcript scrolls, and
# it costs nothing on the second read of the same conversation.
mirror_asset() { # mirror_asset <url> -> prints local path, or nothing
  local url="$1" key target ctype
  [[ -n "$url" ]] || return 0
  url_is_crawlable "$url" || return 0
  key="$(hash_of "$url")"
  mkdir -p "$UNFURL_ASSETS" 2>/dev/null
  # Already mirrored under any extension?
  local existing
  existing="$(find "$UNFURL_ASSETS" -maxdepth 1 -name "$key.*" -size +0c 2>/dev/null | head -n1)"
  if [[ -n "$existing" ]]; then printf '%s' "$existing"; return 0; fi

  target="$UNFURL_ASSETS/$key.part"
  ctype="$(curl -sS -L --max-redirs 3 --max-time 15 --connect-timeout 6 \
      --proto '=http,https' --proto-redir '=http,https' \
      --max-filesize "$ASSET_MAX_BYTES" -A "$UA" \
      -o "$target" -w '%{content_type}' "$url" 2>/dev/null)" || { rm -f "$target"; return 0; }
  [[ -s "$target" ]] || { rm -f "$target"; return 0; }

  local ext
  case "$(printf '%s' "$ctype" | tr '[:upper:]' '[:lower:]')" in
    *png*)  ext=png ;;
    *jpeg*|*jpg*) ext=jpg ;;
    *gif*)  ext=gif ;;
    *webp*) ext=webp ;;
    *svg*)  ext=svg ;;
    *avif*) ext=avif ;;
    *icon*|*ico*) ext=ico ;;
    *) rm -f "$target"; return 0 ;;   # not an image: do not hand the UI a web page to draw
  esac
  mv -f "$target" "$UNFURL_ASSETS/$key.$ext" 2>/dev/null || { rm -f "$target"; return 0; }
  printf '%s' "$UNFURL_ASSETS/$key.$ext"
}

# Crawl one URL into $UNFURL_DIR/<hash>.json. Runs in a subshell per URL, so it
# reports failure by writing a card rather than by exit status.
unfurl_one() { # unfurl_one <url> <cache-file>
  local url="$1" out="$2" tmp hdr body info ctype final code
  if ! url_is_crawlable "$url"; then
    jq -n --arg url "$url" '{ok:false, url:$url, error:"not crawlable"}' >"$out"
    return 0
  fi

  tmp="$(mktemp -d)" || return 0
  hdr="$tmp/h"; body="$tmp/b"
  info="$(curl -sS -L --max-redirs 4 --max-time 12 --connect-timeout 6 \
      --proto '=http,https' --proto-redir '=http,https' --compressed \
      --max-filesize 8000000 \
      -A "$UA" \
      -H 'Accept: text/html,application/xhtml+xml;q=0.9,*/*;q=0.5' \
      -H 'Accept-Language: en;q=0.9' \
      -D "$hdr" -o "$body" \
      -w '%{content_type}\n%{url_effective}\n%{http_code}' "$url" 2>/dev/null)"

  ctype="$(sed -n 1p <<<"$info" | tr '[:upper:]' '[:lower:]')"
  final="$(sed -n 2p <<<"$info")"
  code="$(sed -n 3p <<<"$info")"
  [[ -n "$final" ]] || final="$url"

  if [[ -z "$code" || "$code" == "000" || "$code" -ge 400 ]]; then
    jq -n --arg url "$url" --arg c "${code:-000}" '{ok:false, url:$url, error:("http " + $c)}' >"$out"
    rm -rf "$tmp"; return 0
  fi

  case "$ctype" in
    *text/html*|*application/xhtml*|"")
      local card=""
      if ensure_unfurl_helper; then
        card="$(head -c "$UNFURL_MAX_BYTES" "$body" | "$UNFURL_BIN" "$url" "$final" 2>/dev/null)"
      fi
      if [[ -z "$card" ]] || ! jq -e . >/dev/null 2>&1 <<<"$card"; then
        card="$(unfurl_fallback "$url" "$final" "$body")"
      fi
      # Mirror the preview image and the favicon, then rewrite the card to point
      # at the local copies (keeping the remote URL for the "open" action).
      local img icon localimg="" localicon=""
      img="$(jq -r '.image // ""' <<<"$card")"
      icon="$(jq -r '.icon // ""' <<<"$card")"
      localimg="$(mirror_asset "$img")"
      localicon="$(mirror_asset "$icon")"
      jq -c --arg li "$localimg" --arg lc "$localicon" \
        '. + {imageFile:$li, iconFile:$lc, fetchedAt:(now|floor)}' <<<"$card" >"$out"
      ;;
    image/*)
      # A bare image link: Slack shows the picture, and so do we.
      local localimg=""; localimg="$(mirror_asset "$final")"
      jq -n --arg url "$url" --arg final "$final" --arg li "$localimg" \
        '{ok:true, url:$url, finalUrl:$final, canonical:$final, site:($final | sub("^https?://";"") | sub("/.*$";"") | sub("^www\\.";"")),
          title:"", description:"", image:$final, icon:"", imageFile:$li, iconFile:"", kind:"image", fetchedAt:(now|floor)}' >"$out"
      ;;
    *)
      jq -n --arg url "$url" --arg t "$ctype" '{ok:false, url:$url, error:("not a page: " + $t)}' >"$out"
      ;;
  esac
  rm -rf "$tmp"
  return 0
}

# unfurl <url> [url ...] -> {ok:true, unfurls:{url: card}}
cmd_unfurl() {
  mkdir -p "$UNFURL_DIR" "$UNFURL_ASSETS" 2>/dev/null
  local urls=() url key file n=0
  for url in "$@"; do
    [[ -n "$url" ]] && urls+=("$url")
  done
  if (( ${#urls[@]} == 0 )); then
    jq -n '{ok:true, unfurls:{}}'
    return
  fi
  # Slack unfurls a handful of links per message, not a hundred; the cap is what
  # stops one pasted wall of text from spawning a crawl storm.
  (( ${#urls[@]} > 24 )) && urls=("${urls[@]:0:24}")

  local wanted=()
  for url in "${urls[@]}"; do
    key="$(hash_of "$url")"
    file="$UNFURL_DIR/$key.json"
    if [[ -s "$file" ]]; then
      local ttl="$UNFURL_TTL"
      [[ "$(jq -r '.ok // false' "$file" 2>/dev/null)" == "true" ]] || ttl="$UNFURL_FAIL_TTL"
      fresh "$file" "$ttl" && continue
    fi
    wanted+=("$url")
  done

  if (( ${#wanted[@]} > 0 )); then
    for url in "${wanted[@]}"; do
      unfurl_one "$url" "$UNFURL_DIR/$(hash_of "$url").json" &
      (( ++n % MAX_PARALLEL == 0 )) && wait
    done
    wait
  fi

  # Assemble only what was asked for, keyed by the URL as the caller wrote it.
  local files=()
  for url in "${urls[@]}"; do
    file="$UNFURL_DIR/$(hash_of "$url").json"
    [[ -s "$file" ]] && files+=("$file")
  done
  if (( ${#files[@]} == 0 )); then
    jq -n '{ok:true, unfurls:{}}'
    return
  fi
  jq -s -c '{ok:true, unfurls: (reduce .[] as $c ({};
      if ($c.ok // false) and (($c.title // "") != "" or ($c.description // "") != "" or ($c.imageFile // "") != "")
      then .[$c.url] = {
             url: ($c.canonical // $c.url),
             site: ($c.site // ""),
             title: ($c.title // ""),
             description: ($c.description // ""),
             image: ($c.imageFile // ""),
             icon: ($c.iconFile // ""),
             kind: ($c.kind // "")
           }
      else . end))}' "${files[@]}"
}

# Joining is a visible act in the channel, so the UI asks first rather than
# doing it implicitly when you click a channel you are not in.
cmd_join() {
  local channel="${1:?channel required}"
  local resp; resp="$(api POST conversations.join "channel=$channel")"
  if [[ "$(jq -r '.ok // false' <<<"$resp")" == "true" ]]; then
    rm -f "$CONVOS_CACHE"
    jq -n '{ok:true}'
  else
    fail "$(jq -r '.error // "conversations.join failed"' <<<"$resp")"
  fi
}

cmd_react() {
  local channel="${1:?channel required}" ts="${2:?ts required}" name="${3:?emoji required}" remove="${4:-}"
  local method="reactions.add"
  [[ "$remove" == "remove" ]] && method="reactions.remove"
  local resp; resp="$(api POST "$method" "channel=$channel" "timestamp=$ts" "name=$name")"
  if [[ "$(jq -r '.ok // false' <<<"$resp")" == "true" ]]; then
    jq -n '{ok:true}'
  else
    fail "$(jq -r '.error // "reaction failed"' <<<"$resp")"
  fi
}

# ---------------------------------------------------------------------- main

case "${1:-}" in
  me)        load_me ;;
  list)      load_conversations "${2:-}" ;;
  poll)      cmd_poll "${2:-}" ;;
  history)   cmd_history "${2:-}" "${3:-50}" ;;
  replies)   cmd_replies "${2:-}" "${3:-}" ;;
  send)      cmd_send "${2:-}" "${3:-}" "${4:-}" ;;
  read)      cmd_read "${2:-}" "${3:-}" ;;
  react)     cmd_react "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
  join)      cmd_join "${2:-}" ;;
  emoji)     cmd_emoji ;;
  avatars)   cmd_avatars ;;
  unfurl)    shift; cmd_unfurl "$@" ;;
  build)     # Compile the link-preview helper up front instead of on first use.
             if ensure_unfurl_helper; then
               jq -n --arg bin "$UNFURL_BIN" '{ok:true, helper:$bin}'
             else
               jq -n --arg log "$UNFURL_BUILD_LOG" \
                 '{ok:false, error:("could not build the link-preview helper — link previews fall back to the shell parser; see " + $log)}'
             fi ;;
  sync-read) cmd_sync_read "${2:-}" ;;
  users)     jq -n --argjson u "$(users_cache_read)" '{ok:true, users:$u}' ;;
  reset)     rm -f "$CONVOS_CACHE" "$USERS_CACHE" "$ME_CACHE"; rm -rf "$UNFURL_DIR"; jq -n '{ok:true}' ;;
  tokens)    jq -n --argjson u "$HAVE_USER" --argjson b "$HAVE_BOT" --arg active "$TOKEN_KIND" \
               '{ok:true, haveUserToken:$u, haveBotToken:$b, active:$active}' ;;
  set-credentials)
             # App Client ID/Secret, needed to run the OAuth flow and to renew a
             # rotating token. Passed as argv by the settings pane so neither ever
             # lands in a config file.
             [[ -n "${2:-}" && -n "${3:-}" ]] || fail "usage: slack.sh set-credentials <client-id> <client-secret>"
             printf '%s' "$2" | secret-tool store --label="Slack App Client ID" service slack-agents account client-id
             printf '%s' "$3" | secret-tool store --label="Slack App Client Secret" service slack-agents account client-secret
             jq -n '{ok:true}' ;;
  credentials)
             jq -n \
               --argjson id "$([[ -n "$(secret-tool lookup service slack-agents account client-id 2>/dev/null)" ]] && echo true || echo false)" \
               --argjson secret "$([[ -n "$(secret-tool lookup service slack-agents account client-secret 2>/dev/null)" ]] && echo true || echo false)" \
               --argjson refresh "$([[ -n "$(lookup_token user-refresh-token)" ]] && echo true || echo false)" \
               '{ok:true, haveClientId:$id, haveClientSecret:$secret, haveRefreshToken:$refresh}' ;;
  *)         fail "usage: slack.sh [--token user|bot|auto] [--me <userId>] {me|list|poll|history|replies|send|read|react|join|emoji|avatars|unfurl|build|sync-read|users|tokens|credentials|set-credentials|reset}" ;;
esac
