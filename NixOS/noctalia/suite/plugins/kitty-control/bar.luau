--!nonstrict
-- Kitty Control Panel bar widget
-- Displays terminal icon and toggles the Kitty control panel on click.

local function render()
  local glyph = ui.glyph({ name = "terminal-2", size = 18 })
  barWidget.setTooltip("Kitty Control Panel")
  barWidget.render(ui.row({ gap = 4, align = "center" }, { glyph }))
end

function onClick()
  noctalia.togglePanel("community/kitty-control:panel")
end

render()
