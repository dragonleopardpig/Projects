--!nonstrict
-- Keep swaync as the single notification daemon. Its watch output is the
-- same stream consumed by the existing AGS notification widget.
barWidget.setGlyph("bell")
barWidget.setText("0")
barWidget.setTooltip("Notifications")

noctalia.runStream("swaync-client -swb", function(line)
  local state = noctalia.json.decode(line)
  if type(state) ~= "table" then return end
  local classes = state.class or ""
  if type(classes) ~= "string" then classes = "" end
  if string.find(classes, "dnd", 1, true) then
    barWidget.setGlyph("bell-off")
  elseif string.find(classes, "inhibited", 1, true) then
    barWidget.setGlyph("bell-x")
  else
    barWidget.setGlyph("bell")
  end
  barWidget.setText(tostring(tonumber(state.text) or 0))
  barWidget.setTooltip(state.tooltip or "Notifications")
end)

function onClick()
  noctalia.runAsync("swaync-client -t -sw")
end

function onRightClick()
  noctalia.runAsync("swaync-client -d -sw")
end
