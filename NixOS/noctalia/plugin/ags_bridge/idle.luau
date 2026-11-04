--!nonstrict
-- Match AGS's two independent controls: left toggles hypridle, right toggles
-- the system's always-on mode for remote sessions.
local idleRunning = true
local alwaysOn = false
barWidget.setGlyph("moon")
noctalia.setUpdateInterval(5000)

local function repaint()
  if alwaysOn then
    barWidget.setText("∞")
  else
    barWidget.setText("")
  end
  barWidget.setGlyph(idleRunning and "moon" or "coffee")
  barWidget.setTooltip((idleRunning and "Idle/lock active — click to inhibit" or "Idle inhibited — click to resume") ..
    "\n" .. (alwaysOn and "Always-on ON — right-click for office mode" or "Always-on OFF — right-click to keep host up"))
end

function update()
  noctalia.runAsync("systemctl --user is-active hypridle.service", function(result)
    idleRunning = result.exitCode == 0 and string.find(result.stdout, "active", 1, true) ~= nil
    repaint()
  end)
  noctalia.runAsync("test -e /run/systemd/logind.conf.d/50-always-on.conf", function(result)
    alwaysOn = result.exitCode == 0
    repaint()
  end)
end

function onClick()
  noctalia.runAsync("systemctl --user " .. (idleRunning and "stop" or "start") .. " hypridle.service", function()
    update()
  end)
end

function onRightClick()
  noctalia.runAsync("/run/current-system/sw/bin/always-on " .. (alwaysOn and "off" or "on"), function()
    update()
  end)
end

update()
