--!nonstrict
-- Dropdown for the restic backup: what it is doing, Run now / Stop / Browse / Log,
-- and a Settings view for the daily time, pause, retention, extra folders and excludes.
-- Everything goes through the `backup-pool` helper (scripts/backup-pool.py).

local common = require("./common.luau")

local current = noctalia.state.get("snapshot") or common.DEFAULT_SNAPSHOT
local isOpen = false
local viewMode = "status" -- "status" | "settings"
local actionMessage = ""
local actionIsError = false
local draft = nil

local function syncDraftState()
  noctalia.state.set("panel_ui", { viewMode = viewMode, draft = draft })
end

local function restoreDraftState()
  local saved = noctalia.state.get("panel_ui")
  if type(saved) == "table" then
    if saved.viewMode == "status" or saved.viewMode == "settings" then
      viewMode = saved.viewMode
    end
    if type(saved.draft) == "table" then
      draft = saved.draft
    end
  end
end

local function adopt(data)
  if type(data) == "table" and data.state ~= nil then
    current = data
    noctalia.state.set("snapshot", data)
    return true
  end
  return false
end

local function refreshSnapshot()
  local argv = common.helperArgv({ "status" })
  if argv == nil then
    return
  end
  noctalia.runAsync(argv, function(res)
    if adopt(common.decode(res)) and isOpen then
      render()
    end
  end)
end

local function setMessage(text: string, isError: boolean)
  actionMessage = text
  actionIsError = isError
end

-- Run the helper; it answers with the new snapshot, plus action_error when it failed.
local function runHelper(args, busyMsg: string?, onDone, timeoutMs: number?)
  local argv = common.helperArgv(args)
  if argv == nil then
    setMessage("backup-pool helper not found", true)
    if isOpen then render() end
    return
  end
  if busyMsg and busyMsg ~= "" then
    setMessage(busyMsg, false)
    if isOpen then render() end
  end
  noctalia.runAsync(argv, function(res)
    local data = common.decode(res)
    adopt(data)
    local ok = res ~= nil and res.exitCode == 0
    if ok then
      setMessage("", false)
    else
      setMessage((data and data.action_error) or "That did not work; see the log", true)
    end
    if onDone then onDone(ok) end
    if isOpen then render() end
  end, timeoutMs)
end

local function joinLines(list)
  if type(list) ~= "table" then
    return ""
  end
  return table.concat(list, "\n")
end

local function makeDraft(snap)
  local s = type(snap.settings) == "table" and snap.settings or {}
  local keep = type(s.keep) == "table" and s.keep or {}
  return {
    time = s.time or "12:30",
    paused = s.paused == true,
    keep_daily = tostring(keep.daily or 7),
    keep_weekly = tostring(keep.weekly or 4),
    keep_monthly = tostring(keep.monthly or 6),
    extra_paths = joinLines(s.extra_paths),
    extra_excludes = joinLines(s.extra_excludes),
    rev = ((draft and draft.rev) or 0) + 1,
  }
end

local function openSettings(snap)
  draft = makeDraft(snap)
  viewMode = "settings"
  setMessage("", false)
  syncDraftState()
  render()
end

local function closeSettings()
  viewMode = "status"
  draft = nil
  setMessage("", false)
  syncDraftState()
  render()
end

local function addFolder()
  if draft == nil then
    return
  end
  local argv = common.helperArgv({ "pick-folder", "--initial", "~" })
  if argv == nil then
    return
  end
  syncDraftState()
  noctalia.runAsync(argv, function(res)
    if res and res.exitCode == 0 and res.stdout and draft ~= nil then
      local chosen = noctalia.string.trim(res.stdout)
      if chosen ~= "" then
        local text = noctalia.string.trim(draft.extra_paths or "")
        draft.extra_paths = text == "" and chosen or (text .. "\n" .. chosen)
        draft.rev = (draft.rev or 0) + 1 -- new keys: the inputs take the new text
        syncDraftState()
      end
    end
    if not isOpen then
      noctalia.togglePanel(common.PANEL_ID)
    else
      render()
    end
  end, 120000)
end

-- ------------------------------------------------------------------ status --

local function infoRow(key: string, label: string, value: string?, color: string?)
  return ui.row({ key = key, gap = 8, align = "start" }, {
    ui.label({ text = label, fontSize = 11, color = "on_surface_variant", width = 120 }),
    ui.label({ text = value or "—", fontSize = 11, color = color or "on_surface", flexGrow = 1, maxLines = 3 }),
  })
