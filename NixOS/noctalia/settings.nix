{ plugin }:
{
  shell = {
    font_family = "JetBrainsMono Nerd Font";
    setup_wizard_enabled = false;
    clipboard_enabled = false;
    panel.open_near_click_control_center = true;
  };
  wallpaper.enabled = false;
  theme = {
    mode = "dark";
    source = "builtin";
    builtin = "Catppuccin";
  };
  # swaync remains the notification daemon and history owner.
  notification.enable_daemon = false;
  location = {
    auto_locate = false;
    latitude = 1.3521;
    longitude = 103.8198;
  };
  weather = {
    enabled = true;
    unit = "celsius";
  };
  # The original AGS/brightness-ctl handling remains available, including the
  # DDC-only desktop monitor. Let Noctalia use native backlight where present.
  brightness.enable_ddcutil = false;
  plugins = {
    enabled = [ "thinky/ags_bridge" ];
    auto_update = "none";
    source = [ {
      name = "ags-bridge";
      kind = "path";
      location = toString plugin;
      enabled = true;
    } ];
  };
  bar.main = {
    position = "top";
    thickness = 38;
    margin_ends = 16;
    margin_edge = 8;
    padding = 12;
    widget_spacing = 8;
    radius = 14;
    background_opacity = 0.88;
    compositor_blur = true;
    reserve_space = true;
    start = [ "launcher" "workspaces" "taskbar" ];
    center = [ "clock" ];
    end = [ "media" "weather" "failed" "print_queue" "privacy" "lock_keys" "idle" "group:quick" "swaync" "tray" "ags_control" "control-center" "session" ];
    capsule_group = [ {
      id = "quick";
      members = [ "network" "bluetooth" "volume" "battery" "power_profile" ];
      fill = "surface_container";
      padding = 6.0;
      opacity = 0.85;
      widget_spacing = 5;
    } ];
  };
  widget = {
    launcher.actions = {
      right = "exec ags toggle app-drawer";
    };
    workspaces = {
      labels_only_when_occupied = true;
      hide_when_empty = true;
    };
    taskbar = {
      only_active_workspace = true;
      taskbar_max_width = 420;
      item_spacing = 6;
    };
    failed.type = "thinky/ags_bridge:failed";
    media = {
      hide_when_no_media = true;
      hide_artist = true;
      max_length = 180;
    };
    print_queue.type = "thinky/ags_bridge:print_queue";
    swaync.type = "thinky/ags_bridge:swaync";
    idle.type = "thinky/ags_bridge:idle";
    lock_keys.hide_when_off = true;
    privacy.hide_inactive = true;
    network.show_label = false;
    volume.show_label = false;
    weather.show_condition = false;
    tray.drawer = true;
    weather.actions.left = "panel-toggle control-center weather";
    clock = {
      format = "{:%a %d %b  %H:%M}";
      actions = {
        left = "panel-toggle control-center calendar";
        right = "exec ags toggle calendar";
      };
    };
    control-center.glyph = "adjustments";
    ags_control = {
      type = "custom_button";
      glyph = "tool";
      tooltip = "AGS Control Center: display scale, mouse, WinApps, printers and scanners";
      actions = {
        left = "exec ags toggle control-center";
      };
    };
    session.actions = {
      left = "exec wlogout";
      right = "panel-toggle session";
    };
  };
}
