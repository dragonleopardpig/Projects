--!nonstrict
-- Shared helper definitions for local/rsync-status entries.

local M = {}

M.PANEL_ID = "local/rsync-status:panel"

M.DEFAULT_SNAPSHOT = {
  available = true,
  state = "unmounted",
  badge = "Loading",
  summary = "Checking rsync status...",
  configured = false,
  disk_mounted = false,
  same_disk = false,
  syncing = false,
  can_sync = false,
  target_root = "",
  target_root_raw = "",
  excludes = {},
  log_exists = false,
  last_run_text = "",
  targets = {},
  tooltip = { { key = "Rsync Backup", value = "Checking status..." } },
}

M.BAR_GLYPHS = {
  syncing = "refresh",
  ok = "folder-check",
  ready = "arrows-transfer-up",
  unmounted = "arrows-transfer-up",
  unconfigured = "arrows-transfer-up",
  error = "refresh-alert",
}

M.STATE_COLORS = {
  syncing = "primary",
  ok = "secondary",
  ready = "tertiary",
  queued = "tertiary",
  disabled = "on_surface_variant",
  unmounted = "on_surface_variant",
  skipped = "on_surface_variant",
  absent = "on_surface_variant",
  never = "on_surface_variant",
  unconfigured = "on_surface_variant",
  error = "error",
}

M.TARGET_GLYPHS = {
  syncing = "loader-2",
  ok = "circle-check",
  ready = "clock",
  queued = "clock",
  disabled = "ban",
  skipped = "circle-minus",
  absent = "folder-off",
  never = "circle-dashed",
  error = "circle-x",
}

function M.helperCommand(subcommand: string): string?
  if noctalia.commandExists("noctalia-rsync-status") then
    return "noctalia-rsync-status " .. subcommand
  end
  local fallback = noctalia.expandPath("~/.local/bin/noctalia-rsync-status")
  if noctalia.fileExists(fallback) then
    return "'" .. string.gsub(fallback, "'", "'\\''") .. "' " .. subcommand
  end
  return nil
end

function M.helperArgv(args: { string }): { string }?
  local bin = nil
  if noctalia.commandExists("noctalia-rsync-status") then
    bin = "noctalia-rsync-status"
  else
    local fallback = noctalia.expandPath("~/.local/bin/noctalia-rsync-status")
    if noctalia.fileExists(fallback) then
      bin = fallback
    end
  end
  if bin == nil then
    return nil
  end
  local argv = { bin }
  for _, a in ipairs(args) do
    table.insert(argv, a)
  end
  return argv
end

function M.stateColor(state: string?): string
  if state and M.STATE_COLORS[state] then
    return M.STATE_COLORS[state]
  end
  return "on_surface_variant"
end

function M.barGlyph(state: string?): string
  if state and M.BAR_GLYPHS[state] then
    return M.BAR_GLYPHS[state]
  end
  return "arrows-transfer-up"
end

function M.targetGlyph(state: string?): string
  if state and M.TARGET_GLYPHS[state] then
    return M.TARGET_GLYPHS[state]
  end
  return "circle-dashed"
end

return M
