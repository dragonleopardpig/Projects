--!nonstrict
-- The drawer button: shown only while some icon is unpinned, with how many.
-- Either click opens the drawer (its own right click is not bound to the menu).

local common = require("./common.luau")

local function render()
  local hidden = common.unpinned()
  if #hidden == 0 then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)
  barWidget.setGlyph("pinned-off")
  barWidget.setText(tostring(#hidden))
  local labels = {}
  for _, name in ipairs(hidden) do
    table.insert(labels, common.info(name).label)
  end
  barWidget.setTooltip({
    { key = "Unpinned", value = table.concat(labels, ", ") },
    { key = "Click", value = "open them or pin them back" },
    { key = "Right click an icon", value = "Unpin from bar" },
  })
end

function onClick()
  noctalia.togglePanel(common.DRAWER_ID)
end

function onRightClick()
  noctalia.togglePanel(common.DRAWER_ID)
end

function onConfigChanged()
  render()
end

render()
