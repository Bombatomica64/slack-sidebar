--!nonstrict
-- Slack sidebar panel. Master/detail in one column, because 500px of sidebar
-- has no room for two panes: the conversation list, then the transcript of the
-- one you picked, then a thread if you open one.
--
-- The panel owns no subprocess. It reads `slack_status` / `slack_active` and
-- posts intents to `slack_command`; the service does the rest.

local status = noctalia.state.get("slack_status") or {
  ready = false, connected = false, conversations = {}, totalUnread = 0, error = "",
}
local active = noctalia.state.get("slack_active") or {
  id = "", name = "", messages = {}, threadMessages = {}, threadTs = "",
}

local search = ""
local draft = ""
local draftGeneration = 0
local requestCounter = 0
local dirty = true
local lastActiveRevision = -1

local render

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function send(action, values)
  requestCounter += 1
  local command = { action = action, requestId = `panel-{requestCounter}` }
  if type(values) == "table" then
    for key, value in pairs(values) do command[key] = value end
  end
  noctalia.state.set("slack_command", command)
end

-- ── conversation list ────────────────────────────────────────────────────────

-- A row, not a button: ui.button has no image support, and ui.row takes onClick
-- (a real click target that joins the tab order) plus fill/radius/border, which
-- is what carries the selected / unread distinction the buttons used to.
local function avatarTile(c)
  local avatar = tostring(c.avatar or "")
  if avatar ~= "" then
    return ui.image({
      key = `av-{c.id}`,
      path = avatar,
      width = 32,
      height = 32,
      radius = 16,
      fit = "cover",
    })
  end
  -- ui.box is a leaf and silently drops children, so the fallback tile is a row.
  local glyph = (c.type == "im" or c.type == "mpim") and "user" or "hash"
  return ui.row({
    key = `av-{c.id}`,
    width = 32,
    height = 32,
    radius = 16,
    fill = "surface_variant",
    align = "center",
    justify = "center",
  }, {
    ui.glyph({ name = glyph, size = 16, color = "on_surface_variant" }),
  })
end

local function unreadBadge(c)
  local unread = tonumber(c.unread) or 0
  if unread <= 0 and not c.mention then return nil end
  local tint = c.mention and "error" or "primary"
  if unread <= 0 then
    return ui.box({ width = 9, height = 9, radius = 5, fill = tint })
  end
  return ui.row({
    radius = 9,
    fill = tint,
    paddingH = 6,
    paddingV = 1,
    minWidth = 20,
    minHeight = 18,
    align = "center",
    justify = "center",
  }, {
    ui.label({
      text = unread > 99 and "99+" or tostring(unread),
      fontSize = 11,
      fontWeight = "bold",
      color = c.mention and "on_error" or "on_primary",
    }),
  })
end

local function conversationList()
  local needle = noctalia.string.trim(search):lower()
  local rows = {}
  for _, c in ipairs(status.conversations or {}) do
    local name = tostring(c.name or c.id)
    if needle == "" or name:lower():find(needle, 1, true) ~= nil then
      local prefix = (c.type == "im" or c.type == "mpim") and "@" or "#"
      local unread = tonumber(c.unread) or 0
      local selected = c.id == active.id
      local highlighted = unread > 0 or c.mention == true

      local fill, border = nil, nil
      if selected then
        fill = "primary/0.22"
        border = "primary"
      elseif c.mention then
        border = "error"
      elseif unread > 0 then
        fill = "surface_variant/0.55"
        border = "outline"
      end

      local title = { ui.label({
        text = `{prefix}{name}`,
        fontSize = 13,
        fontWeight = highlighted and "bold" or "medium",
        color = c.mention and "error" or "on_surface",
        maxLines = 1,
        flexGrow = 1,
      }) }
      if c.pinned then
        table.insert(title, ui.glyph({ name = "pin", size = 12, color = "on_surface_variant" }))
      end

      local column = {
        ui.row({ gap = 4, align = "center" }, title),
      }
      local subtitle = tostring(c.latestText or "")
      if subtitle ~= "" then
        table.insert(column, ui.label({
          text = subtitle,
          fontSize = 11,
          color = "on_surface_variant",
          maxLines = 1,
          opacity = c.joined == false and 0.7 or 1,
        }))
      end

      local children = {
        avatarTile(c),
        ui.column({ gap = 1, flexGrow = 1 }, column),
      }
      local badge = unreadBadge(c)
      if badge then table.insert(children, badge) end

      table.insert(rows, ui.row({
        key = `conv-{c.id}`,
        gap = 9,
        align = "center",
        paddingH = 8,
        paddingV = 6,
        radius = 10,
        fill = fill,
        border = border,
        borderWidth = border and 1 or nil,
        onClick = function()
          draft = ""
          draftGeneration += 1
          send("open", { id = c.id })
          dirty = true
          render()
        end,
      }, children))
    end
  end
  if #rows == 0 then
    table.insert(rows, ui.label({ text = tr("panel.no_conversations"), color = "on_surface_variant" }))
  end
  return rows
