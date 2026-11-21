--!nonstrict
-- Top bar backup icon: glyph and colour per state, the percentage while it runs.
-- Hidden where no backup is set up (no `backup-pool` helper, or it says unavailable).

local common = require("./common.luau")

local current = noctalia.state.get("snapshot") or common.DEFAULT_SNAPSHOT

local function render()
  if current.available == false or common.helperArgv({}) == nil then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)
  local state = current.state or "ok"
  barWidget.setGlyph(common.barGlyph(state))
  barWidget.setGlyphColor(common.stateColor(state))
  if state == "running" and type(current.percent) == "number" then
    barWidget.setText(string.format("%d%%", math.floor(current.percent)))
    barWidget.setColor(common.stateColor(state))
  else
    barWidget.setText("")
  end
  if type(current.tooltip) == "table" and #current.tooltip > 0 then
    barWidget.setTooltip(current.tooltip)
  else
    barWidget.setTooltip(current.summary or "Backup")
  end
end

function onClick()
  noctalia.togglePanel(common.PANEL_ID)
end

-- Right click: back up now (when it can; it never stops a running backup).
function onRightClick()
  if current.can_run ~= true then
    noctalia.togglePanel(common.PANEL_ID)
    return
  end
  local argv = common.helperArgv({ "run" })
  if argv ~= nil then
    noctalia.runAsync(argv, function(res)
      local data = common.decode(res)
      if data ~= nil then
        noctalia.state.set("snapshot", data)
      end
    end)
  end
end

function onConfigChanged()
  render()
end

noctalia.state.watch("snapshot", function(value)
  if type(value) == "table" then
    current = value
    render()
  end
end)

render()

if noctalia.state.get("snapshot") == nil then
  local argv = common.helperArgv({ "status" })
  if argv ~= nil then
    noctalia.runAsync(argv, function(res)
      local data = common.decode(res)
      if data ~= nil then
        current = data
        noctalia.state.set("snapshot", data)
        render()
      end
    end)
  end
end
