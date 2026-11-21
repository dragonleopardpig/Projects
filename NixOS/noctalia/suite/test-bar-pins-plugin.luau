-- Test local/bar-pins' menu under Luau with host stand-ins, on the bar and in the tray drawer.
-- The stand-in `noctalia msg config-set` changes the widget table, as Noctalia does.

local toggledPanels, panelTrees, panelClosed, launched = {}, {}, 0, {}

local WIDGETS = {
  launcher = { color = "#6BC5FF" },
  weather = { color = "#7A5CFF" },
  clock = { color = "#CCFF00" },
  volume = { color = "#0499FF" },
  ["backup-status"] = { color = "#FF2BFF", type = "local/backup-status:bar" },
  ["gpu-status"] = { color = "#C4FF7A", type = "local/gpu-status:bar" },
  mystery = {},
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

if TEST_ENTRY == "menu" then
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

  -- in the tray drawer (unpinned): Pin to bar instead of Unpin
  onOpen("clock")
  tree = panelTrees[#panelTrees]
  assert(findNodeByKey(tree, "btn_unpin") == nil, "Unpin offered for an unpinned icon")
  findNodeByKey(tree, "btn_pin").props.onClick()
  assert(lastArgv() == "noctalia msg config-set widget.clock.enabled true", "Pin: " .. lastArgv())
  assert(WIDGETS.clock.enabled == true, "the clock was not pinned back")

  -- an unpinned plugin icon: its own right click needs it on the bar, so only Pin
  WIDGETS["backup-status"].enabled = false
  onOpen("backup-status")
  tree = panelTrees[#panelTrees]
  assert(findNodeByKey(tree, "btn_action") == nil, "Back up now offered while Backup is off the bar")
  assert(findNodeByKey(tree, "btn_pin") ~= nil, "no Pin for the unpinned Backup")

  -- an unpinned built-in icon keeps its old action (it does not need the icon)
  WIDGETS.volume.enabled = false
  onOpen("volume")
  tree = panelTrees[#panelTrees]
  findNodeByKey(tree, "btn_action").props.onClick()
  assert(lastArgv() == "noctalia msg volume-mute", "Mute from the drawer: " .. lastArgv())

  -- pinning from elsewhere while the menu is open redraws it
  onOpen("volume")
  WIDGETS.volume.enabled = true
  onConfigChanged()
  assert(findNodeByKey(panelTrees[#panelTrees], "btn_unpin") ~= nil, "the menu did not follow the pin state")
  onClose()
else
  error("unknown TEST_ENTRY: " .. tostring(TEST_ENTRY))
end

print("bar-pins plugin check OK: " .. tostring(TEST_ENTRY))
