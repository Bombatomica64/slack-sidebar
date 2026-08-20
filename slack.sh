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
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/noctalia-slack"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/noctalia-slack"
CONVOS_TTL=3600
ME_TTL=86400
MAX_PARALLEL=6

mkdir -p "$STATE_DIR" "$CACHE_DIR" 2>/dev/null
chmod 700 "$STATE_DIR" "$CACHE_DIR" 2>/dev/null

fail() { jq -n --arg e "$1" '{ok:false, error:$e}'; exit 0; }

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
    printf 'the stored user token rotates (xoxe.) but no refresh token is saved, so it will stop working when it expires — rerun get-user-token.sh'
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
      token_expired|token_revoked|invalid_auth)
        # Rotating tokens expire on a timer; renew once and retry the call.
        if [[ $attempt -eq 1 ]] && is_rotating "$TOKEN" && refresh_user_token; then
          continue
        fi ;;
    esac
    printf '%s' "$resp"
    return
  done
}

# Wrapper that turns a non-ok Slack response into our error shape.
api_ok() {
  local resp; resp="$(api "$@")"
  if [[ "$(jq -r '.ok // false' <<<"$resp")" != "true" ]]; then
    fail "$(jq -r '.error // "unknown slack error"' <<<"$resp") (${2})"
  fi
  printf '%s' "$resp"
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
    jq -n --arg e "$(jq -r '.error // "auth.test failed"' <<<"$resp")" --arg kind "$TOKEN_KIND" \
      --argjson haveUser "$HAVE_USER" --argjson haveBot "$HAVE_BOT" \
      '{ok:false, error:$e, tokenKind:$kind, haveUserToken:$haveUser, haveBotToken:$haveBot}'
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
    jq -c --arg e "$(jq -r '.error' <<<"$out")" '.stale = true | .warning = $e' "$CONVOS_CACHE"
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
      replyUsers: [ (.reply_users // [])[] | ($users[.].image // "") ] ,
      isBot: ((.bot_id // "") != "" and (.user // "") == ""),
      reactions: [ (.reactions // [])[] | {name: .name, count: .count, mine: ([ (.users // [])[] ] | any(. as $u | ($mine | index($u)) != null))} ],
      files: [ (.files // [])[] | {name: (.name // .title // "file"), url: (.permalink // ""), type: (.filetype // "")} ],
      attachments: [ (.attachments // [])[] | {title: (.title // ""), text: (.text // .fallback // ""), url: (.title_link // "")} ]
    }
  ]'
}

collect_user_ids() { jq -c '[ .messages[]? | (.user // empty), ((.reactions // [])[].users // [])[] ] | unique'; }

cmd_history() {
  local channel="${1:?channel required}" limit="${2:-50}" resp users me
  resp="$(api_ok GET conversations.history "channel=$channel" "limit=$limit" "inclusive=true")"
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
  resp="$(api_ok GET conversations.replies "channel=$channel" "ts=$thread" "limit=100")"
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
  sync-read) cmd_sync_read "${2:-}" ;;
  users)     jq -n --argjson u "$(users_cache_read)" '{ok:true, users:$u}' ;;
  reset)     rm -f "$CONVOS_CACHE" "$USERS_CACHE" "$ME_CACHE"; jq -n '{ok:true}' ;;
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
  *)         fail "usage: slack.sh [--token user|bot|auto] [--me <userId>] {me|list|poll|history|replies|send|read|react|join|emoji|sync-read|users|tokens|credentials|set-credentials|reset}" ;;
esac