end

local function statusCard(snap)
  local color = common.stateColor(snap.state)
  local children = {
    ui.row({ key = "status_line", gap = 8, align = "center" }, {
      ui.glyph({ name = common.barGlyph(snap.state), size = 18, color = color }),
      ui.label({ text = snap.summary or "", fontSize = 13, fontWeight = "bold", color = color, flexGrow = 1, maxLines = 2 }),
    }),
  }
  if snap.state == "running" or snap.state == "stalled" then
    if type(snap.percent) == "number" then
      table.insert(children, ui.progress({ key = "progress_bar", progress = snap.percent / 100, height = 6, radius = 3, fill = color }))
    end
    if snap.progress_text and snap.progress_text ~= "" then
      table.insert(children, ui.label({ key = "progress_text", text = snap.progress_text, fontSize = 11, color = "on_surface_variant", maxLines = 1 }))
    end
  end
  return ui.column({ key = "status_card", gap = 6, padding = 10, radius = 12, fill = "surface_container" }, children)
end

local function detailsCard(snap)
  local last = snap.last_success_text or "never"
  if snap.last_added and snap.last_added ~= "" then
    last = last .. " · added " .. snap.last_added
  end
  local snaps = "—"
  if type(snap.snapshots) == "number" then
    snaps = tostring(snap.snapshots) .. " (newest " .. (snap.latest_text or "—") .. ", " .. (snap.latest_size_text or "—") .. ")"
  end
  local disk = (snap.disk_label or "Backup disk") .. (snap.disk_present and " · plugged in" or " · unplugged")
  local rows = {
    infoRow("info_last", "Last backup", last),
    infoRow("info_next", "Next", snap.next_text),
    infoRow("info_snapshots", "Snapshots", snaps),
    infoRow("info_stored", "Stored", (snap.stored_text or "—") .. " on the disk, " .. (snap.disk_free_text or "—") .. " free"),
    infoRow("info_disk", "Disk", disk, snap.disk_present and "on_surface" or "on_surface_variant"),
  }
  if type(snap.last_warnings) == "number" and snap.last_warnings > 0 then
    local text = tostring(snap.last_warnings) .. " file(s) could not be read"
    local lines = snap.last_warning_lines
    if type(lines) == "table" and #lines > 0 then
      text = text .. ": " .. table.concat(lines, "; ")
    end
    table.insert(rows, infoRow("info_warnings", "Warnings", text, "tertiary"))
  end
  if snap.prune_failed then
    local why = (type(snap.prune_note) == "string" and snap.prune_note ~= "") and (" (" .. snap.prune_note .. ")") or ""
    table.insert(rows, infoRow("info_prune", "Old snapshots", "not removed last time" .. why .. "; retried next run", "tertiary"))
  end
  if type(snap.settings_errors) == "table" and #snap.settings_errors > 0 then
    table.insert(rows, infoRow("info_settings_errors", "Settings", table.concat(snap.settings_errors, "; ") .. " (default used)", "error"))
  end
  return ui.column({ key = "details_card", gap = 4, padding = 10, radius = 12, fill = "surface_container" }, rows)
end

