-- Test local/bar-pins entries (bar, menu, drawer) under Luau with host stand-ins.
-- The stand-in `noctalia msg config-set` changes the widget table, as Noctalia does.

local barGlyphs, barTexts, barTooltips, barVisible = {}, {}, {}, {}
local toggledPanels, panelTrees, panelClosed, launched = {}, {}, 0, {}

local WIDGETS = {
  launcher = { color = "#6BC5FF" },
  weather = { color = "#7A5CFF" },
  clock = { color = "#CCFF00" },
  volume = { color = "#0499FF" },
  ["backup-status"] = { color = "#FF2BFF", type = "local/backup-status:bar" },
  ["gpu-status"] = { color = "#C4FF7A", type = "local/gpu-status:bar" },
  mystery = {},
  ["bar-pins"] = { color = "#FFB300", type = "local/bar-pins:bar" },
}
local BAR = {
  start = { "launcher" },
  center = {},
  ["end"] = { "weather", "clock", "volume", "backup-status", "gpu-status", "mystery", "bar-pins" },
}

barWidget = {
  setGlyph = function(g) table.insert(barGlyphs, g) end,
  setGlyphColor = function(_c) end,
  setColor = function(_c) end,
  setText = function(t) table.insert(barTexts, t) end,
  setTooltip = function(t) table.insert(barTooltips, t) end,
  setVisible = function(v) table.insert(barVisible, v) end,
}

panel = {
  render = function(tree) table.insert(panelTrees, tree) end,
  close = function() panelClosed += 1 end,
}

local function makeNode(kind)
  return function(props, children)
    return { kind = kind, props = props or {}, children = children or {} }
  end
end

ui = {
  column = makeNode("column"), row = makeNode("row"), label = makeNode("label"), glyph = makeNode("glyph"),
  button = makeNode("button"), scroll = makeNode("scroll"), spacer = makeNode("spacer"),
}

noctalia = {
  getSetting = function(path)
    if path == "widget" then
      return WIDGETS
    elseif path == "bar.main" then
      return BAR
    end
    error("unexpected getSetting(" .. tostring(path) .. ")")
  end,
  togglePanel = function(id) table.insert(toggledPanels, id) end,
  runAsync = function(argv, cb)
    table.insert(launched, argv)
    if argv[1] == "noctalia" and argv[2] == "msg" and argv[3] == "config-set" then
      local name = string.match(argv[4], "^widget%.(.+)%.enabled$")
      assert(name ~= nil, "config-set of an unexpected path: " .. tostring(argv[4]))
      WIDGETS[name] = WIDGETS[name] or {}
      WIDGETS[name].enabled = argv[5] == "true"
    end
    if cb then
      cb({ exitCode = 0, stdout = "ok" })
    end
    return true
  end,
  string = { trim = function(s) return (string.gsub(s, "^%s*(.-)%s*$", "%1")) end },
}

local commonModule = (function()
--@COMMON@
end)()

local function findNodeByKey(node, targetKey)
  if type(node) ~= "table" then return nil end
  if node.props and node.props.key == targetKey then return node end
  for _, child in ipairs(node.children or {}) do
    local found = findNodeByKey(child, targetKey)
    if found then return found end
  end
  return nil
end

local function findKind(node, kind)
  if type(node) ~= "table" then return nil end
  if node.kind == kind then return node end
  for _, child in ipairs(node.children or {}) do
    local found = findKind(child, kind)
    if found then return found end
  end
  return nil
end

