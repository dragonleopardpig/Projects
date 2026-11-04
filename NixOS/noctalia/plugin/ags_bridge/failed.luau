--!nonstrict
-- The AGS bar counts failed systemd units and hides the indicator at zero.
barWidget.setGlyph("alert-triangle")
barWidget.setVisible(false)
noctalia.setUpdateInterval(10000)

function update()
  noctalia.runAsync("systemctl --failed --no-legend --plain", function(result)
    local count = 0
    if result.exitCode == 0 then
      for _ in string.gmatch(result.stdout, "[^\n]+") do
        count = count + 1
      end
    end
    barWidget.setVisible(count > 0)
    barWidget.setText(tostring(count))
    barWidget.setTooltip(tostring(count) .. " failed systemd units")
  end)
end

update()
