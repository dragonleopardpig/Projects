--!nonstrict
-- The right-click menu of a bar icon (`panel-toggle local/bar-pins:menu <icon>`).
-- On the bar: its old right-click action first (if it had one), then Unpin from bar.
-- In the tray drawer (unpinned): Pin to bar, after its old action when that action does not
-- need the icon itself (a plugin's own right click only runs while it is on the bar).

local common = require("./common.luau")

local target = nil

local function render()
  if target == nil then
    panel.render(ui.column({ key = "menu_empty" }, {}))
    return
  end
  local name = target
  local info = common.info(name)
  local pinned = common.isPinned(name)
  local items = {
    ui.row({ key = "menu_head", gap = 8, align = "center" }, {
      ui.glyph({ name = info.glyph, size = 16, color = common.color(name) }),
      ui.label({ text = info.label, fontSize = 13, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
    }),
  }
  local action = info.right
  if action ~= nil and (pinned or action.event == nil) then
    table.insert(items, ui.button({
      key = "btn_action",
      text = action.label,
      glyph = action.glyph,
      variant = "ghost",
      controlSize = "sm",
      flexGrow = 1,
      onClick = function()
        panel.close()
        common.run(action)
      end,
    }))
  end
  if pinned then
    table.insert(items, ui.button({
      key = "btn_unpin",
      text = "Unpin from bar",
      glyph = "pinned-off",
      variant = "ghost",
      controlSize = "sm",
      flexGrow = 1,
      tooltip = "It moves into the tray's down-arrow drawer; pin it back from there",
      onClick = function()
        panel.close()
        common.setPinned(name, false)
      end,
    }))
  else
    table.insert(items, ui.button({
      key = "btn_pin",
      text = "Pin to bar",
      glyph = "pin",
      variant = "ghost",
      controlSize = "sm",
      flexGrow = 1,
      onClick = function()
        panel.close()
        common.setPinned(name, true)
      end,
    }))
  end
  panel.render(ui.column({ key = "menu", gap = 4, padding = 8 }, items))
end

function onOpen(context)
  local name = noctalia.string.trim(context or "")
  target = name ~= "" and name or nil
  render()
end

function onClose()
  target = nil
end

function onConfigChanged()
  if target ~= nil then
    render()
  end
end

render()
