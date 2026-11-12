{ themeName, wallpaper, barAccents, launcherIcon }:
{
  storage.key_source = "secret-service";
  shell = {
    font_family = "Inter";
    setup_wizard_enabled = false;
    clipboard_enabled = true;
    # Applications inherit the active session's display.
    launch_apps_as_systemd_services = false;
    polkit_agent = true;
    keyboard_layout = {
      custom_labels = {
        "Keyboard - English (US)" = "US";
        "English (US)" = "US";
        "Pinyin" = "拼";
        "pinyin" = "拼";
      };
    };
    # Familiar AGS app-drawer browsing, using the native shell launcher.
    launcher = {
      layout = "full";
      fullscreen = true;
      width = 1100;
      search_position = "top";
      default_view = "all";
      app_grid = true;
      show_icons = true;
      colorize_icons = false;
      sort_by_usage = false;
    };
    panel.open_near_click_control_center = true;
    panel.launcher_placement = "floating";
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
  wallpaper = {
    enabled = true;
    default.path = toString wallpaper;
    directory = "/home/thinky/Pictures/Wallpapers";
    transition = [ "fade" "wipe" "disc" "stripes" "zoom" "honeycomb" "vortex" "pixel" "diamond" "golden" "melt" ];
    transition_duration = 1500;
    automation = {
      enabled = true;
      interval_seconds = 60;
      order = "random";
      recursive = false;
    };
  };
  theme = {
    mode = "dark";
    source = "custom";
    custom_palette = themeName;
    sync_color_scheme = true;
    templates = { builtin_ids = [ "emacs" ]; community_ids = [ ]; };
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
  # Fetched from the default official/community sources on first start (no background updates);
  # the rest of both catalogs stays available in Settings → Plugins.
  plugins = {
    enabled = [
      "noctalia/umbriel-companion"      # official: layout/submap in the bar, layout + window panel
      "prponkshe/umbriel-displays"      # community: resolution/scale/arrangement -> umbriel/outputs.toml
      "tordex/xwayland"                 # community: is the focused window XWayland?
      "community/kitty-control"         # local/community: kitty terminal control panel
      "local/agent-status"              # local: Antigravity lifecycle status + scratchpad toggle
    ];
    auto_update = "none";
  };
  plugin_settings = {
    "noctalia/umbriel-companion" = {
      panel_placement = "attached";
      panel_position = "top_left";
      panel_open_near_click = true;
    };
    "community/kitty-control" = {
      panel_placement = "attached";
      panel_position = "top_right";
      panel_open_near_click = true;
    };
  };
  bar.main = {
    position = "top";
    thickness = 42;
    margin_ends = 16;
    margin_edge = 0;
    padding = 12;
    widget_spacing = 8;
    radius = 16;
    background_opacity = 0.94;
    compositor_blur = true;
    reserve_space = true;
    start = [ "launcher" "workspaces" "agent-status" "umbriel-companion" "taskbar" ];
    center = [ "active_window" "xwayland" ];
    end = [ "media" "weather" "clock" "control-center" "privacy" "caffeine" "always-on" "volume" "network" "bluetooth" "battery" "notifications" "keyboard_layout" "tray" "umbriel-displays" "kitty-control" "session" ];
  };
  widget = {
    launcher = {
      custom_image = launcherIcon;
      custom_image_colorize = true;
      color = barAccents.desktop;
      scale = 1.25;
    };
    workspaces = { labels_only_when_occupied = true; hide_when_empty = true; };
    taskbar = { only_active_workspace = true; taskbar_max_width = 280; };
    active_window = { display = "text_only"; max_length = 800; title_scroll = "none"; show_empty_label = false; };
    # Right-side controls use the Fastfetch hues plus a neon-purple accent.
    # Native warning/mute/attention colors still communicate exceptional states.
    media = { color = barAccents.audio; hide_when_no_media = true; hide_artist = true; max_length = 100; };
    clock = { color = barAccents.distro; format = "{:%a %d %b  %H:%M}"; actions.left = "panel-toggle control-center calendar"; };
    weather = { color = barAccents.distro; show_condition = false; actions.left = "panel-toggle control-center weather"; };
    privacy = { color = barAccents.system; hide_inactive = true; };
    caffeine.color = barAccents.neonPurple;
    volume = { color = barAccents.audio; show_label = false; };
    network = { color = barAccents.desktop; show_label = false; };
    bluetooth.color = barAccents.desktop;
    battery.color = barAccents.system;
    notifications.color = barAccents.distro;
    keyboard_layout = {
      color = barAccents.desktop;
      display = "short";
      show_glyph = true;
      show_label = true;
      hide_when_single_layout = false;
      actions.left = "exec fcitx5-remote -t";
    };
    tray = { color = barAccents.desktop; drawer = true; };
    control-center = { color = "#FF7E70"; glyph = "adjustments"; };
    session.color = "#FFFFFF";
    # Plugin bar widgets (see plugins.enabled above).
    umbriel-companion.type = "noctalia/umbriel-companion:bar";
    umbriel-displays.type = "prponkshe/umbriel-displays:bar";
    umbriel-displays.color = barAccents.desktop;
    kitty-control.type = "community/kitty-control:bar";
    kitty-control.color = barAccents.neonPurple;
    agent-status.type = "local/agent-status:bar";
    xwayland.type = "tordex/xwayland:bar";
    # ALWAYS-ON MODE (modules/always-on-umbriel.nix): either click switches it; the glyph a cup
    # when off, an infinity when on (the watcher sets it).
    always-on = {
      type = "custom_button";
      color = barAccents.neonPurple;
      glyph = "coffee";
      actions = { left = "exec /run/current-system/sw/bin/always-on-toggle";
                  right = "exec /run/current-system/sw/bin/always-on-toggle"; };
    };
  };
}