local function lastArgv()
  return table.concat(launched[#launched], " ")
end

--@ENTRY@

if TEST_ENTRY == "bar" then
  assert(barVisible[#barVisible] == false, "the drawer button shows although nothing is unpinned")
  WIDGETS.clock.enabled = false
  WIDGETS.weather.enabled = false
  onConfigChanged()
  assert(barVisible[#barVisible] == true, "the drawer button did not appear")
  assert(barGlyphs[#barGlyphs] == "pinned-off", "drawer glyph")
  assert(barTexts[#barTexts] == "2", "the button does not count the unpinned icons: " .. tostring(barTexts[#barTexts]))
  local tip = barTooltips[#barTooltips]
  assert(tip[1].value == "Weather, Clock", "tooltip lists them in bar order: " .. tostring(tip[1].value))
  onClick()
  assert(toggledPanels[#toggledPanels] == "local/bar-pins:drawer", "click did not open the drawer")
  onRightClick()
  assert(toggledPanels[#toggledPanels] == "local/bar-pins:drawer", "right click did not open the drawer")
  WIDGETS.clock.enabled = true
  WIDGETS.weather.enabled = true
  onConfigChanged()
  assert(barVisible[#barVisible] == false, "the drawer button stayed after everything was pinned")
elseif TEST_ENTRY == "menu" then
  -- a plugin icon: its old right click goes back to it as an event, exactly as before
  onOpen("backup-status")
  local tree = panelTrees[#panelTrees]
  assert(findKind(findNodeByKey(tree, "menu_head"), "glyph").props.color == "#FF2BFF", "the header glyph is not the icon's colour")
  local action = findNodeByKey(tree, "btn_action")
  assert(action ~= nil and action.props.text == "Back up now", "Backup's old right-click action is missing")
  local closedBefore = panelClosed
  action.props.onClick()
  assert(panelClosed == closedBefore + 1, "the menu did not close")
  assert(lastArgv() == "noctalia msg plugin local/backup-status:bar all right-click", "wrong backup action: " .. lastArgv())

  -- a built-in icon: its old right click as an IPC line
  onOpen("volume")
  findNodeByKey(panelTrees[#panelTrees], "btn_action").props.onClick()
  assert(lastArgv() == "noctalia msg volume-mute", "wrong volume action: " .. lastArgv())

  -- a panel action
  onOpen("gpu-status")
  findNodeByKey(panelTrees[#panelTrees], "btn_action").props.onClick()
  assert(toggledPanels[#toggledPanels] == "prponkshe/umbriel-displays:arrange", "GPU's Arrange displays")

  -- no old right click: only Unpin, which hides the icon
  onOpen(" clock ")
  tree = panelTrees[#panelTrees]
  assert(findNodeByKey(tree, "btn_action") == nil, "the clock never had a right-click action")
  findNodeByKey(tree, "btn_unpin").props.onClick()
  assert(lastArgv() == "noctalia msg config-set widget.clock.enabled false", "Unpin: " .. lastArgv())
  assert(WIDGETS.clock.enabled == false, "the clock is still pinned")

  -- an icon the catalog does not know still gets Unpin, under its own name
  onOpen("mystery")
  tree = panelTrees[#panelTrees]
  assert(findKind(findNodeByKey(tree, "menu_head"), "label").props.text == "mystery", "unknown icon label")
  assert(findNodeByKey(tree, "btn_unpin") ~= nil, "an unknown icon cannot be unpinned")
  onClose()
elseif TEST_ENTRY == "drawer" then
  onOpen("")
  assert(findNodeByKey(panelTrees[#panelTrees], "drawer_empty") ~= nil, "empty drawer has no note")

  WIDGETS.clock.enabled = false
  WIDGETS.weather.enabled = false
  WIDGETS.mystery.enabled = false
  onConfigChanged()
  local tree = panelTrees[#panelTrees]
  local column = findNodeByKey(tree, "drawer")
  local order = {}
  for _, child in ipairs(column.children) do
    local key = child.props.key
    if type(key) == "string" and string.sub(key, 1, 4) == "row_" then
      table.insert(order, string.sub(key, 5))
    end
  end
  assert(table.concat(order, ",") == "weather,clock,mystery", "drawer order: " .. table.concat(order, ","))
  assert(findNodeByKey(tree, "open_mystery") == nil, "Open shown for an icon without a known action")
  assert(findNodeByKey(tree, "btn_pin_all") ~= nil, "no Pin all")

  -- Open runs the icon's left-click action
  local closedBefore = panelClosed
  findNodeByKey(tree, "open_clock").props.onClick()
  assert(panelClosed == closedBefore + 1, "Open did not close the drawer")
  assert(lastArgv() == "noctalia msg panel-toggle control-center calendar", "Open clock: " .. lastArgv())

  -- Pin puts one back; the drawer redraws without it
  findNodeByKey(tree, "pin_weather").props.onClick()
  assert(lastArgv() == "noctalia msg config-set widget.weather.enabled true", "Pin: " .. lastArgv())
  tree = panelTrees[#panelTrees]
  assert(findNodeByKey(tree, "row_weather") == nil, "the pinned icon is still in the drawer")

  -- Pin all: everything back, and the drawer closes with its button
  closedBefore = panelClosed
  findNodeByKey(tree, "btn_pin_all").props.onClick()
  assert(WIDGETS.clock.enabled == true and WIDGETS.mystery.enabled == true, "Pin all left some unpinned")
  assert(panelClosed > closedBefore, "the drawer stayed open with nothing in it")
  onClose()
else
  error("unknown TEST_ENTRY: " .. tostring(TEST_ENTRY))
end

print("bar-pins plugin check OK: " .. tostring(TEST_ENTRY))
