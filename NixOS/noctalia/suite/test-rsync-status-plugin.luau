-- Test local/rsync-status entries (service, bar, panel) under Luau with host stand-ins.

local sharedState = {}
local stateWatchers = {}
local barGlyphs, barColors, barTooltips, toggledPanels = {}, {}, {}, {}
local panelTrees, panelClosed, launchedCommands = {}, 0, {}
local streamCallback = nil
local nextRunResult = {
  exitCode = 0,
  stdout = '{"state":"ok","badge":"Synced","summary":"All enabled targets synced","configured":true,"disk_mounted":true,"same_disk":false,"syncing":false,"can_sync":true,"target_root":"/run/media/thinky/nixos/home/thinky","target_root_raw":"/run/media/thinky/nixos/home/thinky","excludes":[".devenv/"],"log_exists":true,"last_run_text":"Last run: 15:25 · exit 0","targets":[{"id":"projects","name":"Projects","source":"/home/thinky/Projects","dest":"Projects","enabled":true,"delete":true,"excludes":[],"can_run":true,"state":"ok","line_status":"OK (0) · 15:25","tooltip":"~/Projects -> target"},{"id":"scramble-public","name":"Scramble Public","source":"/home/thinky/Documents/Scramble Public","dest":"Documents/Scramble Public","enabled":true,"delete":true,"excludes":[],"can_run":true,"state":"ok","line_status":"OK (0) · 15:25","tooltip":"~/Documents/Scramble Public -> target"}],"tooltip":[{"key":"Rsync Backup","value":"All enabled targets synced"}]}',
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
  commandExists = function(name) return name == "noctalia-rsync-status" end,
  expandPath = function(p) return p end,
  fileExists = function() return true end,
  togglePanel = function(id) table.insert(toggledPanels, id) end,
  runStream = function(cmd, cb)
    assert(string.find(cmd, "noctalia%-rsync%-status watch"), cmd)
    streamCallback = cb
    return true
  end,
  runAsync = function(argv, cb)
    table.insert(launchedCommands, argv)
    if cb then
      if argv[2] == "pick-folder" then
        cb({ exitCode = 0, stdout = "/tmp/picked-dir\n" })
      else
        cb(nextRunResult)
      end
    end
    return true
  end,
  string = {
    trim = function(s) return (string.gsub(s, "^%s*(.-)%s*$", "%1")) end,
  },
  json = {
    encode = function(tbl)
      if type(tbl) == "table" and tbl.source ~= nil then
        return '{"name":"' .. tostring(tbl.name or "") .. '","source":"' .. tostring(tbl.source or "") .. '"}'
      end
      return "{}"
    end,
    decode = function(str)
      if string.find(str, '"state":"syncing"') then
        return {
          state = "syncing", badge = "Syncing", summary = "Syncing Projects...",
          configured = true, disk_mounted = true, same_disk = false, syncing = true, can_sync = false,
          target_root = "/run/media/thinky/nixos/home/thinky", excludes = {}, log_exists = true,
          last_run_text = "Started: 15:30",
          targets = {
            { id = "projects", name = "Projects", enabled = true, can_run = false, state = "syncing", line_status = "Syncing... (3s)" },
            { id = "scramble-public", name = "Scramble Public", enabled = true, can_run = false, state = "queued", line_status = "Queued" },
          },
          tooltip = { { key = "Rsync Backup", value = "Syncing Projects..." } },
        }
      end
      if string.find(str, '"state":"error"') then
        return {
          state = "error", badge = "Error", summary = "Failed: Projects",
          configured = true, disk_mounted = true, same_disk = false, syncing = false, can_sync = true,
          target_root = "/run/media/thinky/nixos/home/thinky", excludes = {}, log_exists = true,
          last_run_text = "Last run: 15:31 · exit 23",
          targets = {
            { id = "projects", name = "Projects", enabled = true, can_run = true, state = "error", line_status = "Error (23) · 15:31" },
          },
          tooltip = { { key = "Rsync Backup", value = "Failed: Projects" } },
        }
      end
      return {
        state = "ok", badge = "Synced", summary = "All enabled targets synced",
        configured = true, disk_mounted = true, same_disk = false, syncing = false, can_sync = true,
        target_root = "/run/media/thinky/nixos/home/thinky", target_root_raw = "/run/media/thinky/nixos/home/thinky",
        excludes = { ".devenv/" }, log_exists = true,
        last_run_text = "Last run: 15:25 · exit 0",
        targets = {
          { id = "projects", name = "Projects", source = "/home/thinky/Projects", dest = "Projects", enabled = true, delete = true, excludes = {}, can_run = true, state = "ok", line_status = "OK (0) · 15:25" },
          { id = "scramble-public", name = "Scramble Public", source = "/home/thinky/Documents/Scramble Public", dest = "Documents/Scramble Public", enabled = true, delete = true, excludes = {}, can_run = true, state = "ok", line_status = "OK (0) · 15:25" },
        },
        tooltip = { { key = "Rsync Backup", value = "All enabled targets synced" } },
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
  assert(sharedState.snapshot.state == "ok", "service IPC refresh failed")
elseif TEST_ENTRY == "bar" then
  assert(barGlyphs[#barGlyphs] == "folder-check", "expected folder-check, got " .. tostring(barGlyphs[#barGlyphs]))
  assert(barColors[#barColors] == "", "an idle icon keeps its own colour, got " .. tostring(barColors[#barColors]))
  onClick()
  assert(toggledPanels[#toggledPanels] == "local/rsync-status:panel", "onClick did not toggle panel")
  noctalia.state.set("snapshot", noctalia.json.decode('{"state":"syncing"}'))
  assert(barGlyphs[#barGlyphs] == "refresh", "expected refresh while syncing")
  assert(barColors[#barColors] == "", "a syncing icon keeps its own colour")
  noctalia.state.set("snapshot", noctalia.json.decode('{"state":"error"}'))
  assert(barGlyphs[#barGlyphs] == "refresh-alert", "expected refresh-alert on error")
  assert(barColors[#barColors] == "error", "expected error color")
  onConfigChanged()
  assert(#barGlyphs >= 4, "onConfigChanged did not re-render")
elseif TEST_ENTRY == "panel" then
  onOpen("")
  assert(#panelTrees >= 1, "panel did not render on open")
  local tree = panelTrees[#panelTrees]
  local rowProjects = findNodeByKey(tree, "target_projects")
  assert(rowProjects ~= nil and rowProjects.children[3].props.text == "OK (0) · 15:25", "target row mismatch")

  -- Sync All trigger
  local beforeSync = #launchedCommands
  findNodeByKey(tree, "btn_sync_now").props.onClick()
  assert(launchedCommands[beforeSync + 1][2] == "trigger", "sync button did not trigger")

  -- Open Rclone Control button
  local beforeRclone = #launchedCommands
  findNodeByKey(tree, "btn_open_rclone").props.onClick()
  assert(launchedCommands[beforeRclone + 1][2] == "open-rclone", "rclone button did not launch")

  -- Edit target + Browse folder + Save
  findNodeByKey(tree, "btn_edit_projects").props.onClick()
  local editTree = panelTrees[#panelTrees]
  assert(findNodeByKey(editTree, "edit_card") ~= nil, "edit form did not open")
  findNodeByKey(editTree, "btn_browse_src").props.onClick()
  local postPickTree = panelTrees[#panelTrees]
  assert(findNodeByKey(postPickTree, "inp_src_2").props.value == "/tmp/picked-dir", "browse did not update source input")
  local beforeSave = #launchedCommands
  findNodeByKey(postPickTree, "btn_save_target").props.onClick()
  assert(launchedCommands[beforeSave + 1][2] == "save-target", "save button did not invoke save-target")

  -- Global settings view
  local listTree = panelTrees[#panelTrees]
  findNodeByKey(listTree, "btn_settings").props.onClick()
  local settingsTree = panelTrees[#panelTrees]
  assert(findNodeByKey(settingsTree, "settings_card") ~= nil, "settings view did not open")
  findNodeByKey(settingsTree, "btn_close").props.onClick()
  assert(panelClosed == 1, "close button did not close panel")
  onClose()
else
  error("unknown TEST_ENTRY: " .. tostring(TEST_ENTRY))
end

print("rsync-status plugin check OK: " .. tostring(TEST_ENTRY))
