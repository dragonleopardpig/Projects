{ themeName, wallpaper }:
{
  storage.key_source = "secret-service";
  shell = {
    font_family = "Inter";
    setup_wizard_enabled = false;
    clipboard_enabled = true;
    # Applications inherit the active session's display.
    launch_apps_as_systemd_services = false;
    polkit_agent = true;
    panel.open_near_click_control_center = true;
    screenshot = {
      pipe_to_command = true;
      pipe_command = "swappy -f -";
      save_to_file = false;
      copy_to_clipboard = false;
    };
    session.actions = [
      { action = "lock"; }
      { action = "logout"; command = "umbriel msg session-quit"; }
      { action = "lock_and_suspend"; }
      { action = "reboot"; countdown_seconds = 5; }
      { action = "shutdown"; countdown_seconds = 5; }
    ];
  };
  wallpaper = { enabled = true; default.path = toString wallpaper; };
  theme = {
    mode = "dark";
    source = "custom";
    custom_palette = themeName;
    sync_color_scheme = true;
    templates = { builtin_ids = [ ]; community_ids = [ ]; };
  };
  notification.enable_daemon = true;
  location = { auto_locate = false; latitude = 1.3521; longitude = 103.8198; };
  weather = { enabled = true; unit = "celsius"; };
  # Auto-select kernel backlight per output, with DDC/CI for external monitors.
  brightness.enable_ddcutil = true;
  lockscreen = { enabled = true; lock_before_suspend = true; };
  idle.behavior = {
    lock = { enabled = true; timeout = 900; action = "lock"; };
    # The existing desktop has hardware-specific DPMS workarounds. Keep blanking opt-in.
    screen-off = { enabled = false; timeout = 1200; action = "screen_off"; };
  };
  # The official and community catalogs remain available in Settings → Plugins.
  plugins = { enabled = [ ]; auto_update = "none"; };
  bar.main = {
    position = "top";
    thickness = 42;
    margin_ends = 16;
    margin_edge = 10;
    padding = 12;
    widget_spacing = 8;
    radius = 16;
    background_opacity = 0.94;
    compositor_blur = true;
    reserve_space = true;
    start = [ "launcher" "workspaces" "taskbar" ];
    center = [ "active_window" ];
    end = [ "media" "weather" "clock" "privacy" "caffeine" "always-on" "volume" "network" "bluetooth" "battery" "notifications" "tray" "control-center" "session" ];
  };
  widget = {
    workspaces = { labels_only_when_occupied = true; hide_when_empty = true; };
    taskbar = { only_active_workspace = true; taskbar_max_width = 280; };
    active_window = { display = "text_only"; max_length = 800; title_scroll = "none"; show_empty_label = false; };
    media = { hide_when_no_media = true; hide_artist = true; max_length = 100; };
    clock = { format = "{:%a %d %b  %H:%M}"; actions.left = "panel-toggle control-center calendar"; };
    weather = { show_condition = false; actions.left = "panel-toggle control-center weather"; };
    privacy.hide_inactive = true;
    volume.show_label = false;
    network.show_label = false;
    tray.drawer = true;
    control-center.glyph = "adjustments";
    # ALWAYS-ON MODE (modules/always-on-umbriel.nix): either click switches it; the glyph a cup
    # when off, an infinity when on (the watcher sets it).
    always-on = {
      type = "custom_button";
      glyph = "coffee";
      actions = { left = "exec /run/current-system/sw/bin/always-on-toggle";
                  right = "exec /run/current-system/sw/bin/always-on-toggle"; };
    };
  };
}
