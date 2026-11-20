--!nonstrict
-- Dropdown panel for viewing per-target rsync statuses and configuring rsync targets/excludes graphically.

local common = require("./common.luau")

local current = noctalia.state.get("snapshot") or common.DEFAULT_SNAPSHOT
local isOpen = false
local viewMode = "list" -- "list" | "edit" | "settings"
local actionMessage = ""
local editDraft = nil
local settingsDraft = nil

local function syncDraftState()
  noctalia.state.set("panel_ui", {
    viewMode = viewMode,
    editDraft = editDraft,
    settingsDraft = settingsDraft,
  })
end

local function restoreDraftState()
  local saved = noctalia.state.get("panel_ui")
  if type(saved) == "table" then
    if saved.viewMode == "edit" or saved.viewMode == "settings" or saved.viewMode == "list" then
      viewMode = saved.viewMode
    end
    if type(saved.editDraft) == "table" then
      editDraft = saved.editDraft
    end
    if type(saved.settingsDraft) == "table" then
      settingsDraft = saved.settingsDraft
    end
  end
end

local function applySnapshotResponse(res)
  if res and res.exitCode == 0 and res.stdout and res.stdout ~= "" then
    local data = noctalia.json.decode(res.stdout)
    if type(data) == "table" then
      current = data
      noctalia.state.set("snapshot", data)
      return true
    end
  end
  return false
end

local function refreshSnapshot()
  local argv = common.helperArgv({ "status" })
  if argv == nil then
    return
  end
  noctalia.runAsync(argv, function(res)
    if applySnapshotResponse(res) and isOpen then
      render()
    end
  end)
end

local function runHelperAndReload(args, busyMsg: string?, onDone)
  local argv = common.helperArgv(args)
  if argv == nil then
    actionMessage = "noctalia-rsync-status helper not found"
    if isOpen then render() end
    return
  end
  if busyMsg and busyMsg ~= "" then
    actionMessage = busyMsg
    if isOpen then render() end
  end
  noctalia.runAsync(argv, function(res)
    if res and res.exitCode == 0 then
      actionMessage = ""
      applySnapshotResponse(res)
      if onDone then onDone(true) end
    else
      actionMessage = "Operation failed"
      if onDone then onDone(false) end
    end
    if isOpen then render() end
  end)
end

local function triggerSync(dryRun: boolean, targetId: string?)
  local args = { "trigger" }
  if dryRun then
    table.insert(args, "--dry-run")
  end
  if targetId and targetId ~= "" then
    table.insert(args, "--target")
    table.insert(args, targetId)
  end
  local msg = dryRun and "Starting dry run..." or "Starting rsync..."
  runHelperAndReload(args, msg, function(ok)
    if ok then
      refreshSnapshot()
    end
  end)
end

local function pickFolderInto(field: string)
  local initial = ""
  if viewMode == "edit" and type(editDraft) == "table" then
    initial = tostring(editDraft[field] or "~")
  elseif viewMode == "settings" and type(settingsDraft) == "table" then
    initial = tostring(settingsDraft.target_root or "~")
  end
  local argv = common.helperArgv({ "pick-folder", "--initial", initial })
  if argv == nil then
    return
  end
  syncDraftState()
  noctalia.runAsync(argv, function(res)
    if res and res.exitCode == 0 and res.stdout then
      local chosen = noctalia.string.trim(res.stdout)
      if chosen ~= "" then
        if viewMode == "edit" and type(editDraft) == "table" then
          editDraft[field] = chosen
          editDraft.rev = (editDraft.rev or 0) + 1
        elseif viewMode == "settings" and type(settingsDraft) == "table" then
          settingsDraft.target_root = chosen
          settingsDraft.rev = (settingsDraft.rev or 0) + 1
        end
        syncDraftState()
      end
    end
    if not isOpen then
      noctalia.togglePanel(common.PANEL_ID)
    else
      render()
    end
  end, 60000)
end

