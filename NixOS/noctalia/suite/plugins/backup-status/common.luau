--!nonstrict
-- Shared helpers for local/backup-status entries.  The helper is `backup-pool`
-- (scripts/backup-pool.py), installed only on hosts with a backup: without it
-- the bar icon stays hidden.

local M = {}

M.PANEL_ID = "local/backup-status:panel"
M.HELPER = "backup-pool"
M.HELPER_FALLBACK = "/run/current-system/sw/bin/backup-pool"

M.DEFAULT_SNAPSHOT = {
  available = true,
  state = "ok",
  badge = "Loading",
  summary = "Checking the backup...",
  tooltip = { { key = "Backup", value = "Checking..." } },
}

M.BAR_GLYPHS = {
  running = "database-export",
  stalled = "hourglass",
  browsing = "folder-open",
  failed = "alert-triangle",
  paused = "player-pause",
  unplugged = "plug-connected-x",
  stopped = "player-stop",
  incomplete = "database",
  overdue = "history",
  due = "clock",
  ok = "shield-check",
}

M.STATE_COLORS = {
  running = "primary",
  stalled = "error",
  browsing = "secondary",
  failed = "error",
  paused = "on_surface_variant",
  unplugged = "on_surface_variant",
  stopped = "tertiary",
  incomplete = "tertiary",
  overdue = "tertiary",
  due = "tertiary",
  ok = "secondary",
}

local function helperBin(): string?
  if noctalia.commandExists(M.HELPER) then
    return M.HELPER
  end
  if noctalia.fileExists(M.HELPER_FALLBACK) then
    return M.HELPER_FALLBACK
  end
  return nil
end

function M.helperCommand(subcommand: string): string?
  local bin = helperBin()
  if bin == nil then
    return nil
  end
  return bin .. " " .. subcommand
end

function M.helperArgv(args: { string }): { string }?
  local bin = helperBin()
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
  return "database"
end

-- The helper's JSON reply, or nil.
function M.decode(res)
  if res and res.stdout and res.stdout ~= "" then
    local ok, data = pcall(noctalia.json.decode, res.stdout)
    if ok and type(data) == "table" then
      return data
    end
  end
  return nil
end

return M
