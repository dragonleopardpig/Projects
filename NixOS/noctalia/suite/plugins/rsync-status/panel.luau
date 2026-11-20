--!nonstrict
-- Dropdown panel displaying each rsync target status per line plus quick actions.

local common = require("./common.luau")

local current = noctalia.state.get("snapshot") or common.DEFAULT_SNAPSHOT
local isOpen = false
local actionMessage = ""

local function refreshSnapshot()
  local argv = common.helperArgv({ "status" })
  if argv == nil then
    return
  end
  noctalia.runAsync(argv, function(res)
    if res and res.exitCode == 0 and res.stdout and res.stdout ~= "" then
      local data = noctalia.json.decode(res.stdout)
      if type(data) == "table" then
        current = data
        noctalia.state.set("snapshot", data)
        if isOpen then
          render()
        end
      end
    end
  end)
end

local function triggerSync(dryRun: boolean)
  local args = dryRun and { "trigger", "--dry-run" } or { "trigger" }
  local argv = common.helperArgv(args)
  if argv == nil then
    actionMessage = "noctalia-rsync-status helper not found"
    if isOpen then
      render()
    end
    return
  end
  actionMessage = dryRun and "Starting dry run..." or "Starting rsync..."
  if isOpen then
    render()
  end
  noctalia.runAsync(argv, function(res)
    if res and res.exitCode == 0 then
      actionMessage = ""
      refreshSnapshot()
    else
      actionMessage = "Failed to start sync-projects"
      if isOpen then
        render()
      end
    end
  end)
end

local function openLog()
  local argv = common.helperArgv({ "open-log" })
  if argv == nil then
    return
  end
  noctalia.runAsync(argv)
end

local function diskBanner(snap)
  local diskGlyph = "plug-connected-x"
  local diskColor = "on_surface_variant"
  local diskLabel = "Unmounted"
  if snap.same_disk then
    diskGlyph = "alert-triangle"
    diskColor = "error"
    diskLabel = "Same disk"
  elseif snap.disk_mounted then
    diskGlyph = "plug-connected"
    diskColor = "secondary"
    diskLabel = "Mounted"
  end

  local targetText = snap.target_root or ""
  if targetText == "" then
    targetText = "Target disk path not set"
  end

  return ui.row({
    key = "disk_banner",
    align = "center",
    gap = 8,
    paddingH = 10,
    paddingV = 8,
    radius = 10,
    fill = "surface_container",
    tooltip = "Backup destination: " .. targetText,
  }, {
    ui.glyph({ name = diskGlyph, size = 15, color = diskColor }),
    ui.label({
      text = targetText,
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 1,
      flexGrow = 1,
    }),
    ui.label({
      text = diskLabel,
      fontSize = 11,
      fontWeight = "bold",
      color = diskColor,
    }),
  })
end

local function targetRow(target, index: number)
  local tState = target.state or "never"
  local tColor = common.stateColor(tState)
  local isHighlight = (tState == "syncing" or tState == "error")
  local rowFill = tState == "syncing" and "surface_container_high" or nil

  return ui.row({
    key = "target_" .. (target.id or tostring(index)),
    align = "center",
    gap = 8,
    paddingH = 10,
    paddingV = 7,
    radius = 8,
    fill = rowFill,
    tooltip = target.tooltip or ((target.source or "") .. " -> " .. (target.dest or "")),
  }, {
    ui.glyph({ name = common.targetGlyph(tState), size = 15, color = tColor }),
    ui.label({
      text = target.name or ("Target " .. tostring(index)),
      fontSize = 12,
      fontWeight = "medium",
      color = "on_surface",
      maxLines = 1,
      flexGrow = 1,
    }),
    ui.label({
      text = target.line_status or "",
      fontSize = 11,
      fontWeight = isHighlight and "bold" or nil,
      color = tColor,
      maxLines = 1,
    }),
  })
end