local function renderStatusView(snap)
  local running = snap.running == true
  local actions = {}
  if running then
    table.insert(actions, ui.button({
      key = "btn_stop",
      text = "Stop",
      glyph = "player-stop",
      variant = "destructive",
      controlSize = "sm",
      flexGrow = 1,
      enabled = snap.can_stop == true,
      tooltip = "Stop the backup; the next one starts over from where the last snapshot left off",
      onClick = function()
        runHelper({ "stop" }, "Stopping...")
      end,
    }))
  else
    table.insert(actions, ui.button({
      key = "btn_run",
      text = "Run now",
      glyph = "player-play",
      variant = "primary",
      controlSize = "sm",
      flexGrow = 1,
      enabled = snap.can_run == true,
      tooltip = snap.can_run and "Back up now (also while paused)" or ((snap.disk_label or "The backup disk") .. " is not plugged in"),
      onClick = function()
        runHelper({ "run" }, "Starting the backup...")
      end,
    }))
  end
  if snap.browsing then
    table.insert(actions, ui.button({
      key = "btn_browse_stop",
      text = "Close browse",
      glyph = "folder-x",
      variant = "secondary",
      controlSize = "sm",
      tooltip = "Close the read-only view of the backups",
      onClick = function()
        runHelper({ "browse-stop" }, "Closing...")
      end,
    }))
  else
    table.insert(actions, ui.button({
      key = "btn_browse",
      text = "Browse",
      glyph = "folder-open",
      variant = "secondary",
      controlSize = "sm",
      enabled = snap.can_browse == true,
      tooltip = "Open every snapshot read-only in the file manager; copy out what you need. Closes itself after 4 h.",
      onClick = function()
        runHelper({ "browse-start" }, "Opening the backups (reading the index)...", nil, 90000)
      end,
    }))
  end
  table.insert(actions, ui.button({
    key = "btn_log",
    text = "Log",
    glyph = "file-text",
    variant = "secondary",
    controlSize = "sm",
    tooltip = "Follow the backup's journal in a terminal",
    onClick = function()
      local argv = common.helperArgv({ "open-log" })
      if argv ~= nil then
        noctalia.runAsync(argv)
      end
    end,
  }))
  table.insert(actions, ui.button({
    key = "btn_refresh",
    glyph = "refresh",
    variant = "ghost",
    controlSize = "sm",
    tooltip = "Refresh",
    onClick = function()
      refreshSnapshot()
    end,
  }))

  local children = { statusCard(snap), detailsCard(snap) }
  if actionMessage ~= "" then
    table.insert(children, ui.label({ key = "action_msg", text = actionMessage, fontSize = 11, color = actionIsError and "error" or "primary", maxLines = 3 }))
  end
  table.insert(children, ui.row({ key = "actions_row", gap = 6, align = "center" }, actions))
  return children
end

-- ---------------------------------------------------------------- settings --

local function field(label: string, child)
  return ui.column({ gap = 3 }, {
    ui.label({ text = label, fontSize = 11, color = "on_surface_variant" }),
    child,
  })
end

local function keepInput(d, kind: string, label: string, rev: string)
  return ui.column({ gap = 3, flexGrow = 1 }, {
    ui.label({ text = label, fontSize = 11, color = "on_surface_variant" }),
    ui.input({
      key = "inp_keep_" .. kind .. "_" .. rev,
      value = d["keep_" .. kind],
      controlSize = "sm",
      onChange = function(val)
        d["keep_" .. kind] = val
        syncDraftState()
      end,
    }),
  })
end

