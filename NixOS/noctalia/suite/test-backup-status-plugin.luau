-- Test local/backup-status entries (service, bar, panel) under Luau with host stand-ins.

local sharedState = {}
local stateWatchers = {}
local barGlyphs, barColors, barTexts, barTooltips, barVisible = {}, {}, {}, {}, {}
local toggledPanels, panelTrees, panelClosed, launchedCommands = {}, {}, 0, {}
local streamCallback = nil
local helperPresent = true
local encoded = nil

-- What the helper answers: a key into FIXTURES (the stand-in json.decode returns it).
local nextReply = { exitCode = 0, stdout = "ok" }

local FIXTURES = {
  ok = {
    available = true, state = "ok", badge = "Up to date", summary = "Last backup 29 min ago",
    tooltip = { { key = "Backup", value = "Up to date" } },
    running = false, browsing = false, disk_present = true, disk_label = "Seagate Linux-Data",
    last_success_text = "today 12:31", next_text = "tomorrow 12:30", snapshots = 3,
    latest_text = "today 12:31", latest_size_text = "23.9 GiB", stored_text = "14.0 GiB", disk_free_text = "3.4 TiB",
    settings = { time = "12:30", paused = false, keep = { daily = 7, weekly = 4, monthly = 6 }, extra_paths = {}, extra_excludes = {} },
    settings_errors = {}, defaults = { time = "12:30", keep = { daily = 7, weekly = 4, monthly = 6 } },
    paths = { "/home", "/persist" }, excludes = { "/home/*/.cache" }, repository = "/mnt/backup/restic/m90apro",
    can_run = true, can_stop = false, can_browse = true,
  },
  running = {
    available = true, state = "running", badge = "Backing up", summary = "Backing up 42%, 1:30 left",
    percent = 42.4, running = true, can_run = false, can_stop = true, progress_text = "4.2 GiB of 10 GiB, 10 files",
    tooltip = { { key = "Backup", value = "Backing up" } },
  },
  failed = {
    available = true, state = "failed", badge = "Failed", summary = "Last backup failed: disk full",
    last_error = "disk full", can_run = true, tooltip = { { key = "Backup", value = "Failed" } },
  },
  unavailable = { available = false, state = "unavailable" },
  refused = {
    available = true, state = "ok", badge = "Up to date", summary = "x", can_run = true,
    action_error = "time 'noon' is not HH:MM (00:00-23:59)",
  },
}

barWidget = {
  setGlyph = function(g) table.insert(barGlyphs, g) end,
  setGlyphColor = function(c) table.insert(barColors, c) end,
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
  button = makeNode("button"), toggle = makeNode("toggle"), input = makeNode("input"),
  separator = makeNode("separator"), scroll = makeNode("scroll"), spacer = makeNode("spacer"),
  progress = makeNode("progress"),
}

local commonModule = (function()
--@COMMON@
end)()

noctalia = {
  commandExists = function(name) return helperPresent and name == "backup-pool" end,
  expandPath = function(p) return p end,
  fileExists = function() return false end,
  togglePanel = function(id) table.insert(toggledPanels, id) end,
  runStream = function(cmd, cb)
    assert(cmd == "backup-pool watch", cmd)
    streamCallback = cb
    return true
  end,
  runAsync = function(argv, cb)
    table.insert(launchedCommands, argv)
    if cb then
      cb(nextReply)
    end
    return true
  end,
  string = { trim = function(s) return (string.gsub(s, "^%s*(.-)%s*$", "%1")) end },
  json = {
    decode = function(str)
      local fixture = FIXTURES[str]
      assert(fixture ~= nil, "no fixture for " .. tostring(str))
      return fixture
    end,
    encode = function(t)
      encoded = t
      return "ENCODED"
    end,
  },
  state = {
    get = function(k) return sharedState[k] end,
    set = function(k, v)
      sharedState[k] = v
      for _, fn in ipairs(stateWatchers[k] or {}) do
        fn(v)
      end
    end,
    watch = function(k, fn)
      stateWatchers[k] = stateWatchers[k] or {}
      table.insert(stateWatchers[k], fn)
    end,
  },
}

local function findNodeByKey(node, targetKey)
  if type(node) ~= "table" then return nil end
  if node.props and node.props.key == targetKey then return node end
  for _, child in ipairs(node.children or {}) do
    local found = findNodeByKey(child, targetKey)
    if found then return found end
  end
  return nil
end

