--!nonstrict
-- The always-on cup (modules/always-on-umbriel.nix). A plugin rather than a
-- custom button: a custom button's glyph is config, and every change of that
-- config rebuilt the button, so it vanished and came back on each click. Here
-- the glyph and tooltip change in place, like the Caffeine button's.
local DROPIN = "/run/systemd/logind.conf.d/50-always-on.conf"
local TOGGLE = "/run/current-system/sw/bin/always-on-toggle"
local STATUS = "/run/current-system/sw/bin/always-on-status-watch"

local on = noctalia.fileExists(DROPIN)

local function render()
  if on then
    barWidget.setGlyph("infinity")
    barWidget.setTooltip("Always-on mode: ON (power key, lid and suspend ignored; click to turn off)")
  else
    barWidget.setGlyph("coffee")
    barWidget.setTooltip("Always-on mode: off (click to keep the machine up for remote sessions)")
  end
end

local function toggle()
  -- The new state shows at once; once the switch has run, the drop-in says
  -- what really happened (and the status stream confirms it too).
  on = not on
  render()
  -- (60 s, the most allowed: the 5 s default could cut a slow sudo short mid-switch)
  noctalia.runAsync({ TOGGLE }, function()
    on = noctalia.fileExists(DROPIN)
    render()
  end, 60000)
end

function onClick()
  toggle()
end

function onRightClick()
  toggle()
end

-- The bar-pins menu runs the old right click as `noctalia msg plugin <this>:bar all right-click`.
function onIpc(event, _payload)
  if event == "right-click" then
    onRightClick()
  end
end

function onConfigChanged()
  render()
end

render()

-- {"on": true|false} at start and on every change of the mode, so
-- `always-on on` typed in a terminal shows here too.
if noctalia.fileExists(STATUS) then
  noctalia.runStream(STATUS, function(line)
    local data = noctalia.json.decode(line)
    if type(data) == "table" then
      on = data.on == true
      render()
    end
  end)
end
