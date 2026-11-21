--!nonstrict
-- PIN / UNPIN for every bar icon.  settings.nix binds each icon's right click to the menu
-- (`panel-toggle local/bar-pins:menu <icon>`).  Unpinning sets `widget.<icon>.enabled =
-- false` through `noctalia msg config-set`: Noctalia drops the icon at once and keeps the
-- choice in the saved settings (settings.toml), which a rebuild leaves alone.  The unpinned
-- icon then sits in the tray's down-arrow drawer (suite/tray-drawer-unpinned-widgets.patch);
-- its right click there opens this same menu, now with Pin to bar (`enabled = true`).

local M = {}

M.MENU_ID = "local/bar-pins:menu"

-- What the menu shows and runs for each bar icon, by its name in settings.nix.
-- An action is one of:
--   { ipc = "volume-mute" }                    `noctalia msg volume-mute`
--   { panel = "local/rsync-status:panel" }     open that panel
--   { argv = { "fcitx5-remote", "-t" } }       run a command
--   { event = "local/backup-status:bar" }      the icon's own right click, unchanged
--                                              (`noctalia msg plugin <entry> all right-click`);
--                                              only while the icon is on the bar
-- `right`: the icon's old right-click action, offered first in its menu.  (Left clicks need
-- no entry: they are settings.nix actions, which the tray drawer runs too.)
M.WIDGETS = {
  launcher = { label = "Launcher", glyph = "layout-grid" },
  workspaces = { label = "Workspaces", glyph = "layout-board" },
  ["agent-status"] = { label = "AI agent", glyph = "sparkles" },
  ["umbriel-companion"] = { label = "Layout", glyph = "layout-columns" },
  taskbar = { label = "Taskbar", glyph = "layout-bottombar" },
  active_window = { label = "Window title", glyph = "app-window" },
  xwayland = { label = "XWayland", glyph = "app-window" },
  media = {
    label = "Media",
    glyph = "music",
    right = { label = "Play / pause", glyph = "player-play", ipc = "media toggle" },
  },
  weather = { label = "Weather", glyph = "cloud" },
  clock = { label = "Clock", glyph = "clock" },
  ["control-center"] = { label = "Control centre", glyph = "adjustments" },
  privacy = { label = "Privacy", glyph = "shield-lock" },
  caffeine = { label = "Caffeine", glyph = "coffee" },
  ["always-on"] = {
    label = "Always-on",
    glyph = "infinity",
    right = { label = "Always-on on / off", glyph = "infinity", event = "local/always-on:bar" },
  },
  volume = {
    label = "Volume",
    glyph = "volume",
    right = { label = "Mute / unmute", glyph = "volume-off", ipc = "volume-mute" },
  },
  network = {
    label = "Network",
    glyph = "network",
    right = { label = "Network on / off", glyph = "wifi-off", ipc = "network-toggle" },
  },
  bluetooth = {
    label = "Bluetooth",
    glyph = "bluetooth",
    right = { label = "Bluetooth on / off", glyph = "bluetooth-off", ipc = "bluetooth-toggle" },
  },
  battery = { label = "Battery", glyph = "battery" },
  notifications = {
    label = "Notifications",
    glyph = "bell",
    right = { label = "Do not disturb", glyph = "bell-off", ipc = "notification-dnd-toggle" },
  },
  keyboard_layout = { label = "Keyboard layout", glyph = "keyboard" },
  tray = { label = "Tray", glyph = "apps" },
  ["rsync-status"] = {
    label = "rsync",
    glyph = "arrows-transfer-up",
    right = { label = "Refresh", glyph = "refresh", event = "local/rsync-status:bar" },
  },
  ["rclone-status"] = {
    label = "rclone",
    glyph = "cloud-upload",
    right = { label = "Open rclone GUI", glyph = "external-link", event = "local/rclone-status:bar" },
  },
  ["backup-status"] = {
    label = "Backup",
    glyph = "shield-check",
    right = { label = "Back up now", glyph = "player-play", event = "local/backup-status:bar" },
  },
  ["gpu-status"] = {
    label = "GPU",
    glyph = "cpu",
    right = { label = "Arrange displays", glyph = "layout-distribute-horizontal", panel = "prponkshe/umbriel-displays:arrange" },
  },
  ["umbriel-displays"] = {
    label = "Displays",
    glyph = "device-desktop",
    right = { label = "Arrange displays", glyph = "layout-distribute-horizontal", panel = "prponkshe/umbriel-displays:arrange" },
  },
  ["kitty-control"] = { label = "Kitty", glyph = "terminal-2" },
  session = { label = "Power", glyph = "power" },
}

local function split(line: string)
  local words = {}
  for word in string.gmatch(line, "%S+") do
    table.insert(words, word)
  end
  return words
end

-- The menu and drawer entry for an icon; an icon missing from WIDGETS still gets Unpin/Pin.
function M.info(name: string)
  local entry = M.WIDGETS[name]
  return {
    label = entry and entry.label or name,
    glyph = entry and entry.glyph or "point",
    right = entry and entry.right or nil,
  }
end

local function widgetTable()
  local widgets = noctalia.getSetting("widget")
  return type(widgets) == "table" and widgets or {}
end

-- The icon's own colour (settings.nix), for its glyph in the menu and the drawer.
function M.color(name: string): string
  local cfg = widgetTable()[name]
  if type(cfg) == "table" and type(cfg.color) == "string" and cfg.color ~= "" then
    return cfg.color
  end
  return "primary"
end

-- Whether the icon is on the bar (not unpinned).
function M.isPinned(name: string): boolean
  local cfg = widgetTable()[name]
  return not (type(cfg) == "table" and cfg.enabled == false)
end

-- The argv that performs an action, or nil for a panel (opened in-process).
function M.actionArgv(action, name: string?)
  if action.ipc then
    local argv = { "noctalia", "msg" }
    for _, word in ipairs(split(action.ipc)) do
      table.insert(argv, word)
    end
    return argv
  end
  if action.event then
    return { "noctalia", "msg", "plugin", action.event, "all", "right-click" }
  end
  if action.argv then
    return action.argv
  end
  return nil
end

function M.run(action)
  if action == nil then
    return
  end
  if action.panel then
    noctalia.togglePanel(action.panel)
    return
  end
  local argv = M.actionArgv(action)
  if argv ~= nil then
    noctalia.runAsync(argv)
  end
end

function M.setPinned(name: string, pinned: boolean, done)
  noctalia.runAsync(
    { "noctalia", "msg", "config-set", "widget." .. name .. ".enabled", pinned and "true" or "false" },
    done
  )
end

return M
