--!nonstrict
-- PIN / UNPIN for every bar icon.  settings.nix binds each icon's right click to the menu
-- (`panel-toggle local/bar-pins:menu <icon>`).  Unpinning sets `widget.<icon>.enabled =
-- false` through `noctalia msg config-set`: Noctalia drops the icon at once and keeps the
-- choice in the saved settings (settings.toml), which a rebuild leaves alone.  The drawer
-- button lists the unpinned icons and pins them back (`enabled = true`).

local M = {}

M.MENU_ID = "local/bar-pins:menu"
M.DRAWER_ID = "local/bar-pins:drawer"

-- What the menu and the drawer show and run for each bar icon, by its name in settings.nix.
-- An action is one of:
--   { ipc = "volume-mute" }                    `noctalia msg volume-mute`
--   { panel = "local/rsync-status:panel" }     open that panel
--   { argv = { "fcitx5-remote", "-t" } }       run a command
--   { event = "local/backup-status:bar" }      the icon's own right click, unchanged
--                                              (`noctalia msg plugin <entry> all right-click`);
--                                              only while the icon is on the bar
-- `right`: the icon's old right-click action, offered first in its menu.
-- `open`: its left-click action, the drawer's Open button while it is unpinned.
M.WIDGETS = {
  launcher = { label = "Launcher", glyph = "layout-grid", open = { ipc = "panel-toggle launcher" } },
  workspaces = { label = "Workspaces", glyph = "layout-board" },
  ["agent-status"] = {
    label = "AI agent",
    glyph = "sparkles",
    open = { argv = { "umbriel", "msg", "scratchpad-toggle:agent" } },
  },
  ["umbriel-companion"] = {
    label = "Layout",
    glyph = "layout-columns",
    open = { panel = "noctalia/umbriel-companion:panel" },
  },
  taskbar = { label = "Taskbar", glyph = "layout-bottombar" },
  active_window = { label = "Window title", glyph = "app-window" },
  xwayland = { label = "XWayland", glyph = "app-window" },
  media = {
    label = "Media",
    glyph = "music",
    open = { ipc = "panel-toggle control-center media" },
    right = { label = "Play / pause", glyph = "player-play", ipc = "media toggle" },
  },
  weather = { label = "Weather", glyph = "cloud", open = { ipc = "panel-toggle control-center weather" } },
  clock = { label = "Clock", glyph = "clock", open = { ipc = "panel-toggle control-center calendar" } },
  ["control-center"] = {
    label = "Control centre",
    glyph = "adjustments",
    open = { ipc = "panel-toggle control-center home" },
  },
  privacy = { label = "Privacy", glyph = "shield-lock" },
  caffeine = { label = "Caffeine", glyph = "coffee", open = { ipc = "caffeine-toggle" } },
  ["always-on"] = {
    label = "Always-on",
    glyph = "infinity",
    open = { argv = { "/run/current-system/sw/bin/always-on-toggle" } },
    right = { label = "Always-on on / off", glyph = "infinity", event = "local/always-on:bar" },
  },
  volume = {
    label = "Volume",
    glyph = "volume",
    open = { ipc = "panel-toggle control-center audio" },
    right = { label = "Mute / unmute", glyph = "volume-off", ipc = "volume-mute" },
  },
  network = {
    label = "Network",
    glyph = "network",
    open = { ipc = "panel-toggle control-center network" },
    right = { label = "Network on / off", glyph = "wifi-off", ipc = "network-toggle" },
  },
  bluetooth = {
    label = "Bluetooth",
    glyph = "bluetooth",
    open = { ipc = "panel-toggle control-center bluetooth" },
    right = { label = "Bluetooth on / off", glyph = "bluetooth-off", ipc = "bluetooth-toggle" },
  },
  battery = { label = "Battery", glyph = "battery", open = { ipc = "panel-toggle control-center power" } },
  notifications = {
    label = "Notifications",
    glyph = "bell",
    open = { ipc = "panel-toggle control-center notifications" },
    right = { label = "Do not disturb", glyph = "bell-off", ipc = "notification-dnd-toggle" },
  },
  keyboard_layout = { label = "Keyboard layout", glyph = "keyboard", open = { argv = { "fcitx5-remote", "-t" } } },
  tray = { label = "Tray", glyph = "apps" },
  ["rsync-status"] = {
    label = "rsync",
    glyph = "arrows-transfer-up",
    open = { panel = "local/rsync-status:panel" },
    right = { label = "Refresh", glyph = "refresh", event = "local/rsync-status:bar" },
  },
  ["rclone-status"] = {
    label = "rclone",
    glyph = "cloud-upload",
    open = { panel = "local/rclone-status:panel" },
    right = { label = "Open rclone GUI", glyph = "external-link", event = "local/rclone-status:bar" },
  },
  ["backup-status"] = {
    label = "Backup",
    glyph = "shield-check",
    open = { panel = "local/backup-status:panel" },
    right = { label = "Back up now", glyph = "player-play", event = "local/backup-status:bar" },
  },
  ["gpu-status"] = {
    label = "GPU",
    glyph = "cpu",
    open = { panel = "prponkshe/umbriel-displays:panel" },
    right = { label = "Arrange displays", glyph = "layout-distribute-horizontal", panel = "prponkshe/umbriel-displays:arrange" },
  },
  ["umbriel-displays"] = {
    label = "Displays",
    glyph = "device-desktop",
    open = { panel = "prponkshe/umbriel-displays:panel" },
    right = { label = "Arrange displays", glyph = "layout-distribute-horizontal", panel = "prponkshe/umbriel-displays:arrange" },
  },
  ["kitty-control"] = { label = "Kitty", glyph = "terminal-2", open = { panel = "community/kitty-control:panel" } },
  session = { label = "Power", glyph = "power", open = { ipc = "panel-toggle session" } },
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
    open = entry and entry.open or nil,
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

-- Every icon of the main bar, in bar order.
function M.barOrder()
  local bar = noctalia.getSetting("bar.main")
  local names = {}
  if type(bar) ~= "table" then
    return names
  end
  for _, side in ipairs({ "start", "center", "end" }) do
    if type(bar[side]) == "table" then
      for _, name in ipairs(bar[side]) do
        table.insert(names, name)
      end
    end
  end
  return names
end

-- The unpinned icons, in bar order.
function M.unpinned()
  local widgets = widgetTable()
  local hidden = {}
  for _, name in ipairs(M.barOrder()) do
    local cfg = widgets[name]
    if type(cfg) == "table" and cfg.enabled == false then
      table.insert(hidden, name)
    end
  end
  return hidden
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