end

local function listView()
  return ui.column({ flexGrow = 1, gap = 8 }, {
    ui.input({
      key = "conv-search",
      value = search,
      placeholder = tr("panel.search_placeholder"),
      onChange = "onSearchChange",
    }),
    ui.scroll({ key = "conv-scroll", flexGrow = 1, gap = 4, align = "stretch" }, conversationList()),
  })
end

-- ── messages ─────────────────────────────────────────────────────────────────

local function reactionRow(message)
  local buttons = {}
  for _, r in ipairs(message.reactions or {}) do
    local name = tostring(r.name or "")
    local mine = r.mine == true
    table.insert(buttons, ui.button({
      key = `react-{message.ts}-{name}`,
      text = `:{name}: {r.count}`,
      variant = mine and "primary" or "ghost",
      onClick = function()
        send("react", { ts = message.ts, name = name, mine = mine })
      end,
    }))
  end
  table.insert(buttons, ui.button({
    key = `react-add-{message.ts}`,
    glyph = "thumb-up",
    variant = "ghost",
    onClick = function()
      send("react", { ts = message.ts, name = "thumbsup", mine = false })
    end,
  }))
  if (message.replyCount or 0) > 0 and active.threadTs == "" then
    table.insert(buttons, ui.button({
      key = `thread-{message.ts}`,
      text = tr("panel.replies", { count = message.replyCount }),
      glyph = "message-circle",
      variant = "outline",
      onClick = function()
        send("open_thread", { ts = message.ts })
      end,
    }))
  end
  return ui.row({ gap = 4, align = "center" }, buttons)
end

-- Link unfurls, ported from v4's LinkCard: a bordered block with the site, the
-- title and the flattened description.
local function attachmentCard(message, index, attachment)
  local lines = {}
  local site = tostring(attachment.site or "")
  if site ~= "" then
    table.insert(lines, ui.label({ text = site, fontSize = 10, color = "on_surface_variant" }))
  end
  local title = tostring(attachment.title or "")
  if title ~= "" then
    table.insert(lines, ui.label({ text = title, fontSize = 12, fontWeight = "bold", maxLines = 2 }))
  end
  local body = tostring(attachment.text or "")
  if body ~= "" then
    table.insert(lines, ui.label({ text = body, fontSize = 11, color = "on_surface_variant", maxLines = 3 }))
  end
  return ui.column({
    key = `att-{message.ts}-{index}`,
    gap = 2,
    paddingH = 8,
    paddingV = 6,
    radius = 8,
    fill = "surface_variant/0.4",
    border = "outline",
    borderWidth = 1,
  }, lines)
end

