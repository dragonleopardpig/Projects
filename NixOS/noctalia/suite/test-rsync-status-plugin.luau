-- Test local/rsync-status entries (service, bar, panel) under Luau with host stand-ins.
-- Default.nix copies common.luau alongside and splices each entry at the marker.

local sharedState = {}
local stateWatchers = {}
local barGlyphs, barColors, barTooltips, toggledPanels = {}, {}, {}, {}
local panelTrees, panelClosed, launchedCommands = {}, 0, {}
local streamCallback = nil
local nextRunResult = { exitCode = 0, stdout = '{"state":"ok","badge":"Synced","summary":"All targets synced","script_exists":true,"disk_mounted":true,"same_disk":false,"syncing":false,"can_sync":true,"target_root":"/run/media/thinky/nixos/home/thinky","log_exists":true,"last_run_text":"Last run: 15:25 · exit 0","targets":[{"id":"projects","name":"Projects","state":"ok","line_status":"OK (0) · 15:25","tooltip":"~/Projects -> target"}],"tooltip":[{"key":"Rsync Backup","value":"All targets synced"}]}' }

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
      cb(nextRunResult)
    end
    return true
  end,
  json = {
    decode = function(str)
      if string.find(str, '"state":"syncing"') then
        return {
          state = "syncing",
          badge = "Syncing",
          summary = "Syncing Projects...",
          script_exists = true,
          disk_mounted = true,
          same_disk = false,
          syncing = true,
          can_sync = false,
          target_root = "/run/media/thinky/nixos/home/thinky",
          log_exists = true,
          last_run_text = "Started: 15:30",
          targets = {
            { id = "projects", name = "Projects", state = "syncing", line_status = "Syncing... (3s)" },
            { id = "scramble-public", name = "Scramble Public", state = "queued", line_status = "Queued" },
          },
          tooltip = { { key = "Rsync Backup", value = "Syncing Projects..." } },
        }
      end
      if string.find(str, '"state":"error"') then
        return {
          state = "error",
          badge = "Error",
          summary = "Failed: Projects",
          script_exists = true,
          disk_mounted = true,
          same_disk = false,
          syncing = false,
          can_sync = true,
          target_root = "/run/media/thinky/nixos/home/thinky",
          log_exists = true,
          last_run_text = "Last run: 15:31 · exit 23",
          targets = {
            { id = "projects", name = "Projects", state = "error", line_status = "Error (23) · 15:31" },
          },
          tooltip = { { key = "Rsync Backup", value = "Failed: Projects" } },
        }
      end
      return {
        state = "ok",
        badge = "Synced",
        summary = "All targets synced",
        script_exists = true,
        disk_mounted = true,
        same_disk = false,
        syncing = false,
        can_sync = true,
        target_root = "/run/media/thinky/nixos/home/thinky",
        log_exists = true,
        last_run_text = "Last run: 15:25 · exit 0",
        targets = {
          { id = "projects", name = "Projects", state = "ok", line_status = "OK (0) · 15:25" },
          { id = "scramble-public", name = "Scramble Public", state = "ok", line_status = "OK (0) · 15:25" },
        },
        tooltip = { { key = "Rsync Backup", value = "All targets synced" } },
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
  assert(barColors[#barColors] == "secondary", "expected secondary, got " .. tostring(barColors[#barColors]))
  onClick()
  assert(toggledPanels[#toggledPanels] == "local/rsync-status:panel", "onClick did not toggle panel")
  noctalia.state.set("snapshot", noctalia.json.decode('{"state":"syncing"}'))
  assert(barGlyphs[#barGlyphs] == "refresh", "expected refresh while syncing")
  assert(barColors[#barColors] == "primary", "expected primary while syncing")
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
  local rowPublic = findNodeByKey(tree, "target_scramble-public")
  assert(rowProjects ~= nil and rowPublic ~= nil, "target rows missing")
  assert(rowProjects.children[3].props.text == "OK (0) · 15:25", rowProjects.children[3].props.text)
  local syncBtn = findNodeByKey(tree, "btn_sync_now")
  assert(syncBtn ~= nil and syncBtn.props.enabled == true, "sync button should be enabled")
  local beforeSync = #launchedCommands
  syncBtn.props.onClick()
  assert(launchedCommands[beforeSync + 1][2] == "trigger", "sync button did not trigger")
  assert(launchedCommands[beforeSync + 2][2] == "status", "trigger callback did not refresh status")
  local closeBtn = findNodeByKey(tree, "btn_close")
  closeBtn.props.onClick()
  assert(panelClosed == 1, "close button did not close panel")
  onClose()
else
  error("unknown TEST_ENTRY: " .. tostring(TEST_ENTRY))
end

print("rsync-status plugin check OK: " .. tostring(TEST_ENTRY))
