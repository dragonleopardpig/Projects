--!nonstrict
-- Shared helpers for local/rclone-status entries.

local M = {}

M.PANEL_ID = "local/rclone-status:panel"

M.DEFAULT_SNAPSHOT = {
  available = true,
  state = "ready",
  badge = "Loading",
  summary = "Checking rclone mounts & remotes...",
  remotes = {},
  mounts = {},
  active_jobs = {},
  saved_jobs_count = 0,
  gui_available = true,
  tooltip = { { key = "Rclone Control", value = "Checking status..." } },
}

M.BAR_GLYPHS = {
  syncing = "cloud-upload",
  mounted = "cloud-check",
  ready = "cloud",
  unconfigured = "cloud-off",
  error = "alert-triangle",
}

M.STATE_COLORS = {
  syncing = "primary",
  mounted = "secondary",
  active = "secondary",
  ready = "tertiary",
  inactive = "on_surface_variant",
  disabled = "on_surface_variant",
  unconfigured = "on_surface_variant",
  error = "error",
  failed = "error",
}

M.ITEM_GLYPHS = {
  mounted = "circle-check",
  active = "circle-check",
  syncing = "loader-2",
  inactive = "circle-dashed",
  ready = "circle-dashed",
  error = "circle-x",
  failed = "circle-x",
}

function M.helperCommand(subcommand: string): string?
  if noctalia.commandExists("noctalia-rclone-status") then
    return "noctalia-rclone-status " .. subcommand
  end
  local fallback = noctalia.expandPath("~/.local/bin/noctalia-rclone-status")
  if noctalia.fileExists(fallback) then
    return "'" .. string.gsub(fallback, "'", "'\\''") .. "' " .. subcommand
  end
  return nil
end

function M.helperArgv(args: { string }): { string }?
  local bin = nil
  if noctalia.commandExists("noctalia-rclone-status") then
    bin = "noctalia-rclone-status"
  else
    local fallback = noctalia.expandPath("~/.local/bin/noctalia-rclone-status")
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
  return "cloud"
end

function M.itemGlyph(state: string?): string
  if state and M.ITEM_GLYPHS[state] then
    return M.ITEM_GLYPHS[state]
  end
  return "circle-dashed"
end

return M
