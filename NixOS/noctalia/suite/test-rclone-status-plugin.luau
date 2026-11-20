-- Test local/rclone-status entries (service, bar, panel) under Luau with host stand-ins.

local sharedState = {}
local stateWatchers = {}
local barGlyphs, barColors, barTooltips, toggledPanels = {}, {}, {}, {}
local panelTrees, panelClosed, launchedCommands = {}, 0, {}
local streamCallback = nil
local nextRunResult = {
  exitCode = 0,
  stdout = '{"state":"mounted","badge":"1 Mounted","summary":"1 mount(s) active · 2 remote(s)","gui_available":true,"remotes":[{"name":"gdrive","type":"drive","target_summary":"—","mounted":true},{"name":"mega","type":"mega","target_summary":"—","mounted":false}],"mounts":[{"id":"gdrive-mount","label":"Google Drive","source":"gdrive:","mountpoint":"/home/thinky/Google Drive","mountpoint_short":"~/Google Drive","systemd_unit":"gdrive-mount.service","state":"mounted","line_status":"Mounted","is_mounted":true,"can_start":false,"can_stop":true,"can_unmount":true}],"active_jobs":[],"saved_jobs_count":0,"tooltip":[{"key":"Rclone Control","value":"1 mount(s) active"}]}',
}

barWidget = {
  setGlyph = function(g) table.insert(barGlyphs, g) end,
  setGlyphColor = function(c) table.insert(barColors, c) end,
  setTooltip = function(t) table.insert(barTooltips, t) end,
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
  column = makeNode("column"),
  row = makeNode("row"),
  label = makeNode("label"),
  glyph = makeNode("glyph"),
  button = makeNode("button"),
  toggle = makeNode("toggle"),
  input = makeNode("input"),
  separator = makeNode("separator"),
  scroll = makeNode("scroll"),
  spacer = makeNode("spacer"),
}

local commonModule = (function()
--@COMMON@
end)()

noctalia = {
  commandExists = function(name) return name == "noctalia-rclone-status" end,
  expandPath = function(p) return p end,
  fileExists = function() return true end,
  togglePanel = function(id) table.insert(toggledPanels, id) end,
  runStream = function(cmd, cb)
    assert(string.find(cmd, "noctalia%-rclone%-status watch"), cmd)
    streamCallback = cb
    return true
  end,
  runAsync = function(argv, cb)
    table.insert(launchedCommands, argv)
    if cb then
      cb(nextRunResult)
    end
    return true
  end,
  json = {
    decode = function(str)
      if string.find(str, '"state":"syncing"') then
        return {
          state = "syncing", badge = "1 Active", summary = "Running 1 rclone job(s)", gui_available = true,
          remotes = {}, mounts = {}, active_jobs = { { pid = 123, op = "copy", cmd_short = "copy a b" } },
          tooltip = { { key = "Rclone Control", value = "Running 1 job" } },
        }
      end
      if string.find(str, '"state":"error"') then
        return {
          state = "error", badge = "1 Mount Error", summary = "1 mount unit(s) failed", gui_available = true,
          remotes = {}, mounts = {}, active_jobs = {},
          tooltip = { { key = "Rclone Control", value = "Mount error" } },
        }
      end
      return {
        state = "mounted", badge = "1 Mounted", summary = "1 mount(s) active · 2 remote(s)", gui_available = true,
        remotes = {
          { name = "gdrive", type = "drive", target_summary = "—", mounted = true },
          { name = "mega", type = "mega", target_summary = "—", mounted = false },
        },
        mounts = {
          {
            id = "gdrive-mount", label = "Google Drive", source = "gdrive:",
            mountpoint = "/home/thinky/Google Drive", mountpoint_short = "~/Google Drive",
            systemd_unit = "gdrive-mount.service", state = "mounted", line_status = "Mounted",
            is_mounted = true, can_start = false, can_stop = true, can_unmount = true,
          },
        },
        active_jobs = {},
        tooltip = { { key = "Rclone Control", value = "1 mount(s) active" } },
      }
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

--@ENTRY@

if TEST_ENTRY == "service" then
  assert(streamCallback ~= nil, "service did not attach watch stream")
  streamCallback('{"state":"syncing"}')
  assert(sharedState.snapshot.state == "syncing", "service failed to publish syncing")
  onIpc("refresh", "")
  assert(sharedState.snapshot.state == "mounted", "service IPC refresh failed")
elseif TEST_ENTRY == "bar" then
  assert(barGlyphs[#barGlyphs] == "cloud-check", "expected cloud-check, got " .. tostring(barGlyphs[#barGlyphs]))
  assert(barColors[#barColors] == "secondary", "expected secondary, got " .. tostring(barColors[#barColors]))
  onClick()
  assert(toggledPanels[#toggledPanels] == "local/rclone-status:panel", "onClick did not toggle panel")
  onRightClick()
  assert(launchedCommands[#launchedCommands][2] == "open-gui", "right click did not open GUI")
  noctalia.state.set("snapshot", noctalia.json.decode('{"state":"syncing"}'))
  assert(barGlyphs[#barGlyphs] == "cloud-upload", "expected cloud-upload while syncing")
  assert(barColors[#barColors] == "primary", "expected primary while syncing")
  noctalia.state.set("snapshot", noctalia.json.decode('{"state":"error"}'))
  assert(barGlyphs[#barGlyphs] == "alert-triangle", "expected alert-triangle on error")
  assert(barColors[#barColors] == "error", "expected error color")
  onConfigChanged()
elseif TEST_ENTRY == "panel" then
  onOpen("")
  assert(#panelTrees >= 1, "panel did not render on open")
  local tree = panelTrees[#panelTrees]
  assert(findNodeByKey(tree, "mount_gdrive-mount") ~= nil, "mount row missing")
  assert(findNodeByKey(tree, "remote_mega") ~= nil, "remote row missing")

  local beforeStop = #launchedCommands
  findNodeByKey(tree, "btn_stop_gdrive-mount").props.onClick()
  assert(launchedCommands[beforeStop + 1][2] == "mount-action", "stop button did not call mount-action")

  local beforeGui = #launchedCommands
  findNodeByKey(tree, "btn_open_gui").props.onClick()
  assert(launchedCommands[beforeGui + 1][2] == "open-gui", "open gui button did not launch GUI")
  assert(panelClosed >= 1, "panel did not close after launching GUI")
  onClose()
else
  error("unknown TEST_ENTRY: " .. tostring(TEST_ENTRY))
end

print("rclone-status plugin check OK: " .. tostring(TEST_ENTRY))
