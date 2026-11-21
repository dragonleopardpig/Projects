--!nonstrict
local current = { available = false, state = "idle", glyph = "cpu", text = "", tooltip = {} }
-- One colour whatever renders (the text names the GPU): the icon's own, from settings.nix.
local OWN_COLOR = ""

local function render()
  if current.available ~= true then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)
  local color = OWN_COLOR
  barWidget.setGlyph(current.glyph or "cpu")
  barWidget.setText(current.text or "GPU")
  barWidget.setColor(color)
  barWidget.setGlyphColor(color)
  if type(current.tooltip) == "table" and #current.tooltip > 0 then
    barWidget.setTooltip(current.tooltip)
  else
    barWidget.setTooltip("Active GPU & Monitors")
  end
end

function onClick()
  noctalia.togglePanel("prponkshe/umbriel-displays:panel")
end

function onRightClick()
  noctalia.togglePanel("prponkshe/umbriel-displays:arrange")
end

function onConfigChanged()
  render()
end

render()

local command = nil
if noctalia.commandExists("noctalia-gpu-status") then
  command = "noctalia-gpu-status watch"
else
  local fallback = noctalia.expandPath("~/.local/bin/noctalia-gpu-status")
  if noctalia.fileExists(fallback) then
    command = "'" .. string.gsub(fallback, "'", "'\\''") .. "' watch"
  end
end

if command ~= nil then
  noctalia.runStream(command, function(line)
    local data = noctalia.json.decode(line)
    if type(data) == "table" then
      current = data
      render()
    end
  end)
end
