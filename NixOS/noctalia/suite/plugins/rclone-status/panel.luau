--!nonstrict
-- Dropdown panel for monitoring rclone mounts/remotes and controlling or launching rclone-control.

local common = require("./common.luau")

local current = noctalia.state.get("snapshot") or common.DEFAULT_SNAPSHOT
local isOpen = false
local actionMessage = ""

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

local function runHelper(args, busyMsg: string?, closeAfter: boolean?)
  local argv = common.helperArgv(args)
  if argv == nil then
    actionMessage = "noctalia-rclone-status helper not found"
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
      if closeAfter then
        panel.close()
        return
      end
    else
      actionMessage = "Action failed"
    end
    if isOpen then
      render()
    end
  end)
end

local function openGui(opts)
  local args = { "open-gui" }
  if type(opts) == "table" then
    if type(opts.left) == "string" and opts.left ~= "" then
      table.insert(args, "--left")
      table.insert(args, opts.left)
    end
    if type(opts.right) == "string" and opts.right ~= "" then
      table.insert(args, "--right")
      table.insert(args, opts.right)
    end
    if type(opts.tab) == "string" and opts.tab ~= "" then
      table.insert(args, "--tab")
      table.insert(args, opts.tab)
    end
  end
  runHelper(args, nil, true)
end

local function mountRow(mount, idx)
  local mid = tostring(mount.id or idx)
  local state = tostring(mount.state or "inactive")
  local color = common.stateColor(state)
  local unit = tostring(mount.systemd_unit or "")
  local controls = {}

  if unit ~= "" then
    if mount.can_start == true then
      table.insert(controls, ui.button({
        key = "btn_start_" .. mid,
        glyph = "player-play",
        glyphSize = 13,
        controlSize = "sm",
        variant = "ghost",
        tooltip = "Start " .. unit,
        onClick = function()
          runHelper({ "mount-action", "--unit", unit, "--action", "start" }, "Starting " .. tostring(mount.label) .. "...")
        end,
      }))
    else
      table.insert(controls, ui.button({
        key = "btn_stop_" .. mid,
        glyph = "player-stop",
        glyphSize = 13,
        controlSize = "sm",
        variant = "ghost",
        tooltip = "Stop " .. unit,
        onClick = function()
          runHelper({ "mount-action", "--unit", unit, "--action", "stop" }, "Stopping " .. tostring(mount.label) .. "...")
        end,
      }))
    end
  elseif mount.can_unmount == true then
    table.insert(controls, ui.button({
      key = "btn_unmount_" .. mid,
      glyph = "plug-connected-x",
      glyphSize = 13,
      controlSize = "sm",
      variant = "ghost",
      tooltip = "Unmount FUSE path",
      onClick = function()
        runHelper({ "unmount", "--path", tostring(mount.mountpoint) }, "Unmounting " .. tostring(mount.mountpoint_short) .. "...")
      end,
    }))
  end

  table.insert(controls, ui.button({
    key = "btn_browse_mount_" .. mid,
    glyph = "folder",
    glyphSize = 13,
    controlSize = "sm",
    variant = "ghost",
    enabled = current.gui_available == true,
    tooltip = mount.is_mounted and ("Browse " .. tostring(mount.mountpoint_short) .. " in Rclone Control") or ("Inspect " .. tostring(mount.source) .. " in Rclone Control"),
    onClick = function()
      if mount.is_mounted == true and type(mount.mountpoint) == "string" and mount.mountpoint ~= "" then
        openGui({ left = mount.mountpoint })
      else
        openGui({ right = tostring(mount.source or ""), tab = "mounts" })
      end
    end,
  }))

  local rowChildren = {
    ui.glyph({ name = common.itemGlyph(state), size = 14, color = color }),
    ui.label({
      text = mount.label or mount.source or "Mount",
      fontSize = 12,
      fontWeight = "medium",
      flexGrow = 1,
      maxLines = 1,
      tooltip = (mount.source or "") .. " -> " .. (mount.mountpoint or ""),
    }),
    ui.label({
      text = mount.line_status or state,
      fontSize = 11,
      fontWeight = mount.is_mounted and "semibold" or nil,
      color = color,
      maxLines = 1,
    }),
  }
  for _, c in ipairs(controls) do
    table.insert(rowChildren, c)
  end

  return ui.row({
    key = "mount_" .. mid,
    align = "center",
    gap = 6,
    paddingH = 8,
    paddingV = 5,
    radius = 8,
    hoverable = true,
  }, rowChildren)
end

local function remoteRow(remote, idx)
  local rname = tostring(remote.name or ("remote_" .. tostring(idx)))
  local rtype = tostring(remote.type or "unknown")
  local isMounted = remote.mounted == true
  local color = isMounted and "secondary" or "tertiary"
  return ui.row({
    key = "remote_" .. rname,
    align = "center",
    gap = 6,
    paddingH = 8,
    paddingV = 5,
    radius = 8,
    hoverable = true,
  }, {
    ui.glyph({ name = isMounted and "plug-connected" or "cloud", size = 14, color = color }),
    ui.label({
      text = rname,
      fontSize = 12,
      fontWeight = "medium",
      flexGrow = 1,
      maxLines = 1,
      tooltip = rname .. " (" .. rtype .. ") -> " .. tostring(remote.target_summary or ""),
    }),
    ui.label({
      text = isMounted and (rtype .. " · Mounted") or rtype,
      fontSize = 11,
      color = isMounted and "secondary" or "on_surface_variant",
      maxLines = 1,
    }),
    ui.button({
      key = "btn_browse_remote_" .. rname,
      glyph = "external-link",
      glyphSize = 13,
      controlSize = "sm",
      variant = "ghost",
      enabled = current.gui_available == true,
      tooltip = "Browse " .. rname .. ": in Rclone Control",
      onClick = function()
        openGui({ right = rname .. ":" })
      end,
    }),
  })
