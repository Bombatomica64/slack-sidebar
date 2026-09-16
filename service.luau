--!nonstrict
-- Slack backend. Owns every `slack-agent` invocation and the polling loop;
-- the widget and the panel only read `slack_status` / `slack_active` and post
-- intents to `slack_command`. Each entry is its own Luau VM, so noctalia.state
-- is the only channel between them.
--
-- The agent is the compiled helper shipped in bin/; it prints exactly one JSON
-- object per invocation and never streams.

local AGENT = `{noctalia.pluginDir()}/bin/slack-agent`
local PINNED_FILE = `{noctalia.pluginDataDir()}/pinned.json`

-- ── configuration ────────────────────────────────────────────────────────────

local function cfgInt(key, fallback)
  local value = tonumber(noctalia.getConfig(key))
  return value or fallback
end

local function cfgBool(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) == "boolean" then return value end
  return fallback
end

local function cfgString(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) == "string" then return value end
  return fallback
end

local function pollIntervalMs() return cfgInt("poll_interval", 45) * 1000 end
local function activePollIntervalMs() return cfgInt("active_poll_interval", 6) * 1000 end
local function syncIntervalMs() return cfgInt("sync_interval", 300) * 1000 end
local function historyLimit() return cfgInt("history_limit", 60) end
local function maxWatched() return cfgInt("max_watched", 48) end
-- How many of the watched conversations one poll actually asks about. See
-- pollSlice: watching more conversations must not mean spending more requests.
local function pollBatch() return cfgInt("poll_batch", 12) end
-- An edit or a new reaction changes a message without changing the newest
-- timestamp, so the incremental refresh cannot see it. This is how often the
-- open conversation re-reads a whole page anyway.
local function historyRefreshMs() return cfgInt("history_refresh_interval", 180) * 1000 end
local function tokenPreference() return cfgString("token_preference", "bot") end
local function identityUserId() return cfgString("identity_user_id", "") end

-- ── mutable state ────────────────────────────────────────────────────────────

local ready = false
local connected = false
local identity = { meId = "", meName = "", team = "", teamId = "", teamUrl = "", tokenKind = "" }
local conversations = {}     -- raw `list` rows
local pollState = {}         -- id -> { unread, mention, latest, cursor, error }
local userMap = {}           -- userId -> { name, realName, image, isBot }
local avatarMap = {}         -- userId -> local file, filled by the agent's own cache
local convAvatar = {}        -- conversationId -> local file, downloaded from `list`.image
local avatarPending = {}     -- conversationId -> true while a download is in flight
local avatarsDirty = true
local pinned = {}            -- id -> true
local lastError = ""

local activeId = ""
local activeMessages = {}
local activeHasMore = false
local activeReadCursor = ""
local activeLoading = false
local sending = false
local sendError = ""
local threadTs = ""
local threadMessages = {}
local threadLoading = false

local notifiedTs = {}
local seenFirstPoll = false

local busyList, busyPoll, busySync, busyAvatars = false, false, false, false
local lastListAt, lastPollAt, lastSyncAt, lastHistoryAt, lastAvatarAt = 0, 0, 0, 0, 0
local lastActivePollAt, lastFullHistoryAt = 0, 0
local pollCursor = 0          -- where the rotating slice of watchedIds resumes
local lastPolledIds = {}      -- the slice the last poll covered; sync-read reuses it
local statusRevision, activeRevision = 0, 0

-- Rate-limit backoff. Slack answers a throttled call with 429 and a Retry-After;
-- the helper waits out a short one itself and hands a long one back here, where
-- the only useful response is to stop asking for a while. Retrying on the very
-- next tick is what turned one throttle into a sidebar that never recovered.
local rateLimited = false
local backoffUntil = 0
local backoffStep = 0
local BACKOFF_CEILING_MS = 120000

local function noteRateLimit(retryAfter)
  backoffStep = math.min(backoffStep + 1, 7)
  -- 2s, 4s, 8s … capped, or Slack's own number when it asked for longer.
  local wait = math.min(2 ^ backoffStep * 1000, BACKOFF_CEILING_MS)
  local hinted = (tonumber(retryAfter) or 0) * 1000
  if hinted > wait then wait = math.min(hinted, BACKOFF_CEILING_MS) end
  rateLimited = true
  backoffUntil = noctalia.nowMs() + wait
  noctalia.log(`slack: rate limited, backing off {math.floor(wait / 1000)}s`)
end

local function noteAgentOk()
  if rateLimited or backoffStep ~= 0 then
    rateLimited = false
    backoffStep = 0
    backoffUntil = 0
  end
end

local function throttled() return noctalia.nowMs() < backoffUntil end

-- Slack timestamps are "1712345678.000200" strings; tonumber orders them
-- correctly and an absent one sorts oldest.
local function tsValue(ts) return tonumber(ts) or 0 end

-- ── helpers ──────────────────────────────────────────────────────────────────

local publishStatusRef = function() end

local function trim(value) return noctalia.string.trim(tostring(value or "")) end

local function shellQuote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

