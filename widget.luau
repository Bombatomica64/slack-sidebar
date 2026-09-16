--!nonstrict
-- Bar widget: the Slack glyph, tinted when something is unread, plus the
-- unread count. Reads `slack_status` only; the service owns every subprocess.

-- A panel cannot move itself, so plugin.toml declares the same panel.luau twice
-- (right edge and left edge) and the `side` setting picks which id to toggle.
local function panelId()
  return noctalia.getConfig("side") == "left"
    and "lollo/slack:sidebar_left"
    or "lollo/slack:sidebar"
end

local status = noctalia.state.get("slack_status") or {
  ready = false,
  connected = false,
  totalUnread = 0,
  mentionCount = 0,
}
local requestId = 0

local function configString(key, fallback)
  local value = noctalia.getConfig(key)
  return type(value) == "string" and value or fallback
end

local function render()
  local unread = tonumber(status.totalUnread) or 0
  local mentions = tonumber(status.mentionCount) or 0
  local connected = status.connected == true
  local showCount = noctalia.getConfig("show_count") ~= false
  local unreadColor = configString("unread_color", "primary")
  local idleColor = configString("glyph_color", "on_surface")

  local tint = idleColor
  if not connected then
    tint = "on_surface_variant"
  elseif unread > 0 or mentions > 0 then
    tint = unreadColor
  end

  local children = {
    ui.glyph({ name = "brand-slack", size = 16, color = tint }),
  }
  if showCount and unread > 0 then
    table.insert(children, ui.label({
      text = unread > 99 and "99+" or tostring(unread),
      fontWeight = "bold",
      color = tint,
    }))
  end
  if mentions > 0 then
    table.insert(children, ui.box({ width = 7, height = 7, radius = 4, fill = "error" }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))

  if not connected then
    barWidget.setTooltip(noctalia.tr("widget.disconnected"))
  elseif unread > 0 then
    barWidget.setTooltip(noctalia.tr("widget.unread", { count = unread, mentions = mentions }))
  else
    barWidget.setTooltip(noctalia.tr("widget.idle", { team = tostring(status.team or "") }))
  end
end

noctalia.state.watch("slack_status", function(value)
  if type(value) == "table" then
    status = value
    render()
  end
end)

render()

function update()
  render()
end

function onClick()
  noctalia.togglePanel(panelId())
end

function onRightClick()
  requestId += 1
  noctalia.state.set("slack_command", { action = "refresh", requestId = `widget-{requestId}` })
  noctalia.notify(noctalia.tr("title"), noctalia.tr("widget.refresh_requested"))
end

function onMiddleClick()
  requestId += 1
  noctalia.state.set("slack_command", { action = "mark_read", requestId = `widget-{requestId}` })
end
