--!nonstrict
-- The right-click menu of a bar icon: its old right-click action first (if it had one),
-- then Unpin from bar.  Opened as `panel-toggle local/bar-pins:menu <icon>`.

local common = require("./common.luau")

local target = nil

local function render()
  if target == nil then
    panel.render(ui.column({ key = "menu_empty" }, {}))
    return
  end
  local name = target
  local info = common.info(name)
  local items = {
    ui.row({ key = "menu_head", gap = 8, align = "center" }, {
      ui.glyph({ name = info.glyph, size = 16, color = common.color(name) }),
      ui.label({ text = info.label, fontSize = 13, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
    }),
  }
  if info.right ~= nil then
    table.insert(items, ui.button({
      key = "btn_action",
      text = info.right.label,
      glyph = info.right.glyph,
      variant = "ghost",
      controlSize = "sm",
      flexGrow = 1,
      onClick = function()
        panel.close()
        common.run(info.right)
      end,
    }))
  end
  table.insert(items, ui.button({
    key = "btn_unpin",
    text = "Unpin from bar",
    glyph = "pinned-off",
    variant = "ghost",
    controlSize = "sm",
    flexGrow = 1,
    tooltip = "It moves into the drawer button; pin it back from there",
    onClick = function()
      panel.close()
      common.setPinned(name, false)
    end,
  }))
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

render()