end

function render()
  local snap = current
  local state = snap.state or "ready"
  local color = common.stateColor(state)

  local header = ui.row({ key = "header_row", align = "center", justify = "space_between", gap = 8 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = common.barGlyph(state), size = 16, color = color }),
      ui.label({ text = "Rclone Control", fontSize = 14, fontWeight = "bold" }),
    }),
    ui.row({ align = "center", gap = 6 }, {
      ui.label({
        key = "header_badge",
        text = snap.badge or "Ready",
        fontSize = 11,
        fontWeight = "semibold",
        color = color,
      }),
      ui.button({
        key = "btn_close",
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        tooltip = "Close panel",
        onClick = function()
          panel.close()
        end,
      }),
    }),
  })

  local banner = ui.row({
    key = "summary_banner",
    align = "center",
    gap = 8,
    paddingH = 10,
    paddingV = 6,
    radius = 8,
    fill = "surface_container",
  }, {
    ui.label({ text = snap.summary or "", fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
  })

  local mountRows = {}
  local mounts = type(snap.mounts) == "table" and snap.mounts or {}
  if #mounts == 0 then
    table.insert(mountRows, ui.label({
      key = "empty_mounts",
      text = "No active FUSE mounts or loaded mount units.",
      fontSize = 11,
      color = "on_surface_variant",
      paddingH = 8,
      paddingV = 6,
    }))
  else
    for i, m in ipairs(mounts) do
      table.insert(mountRows, mountRow(m, i))
    end
  end

  local mountsCard = ui.column({
    key = "mounts_card",
    gap = 2,
    padding = 6,
    radius = 12,
    fill = "surface_container",
  }, {
    ui.label({ text = "FUSE MOUNTS", fontSize = 10, fontWeight = "bold", color = "primary", paddingH = 8, paddingV = 2 }),
    table.unpack(mountRows),
  })

  local remoteRows = {}
  local remotes = type(snap.remotes) == "table" and snap.remotes or {}
  if #remotes == 0 then
    table.insert(remoteRows, ui.label({
      key = "empty_remotes",
      text = "No remotes found in rclone.conf. Open Rclone Control to add one.",
      fontSize = 11,
      color = "on_surface_variant",
      paddingH = 8,
      paddingV = 6,
    }))
  else
    for i, r in ipairs(remotes) do
      table.insert(remoteRows, remoteRow(r, i))
    end
  end

  local remotesCard = ui.column({
    key = "remotes_card",
    gap = 2,
    padding = 6,
    radius = 12,
    fill = "surface_container",
  }, {
    ui.label({ text = "CONFIGURED REMOTES", fontSize = 10, fontWeight = "bold", color = "tertiary", paddingH = 8, paddingV = 2 }),
    table.unpack(remoteRows),
  })

  local actionsRow = ui.row({ key = "actions_row", gap = 6, align = "center" }, {
    ui.button({
      key = "btn_open_gui",
      text = "Open Rclone Control",
      glyph = "external-link",
      variant = "primary",
      controlSize = "sm",
      flexGrow = 1,
      enabled = snap.gui_available == true,
      tooltip = "Launch full dual-pane Rclone Control window",
      onClick = function()
        openGui({ tab = "explorer" })
      end,
    }),
    ui.button({
      key = "btn_open_remotes",
      text = "Remotes",
      glyph = "settings",
      variant = "secondary",
      controlSize = "sm",
      enabled = snap.gui_available == true,
      tooltip = "Manage remotes & OAuth config in GUI",
      onClick = function()
        openGui({ tab = "remotes" })
      end,
    }),
    ui.button({
      key = "btn_open_mounts",
      text = "Mounts",
      glyph = "folder",
      variant = "secondary",
      controlSize = "sm",
      enabled = snap.gui_available == true,
      tooltip = "Manage FUSE & VFS mounts in GUI",
      onClick = function()
        openGui({ tab = "mounts" })
      end,
    }),
    ui.button({
      key = "btn_refresh",
      glyph = "refresh",
      variant = "ghost",
      controlSize = "sm",
      tooltip = "Refresh rclone status",
      onClick = function()
        refreshSnapshot()
      end,
    }),
  })

  local body = { header, banner, mountsCard, remotesCard }
  if actionMessage ~= "" then
    table.insert(body, ui.label({ key = "action_msg", text = actionMessage, fontSize = 11, color = "primary" }))
  end
  table.insert(body, actionsRow)

  panel.render(ui.column({ key = "root_panel", gap = 10, padding = 14 }, body))
end

function onOpen(_payload)
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

noctalia.state.watch("snapshot", function(value)
  if type(value) == "table" then
    current = value
    if isOpen then
      render()
    end
  end
end)