-- Global flags mirror the v4 `_run`: an explicit token, the identity override
-- (only meaningful while a bot token is reporting the app's own id), and the
-- archive opt-out.
local function agentCommand(args)
  local parts = { shellQuote(AGENT) }
  local pref = tokenPreference()
  if pref ~= "auto" then
    table.insert(parts, "--token")
    table.insert(parts, pref)
  end
  local me = trim(identityUserId())
  if me ~= "" and pref ~= "user" then
    table.insert(parts, "--me")
    table.insert(parts, shellQuote(me))
  end
  if not cfgBool("archive_messages", true) then
    table.insert(parts, "--no-archive")
  end
  for _, value in ipairs(args) do
    table.insert(parts, shellQuote(value))
  end
  return table.concat(parts, " ")
end

-- Every agent reply is one JSON object. `ok ~= true` carries `error`; a
-- `needsSignIn` reply means the stored refresh token no longer works, which
-- this port surfaces as an error string rather than reopening OAuth.
local function runAgent(args, context, timeoutMs, onOk)
  local started = noctalia.runAsync(agentCommand(args), function(result)
    if not result or result.exitCode ~= 0 then
      local err = trim(result and result.stderr or "")
      lastError = err ~= "" and err or noctalia.tr("error.helper_failed", { context = context })
      noctalia.log(`slack: {context} failed: {lastError}`)
      onOk(nil)
      return
    end
    local decoded = noctalia.json.decode(trim(result.stdout))
    if type(decoded) ~= "table" then
      lastError = noctalia.tr("error.unreadable", { context = context })
      onOk(nil)
      return
    end
    if decoded.needsSignIn == true then
      connected = false
      lastError = noctalia.tr("error.session_expired")
      onOk(nil)
      return
    end
    -- A throttle is not a failure of the thing being asked for, and must never
    -- read as one: the panel keeps what it has and says it is throttled, and
    -- every timer stands down until the backoff expires.
    if decoded.error == "ratelimited" or decoded.rateLimited == true then
      noteRateLimit(decoded.retryAfter)
      lastError = noctalia.tr("error.rate_limited")
      -- `poll` still answers ok with partial results; hand those on.
      onOk(decoded.ok == true and decoded or nil)
      return
    end
    if decoded.ok ~= true then
      lastError = trim(decoded.error) ~= "" and tostring(decoded.error)
        or noctalia.tr("error.helper_failed", { context = context })
      onOk(nil)
      return
    end
    noteAgentOk()
    lastError = ""
    onOk(decoded)
  end, timeoutMs or 60000)
  if not started then onOk(nil) end
  return started
end

-- ── text rendering ───────────────────────────────────────────────────────────

-- A faithful port of the v4 Components/Mrkdwn.js. Slack escapes only &, < and >
-- inside message text and uses real angle brackets for its own entities
-- (<@U123>, <#C1|name>, <!here>, <https://x|label>), so the order is fixed:
-- resolve the entities first, then unescape the prose, then the shortcodes.
local EMOJI = {
  smile = "\u{1F604}", smiley = "\u{1F603}", grin = "\u{1F601}", joy = "\u{1F602}",
  rofl = "\u{1F923}", sweat_smile = "\u{1F605}", wink = "\u{1F609}", blush = "\u{1F60A}",
  thinking_face = "\u{1F914}", neutral_face = "\u{1F610}", expressionless = "\u{1F611}",
  smirk = "\u{1F60F}", unamused = "\u{1F612}", disappointed = "\u{1F61E}",
  pensive = "\u{1F614}", confused = "\u{1F615}", worried = "\u{1F61F}",
  cry = "\u{1F622}", sob = "\u{1F62D}", scream = "\u{1F631}", flushed = "\u{1F633}",
  sunglasses = "\u{1F60E}", sleeping = "\u{1F634}", nerd_face = "\u{1F913}",
  exploding_head = "\u{1F92F}", face_with_monocle = "\u{1F9D0}",
  shushing_face = "\u{1F92B}", saluting_face = "\u{1FAE1}",
  thumbsup = "\u{1F44D}", ["+1"] = "\u{1F44D}", thumbsdown = "\u{1F44E}", ["-1"] = "\u{1F44E}",
  ok_hand = "\u{1F44C}", clap = "\u{1F44F}", raised_hands = "\u{1F64C}",
  pray = "\u{1F64F}", muscle = "\u{1F4AA}", point_right = "\u{1F449}",
  point_left = "\u{1F448}", wave = "\u{1F44B}", eyes = "\u{1F440}",
  brain = "\u{1F9E0}", handshake = "\u{1F91D}", crossed_fingers = "\u{1F91E}",
  heart = "\u{2764}", yellow_heart = "\u{1F49B}", green_heart = "\u{1F49A}",
  blue_heart = "\u{1F499}", purple_heart = "\u{1F49C}", broken_heart = "\u{1F494}",
  sparkling_heart = "\u{1F496}", fire = "\u{1F525}", tada = "\u{1F389}",
  confetti_ball = "\u{1F38A}", rocket = "\u{1F680}", sparkles = "\u{2728}",
  star = "\u{2B50}", star2 = "\u{1F31F}", zap = "\u{26A1}", boom = "\u{1F4A5}",
  ["100"] = "\u{1F4AF}", bulb = "\u{1F4A1}", wrench = "\u{1F527}", hammer = "\u{1F528}",
  gear = "\u{2699}", bug = "\u{1F41B}", skull = "\u{1F480}", ghost = "\u{1F47B}",
  alien = "\u{1F47D}", robot_face = "\u{1F916}", computer = "\u{1F4BB}",
  keyboard = "\u{2328}", white_check_mark = "\u{2705}", heavy_check_mark = "\u{2714}",
  ballot_box_with_check = "\u{2611}", x = "\u{274C}", warning = "\u{26A0}",
  no_entry = "\u{26D4}", no_entry_sign = "\u{1F6AB}", exclamation = "\u{2757}",
  question = "\u{2753}", bangbang = "\u{203C}", arrow_up = "\u{2B06}",
  arrow_down = "\u{2B07}", arrow_right = "\u{27A1}", arrow_left = "\u{2B05}",
  recycle = "\u{267B}", hourglass = "\u{231B}", hourglass_flowing_sand = "\u{23F3}",
  alarm_clock = "\u{23F0}", calendar = "\u{1F4C5}", date = "\u{1F4C6}",
  memo = "\u{1F4DD}", pencil = "\u{270F}", books = "\u{1F4DA}", book = "\u{1F4D6}",
  page_facing_up = "\u{1F4C4}", clipboard = "\u{1F4CB}", paperclip = "\u{1F4CE}",
  link = "\u{1F517}", lock = "\u{1F512}", key = "\u{1F511}", mag = "\u{1F50D}",
  chart_with_upwards_trend = "\u{1F4C8}", chart_with_downwards_trend = "\u{1F4C9}",
  bar_chart = "\u{1F4CA}", moneybag = "\u{1F4B0}", dollar = "\u{1F4B5}",
  credit_card = "\u{1F4B3}", mailbox = "\u{1F4EC}", email = "\u{1F4E7}",
  inbox_tray = "\u{1F4E5}", outbox_tray = "\u{1F4E4}", bell = "\u{1F514}",
  no_bell = "\u{1F515}", loudspeaker = "\u{1F4E2}", mega = "\u{1F4E3}",
  coffee = "\u{2615}", tea = "\u{1F375}", beer = "\u{1F37A}", beers = "\u{1F37B}",
  wine_glass = "\u{1F377}", pizza = "\u{1F355}", hamburger = "\u{1F354}",
  cake = "\u{1F370}", birthday = "\u{1F382}", sos = "\u{1F198}", new = "\u{1F195}",
  ok = "\u{1F197}", up = "\u{1F199}", sunny = "\u{2600}", cloud = "\u{2601}",
  snowflake = "\u{2744}", rainbow = "\u{1F308}", earth_africa = "\u{1F30D}",
  moon = "\u{1F319}", seedling = "\u{1F331}", palm_tree = "\u{1F334}",
  cactus = "\u{1F335}", four_leaf_clover = "\u{1F340}", dog = "\u{1F436}",
  cat = "\u{1F431}", mouse = "\u{1F42D}", hamster = "\u{1F439}",
  rabbit = "\u{1F430}", bear = "\u{1F43B}", panda_face = "\u{1F43C}",
  penguin = "\u{1F427}", owl = "\u{1F989}", whale = "\u{1F433}",
  dolphin = "\u{1F42C}", fish = "\u{1F41F}", octopus = "\u{1F419}",
  snail = "\u{1F40C}", turtle = "\u{1F422}", snake = "\u{1F40D}",
  dragon = "\u{1F409}", unicorn_face = "\u{1F984}", shrug = "\u{1F937}",
  ["man-shrugging"] = "\u{1F937}", ["woman-shrugging"] = "\u{1F937}",
  facepalm = "\u{1F926}", party_parrot = "\u{1F99C}", frog = "\u{1F438}",
}

-- Mrkdwn.js renderEntity/preview, minus the HTML: one <...> token to plain text.
local function resolveEntity(inner)
  local bar = inner:find("|", 1, true)
  local head = bar and inner:sub(1, bar - 1) or inner
  local label = bar and inner:sub(bar + 1) or ""
  local lead = head:sub(1, 1)

  if lead == "@" then
    local uid = head:sub(2)
    if label ~= "" then return `@{label}` end
    local u = userMap[uid]
    return `@{(u and u.name) or uid}`
  end
  if lead == "#" then
    return `#{label ~= "" and label or head:sub(2)}`
  end
  if lead == "!" then
    -- <!here>, <!channel>, <!everyone> and <!subteam^S123|@group>.
    local special = head:sub(2)
    local caret = special:find("%^")
    if caret then
      special = label ~= "" and (label:gsub("^@", "")) or special:sub(1, caret - 1)
    end
    return `@{special}`
  end
  if label ~= "" then return label end
  if head:sub(1, 7) == "mailto:" then return head:sub(8) end
  return (head:gsub("^https?://", ""):gsub("/$", ""))
end

-- Slack escapes exactly these inside message text; &quot;/&#39; leak in from
-- pasted HTML, which the v4 renderer also had to survive.
local function unescapeEntities(s)
  s = s:gsub("&lt;", "<"):gsub("&gt;", ">")
  s = s:gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&nbsp;", " ")
  return (s:gsub("&amp;", "&"))
end

local function emojify(s)
  if not s:find(":", 1, true) then return s end
  s = s:gsub(":skin%-tone%-%d:", "")
  return (s:gsub(":([%w_%+%-']+):", function(name)
    return EMOJI[name:lower()]
  end))
end

-- Memoised: publishStatus runs over every watched conversation on every poll and
-- the panel re-renders a whole page of history.
local renderCache = {}
local renderCacheSize = 0

local function cacheGet(key)
  return renderCache[key]
end

local function cachePut(key, value)
  if renderCacheSize > 1500 then
    renderCache = {}
    renderCacheSize = 0
  end
  renderCache[key] = value
  renderCacheSize += 1
  return value
end

-- Message body: entities and escapes resolved, newlines and mrkdwn emphasis
-- markers left alone (ui.label is plain text, so `*bold*` is the honest form).
local function renderText(text)
  local raw = tostring(text or "")
  if not raw:find("[<&:]") then return raw end
  local hit = cacheGet(`b\0{raw}`)
  if hit ~= nil then return hit end
  local s = raw:gsub("<([^<>\n]*)>", resolveEntity)
  return cachePut(`b\0{raw}`, emojify(unescapeEntities(s)))
end

-- One-line flattening for the conversation list and notifications: the v4
-- Mrkdwn.preview(). Render first, truncate after — truncating the raw text cut
-- <https://…|label> entities in half and left the angle brackets on screen,
-- which is exactly the "mangled preview" this replaces.
local function oneLine(text, limit)
  local raw = tostring(text or "")
  if raw == "" then return "" end
  local key = `p{limit or 0}\0{raw}`
  local hit = cacheGet(key)
  if hit ~= nil then return hit end

  local s = raw:gsub("```", " ")
  -- `poll` hands back a latest.text truncated to 140 characters, which happily
  -- cuts a <https://…|label> entity in half; close the dangling one so it
  -- resolves to its label instead of leaking a raw URL into the list.
  if s:match("<[^<>]*$") then s ..= ">" end
  s = s:gsub("<([^<>\n]*)>", resolveEntity)
  s = emojify(unescapeEntities(s))
  -- Emphasis markers go, but not the underscores inside a shortcode we could
  -- not resolve: v4's preview() turned :large_yellow_circle: into
  -- :largeyellowcircle:, which is worse than leaving the token alone.
  local shortcodes = {}
  s = s:gsub(":([%w_%+%-']+):", function(name)
    table.insert(shortcodes, name)
    return `\1{#shortcodes}\1`
  end)
  s = s:gsub("[%*_~`]", "")
  s = s:gsub("\1(%d+)\1", function(index)
    return `:{shortcodes[tonumber(index)]}:`
  end)
  s = s:gsub("%s+", " ")
  s = trim(s)
  if limit and #s > limit then
    local cut = limit - 1
    -- Never cut inside a UTF-8 sequence: back off over continuation bytes.
    while cut > 1 and s:byte(cut + 1) and s:byte(cut + 1) >= 0x80 and s:byte(cut + 1) < 0xC0 do
      cut -= 1
    end
    s = s:sub(1, cut) .. "\u{2026}"
  end
  return cachePut(key, s)
end

local function mergeUsers(users)
  if type(users) ~= "table" then return end
  local added = false
  for id, info in pairs(users) do
    if type(info) == "table" and userMap[id] == nil then
      added = true
    end
    if type(info) == "table" then userMap[id] = info end
  end
  -- A newly known user changes how "<@U…>" renders, so drop the memo once.
  if added then
    renderCache = {}
    renderCacheSize = 0
    avatarsDirty = true
  end
end

-- ── avatars ──────────────────────────────────────────────────────────────────

-- ui.image takes a local path, never a URL. Two sources, cheapest first:
-- the agent already downloads every known user's avatar into its own cache
-- (`avatars` returns userId -> file), which covers every DM; anything left over
-- (a conversation whose `list` row carries an `image` URL for a user the agent
-- has not seen yet) is fetched once into the plugin data dir.
local AVATAR_DIR = `{noctalia.pluginDataDir()}/avatars`

local function refreshAvatars()
  if busyAvatars then return end
  busyAvatars = true
  avatarsDirty = false
  lastAvatarAt = noctalia.nowMs()
  runAgent({ "avatars" }, "avatars", 60000, function(res)
    busyAvatars = false
    if res and type(res.avatars) == "table" then
      avatarMap = res.avatars
      publishStatusRef()
    end
  end)
end

local function avatarFor(conv)
  local uid = tostring(conv.user or "")
  if uid ~= "" then
    local path = avatarMap[uid]
    if type(path) == "string" and path ~= "" then return path end
  end
  local cached = convAvatar[conv.id]
  if cached ~= nil then return cached end

  local url = tostring(conv.image or "")
  if url == "" or avatarPending[conv.id] then return "" end
  local ext = url:match("%.(%a%a%a?%a?)$") or "jpg"
  local dest = `{AVATAR_DIR}/{conv.id}.{ext}`
  if noctalia.fileExists(dest) then
    convAvatar[conv.id] = dest
    return dest
  end
  avatarPending[conv.id] = true
  noctalia.mkdirAll(AVATAR_DIR)
  noctalia.download(url, dest, function(success)
    avatarPending[conv.id] = nil
    if success then
      convAvatar[conv.id] = dest
      publishStatusRef()
    end
  end)
  return ""
end

-- ── pinned channels (runtime state, not a setting) ───────────────────────────

local function loadPinned()
  local raw = noctalia.readFile(PINNED_FILE)
  if type(raw) ~= "string" or trim(raw) == "" then return end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then return end
  for _, id in ipairs(decoded) do
    if type(id) == "string" and id ~= "" then pinned[id] = true end
  end
end

local function savePinned()
  local list = {}
  for id in pairs(pinned) do table.insert(list, id) end
  table.sort(list)
  noctalia.writeFile(PINNED_FILE, noctalia.json.encode(list))
end

-- ── derived views ────────────────────────────────────────────────────────────

local function conversationById(id)
  for _, c in ipairs(conversations) do
    if c.id == id then return c end
  end
  return nil
end

-- Only a conversation the agent actually polls can report a count, and only a
-- *joined* conversation has a read cursor at all — so every joined conversation
-- is watched, channels included. Watching DMs alone (the first port's rule) is
-- why every badge read zero: this workspace's unread all sits in #channels,
-- and 140 of the 154 rows in `list` are channels the token has not joined and
-- which can never be unread.
-- Order is the priority order, because the list is truncated to max_watched.
local function watchedIds()
  local out, seen = {}, {}
  local function push(id)
    if type(id) == "string" and id ~= "" and not seen[id] then
      seen[id] = true
      table.insert(out, id)
    end
  end
  push(activeId)
  for id in pairs(pinned) do push(id) end
  for _, c in ipairs(conversations) do
    if (c.type == "im" or c.type == "mpim") and c.joined ~= false then push(c.id) end
  end
  for _, c in ipairs(conversations) do
    if c.joined ~= false then push(c.id) end
  end
  local limit = math.max(1, maxWatched())
  while #out > limit do table.remove(out) end
  return out
end

-- Mentions first, then unread, then pinned, then recency — the v4 ordering.
local function decorated()
  local list = {}
  for _, c in ipairs(conversations) do
    local st = pollState[c.id] or {}
    local latest = type(st.latest) == "table" and st.latest or nil
    local joined = c.joined ~= false
    -- v4's ConversationList preview: "You: …" / "Author: …", the channel topic
    -- when nothing has been said, and a members line for channels not joined.
    local preview
    if not joined then
      local members = tonumber(c.members) or 0
      preview = members > 0
        and noctalia.tr("panel.not_joined_members", { count = members })
        or noctalia.tr("panel.not_joined")
    elseif latest then
      local who = latest.mine == true
        and noctalia.tr("panel.you")
        or tostring(latest.author or "")
      local body = oneLine(latest.text, 80)
      preview = who ~= "" and `{who}: {body}` or body
    else
      preview = oneLine(c.topic, 90)
    end
    table.insert(list, {
      id = c.id,
      type = c.type or "",
      name = tostring(c.name or c.id),
      unread = tonumber(st.unread) or 0,
      mention = st.mention == true,
      pinned = pinned[c.id] == true,
      joined = joined,
      avatar = avatarFor(c),
      latestTs = latest and (tonumber(latest.ts) or 0) or 0,
      latestText = preview,
      latestAuthor = latest and tostring(latest.author or "") or "",
      error = tostring(st.error or ""),
    })
  end
  table.sort(list, function(a, b)
    if a.mention ~= b.mention then return a.mention end
    if (a.unread > 0) ~= (b.unread > 0) then return a.unread > 0 end
    if a.pinned ~= b.pinned then return a.pinned end
    if a.latestTs ~= b.latestTs then return a.latestTs > b.latestTs end
    return a.name:lower() < b.name:lower()
  end)
  return list
end

local function totals()
  local unread, mentions = 0, 0
  for _, st in pairs(pollState) do
    unread += tonumber(st.unread) or 0
    if st.mention == true then mentions += 1 end
  end
  return unread, mentions
end

-- ── publishing ───────────────────────────────────────────────────────────────

local function publishStatus()
  local unread, mentions = totals()
  statusRevision += 1
  noctalia.state.set("slack_status", {
    ready = ready,
    connected = connected,
    error = lastError,
    meId = identity.meId,
    meName = identity.meName,
    team = identity.team,
    teamId = identity.teamId,
    teamUrl = identity.teamUrl,
    tokenKind = identity.tokenKind,
    totalUnread = unread,
    mentionCount = mentions,
    conversations = decorated(),
    updatedAt = math.floor(noctalia.nowMs() / 1000),
    revision = statusRevision,
  })
end

publishStatusRef = publishStatus

local function messageView(m)
  local ts = tostring(m.ts or "")
  local reactions = {}
  if type(m.reactions) == "table" then
    for _, r in ipairs(m.reactions) do
      table.insert(reactions, {
        name = tostring(r.name or ""),
        count = tonumber(r.count) or 0,
        mine = r.mine == true,
      })
    end
  end
  -- v4 rendered link unfurls as LinkCards; dropping them entirely is why a
  -- message that is only a pasted link showed up blank.
  local attachments = {}
  if type(m.attachments) == "table" then
    for _, a in ipairs(m.attachments) do
      local title = oneLine(a.title, 110)
      local body = oneLine(a.text, 220)
      if title ~= "" or body ~= "" then
        table.insert(attachments, {
          title = title,
          text = body,
          site = tostring(a.site or ""),
          url = tostring(a.url or a.fromUrl or ""),
        })
      end
    end
  end
  local files = {}
  if type(m.files) == "table" then
    for _, f in ipairs(m.files) do
      table.insert(files, tostring(f.name or f.type or ""))
    end
  end
  return {
    ts = ts,
    author = tostring(m.author or ""),
    avatar = avatarMap[tostring(m.user or "")] or "",
    text = renderText(m.text),
    mine = m.mine == true,
    isBot = m.isBot == true,
    edited = m.edited == true,
    replyCount = tonumber(m.replyCount) or 0,
    fileCount = #files,
    files = files,
    attachments = attachments,
    time = noctalia.formatTime("%H:%M", math.floor(tonumber(ts) or 0)),
    reactions = reactions,
  }
end

local function viewList(messages)
  local out = {}
  if type(messages) ~= "table" then return out end
  for _, m in ipairs(messages) do
    table.insert(out, messageView(m))
  end
  return out
end

local function publishActive()
  local conv = conversationById(activeId)
  activeRevision += 1
  noctalia.state.set("slack_active", {
    id = activeId,
    name = conv and tostring(conv.name or activeId) or activeId,
    type = conv and tostring(conv.type or "") or "",
    joined = conv == nil or conv.joined ~= false,
    loading = activeLoading,
    hasMore = activeHasMore,
    sending = sending,
    sendError = sendError,
    messages = viewList(activeMessages),
    threadTs = threadTs,
    threadLoading = threadLoading,
    threadMessages = viewList(threadMessages),
    -- An empty transcript that actually means "Slack throttled us" is the bug
    -- that made this whole regression invisible. The panel gets told which one
    -- it is looking at.
    rateLimited = rateLimited,
    error = rateLimited and noctalia.tr("error.rate_limited") or "",
    revision = activeRevision,
  })
end

-- ── notifications ────────────────────────────────────────────────────────────

-- The first poll of a session describes what was already waiting; that is not
-- news, so it is recorded and not announced.
local function notifyForPoll(next)
  local firstPoll = not seenFirstPoll
  seenFirstPoll = true
  local notifyDms = cfgBool("notify_dms", true)
  local notifyMentions = cfgBool("notify_mentions", true)
  local seen = {}

  for id, st in pairs(next) do
    if type(st) == "table" then
      local msg = type(st.latestUnread) == "table" and st.latestUnread or nil
      local prior = notifiedTs[id]
      if msg == nil then
        -- Nothing unread: keep what we knew, so an older message can never come
        -- back around and announce itself.
        if prior ~= nil then seen[id] = prior end
      else
        seen[id] = msg.ts
        local isNew = not firstPoll
          and (prior == nil or (tonumber(msg.ts) or 0) > (tonumber(prior) or 0))
        local mine = msg.mine == true
          or (msg.user ~= nil and (msg.user == identity.meId or msg.user == identityUserId()))
        if isNew and id ~= activeId and not mine then
          local conv = conversationById(id)
          local kind = conv and tostring(conv.type or "") or ""
          local isDm = kind == "im"
          local isGroupDm = kind == "mpim"
          local wanted = ((isDm or isGroupDm) and notifyDms) or (st.mention == true and notifyMentions)
          if wanted then
            local where = conv and (isDm and tostring(conv.name) or `#{conv.name}`) or id
            -- In a 1:1 the title already names the sender.
            local body = isDm and oneLine(msg.text, 180)
              or `{tostring(msg.author or "")}: {oneLine(msg.text, 160)}`
            noctalia.notify(where, body)
          end
        end
      end
    end
  end
  -- `next` is one rotating slice of the watched list, not all of it. Whatever it
  -- did not mention keeps the timestamp it already had, or the conversation
  -- would re-announce its newest message every time the rotation came back to
  -- it.
  for id, ts in pairs(notifiedTs) do
    if next[id] == nil then seen[id] = ts end
  end
  notifiedTs = seen
end

-- ── agent actions ────────────────────────────────────────────────────────────

local function refreshIdentity()
  runAgent({ "me" }, "auth", 45000, function(res)
    if res then
      connected = true
      identity = {
        meId = tostring(res.userId or ""),
        meName = tostring(res.user or ""),
        team = tostring(res.team or ""),
        teamId = tostring(res.teamId or ""),
        teamUrl = tostring(res.url or ""),
        tokenKind = tostring(res.tokenKind or ""),
      }
    else
      connected = false
    end
    publishStatus()
  end)
end

local function refreshList(force)
  if busyList then return end
  busyList = true
  lastListAt = noctalia.nowMs()
  local args = force and { "list", "force" } or { "list" }
  runAgent(args, "conversations", 180000, function(res)
    busyList = false
    if res and type(res.conversations) == "table" then
      conversations = res.conversations
      avatarsDirty = true
    end
    publishStatus()
  end)
end

-- `poll` costs one Slack request per conversation in the batch, so asking about
-- all `max_watched` of them on every tick made the request rate a multiple of a
-- setting that exists to make *badges* better. It does not have to: the open
-- conversation is always in the batch, and the rest take turns.
--
-- With the defaults (48 watched, 12 per batch, a 45s tick) a full sweep takes
-- four ticks - three minutes - instead of one 48-request burst. A background
-- channel's badge is therefore up to a sweep stale, which for a channel nobody
-- is looking at is minutes-old news anyway; the open conversation and the DMs at
-- the head of watchedIds are never stale, because the active tick covers the
-- former and the rotation reaches the latter first.
local function pollSlice()
  local ids = watchedIds()
  local batch = math.max(1, pollBatch())
  if #ids <= batch then
    pollCursor = 0
    return ids
  end

  local out, seen = {}, {}
  if activeId ~= "" then
    table.insert(out, activeId)
    seen[activeId] = true
  end
  local scanned = 0
  while #out < batch and scanned < #ids do
    local id = ids[(pollCursor + scanned) % #ids + 1]
    if not seen[id] then
      seen[id] = true
      table.insert(out, id)
    end
    scanned += 1
  end
  pollCursor = (pollCursor + scanned) % #ids
  return out
end

local function poll()
  local ids = pollSlice()
  if #ids == 0 or busyPoll then return end
  busyPoll = true
  lastPollAt = noctalia.nowMs()
  lastPolledIds = ids
  runAgent({ "poll", table.concat(ids, ",") }, "poll", 120000, function(res)
    busyPoll = false
    if res and type(res.conversations) == "table" then
      notifyForPoll(res.conversations)
      -- A slice, not the whole list: merge, or every conversation this tick did
      -- not ask about would report zero unread and lose its badge. A throttled
      -- slot is missing from the answer for the same reason, and is kept too.
      for id, state in pairs(res.conversations) do
        pollState[id] = state
      end
      -- Anything no longer watched stops contributing to the totals.
      local watched = {}
      for _, id in ipairs(watchedIds()) do watched[id] = true end
      for id in pairs(pollState) do
        if not watched[id] then pollState[id] = nil end
      end
    end
    publishStatus()
  end)
end

-- Just the open conversation, on the fast tick: one request, which is what
-- makes the transcript feel live without the other 47 riding along.
local function pollActive()
  if activeId == "" or busyPoll then return end
  busyPoll = true
  lastActivePollAt = noctalia.nowMs()
  local channel = activeId
  runAgent({ "poll", channel }, "poll", 60000, function(res)
    busyPoll = false
    if res and type(res.conversations) == "table" then
      notifyForPoll(res.conversations)
      for id, state in pairs(res.conversations) do
        pollState[id] = state
      end
    end
    publishStatus()
  end)
end

-- Reconciles local read cursors with Slack's, one `conversations.info` per id.
-- Same slice the last poll used, for the same reason: it is per-conversation
-- cost on a timer, and the tail does not need it any sooner than the rotation
-- reaches it.
local function syncReadState()
  local ids = #lastPolledIds > 0 and lastPolledIds or pollSlice()
  if #ids == 0 or busySync then return end
  busySync = true
  lastSyncAt = noctalia.nowMs()
  runAgent({ "sync-read", table.concat(ids, ",") }, "sync read", 120000, function()
    busySync = false
  end)
end

local markPending = nil

local function markActiveRead()
  if activeId == "" or #activeMessages == 0 then return end
  local newest = tostring(activeMessages[1].ts or "")
  if newest == "" or newest == activeReadCursor then return end
  local channel = activeId
  markPending = newest
  runAgent({ "read", channel, newest }, "mark read", 45000, function(res)
    if not res or markPending ~= newest then return end
    markPending = nil
    -- Reflect the new cursor locally so the badge clears without waiting for
    -- the next poll round-trip.
    local entry = pollState[channel] or {}
    pollState[channel] = {
      ok = true,
      error = entry.error or "",
      unread = 0,
      mention = false,
      cursor = newest,
      latest = entry.latest,
    }
    if channel == activeId then activeReadCursor = newest end
    publishStatus()
    pollActive()
  end)
end

-- Both arrays are newest-first. The fresh page wins wherever the two overlap,
-- because that is where an edit or a new reaction shows up; everything older is
-- kept, which is what stops a poll from throwing away pages already scrolled to.
local function mergeHistory(fresh)
  if #activeMessages == 0 or #fresh == 0 then return fresh end
  local oldestFresh = tonumber(fresh[#fresh].ts) or 0
  local merged = {}
  for _, m in ipairs(fresh) do table.insert(merged, m) end
  for _, m in ipairs(activeMessages) do
    if (tonumber(m.ts) or 0) < oldestFresh then table.insert(merged, m) end
  end
  return merged
end

-- The newest message the transcript is holding, or "" when it holds none.
local function activeNewestTs()
  return #activeMessages > 0 and tostring(activeMessages[1].ts or "") or ""
end

-- `fresh` is newest-first and entirely newer than what we hold, so it goes on
-- the front. Keyed on ts anyway: a message we just sent is already in the list,
-- and a duplicate of it would render twice.
local function prependNew(fresh)
  if #fresh == 0 then return activeMessages end
  local have = {}
  for _, m in ipairs(activeMessages) do have[tostring(m.ts or "")] = true end
  local merged = {}
  for _, m in ipairs(fresh) do
    if not have[tostring(m.ts or "")] then table.insert(merged, m) end
  end
  if #merged == 0 then return activeMessages end
  for _, m in ipairs(activeMessages) do table.insert(merged, m) end
  return merged
end

-- `incremental` asks only for what arrived after the newest message already on
-- screen. That is the whole rate-limit fix: the open conversation used to
-- re-request its entire `history_limit` every `active_poll_interval`, which on
-- the six-second default is ten full transcripts a minute, every minute, for a
-- conversation nobody was typing in.
local function loadHistory(channel, incremental)
  channel = channel or activeId
  if channel == "" then return end

  local since = ""
  if incremental and channel == activeId then since = activeNewestTs() end

  local now = noctalia.nowMs()
  activeLoading = true
  lastHistoryAt = now
  -- Only a full read resets the full-read clock; an incremental one has not
  -- looked at the older messages at all.
  if since == "" then lastFullHistoryAt = now end
  publishActive()

  local args = { "history", channel, tostring(historyLimit()) }
  if since ~= "" then
    -- Positional: <channel> <limit> <before-ts> <since-ts>. No `before`, so the
    -- slot is empty.
    table.insert(args, "")
    table.insert(args, since)
  end

  runAgent(args, "history", 90000, function(res)
    activeLoading = false
    if res and channel == activeId then
      mergeUsers(res.users)
      -- An incremental answer is strictly newer than what is on screen, so it
      -- goes on the front. If more had arrived than one page holds the helper
      -- would have answered with a plain read instead (see historySince), which
      -- lands in the branch below.
      if res.incremental == true then
        activeMessages = prependNew(res.messages or {})
      else
        -- Either a read we asked for, or an incremental one the helper turned
        -- into a plain read because too much had arrived. Both are a whole
        -- page, so both reset the slow-refresh clock.
        lastFullHistoryAt = noctalia.nowMs()
        activeMessages = mergeHistory(res.messages or {})
        activeHasMore = res.hasMore == true
      end
      activeReadCursor = tostring(res.readCursor or "")
      if cfgBool("mark_read_on_open", true) then markActiveRead() end
    end
    publishActive()
  end)
end

local function loadOlder()
  if activeId == "" or not activeHasMore or #activeMessages == 0 then return end
  local channel = activeId
  local oldest = tostring(activeMessages[#activeMessages].ts or "")
  if oldest == "" then return end
  activeLoading = true
  publishActive()
  runAgent({ "history", channel, tostring(historyLimit()), oldest }, "history", 90000, function(res)
    activeLoading = false
    if res and channel == activeId then
      mergeUsers(res.users)
      for _, m in ipairs(res.messages or {}) do table.insert(activeMessages, m) end
      activeHasMore = res.hasMore == true
    end
    publishActive()
  end)
end

local function loadThread(ts)
  if activeId == "" or ts == "" then return end
  local channel = activeId
  threadTs = ts
  threadLoading = true
  publishActive()
  runAgent({ "replies", channel, ts }, "thread", 90000, function(res)
    threadLoading = false
    if res and channel == activeId and threadTs == ts then
      mergeUsers(res.users)
      threadMessages = res.messages or {}
    end
    publishActive()
  end)
end

local function openConversation(id)
  if type(id) ~= "string" or id == "" then return end
  if id ~= activeId then
    activeId = id
    activeMessages = {}
    activeHasMore = false
    activeReadCursor = ""
    threadTs = ""
    threadMessages = {}
    sendError = ""
  end
  publishActive()
  loadHistory(id)
  pollActive()
end

local function sendMessage(text)
  local body = trim(text)
  if body == "" or activeId == "" or sending then return end
  sending = true
  sendError = ""
  publishActive()
  local args = { "send", activeId, body }
  if threadTs ~= "" then table.insert(args, threadTs) end
  runAgent(args, "send", 60000, function(res)
    sending = false
    if not res then
      sendError = lastError ~= "" and lastError or noctalia.tr("error.not_sent")
      publishActive()
      return
    end
    sendError = ""
    if threadTs ~= "" then loadThread(threadTs) else loadHistory(activeId, true) end
    pollActive()
  end)
end

local function toggleReaction(ts, name, mine)
  if activeId == "" or type(ts) ~= "string" or ts == "" or type(name) ~= "string" or name == "" then
    return
  end
  local channel = activeId
  runAgent({ "react", channel, ts, name, mine and "remove" or "add" }, "react", 45000, function(res)
    if not res then
      publishActive()
      return
    end
    if threadTs ~= "" then loadThread(threadTs) else loadHistory(channel) end
  end)
end

local function joinConversation(id)
  local target = trim(id) ~= "" and id or activeId
  if target == "" then return end
  runAgent({ "join", target }, "join", 60000, function(res)
    if res then
      refreshList(true)
      if target == activeId then loadHistory(target) end
    else
      publishStatus()
    end
  end)
end

local function openInSlack(id)
  local target = trim(id) ~= "" and id or activeId
  if target == "" then return end
  local url = identity.teamId ~= ""
    and `slack://channel?team={identity.teamId}&id={target}`
    or `{identity.teamUrl}archives/{target}`
  noctalia.runAsync(`xdg-open {shellQuote(url)}`, function() end, 10000)
end

-- ── command channel ──────────────────────────────────────────────────────────

local function executeCommand(command)
  if type(command) ~= "table" then return end
  local action = tostring(command.action or "")

  if action == "refresh" then
    -- The user asking out loud clears the backoff: they would rather see the
    -- throttle again than a sidebar that refuses to try.
    backoffUntil = 0
    backoffStep = 0
    rateLimited = false
    refreshIdentity()
    refreshList(true)
    poll()
    if activeId ~= "" then loadHistory() end
  elseif action == "open" then
    openConversation(tostring(command.id or ""))
  elseif action == "close" then
    activeId = ""
    activeMessages = {}
    threadTs = ""
    threadMessages = {}
    publishActive()
  elseif action == "send" then
    sendMessage(command.text)
  elseif action == "mark_read" then
    markActiveRead()
  elseif action == "load_older" then
    loadOlder()
  elseif action == "open_thread" then
    loadThread(tostring(command.ts or ""))
  elseif action == "close_thread" then
    threadTs = ""
    threadMessages = {}
    publishActive()
  elseif action == "react" then
    toggleReaction(tostring(command.ts or ""), tostring(command.name or ""), command.mine == true)
  elseif action == "toggle_pin" then
    local id = tostring(command.id or "")
    if id ~= "" then
      if pinned[id] then pinned[id] = nil else pinned[id] = true end
      savePinned()
      publishStatus()
      poll()
    end
  elseif action == "join" then
    joinConversation(tostring(command.id or ""))
  elseif action == "open_external" then
    openInSlack(tostring(command.id or ""))
  end
end

noctalia.state.watch("slack_command", executeCommand)

-- ── startup and scheduling ───────────────────────────────────────────────────

loadPinned()
publishStatus()
publishActive()

-- Nothing runs until the helper has answered once: a missing binary would
-- otherwise look like a hundred separate failures.
noctalia.runAsync(`test -x {shellQuote(AGENT)} && {shellQuote(AGENT)} credentials`, function(result)
  if result and result.exitCode == 0 then
    ready = true
    refreshIdentity()
    refreshList(false)
    poll()
    refreshAvatars()
  else
    ready = false
    lastError = noctalia.tr("error.no_agent", { path = AGENT })
    noctalia.log(`slack: helper not runnable at {AGENT}`)
  end
  publishStatus()
end, 30000)

-- One second tick drives every timer; the intervals are compared against
-- nowMs so a settings change takes effect on the next tick.
noctalia.setUpdateInterval(1000)

function update()
  if not ready then return end
  local now = noctalia.nowMs()
  -- Throttled: every timer stands down together. Asking a smaller question
  -- while Slack is refusing is still asking.
  if throttled() then return end

  -- Two cadences, not one. The open conversation is asked about every
  -- `active_poll_interval` because that is what makes it feel live, and costs
  -- exactly one request; the watched list takes turns at `poll_interval`,
  -- `poll_batch` at a time. Before this, an open conversation put *every*
  -- watched conversation on the six-second tick.
  if activeId ~= "" and now - lastActivePollAt >= activePollIntervalMs() then pollActive() end
  if now - lastPollAt >= pollIntervalMs() then poll() end
  if now - lastListAt >= 600000 then refreshList(false) end
  if now - lastSyncAt >= syncIntervalMs() then syncReadState() end
  -- The agent downloads avatars for every user it learns about; re-read its
  -- cache a few seconds after the user map grows (the v4 4s debounce).
  if avatarsDirty and now - lastAvatarAt >= 4000 then refreshAvatars() end

  -- The floor is what stops a conversation whose history call keeps failing from
  -- retrying on every one-second tick: the transcript stays empty, so the
  -- "something is newer" test below stays true forever.
  if activeId ~= "" and not activeLoading and now - lastHistoryAt >= activePollIntervalMs() then
    -- Fetch only when `poll` has actually seen something newer than the newest
    -- message on screen, and then only the part that is new. A quiet open
    -- conversation costs no history requests at all, where it used to cost one
    -- full transcript every six seconds.
    local state = pollState[activeId]
    local latest = type(state) == "table" and type(state.latest) == "table" and state.latest or nil
    local newest = latest and tostring(latest.ts or "") or ""
    if newest ~= "" and tsValue(newest) > tsValue(activeNewestTs()) then
      loadHistory(activeId, true)
    elseif now - lastFullHistoryAt >= historyRefreshMs() then
      -- An edit or a reaction moves no timestamp, so a whole page is still
      -- re-read - about twice an hour rather than six hundred times.
      loadHistory(activeId, false)
    end
  end
end
