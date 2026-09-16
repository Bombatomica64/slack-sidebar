--!nonstrict
-- Driver half of the service.luau request-rate simulation. Appended after
-- service.luau, so `update` and the published state are in scope. See
-- service_sim.luau for the host stub and the fixture.
--
-- The numbers below are Slack *requests*, not agent invocations: one `poll` run
-- costs one request per conversation in its batch, which is the whole reason
-- the regression existed.

local sim = sim
local failures, checks = 0, 0

local function expect(cond, what)
  checks += 1
  if cond then return end
  failures += 1
  print(`FAIL {what}`)
end

local function expect_between(got, lo, hi, what)
  checks += 1
  if got >= lo and got <= hi then return end
  failures += 1
  print(`FAIL {what}: got {got}, wanted {lo}..{hi}`)
end

local function count(verb) return sim.calls[verb] or 0 end

local function resetCounts()
  sim.calls = {}
  sim.log = {}
  sim.seenIds = {}
  sim.requests = 0
end

-- One simulated second per tick: what noctalia.setUpdateInterval(1000) asks for.
local function runSeconds(seconds)
  for _ = 1, seconds do
    sim.now += 1000
    update()
  end
end

-- Slack requests spent, counted the way Slack counts them.
local function requestsSpent()
  local spent = count("history") + count("list") + count("avatars") + count("me")
  for id, times in pairs(sim.seenIds) do spent += times end     -- poll: one per id
  spent += count("sync-read") * 12                              -- one conversations.info per id
  return spent
end

-- ── settle ───────────────────────────────────────────────────────────────────

runSeconds(60)
local status = noctalia.state.get("slack_status")
expect(status ~= nil and status.ready == true, "sim: the service comes up ready")
expect(#status.conversations == 60, "sim: the fixture's conversations are published")

-- ── an open, idle conversation ───────────────────────────────────────────────
--
-- The regression's exact shape: a conversation is open and nobody is talking.
-- Before the fix this cost, every six seconds, one `poll` over all 48 watched
-- conversations plus one full 60-message `history` - 10 * (48 + 1) = 490 Slack
-- requests a minute, against a tier limit of about 50.

expect(postCommand ~= nil, "sim: the service registered a command handler")
postCommand({ action = "open", id = "D0BJ07LUH0A" })
runSeconds(10)
resetCounts()
runSeconds(300)

local idleRequests = requestsSpent()
print(`idle, conversation open, 5 minutes: {count("poll")} poll runs, `
  .. `{count("history")} history, {count("sync-read")} sync-read`)
print(`-> {string.format("%.1f", idleRequests / 5)} Slack requests/minute`)

-- The headline. Anything near the old 490/min is a regression; the ceiling here
-- is deliberately loose enough not to break on a one-tick scheduling shift and
-- tight enough that losing the incremental fetch or the rotating batch fails it.
expect(idleRequests / 5 < 50,
  "sim: an idle open conversation stays under Slack's per-minute tier limit")

-- A quiet conversation re-reads its transcript only on the slow full refresh
-- (5 minutes / 180s = at most two).
expect_between(count("history"), 0, 2,
  "sim: an idle open conversation does not re-read the transcript on the fast tick")

-- The open conversation is still polled every active_poll_interval; it is the
-- other 47 that stopped riding along. 300s / 6s = 50, plus ~7 batch polls.
expect_between(count("poll"), 50, 60,
  "sim: the open conversation keeps its fast cadence")
expect(sim.seenIds["D0BJ07LUH0A"] >= 50, "sim: and it is in every one of those polls")

-- ── nothing is starved by the rotation ───────────────────────────────────────
--
-- Rotating is only acceptable if every watched conversation is still reached.
-- max_watched 48 / poll_batch 12 = four batch polls per sweep, so five minutes
-- of 45-second ticks is more than one full sweep.
local reached = 0
for _ in pairs(sim.seenIds) do reached += 1 end
expect(reached >= 48, `sim: every watched conversation is still swept (reached {reached})`)

-- ── a conversation that actually moves ───────────────────────────────────────

resetCounts()
sim.latestTs["D0BJ07LUH0A"] = "2000.000100"
runSeconds(30)

expect(count("history") >= 1, "sim: a new message is fetched")
expect_between(count("history"), 1, 2, "sim: and fetched once, not once per tick")

local active = noctalia.state.get("slack_active")
expect(active ~= nil and #active.messages >= 1, "sim: the new message reaches the panel")
expect(active.messages[1].ts == "2000.000100", "sim: and it is on top")
expect(#active.messages >= 2, "sim: spliced onto the messages already held, not replacing them")

-- Quiet again: back to no transcript reads.
resetCounts()
runSeconds(120)
expect_between(count("history"), 0, 1, "sim: the conversation goes quiet and so does the fetching")

-- The luau CLI sandbox has no os.exit; an uncaught error is how this run fails.
if failures ~= 0 then
  error(`{failures} of {checks} checks failed`, 0)
end
print(`{checks} checks passed`)
