--!nonstrict
barWidget.setGlyph("printer")
barWidget.setVisible(false)
noctalia.setUpdateInterval(5000)

function update()
  noctalia.runAsync("lpstat -o", function(result)
    local count = 0
    if result.exitCode == 0 then
      for _ in string.gmatch(result.stdout, "[^\n]+") do
        count = count + 1
      end
    end
    barWidget.setVisible(count > 0)
    barWidget.setText(tostring(count))
    barWidget.setTooltip(tostring(count) .. " print jobs — open AGS Printers & Scanners")
  end)
end

function onClick()
  noctalia.runAsync("ags toggle control-center")
end

update()
