--!nonstrict
-- Top bar rclone status icon matching the active Noctalia theme.

local common = require("./common.luau")

local current = noctalia.state.get("snapshot") or common.DEFAULT_SNAPSHOT

local function render()
  local state = current.state or "ready"
  barWidget.setGlyph(common.barGlyph(state))
  barWidget.setGlyphColor(common.stateColor(state))
  if type(current.tooltip) == "table" and #current.tooltip > 0 then
    barWidget.setTooltip(current.tooltip)
  else
    barWidget.setTooltip(current.summary or "Rclone Control")
  end
end

function onClick()
  noctalia.togglePanel(common.PANEL_ID)
end

function onRightClick()
  local argv = common.helperArgv({ "open-gui" })
  if argv ~= nil then
    noctalia.runAsync(argv)
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
      if res and res.exitCode == 0 and res.stdout and res.stdout ~= "" then
        local data = noctalia.json.decode(res.stdout)
        if type(data) == "table" then
          current = data
          noctalia.state.set("snapshot", data)
          render()
        end
      end
    end)
  end
end