local function openEdit(target)
  if target == nil then
    editDraft = {
      orig_id = "",
      name = "",
      source = "",
      dest = "",
      enabled = true,
      delete = true,
      excludesText = "",
      rev = 1,
    }
  else
    local exList = type(target.excludes) == "table" and target.excludes or {}
    editDraft = {
      orig_id = target.id or "",
      name = target.name or "",
      source = target.source or "",
      dest = target.dest or "",
      enabled = target.enabled ~= false,
      delete = target.delete ~= false,
      excludesText = table.concat(exList, ", "),
      rev = 1,
    }
  end
  viewMode = "edit"
  actionMessage = ""
  syncDraftState()
  render()
end

local function openSettings(snap)
  local exList = type(snap.excludes) == "table" and snap.excludes or {}
  settingsDraft = {
    target_root = snap.target_root_raw or snap.target_root or "",
    excludesText = table.concat(exList, "\n"),
    rev = 1,
  }
  viewMode = "settings"
  actionMessage = ""
  syncDraftState()
  render()
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
    paddingV = 7,
    radius = 10,
    fill = "surface_container",
    tooltip = "Default destination root: " .. targetText,
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
  local tid = target.id or tostring(index)

  return ui.row({
    key = "target_" .. tid,
    align = "center",
    gap = 6,
    paddingH = 8,
    paddingV = 5,
    radius = 8,
    fill = rowFill,
    tooltip = target.tooltip or ((target.source or "") .. " -> " .. (target.dest or "")),
  }, {
    ui.glyph({ name = common.targetGlyph(tState), size = 15, color = tColor }),
    ui.label({
      text = target.name or ("Target " .. tostring(index)),
      fontSize = 12,
      fontWeight = "medium",
      color = target.enabled == false and "on_surface_variant" or "on_surface",
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
    ui.button({
      key = "btn_run_" .. tid,
      glyph = "player-play",
      glyphSize = 13,
      controlSize = "sm",
      variant = "ghost",
      enabled = target.can_run == true,
      tooltip = target.can_run and ("Run rsync for " .. (target.name or tid)) or "Unavailable right now",
      onClick = function()
        triggerSync(false, tid)
      end,
    }),
    ui.button({
      key = "btn_edit_" .. tid,
      glyph = "pencil",
      glyphSize = 13,
      controlSize = "sm",
      variant = "ghost",
      tooltip = "Edit target",
      onClick = function()
        openEdit(target)
      end,
    }),
  })
end

local function renderListView(snap)
  local targets = type(snap.targets) == "table" and snap.targets or {}
  local rows = {}
  if #targets == 0 then
    table.insert(rows, ui.row({
      key = "empty_targets",
      align = "center",
      gap = 8,
      paddingH = 10,
      paddingV = 10,
    }, {
      ui.glyph({ name = "folder-off", size = 15, color = "on_surface_variant" }),
      ui.label({
        text = "No rsync targets configured. Click + Add to create one.",
        fontSize = 12,
        color = "on_surface_variant",
        flexGrow = 1,
      }),
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
  local syncTooltip = "Sync all enabled targets"
  if not snap.configured then
    syncTooltip = "Add at least one rsync target first"
  elseif snap.syncing then
    syncTooltip = "Rsync is currently running"
  elseif not canSync then
    syncTooltip = "Mount backup disk at " .. (snap.target_root or "target") .. " first"
  end

  local actionsRow = ui.row({ key = "actions_row", gap = 6, align = "center" }, {
    ui.button({
      key = "btn_sync_now",
      text = snap.syncing and "Syncing..." or "Sync All",
      glyph = snap.syncing and "loader-2" or "player-play",
      variant = "primary",
      controlSize = "sm",
      flexGrow = 1,
      enabled = canSync,
      tooltip = syncTooltip,
      onClick = function()
        triggerSync(false, nil)
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
        triggerSync(true, nil)
      end,
    }),
    ui.button({
      key = "btn_add_target",
      text = "Add",
      glyph = "plus",
      variant = "secondary",
      controlSize = "sm",
      tooltip = "Add a new rsync folder pair",
      onClick = function()
        openEdit(nil)
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
        local argv = common.helperArgv({ "open-log" })
        if argv ~= nil then
          noctalia.runAsync(argv)
        end
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

  local children = { diskBanner(snap), targetsCard }
  if actionMessage ~= "" then
    table.insert(children, ui.label({ key = "action_msg", text = actionMessage, fontSize = 11, color = "primary" }))
  elseif type(snap.last_run_text) == "string" and snap.last_run_text ~= "" then
    table.insert(children, ui.label({ key = "last_run_footer", text = snap.last_run_text, fontSize = 10, color = "on_surface_variant", maxLines = 1 }))
  end
  table.insert(children, actionsRow)
  return children
end

local function renderEditView()
  local d = editDraft or { orig_id = "", name = "", source = "", dest = "", enabled = true, delete = true, excludesText = "", rev = 1 }
  local rev = tostring(d.rev or 1)
  local isEditing = d.orig_id ~= nil and d.orig_id ~= ""

  local form = ui.column({ key = "edit_card", gap = 8, padding = 10, radius = 12, fill = "surface_container" }, {
    ui.label({
      text = isEditing and ("Edit Target: " .. d.name) or "New Rsync Target",
      fontSize = 13,
      fontWeight = "bold",
      color = "primary",
    }),
    ui.column({ gap = 3 }, {
      ui.label({ text = "Name", fontSize = 11, color = "on_surface_variant" }),
      ui.input({
        key = "inp_name_" .. rev,
        value = d.name,
        placeholder = "e.g. Projects",
        controlSize = "sm",
        onChange = function(val)
          d.name = val
          syncDraftState()
        end,
      }),
    }),
    ui.column({ gap = 3 }, {
      ui.label({ text = "Source Directory", fontSize = 11, color = "on_surface_variant" }),
      ui.row({ gap = 6, align = "center" }, {
        ui.input({
          key = "inp_src_" .. rev,
          value = d.source,
          placeholder = "/home/thinky/Folder",
          controlSize = "sm",
          flexGrow = 1,
          onChange = function(val)
            d.source = val
            syncDraftState()
          end,
        }),
        ui.button({
          key = "btn_browse_src",
          glyph = "folder",
          text = "Browse",
          controlSize = "sm",
          variant = "secondary",
          onClick = function()
            pickFolderInto("source")
          end,
        }),
      }),
    }),
    ui.column({ gap = 3 }, {
      ui.label({ text = "Destination (relative to target root, /abs/path, or user@host:/path)", fontSize = 11, color = "on_surface_variant" }),
      ui.row({ gap = 6, align = "center" }, {
        ui.input({
          key = "inp_dest_" .. rev,
          value = d.dest,
          placeholder = "Folder or /mnt/backup/Folder",
          controlSize = "sm",
          flexGrow = 1,
          onChange = function(val)
            d.dest = val
            syncDraftState()
          end,
        }),
        ui.button({
          key = "btn_browse_dest",
          glyph = "folder",
          text = "Browse",
          controlSize = "sm",
          variant = "secondary",
          onClick = function()
            pickFolderInto("dest")
          end,
        }),
      }),
    }),
    ui.row({ align = "center", justify = "space_between", gap = 12 }, {
      ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = "Enabled", fontSize = 12 }),
        ui.toggle({
          key = "tog_enabled_" .. rev,
          checked = d.enabled == true,
          onChange = function(v)
            d.enabled = (v == true or v == "true")
            syncDraftState()
          end,
        }),
      }),
      ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = "Mirror (--delete)", fontSize = 12 }),
        ui.toggle({
          key = "tog_delete_" .. rev,
          checked = d.delete == true,
          onChange = function(v)
            d.delete = (v == true or v == "true")
            syncDraftState()
          end,
        }),
      }),
    }),
    ui.column({ gap = 3 }, {
      ui.label({ text = "Extra Excludes (comma-separated)", fontSize = 11, color = "on_surface_variant" }),
      ui.input({
        key = "inp_ex_" .. rev,
        value = d.excludesText,
        placeholder = "*.tmp, build/",
        controlSize = "sm",
        onChange = function(val)
          d.excludesText = val
          syncDraftState()
        end,
      }),
    }),
  })

  local buttonBarChildren = {}
  if isEditing then
    table.insert(buttonBarChildren, ui.button({
      key = "btn_up",
      glyph = "arrow-up",
      controlSize = "sm",
      variant = "ghost",
      tooltip = "Move Up",
      onClick = function()
        runHelperAndReload({ "move-target", "--id", d.orig_id, "--dir", "up" }, nil, nil)
      end,
    }))
    table.insert(buttonBarChildren, ui.button({
      key = "btn_down",
      glyph = "arrow-down",
      controlSize = "sm",
      variant = "ghost",
      tooltip = "Move Down",
      onClick = function()
        runHelperAndReload({ "move-target", "--id", d.orig_id, "--dir", "down" }, nil, nil)
      end,
    }))
    table.insert(buttonBarChildren, ui.button({
      key = "btn_delete_target",
      text = "Delete",
      glyph = "trash",
      controlSize = "sm",
      variant = "destructive",
      onClick = function()
        runHelperAndReload({ "delete-target", "--id", d.orig_id }, "Removing...", function(ok)
          if ok then
            viewMode = "list"
            editDraft = nil
            syncDraftState()
          end
        end)
      end,
    }))
  end
  table.insert(buttonBarChildren, ui.spacer({ flexGrow = 1 }))
  table.insert(buttonBarChildren, ui.button({
    key = "btn_cancel_edit",
    text = "Cancel",
    controlSize = "sm",
    variant = "ghost",
    onClick = function()
      viewMode = "list"
      editDraft = nil
      actionMessage = ""
      syncDraftState()
      render()
    end,
  }))
  table.insert(buttonBarChildren, ui.button({
    key = "btn_save_target",
    text = "Save",
    glyph = "check",
    controlSize = "sm",
    variant = "primary",
    onClick = function()
      if noctalia.string.trim(d.source or "") == "" then
        actionMessage = "Source Directory is required"
        render()
        return
      end
      local encoded = noctalia.json.encode({
        orig_id = d.orig_id,
        name = d.name,
        source = d.source,
        dest = d.dest,
        enabled = d.enabled,
        delete = d.delete,
        excludes = d.excludesText,
      })
      runHelperAndReload({ "save-target", "--json", encoded }, "Saving...", function(ok)
        if ok then
          viewMode = "list"
          editDraft = nil
          syncDraftState()
        end
      end)
    end,
  }))

  local children = { form }
  if actionMessage ~= "" then
    table.insert(children, ui.label({ key = "edit_err", text = actionMessage, fontSize = 11, color = "error" }))
  end
  table.insert(children, ui.row({ key = "edit_buttons", gap = 6, align = "center" }, buttonBarChildren))
  return children
end

local function renderSettingsView()
  local d = settingsDraft or { target_root = "", excludesText = "", rev = 1 }
  local rev = tostring(d.rev or 1)

  local form = ui.column({ key = "settings_card", gap = 8, padding = 10, radius = 12, fill = "surface_container" }, {
    ui.label({ text = "Global Rsync Settings", fontSize = 13, fontWeight = "bold", color = "primary" }),
    ui.column({ gap = 3 }, {
      ui.label({ text = "Default Target Root (for relative destinations)", fontSize = 11, color = "on_surface_variant" }),
      ui.row({ gap = 6, align = "center" }, {
        ui.input({
          key = "inp_root_" .. rev,
          value = d.target_root,
          placeholder = "/run/media/thinky/nixos/home/thinky",
          controlSize = "sm",
          flexGrow = 1,
          onChange = function(val)
            d.target_root = val
            syncDraftState()
          end,
        }),
        ui.button({
          key = "btn_browse_root",
          glyph = "folder",
          text = "Browse",
          controlSize = "sm",
          variant = "secondary",
          onClick = function()
            pickFolderInto("target_root")
          end,
        }),
      }),
    }),
    ui.column({ gap = 3 }, {
      ui.label({ text = "Shared Exclude Patterns (one per line)", fontSize = 11, color = "on_surface_variant" }),
      ui.input({
        key = "inp_global_ex_" .. rev,
        value = d.excludesText,
        multiline = true,
        height = 140,
        onChange = function(val)
          d.excludesText = val
          syncDraftState()
        end,
      }),
    }),
  })

  local buttons = ui.row({ key = "settings_buttons", gap = 6, align = "center" }, {
    ui.button({
      key = "btn_reset_defaults",
      text = "Reset Defaults",
      glyph = "rotate-ccw",
      controlSize = "sm",
      variant = "secondary",
      onClick = function()
        runHelperAndReload({ "reset-defaults" }, "Resetting...", function(ok)
          if ok then
            viewMode = "list"
            settingsDraft = nil
            syncDraftState()
          end
        end)
      end,
    }),
    ui.spacer({ flexGrow = 1 }),
    ui.button({
      key = "btn_back_settings",
      text = "Back",
      controlSize = "sm",
      variant = "ghost",
      onClick = function()
        viewMode = "list"
        settingsDraft = nil
        actionMessage = ""
        syncDraftState()
        render()
      end,
    }),
    ui.button({
      key = "btn_save_settings",
      text = "Save",
      glyph = "check",
      controlSize = "sm",
      variant = "primary",
      onClick = function()
        local encoded = noctalia.json.encode({
          target_root = d.target_root,
          excludes = d.excludesText,
        })
        runHelperAndReload({ "save-settings", "--json", encoded }, "Saving...", function(ok)
          if ok then
            viewMode = "list"
            settingsDraft = nil
            syncDraftState()
          end
        end)
      end,
    }),
  })

  local children = { form }
  if actionMessage ~= "" then
    table.insert(children, ui.label({ key = "settings_msg", text = actionMessage, fontSize = 11, color = "error" }))
  end
  table.insert(children, buttons)
  return children
end

function render()
  local snap = current or common.DEFAULT_SNAPSHOT
  local overallColor = common.stateColor(snap.state)

  local headerRow = ui.row({ key = "header_row", align = "center", gap = 6 }, {
    ui.glyph({ name = common.barGlyph(snap.state), size = 18, color = overallColor }),
    ui.label({
      text = "Rsync Control",
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
      key = "btn_open_rclone",
      text = "Rclone",
      glyph = "cloud",
      controlSize = "sm",
      variant = "secondary",
      tooltip = "Open Rclone Control GUI",
      onClick = function()
        local argv = common.helperArgv({ "open-rclone" })
        if argv ~= nil then
          noctalia.runAsync(argv)
        end
      end,
    }),
    ui.button({
      key = "btn_settings",
      glyph = "settings",
      controlSize = "sm",
      variant = viewMode == "settings" and "primary" or "ghost",
      tooltip = "Global rsync target root & excludes",
      onClick = function()
        if viewMode == "settings" then
          viewMode = "list"
          settingsDraft = nil
          syncDraftState()
          render()
        else
          openSettings(snap)
        end
      end,
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

  local bodyChildren
  if viewMode == "edit" then
    bodyChildren = renderEditView()
  elseif viewMode == "settings" then
    bodyChildren = renderSettingsView()
  else
    bodyChildren = renderListView(snap)
  end

  local rootChildren = { headerRow }
  for _, child in ipairs(bodyChildren) do
    table.insert(rootChildren, child)
  end

  panel.render(ui.scroll({ key = "rsync_panel_scroll", flexGrow = 1, gap = 10, padding = 12 }, rootChildren))
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
  restoreDraftState()
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
