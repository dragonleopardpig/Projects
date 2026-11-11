--!nonstrict
local current = { status = "idle", counts = {} }
local labels = { idle = "AI", working = "Working", waiting = "Waiting", done = "Done", error = "Error" }
local glyphs = { idle = "sparkles", working = "loader", waiting = "message-question", done = "circle-check", error = "alert-circle" }
local colors = { idle = "on_surface_variant", working = "primary", waiting = "tertiary", done = "secondary", error = "error" }

local function render()
  local state = labels[current.status] and current.status or "idle"
  local counts = current.counts or {}
  local tooltip = "Antigravity — " .. (state == "idle" and "Ready" or labels[state])
  if current.workspace and current.workspace ~= "" then
    tooltip ..= "\n" .. current.workspace
  end
  if (counts.working or 0) + (counts.waiting or 0) > 1 then
    tooltip ..= "\n" .. tostring(counts.working or 0) .. " working, " .. tostring(counts.waiting or 0) .. " waiting"
  end
  tooltip ..= "\nClick to show/hide agent · Super+C"
  barWidget.setTooltip(tooltip)
  barWidget.setGlyph(glyphs[state])
  barWidget.setText(labels[state])
  barWidget.setColor(colors[state])
  barWidget.setGlyphColor(colors[state])
end

function onClick()
  noctalia.runAsync({ "umbriel", "msg", "scratchpad-toggle:agent" })
end

function onConfigChanged()
  render()
end

render()
local executable = noctalia.expandPath("~/.local/bin/noctalia-agent-status")
local command = "'" .. string.gsub(executable, "'", "'\\''") .. "' watch"
noctalia.runStream(command, function(line)
  local data = noctalia.json.decode(line)
  if type(data) == "table" then
    current = data
    render()
  end
end)
