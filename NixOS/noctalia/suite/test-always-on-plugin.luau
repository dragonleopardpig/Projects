-- The always-on cup plugin (plugins/always-on/bar.luau) run with stand-ins for the bar and
-- the host. The Luau CLI reads no files, so default.nix splices the plugin in at the marker.
-- Asked 2026-11-20: the cup vanished and came back on each click; it must change in place.
local dropin = false
local glyphs, tips, pending, streamed = {}, {}, nil, nil
barWidget = {
  setGlyph = function(g) table.insert(glyphs, g) end,
  setTooltip = function(t) table.insert(tips, t) end,
}
noctalia = {
  fileExists = function(p)
    if string.find(p, "50%-always%-on%.conf") then return dropin end
    return true
  end,
  runAsync = function(argv, cb, timeout)
    assert(argv[1] == "/run/current-system/sw/bin/always-on-toggle", argv[1])
    assert(timeout == 60000, "timeout " .. tostring(timeout))
    pending = cb
    return true
  end,
  runStream = function(cmd, cb) streamed = cb; return true end,
  json = { decode = function(line) return { on = string.find(line, "true") ~= nil } end },
}
--@PLUGIN@

-- off at start: a cup
assert(glyphs[#glyphs] == "coffee", "start " .. glyphs[#glyphs])
-- CLICK: the infinity shows before the toggle has even run
onClick()
assert(glyphs[#glyphs] == "infinity", "after click " .. glyphs[#glyphs])
assert(string.find(tips[#tips], "ON"), tips[#tips])
-- the toggle finished and the drop-in is there: still infinity
dropin = true; pending()
assert(glyphs[#glyphs] == "infinity", "confirmed " .. glyphs[#glyphs])
-- RIGHT click turns it off at once
onRightClick()
assert(glyphs[#glyphs] == "coffee", "right click " .. glyphs[#glyphs])
-- ...but the switch failed (drop-in still there): put back to infinity
pending()
assert(glyphs[#glyphs] == "infinity", "failed switch " .. glyphs[#glyphs])
-- a terminal `always-on off` arrives through the stream
dropin = false; streamed('{"on": false}')
assert(glyphs[#glyphs] == "coffee", "stream " .. glyphs[#glyphs])
print("click test OK: " .. table.concat(glyphs, " -> "))