local function renderSettingsView(snap)
  if draft == nil then
    draft = makeDraft(snap)
  end
  local d = draft
  local rev = tostring(d.rev or 1)
  local defaults = type(snap.defaults) == "table" and snap.defaults or {}
  local dk = type(defaults.keep) == "table" and defaults.keep or {}

  local form = ui.column({ key = "settings_card", gap = 10, padding = 10, radius = 12, fill = "surface_container" }, {
    ui.row({ gap = 12, align = "end" }, {
      ui.column({ gap = 3, flexGrow = 1 }, {
        ui.label({ text = "Daily at (HH:MM, 24 h)", fontSize = 11, color = "on_surface_variant" }),
        ui.input({
          key = "inp_time_" .. rev,
          value = d.time,
          placeholder = defaults.time or "12:30",
          controlSize = "sm",
          onChange = function(val)
            d.time = val
            syncDraftState()
          end,
        }),
      }),
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = "Paused", fontSize = 12 }),
        ui.toggle({
          key = "tog_paused",
          checked = d.paused == true,
          onChange = function(v)
            d.paused = (v == true or v == "true")
            syncDraftState()
            render()
          end,
        }),
      }),
    }),
    ui.label({
      text = "Missed days (machine off, disk unplugged) run as soon as they can.",
      fontSize = 10,
      color = "on_surface_variant",
    }),
    field("Snapshots to keep (defaults " .. tostring(dk.daily or 7) .. " / " .. tostring(dk.weekly or 4) .. " / " .. tostring(dk.monthly or 6) .. "; 0 = none of that kind)",
      ui.row({ gap = 8 }, {
        keepInput(d, "daily", "Daily", rev),
        keepInput(d, "weekly", "Weekly", rev),
        keepInput(d, "monthly", "Monthly", rev),
      })),
    field("Extra folders to back up (one per line)", ui.column({ gap = 6 }, {
      ui.input({
        key = "inp_paths_" .. rev,
        value = d.extra_paths,
        multiline = true,
        height = 70,
        placeholder = "/home/thinky/VMs",
        onChange = function(val)
          d.extra_paths = val
          syncDraftState()
        end,
      }),
      ui.row({ gap = 6 }, {
        ui.spacer({ flexGrow = 1 }),
        ui.button({
          key = "btn_add_folder",
          text = "Add folder",
          glyph = "folder-plus",
          controlSize = "sm",
          variant = "secondary",
          onClick = function()
            addFolder()
          end,
        }),
      }),
    })),
    field("Extra patterns to leave out (one per line, restic --exclude)", ui.input({
      key = "inp_excludes_" .. rev,
      value = d.extra_excludes,
      multiline = true,
      height = 70,
      placeholder = "*.iso\n/home/thinky/Downloads",
      onChange = function(val)
        d.extra_excludes = val
        syncDraftState()
      end,
    })),
  })

  local fixed = ui.column({ key = "fixed_card", gap = 4, padding = 10, radius = 12, fill = "surface_container" }, {
    ui.label({ text = "Set in the NixOS config (hosts/M90aPro/backup.nix)", fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    infoRow("fixed_paths", "Always backed up", joinLines(snap.paths)),
    infoRow("fixed_excludes", "Always left out", joinLines(snap.excludes) .. "\ncaches (CACHEDIR.TAG), other filesystems"),
    infoRow("fixed_repo", "Repository", (snap.repository or "—") .. " on " .. (snap.disk_label or "the backup disk")),
  })

  local buttons = ui.row({ key = "settings_buttons", gap = 6, align = "center" }, {
    ui.button({
      key = "btn_reset",
      text = "Reset to defaults",
      glyph = "arrow-back-up",
      controlSize = "sm",
      variant = "secondary",
      tooltip = "Forget your changes: the NixOS defaults apply again",
      onClick = function()
        runHelper({ "reset-settings" }, "Resetting...", function(ok)
          if ok then
            closeSettings()
          end
        end)
      end,
    }),
    ui.spacer({ flexGrow = 1 }),
    ui.button({
      key = "btn_cancel",
      text = "Cancel",
      controlSize = "sm",
      variant = "ghost",
      onClick = function()
        closeSettings()
      end,
    }),
    ui.button({
      key = "btn_save",
      text = "Save",
      glyph = "check",
      controlSize = "sm",
      variant = "primary",
      tooltip = "Applies from the next backup; no rebuild needed",
      onClick = function()
        local encoded = noctalia.json.encode({
          time = d.time,
          paused = d.paused,
          keep_daily = d.keep_daily,
          keep_weekly = d.keep_weekly,
          keep_monthly = d.keep_monthly,
          extra_paths = d.extra_paths,
          extra_excludes = d.extra_excludes,
        })
        runHelper({ "save-settings", "--json", encoded }, "Saving...", function(ok)
          if ok then
            closeSettings()
            setMessage("Saved: applies from the next backup", false)
          end
        end)
      end,
    }),
  })

  local children = { form, fixed }
  if actionMessage ~= "" then
    table.insert(children, ui.label({ key = "settings_msg", text = actionMessage, fontSize = 11, color = actionIsError and "error" or "primary", maxLines = 3 }))
  end
  table.insert(children, buttons)
  return children
end

-- -------------------------------------------------------------------- root --

function render()
  local snap = current or common.DEFAULT_SNAPSHOT
  local color = common.stateColor(snap.state)

  if snap.available == false then
    panel.render(ui.column({ key = "unavailable", gap = 8, padding = 12 }, {
      ui.label({ text = "No backup is set up on this computer.", fontSize = 13 }),
    }))
    return
  end

  local header = ui.row({ key = "header_row", align = "center", gap = 6 }, {
    ui.glyph({ name = "database", size = 18, color = color }),
    ui.label({ text = "Backup", fontSize = 15, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
    ui.label({ text = snap.badge or "", fontSize = 11, fontWeight = "bold", color = color }),
    ui.button({
      key = "btn_settings",
      glyph = "settings",
      controlSize = "sm",
      variant = viewMode == "settings" and "primary" or "ghost",
      tooltip = "Daily time, pause, snapshots to keep, extra folders and excludes",
      onClick = function()
        if viewMode == "settings" then
          closeSettings()
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

  local body = viewMode == "settings" and renderSettingsView(snap) or renderStatusView(snap)
  local rootChildren = { header }
  for _, child in ipairs(body) do
    table.insert(rootChildren, child)
  end
  panel.render(ui.scroll({ key = "backup_panel_scroll", flexGrow = 1, gap = 10, padding = 12 }, rootChildren))
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
  setMessage("", false)
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
