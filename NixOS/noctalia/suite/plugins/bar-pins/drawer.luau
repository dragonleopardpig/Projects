--!nonstrict
-- The drawer: every unpinned icon, with Open (its left-click action) and Pin.

local common = require("./common.luau")

local isOpen = false
local render

local function pin(name: string)
  common.setPinned(name, true, function()
    if #common.unpinned() == 0 then
      -- The last one is back: the drawer button hides, so the drawer goes too.
      panel.close()
    else
      render()
    end
  end)
end

local function itemRow(name: string)
  local info = common.info(name)
  local children = {
    ui.glyph({ name = info.glyph, size = 16, color = common.color(name) }),
    ui.label({ text = info.label, fontSize = 13, color = "on_surface", flexGrow = 1 }),
  }
  if info.open ~= nil then
    table.insert(children, ui.button({
      key = "open_" .. name,
      text = "Open",
      glyph = "external-link",
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        panel.close()
        common.run(info.open)
      end,
    }))
  end
  table.insert(children, ui.button({
    key = "pin_" .. name,
    text = "Pin",
    glyph = "pin",
    variant = "secondary",
    controlSize = "sm",
    tooltip = "Back on the bar",
    onClick = function()
      pin(name)
    end,
  }))
  return ui.row({ key = "row_" .. name, gap = 8, align = "center" }, children)
end

render = function()
  local hidden = common.unpinned()
  local rows = {
    ui.row({ key = "drawer_head", gap = 6, align = "center" }, {
      ui.glyph({ name = "pinned-off", size = 18, color = common.color("bar-pins") }),
      ui.label({ text = "Unpinned icons", fontSize = 15, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({
        key = "btn_close",
        glyph = "x",
        controlSize = "sm",
        variant = "ghost",
        tooltip = "Close",
        onClick = function()
          panel.close()
        end,
      }),
    }),
  }
  if #hidden == 0 then
    table.insert(rows, ui.label({ key = "drawer_empty", text = "Every icon is on the bar.", fontSize = 12, color = "on_surface_variant" }))
  else
    for _, name in ipairs(hidden) do
      table.insert(rows, itemRow(name))
    end
    if #hidden > 1 then
      table.insert(rows, ui.button({
        key = "btn_pin_all",
        text = "Pin all",
        glyph = "pin",
        variant = "primary",
        controlSize = "sm",
        onClick = function()
          for _, name in ipairs(hidden) do
            pin(name)
          end
        end,
      }))
    end
  end
  table.insert(rows, ui.label({
    key = "drawer_hint",
    text = "Right click any icon on the bar for Unpin from bar.",
    fontSize = 11,
    color = "on_surface_variant",
  }))
  panel.render(ui.column({ key = "drawer", gap = 8, padding = 12 }, rows))
end

function onOpen(_context)
  isOpen = true
  render()
end

function onClose()
  isOpen = false
end

function onConfigChanged()
  if isOpen then
    render()
  end
end

render()