local function findKeyPrefix(node, prefix)
  if type(node) ~= "table" then return nil end
  local key = node.props and node.props.key
  if type(key) == "string" and string.sub(key, 1, #prefix) == prefix then return node end
  for _, child in ipairs(node.children or {}) do
    local found = findKeyPrefix(child, prefix)
    if found then return found end
  end
  return nil
end

local function lastArgs()
  local argv = launchedCommands[#launchedCommands]
  return argv[2], argv
end

--@ENTRY@

if TEST_ENTRY == "service" then
  assert(streamCallback ~= nil, "service did not attach the watch stream")
  streamCallback("running")
  assert(sharedState.snapshot.state == "running", "service did not publish the stream")
  onIpc("refresh", "")
  assert(lastArgs() == "status", "IPC refresh did not ask for the status")
  assert(sharedState.snapshot.state == "ok", "IPC refresh did not publish")
elseif TEST_ENTRY == "bar" then
  -- first render: the helper answers ok
  assert(barVisible[#barVisible] == true, "bar hidden although the helper is there")
  assert(barGlyphs[#barGlyphs] == "shield-check", "ok glyph: " .. tostring(barGlyphs[#barGlyphs]))
  assert(barColors[#barColors] == "", "an ok icon keeps its own colour: " .. tostring(barColors[#barColors]))
  assert(barTexts[#barTexts] == "", "no text when idle")

  noctalia.state.set("snapshot", FIXTURES.running)
  assert(barGlyphs[#barGlyphs] == "database-export", "running glyph")
  assert(barColors[#barColors] == "", "a running icon keeps its own colour")
  assert(barTexts[#barTexts] == "42%", "running shows the percentage: " .. tostring(barTexts[#barTexts]))

  -- right click never stops a running backup: it opens the panel instead
  local before = #launchedCommands
  onRightClick()
  assert(#launchedCommands == before, "right click launched something while running")
  assert(toggledPanels[#toggledPanels] == "local/backup-status:panel", "right click while running did not open the panel")

  noctalia.state.set("snapshot", FIXTURES.failed)
  assert(barGlyphs[#barGlyphs] == "alert-triangle", "failed glyph")
  assert(barColors[#barColors] == "error", "failed colour")
  onRightClick()
  assert(lastArgs() == "run", "right click did not run the backup")
  -- the bar-pins menu's "Back up now" sends the old right click as an event
  local beforeEvent = #launchedCommands
  onIpc("right-click", "")
  assert(#launchedCommands == beforeEvent + 1 and lastArgs() == "run", "the menu's right-click event did not run the backup")

  onClick()
  assert(toggledPanels[#toggledPanels] == "local/backup-status:panel", "click did not toggle the panel")

  noctalia.state.set("snapshot", FIXTURES.unavailable)
  assert(barVisible[#barVisible] == false, "bar shown on a host without a backup")
  noctalia.state.set("snapshot", FIXTURES.ok)
  assert(barVisible[#barVisible] == true, "bar did not come back")
  helperPresent = false
  onConfigChanged()
  assert(barVisible[#barVisible] == false, "bar shown without the helper")
elseif TEST_ENTRY == "panel" then
  onOpen("")
  local tree = panelTrees[#panelTrees]
  assert(findNodeByKey(tree, "status_card") ~= nil, "status card missing")
  assert(findNodeByKey(tree, "info_next") ~= nil, "next run row missing")
  assert(findNodeByKey(tree, "btn_stop") == nil, "Stop shown while idle")

  findNodeByKey(tree, "btn_run").props.onClick()
  assert(lastArgs() == "run", "Run now did not call run")

  nextReply = { exitCode = 0, stdout = "ok" }
  findNodeByKey(panelTrees[#panelTrees], "btn_browse").props.onClick()
  assert(lastArgs() == "browse-start", "Browse did not call browse-start")

  -- while running: Stop, a progress bar
  noctalia.state.set("snapshot", FIXTURES.running)
  tree = panelTrees[#panelTrees]
  assert(findNodeByKey(tree, "progress_bar") ~= nil, "no progress bar while running")
  assert(math.abs(findNodeByKey(tree, "progress_bar").props.progress - 0.424) < 1e-6, "progress fraction")
  findNodeByKey(tree, "btn_stop").props.onClick()
  assert(lastArgs() == "stop", "Stop did not call stop")

  -- settings: edit the time and a keep count, save
  noctalia.state.set("snapshot", FIXTURES.ok)
  findNodeByKey(panelTrees[#panelTrees], "btn_settings").props.onClick()
  tree = panelTrees[#panelTrees]
  assert(findNodeByKey(tree, "settings_card") ~= nil, "settings view did not open")
  assert(findNodeByKey(tree, "fixed_paths") ~= nil, "the fixed paths are not shown")
  local timeInput = findKeyPrefix(tree, "inp_time_")
  assert(timeInput.props.value == "12:30", "time input not seeded from the settings")
  timeInput.props.onChange("03:15")
  findKeyPrefix(tree, "inp_keep_daily_").props.onChange("10")
  findKeyPrefix(tree, "inp_paths_").props.onChange("/home/thinky/VMs")
  findNodeByKey(tree, "tog_paused").props.onChange("true")
  tree = panelTrees[#panelTrees]

  -- a refusal keeps the form open and shows why
  nextReply = { exitCode = 1, stdout = "refused" }
  findNodeByKey(tree, "btn_save").props.onClick()
  local cmd, argv = lastArgs()
  assert(cmd == "save-settings" and argv[3] == "--json" and argv[4] == "ENCODED", "Save did not call save-settings")
  assert(encoded.time == "03:15" and encoded.keep_daily == "10" and encoded.paused == true, "Save sent the wrong form")
  assert(encoded.extra_paths == "/home/thinky/VMs", "Save lost the extra folder")
  tree = panelTrees[#panelTrees]
  assert(findNodeByKey(tree, "settings_card") ~= nil, "a refused save closed the form")
  local msg = findNodeByKey(tree, "settings_msg")
  assert(msg ~= nil and string.find(msg.props.text, "not HH:MM"), "the refusal is not shown")

  -- accepted: back to the status view, with a note
  nextReply = { exitCode = 0, stdout = "ok" }
  findNodeByKey(tree, "btn_save").props.onClick()
  tree = panelTrees[#panelTrees]
  assert(findNodeByKey(tree, "status_card") ~= nil, "a saved form did not close")
  assert(string.find(findNodeByKey(tree, "action_msg").props.text, "Saved"), "no saved note")

  findNodeByKey(tree, "btn_close").props.onClick()
  assert(panelClosed == 1, "close button")
  onClose()
else
  error("unknown TEST_ENTRY: " .. tostring(TEST_ENTRY))
end

print("backup-status plugin check OK: " .. tostring(TEST_ENTRY))