local function messageBlock(message)
  local header = {
    ui.label({
      text = tostring(message.author or ""),
      fontWeight = "bold",
      color = message.mine and "primary" or "on_surface",
      fontSize = 12,
    }),
    ui.label({ text = tostring(message.time or ""), color = "on_surface_variant", fontSize = 11 }),
  }
  if message.edited then
    table.insert(header, ui.label({ text = tr("panel.edited"), color = "on_surface_variant", fontSize = 11 }))
  end
  table.insert(header, ui.spacer({ flexGrow = 1 }))

  local body = {}
  local text = tostring(message.text or "")
  if text ~= "" then
    table.insert(body, ui.label({ text = text, color = "on_surface" }))
  end
  for index, attachment in ipairs(message.attachments or {}) do
    table.insert(body, attachmentCard(message, index, attachment))
  end
  for index, name in ipairs(message.files or {}) do
    table.insert(body, ui.row({ key = `file-{message.ts}-{index}`, gap = 5, align = "center" }, {
      ui.glyph({ name = "paperclip", size = 13, color = "on_surface_variant" }),
      ui.label({ text = tostring(name), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }))
  end
  if #body == 0 then
    table.insert(body, ui.label({ text = tr("panel.no_text"), color = "on_surface_variant", fontSize = 11 }))
  end
  if #(message.reactions or {}) > 0 or (message.replyCount or 0) > 0 then
    table.insert(body, reactionRow(message))
  end

  local avatar = tostring(message.avatar or "")
  local gutter = avatar ~= ""
    and ui.image({ path = avatar, width = 24, height = 24, radius = 12, fit = "cover" })
    or ui.row({ width = 24, height = 24, radius = 12, fill = "surface_variant" }, {})

  return ui.row({ key = `msg-{message.ts}`, gap = 8, align = "start" }, {
    gutter,
    ui.column({ gap = 3, flexGrow = 1 }, {
      ui.row({ gap = 6, align = "center" }, header),
      ui.column({ gap = 4 }, body),
    }),
  })
end

-- Newest first. The declarative scroll has no "pin to bottom", so the message
-- you actually want to read is put where it is guaranteed to be visible.
local function messageRows(messages)
  local rows = {}
  for _, message in ipairs(messages or {}) do
    table.insert(rows, messageBlock(message))
    table.insert(rows, ui.separator({ opacity = 0.18 }))
  end
  if #rows == 0 then
    table.insert(rows, ui.label({ text = tr("panel.no_messages"), color = "on_surface_variant" }))
  end
  return rows
end

local function composer()
  local placeholder = active.threadTs ~= ""
    and tr("panel.reply_placeholder")
    or tr("panel.message_placeholder", { name = tostring(active.name or "") })
  return ui.row({ gap = 6, align = "center" }, {
    ui.input({
      key = `composer-{active.id}-{draftGeneration}`,
      value = draft,
      placeholder = placeholder,
      flexGrow = 1,
      onChange = "onDraftChange",
    }),
    ui.button({
      glyph = "send",
      variant = "primary",
      enabled = noctalia.string.trim(draft) ~= "" and active.sending ~= true,
      onClick = function()
        local text = noctalia.string.trim(draft)
        if text == "" then return end
        send("send", { text = text })
        draft = ""
        draftGeneration += 1
        render()
      end,
    }),
  })
end

local function conversationHeader()
  local conv = nil
  for _, c in ipairs(status.conversations or {}) do
    if c.id == active.id then conv = c end
  end
  return ui.row({ gap = 4, align = "center" }, {
    ui.button({
      glyph = "chevron-left",
      variant = "ghost",
      onClick = function()
        send("close")
        render()
      end,
    }),
    ui.label({
      text = tostring(active.name or ""),
      fontWeight = "bold",
      fontSize = 15,
      flexGrow = 1,
    }),
    ui.button({
      glyph = conv and conv.pinned and "pinned-off" or "pin",
      variant = "ghost",
      onClick = function()
        send("toggle_pin", { id = active.id })
      end,
    }),
    ui.button({
      glyph = "checks",
      variant = "ghost",
      onClick = function()
        send("mark_read")
      end,
    }),
    ui.button({
      glyph = "external-link",
      variant = "ghost",
      onClick = function()
        send("open_external", { id = active.id })
      end,
    }),
  })
end

local function threadView()
  return ui.column({ flexGrow = 1, gap = 6 }, {
    ui.row({ gap = 4, align = "center" }, {
      ui.button({
        glyph = "chevron-left",
        variant = "ghost",
        onClick = function()
          send("close_thread")
          render()
        end,
      }),
      ui.label({ text = tr("panel.thread"), fontWeight = "bold", fontSize = 15, flexGrow = 1 }),
    }),
    ui.scroll({ key = "thread-scroll", flexGrow = 1, gap = 6, align = "stretch" },
      messageRows(active.threadMessages)),
    composer(),
  })
end

local function conversationView()
  local rows = messageRows(active.messages)
  if active.hasMore == true then
    table.insert(rows, ui.button({
      key = "load-older",
      text = tr("panel.load_older"),
      variant = "outline",
      enabled = active.loading ~= true,
      onClick = function()
        send("load_older")
      end,
    }))
  end
  local children = { conversationHeader() }
  if active.joined == false then
    table.insert(children, ui.button({
      text = tr("panel.join"),
      glyph = "door-enter",
      variant = "primary",
      onClick = function()
        send("join", { id = active.id })
      end,
    }))
  end
  table.insert(children, ui.scroll({ key = `msg-scroll-{active.id}`, flexGrow = 1, gap = 6, align = "stretch" }, rows))
  if noctalia.string.trim(tostring(active.sendError or "")) ~= "" then
    table.insert(children, ui.label({ text = tostring(active.sendError), color = "error", maxLines = 2 }))
  end
  table.insert(children, composer())
  return ui.column({ flexGrow = 1, gap = 6 }, children)
end

-- ── root ─────────────────────────────────────────────────────────────────────

render = function()
  dirty = false
  local header = ui.row({ gap = 6, align = "center" }, {
    ui.glyph({
      name = "brand-slack",
      size = 22,
      color = status.connected and "primary" or "on_surface_variant",
    }),
    ui.label({ text = tr("title"), fontSize = 17, fontWeight = "bold" }),
    ui.label({
      text = status.connected
        and tr("panel.account", { user = tostring(status.meName or ""), team = tostring(status.team or "") })
        or tr("panel.disconnected"),
      color = "on_surface_variant",
      fontSize = 11,
      flexGrow = 1,
      maxLines = 1,
    }),
    ui.button({ glyph = "refresh", variant = "ghost", onClick = function() send("refresh") end }),
    ui.button({ glyph = "close", variant = "ghost", onClick = function() panel.close() end }),
  })

  local children = { header }
  if noctalia.string.trim(tostring(status.error or "")) ~= "" then
    table.insert(children, ui.label({ text = tostring(status.error), color = "error", maxLines = 3 }))
  end
  if status.ready ~= true then
    table.insert(children, ui.label({ text = tr("panel.starting"), color = "on_surface_variant" }))
  end

  if active.id ~= "" and active.threadTs ~= "" then
    table.insert(children, threadView())
  elseif active.id ~= "" then
    table.insert(children, conversationView())
  else
    table.insert(children, listView())
  end

  panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 10 }, children))
end

noctalia.state.watch("slack_status", function(value)
  if type(value) == "table" then
    status = value
    dirty = true
  end
end)

noctalia.state.watch("slack_active", function(value)
  if type(value) == "table" then
    active = value
    if active.revision ~= lastActiveRevision then
      lastActiveRevision = active.revision
      dirty = true
    end
  end
end)

panel.setWantsSecondTicks(true)

function onOpen(_context)
  send("refresh")
  render()
end

function update()
  if dirty then render() end
end

function onSearchChange(value)
  search = tostring(value or "")
  dirty = true
end

function onDraftChange(value)
  draft = tostring(value or "")
end
