--!nonstrict
-- Request-rate simulation for service.luau.
--
-- The rate-limit regression was not a logic bug any unit test would have caught:
-- every individual call was correct, there were simply far too many of them. So
-- the thing worth pinning down is the *count*. This harness stubs the noctalia
-- host, runs the real service.luau scheduler against a fake clock, and asserts
-- how many `slack-agent` invocations an hour of sidebar actually costs.
--
-- Run by `make luau` (which concatenates prelude + service.luau + driver and
-- pipes the result to the luau interpreter), so the service source is the real
-- one and not a copy that can drift.
--
-- This file is the PRELUDE half. The driver half is service_sim_driver.luau.

-- ── the recorder ─────────────────────────────────────────────────────────────

-- Global on purpose: service.luau is concatenated after this file and the
-- driver after that, so the recorder has to outlive this chunk's scope.
sim = {
  now = 0,            -- ms, advanced only by the driver
  calls = {},         -- verb -> count
  log = {},           -- every verb, in order
  replies = {},       -- token -> the table json.decode should hand back
  nextToken = 0,
  pending = {},       -- callbacks not yet delivered
  autoDeliver = true,
}

local function record(verb)
  sim.calls[verb] = (sim.calls[verb] or 0) + 1
  table.insert(sim.log, verb)
end

-- The fixture. One DM and 59 channels, all joined, so watchedIds truncates to
-- max_watched exactly as it does against the real workspace.
local FIXTURE_CONVERSATIONS = {}
do
  table.insert(FIXTURE_CONVERSATIONS,
    { id = "D0BJ07LUH0A", name = "alice", type = "im", joined = true, user = "UALICE" })
  for i = 1, 59 do
    table.insert(FIXTURE_CONVERSATIONS,
      { id = `C{i}`, name = `chan{i}`, type = "channel", joined = true })
  end
end

-- What every watched conversation last said. The driver moves these to make a
-- conversation "change"; while they sit still the sidebar must go quiet.
sim.latestTs = {}
for _, c in ipairs(FIXTURE_CONVERSATIONS) do sim.latestTs[c.id] = "1000.000100" end

sim.seenIds = {}

local function pollReply(idsCsv)
  local out = {}
  for id in idsCsv:gmatch("[^,]+") do
    sim.seenIds[id] = (sim.seenIds[id] or 0) + 1
    out[id] = {
      ok = true,
      error = "",
      unread = 0,
      mention = false,
      cursor = "",
      latest = { ts = sim.latestTs[id] or "1000.000100", author = "bob", text = "hi", mine = false },
      latestUnread = nil,
    }
  end
  return { ok = true, me = "UME", needsSignIn = false, rateLimited = false, conversations = out }
end

-- `history` honours the `since` argument the way the helper does: only messages
-- strictly newer than it. That is what makes "quiet conversation costs nothing"
-- observable here rather than assumed.
local function historyReply(channel, since)
  local newest = sim.latestTs[channel] or "1000.000100"
  if since ~= nil and since ~= "" then
    local fresh = {}
    if tonumber(newest) > tonumber(since) then
      table.insert(fresh, { ts = newest, author = "bob", text = "new", user = "UBOB" })
    end
    return { ok = true, incremental = true, messages = fresh, users = {}, readCursor = "" }
  end
  return {
    ok = true,
    messages = { { ts = newest, author = "bob", text = "hi", user = "UBOB" } },
    users = {},
    hasMore = false,
    readCursor = "",
  }
end

-- The agent command is a shell string; split it back into the argv the service
-- built, undoing shellQuote.
local function argv(command)
  local parts = {}
  for piece in command:gmatch("'([^']*)'") do table.insert(parts, piece) end
  return parts
end

local function replyFor(command)
  local args = argv(command)
  -- args[1] is the agent path; the flags the service adds are quoted too.
  local verb, rest = "", {}
  for i = 2, #args do
    local a = args[i]
    if verb == "" then
      if a ~= "--token" and a ~= "--me" and a ~= "--no-archive" and a ~= "bot" and a ~= "user" and a ~= "auto" then
        verb = a
      end
    else
      table.insert(rest, a)
    end
  end
  record(verb)

  if verb == "me" then
    return { ok = true, userId = "UME", user = "me", team = "T", teamId = "T1", url = "https://x/", tokenKind = "user" }
  elseif verb == "list" then
    return { ok = true, conversations = FIXTURE_CONVERSATIONS }
  elseif verb == "poll" then
    return pollReply(rest[1] or "")
  elseif verb == "history" then
    return historyReply(rest[1] or "", rest[3])
  elseif verb == "avatars" then
    return { ok = true, avatars = {} }
  elseif verb == "sync-read" then
    return { ok = true, cursors = {} }
  end
  return { ok = true }
end

-- ── the host stub ────────────────────────────────────────────────────────────

local state = {}

noctalia = {
  pluginDir = function() return "/tmp/slack-sim" end,
  pluginDataDir = function() return "/tmp/slack-sim/data" end,
  nowMs = function() return sim.now end,
  log = function() end,
  notify = function() end,
  -- Nothing configured: every cfgInt/cfgBool falls through to the default in
  -- service.luau, which is the point - the simulation measures the shipped
  -- defaults.
  getConfig = function() return nil end,
  tr = function(key) return key end,
  formatTime = function() return "00:00" end,
  readFile = function() return "" end,
  writeFile = function() end,
  fileExists = function() return false end,
  mkdirAll = function() end,
  download = function() end,
  setUpdateInterval = function() end,
  string = {
    trim = function(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end,
  },
  state = {
    set = function(key, value) state[key] = value end,
    get = function(key) return state[key] end,
    -- Keep the command handler: the driver posts intents through it, the same
    -- way the panel does.
    watch = function(key, fn)
      if key == "slack_command" then postCommand = fn end
    end,
  },
  json = {
    -- No JSON here: runAsync hands back a token and this returns the table it
    -- stands for. A parser would be a second thing to get wrong.
    decode = function(token) return sim.replies[token] end,
    encode = function() return "[]" end,
  },
  runAsync = function(command, callback)
    -- The startup probe is `test -x '<agent>' && '<agent>' credentials`.
    if command:find("credentials", 1, true) then
      record("credentials")
      callback({ exitCode = 0, stdout = "", stderr = "" })
      return true
    end
    if command:find("xdg%-open") then return true end

    sim.nextToken += 1
    local token = `tok{sim.nextToken}`
    sim.replies[token] = replyFor(command)
    local deliver = function() callback({ exitCode = 0, stdout = token, stderr = "" }) end
    if sim.autoDeliver then deliver() else table.insert(sim.pending, deliver) end
    return true
  end,
}

sim.flush = function()
  local queued = sim.pending
  sim.pending = {}
  for _, deliver in ipairs(queued) do deliver() end
end