function render()
  local snap = current or common.DEFAULT_SNAPSHOT
  local overallColor = common.stateColor(snap.state)
  local targets = type(snap.targets) == "table" and snap.targets or {}

  local headerRow = ui.row({ key = "header_row", align = "center", gap = 8 }, {
    ui.glyph({ name = common.barGlyph(snap.state), size = 18, color = overallColor }),
    ui.label({
      text = "Rsync Status",
      fontSize = 15,
      fontWeight = "bold",
      color = "on_surface",
      flexGrow = 1,
    }),
    ui.label({
      text = snap.badge or "Unknown",
      fontSize = 11,
      fontWeight = "bold",
      color = overallColor,
    }),
    ui.button({
      key = "btn_close",
      glyph = "x",
      controlSize = "sm",
      variant = "ghost",
      tooltip = "Close",
      onClick = function()
        panel.close()
      end,
    }),
  })

  local rows = {}
  if not snap.script_exists then
    table.insert(rows, ui.row({
      key = "not_configured_row",
      align = "center",
      gap = 8,
      paddingH = 10,
      paddingV = 8,
      radius = 8,
    }, {
      ui.glyph({ name = "alert-circle", size = 15, color = "on_surface_variant" }),
      ui.label({
        text = "sync-projects script not found at " .. (snap.script_path or "~/.local/bin/sync-projects"),
        fontSize = 11,
        color = "on_surface_variant",
        flexGrow = 1,
      }),
    }))
  elseif #targets == 0 then
    table.insert(rows, ui.label({
      key = "empty_targets",
      text = "No rsync targets configured",
      fontSize = 12,
      color = "on_surface_variant",
    }))
  else
    for idx, target in ipairs(targets) do
      table.insert(rows, targetRow(target, idx))
    end
  end

  local targetsCard = ui.column({
    key = "targets_card",
    gap = 2,
    padding = 6,
    radius = 12,
    fill = "surface_container",
  }, rows)

  local canSync = snap.can_sync == true
  local syncTooltip = "Run sync-projects now"
  if not snap.script_exists then
    syncTooltip = "sync-projects script not found on this host"
  elseif snap.syncing then
    syncTooltip = "Rsync is currently running"
  elseif not snap.disk_mounted then
    syncTooltip = "Mount backup disk at " .. (snap.target_root or "target") .. " first"
  end

  local actionsRow = ui.row({ key = "actions_row", gap = 8, align = "center" }, {
    ui.button({
      key = "btn_sync_now",
      text = snap.syncing and "Syncing..." or "Sync Now",
      glyph = snap.syncing and "loader-2" or "player-play",
      variant = "primary",
      controlSize = "sm",
      flexGrow = 1,
      enabled = canSync,
      tooltip = syncTooltip,
      onClick = function()
        triggerSync(false)
      end,
    }),
    ui.button({
      key = "btn_dry_run",
      text = "Dry Run",
      glyph = "eye",
      variant = "secondary",
      controlSize = "sm",
      enabled = canSync,
      tooltip = canSync and "Preview changes without modifying files" or syncTooltip,
      onClick = function()
        triggerSync(true)
      end,
    }),
    ui.button({
      key = "btn_open_log",
      text = "Log",
      glyph = "file-text",
      variant = "secondary",
      controlSize = "sm",
      enabled = snap.log_exists == true,
      tooltip = snap.log_exists and "Open sync-projects.log" or "No log file yet",
      onClick = function()
        openLog()
      end,
    }),
    ui.button({
      key = "btn_refresh",
      glyph = "refresh",
      variant = "ghost",
      controlSize = "sm",
      tooltip = "Refresh status",
      onClick = function()
        refreshSnapshot()
      end,
    }),
  })

  local children = { headerRow, diskBanner(snap), targetsCard }
  if actionMessage ~= "" then
    table.insert(children, ui.label({
      key = "action_msg",
      text = actionMessage,
      fontSize = 11,
      color = "primary",
    }))
  elseif type(snap.last_run_text) == "string" and snap.last_run_text ~= "" then
    table.insert(children, ui.label({
      key = "last_run_footer",
      text = snap.last_run_text,
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 1,
    }))
  end
  table.insert(children, actionsRow)

  panel.render(ui.column({ key = "rsync_panel_root", gap = 10, padding = 12 }, children))
end

noctalia.state.watch("snapshot", function(value)
  if type(value) == "table" then
    current = value
    if isOpen then
      render()
    end
  end
end)

function onOpen(_context)
  isOpen = true
  actionMessage = ""
  local latest = noctalia.state.get("snapshot")
  if type(latest) == "table" then
    current = latest
  end
  render()
  refreshSnapshot()
end

function onClose()
  isOpen = false
end

function onConfigChanged()
  if isOpen then
    render()
  end
end
