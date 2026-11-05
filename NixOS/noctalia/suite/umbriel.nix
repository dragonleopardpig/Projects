{ lib, pkgs, shellCommand, terminalCommand, dark, neon, displayCycleCommand, stopRecordingCommand, lockCommand }:
let
  spawn = cmd: { action = "spawn:${cmd}"; repeat = false; };
  control = cmd: {
    action = "spawn:noctalia msg ${cmd}";
    allow_when_locked = true;
    repeat = !builtins.elem cmd [ "volume-mute" "mic-mute" "media toggle" ];
  };
in {
  general = {
    mod_key = "Super";
    autostart = [ shellCommand ];
    # Match the previous Hyprland force_zero_scaling behavior: X11 clients
    # render at physical pixels and scale text/UI through XSETTINGS, rather
    # than stretching a low-resolution framebuffer at fractional output scales.
    xwayland_native_resolution = true;
    xwayland_xsettings = true;
  };
  colors = {
    background = dark.surface; text_primary = dark.on_surface;
    text_muted = dark.on_surface_variant;
    accent_primary = dark.primary; accent_secondary = dark.secondary;
    warning = "#F6DF82"; error = dark.error; insert_hint = "${dark.primary}55";
    backdrop = dark.surface; shadow = "${neon}1A";
    border = { focused = neon; unfocused = "#213846"; outer = dark.surface; };
    overview = { background_tint = "#040A1490"; workspace_background = "#0B1726CC"; badge = dark.primary; };
  };
  appearance = {
    corner_radius = 14;
    border_width = 2;
    blur.radius = 4;
    shadow = { enabled = true; softness = 24; offset_x = 0; offset_y = 4; };
  };
  input = {
    keyboard.numlock_toggle = true;
    mouse.natural_scroll = true;
    touchpad.natural_scroll = true;
    focus.follows_mouse = true;
  };
  layout = {
    mode = "scrolling";
    extent_presets = [ 0.333 0.5 0.667 ];
    scrolling.default_extent_fraction = 0.5;
  };
  keybinds = {
    # Keep daily Hyprland app chords; give Suite additions separate bindings.
    "Mod+F" = spawn "firefox";
    "Mod+Q" = spawn "kitty";
    "Mod+E" = spawn "emacs";
    "Mod+P" = spawn "protonvpn-app";
    "Mod+W" = spawn "walker";
    "Mod+B" = spawn "kitty -e btop";
    "Mod+N" = spawn "$HOME/.local/bin/nemo-x11";
    "Mod+S" = spawn "$HOME/.local/bin/sioyek --new-window";
    "Mod+Y" = spawn "kitty -e yazi";
    "Mod+M" = spawn "minder";
    "Mod+Return" = spawn terminalCommand;
    "Mod+Shift+N" = spawn "strata";
    "Mod+Space" = spawn "noctalia msg panel-toggle launcher";
    "Mod+Shift+V" = spawn "noctalia msg panel-toggle clipboard";
    "Mod+Comma" = spawn "noctalia msg settings-open";
    "Mod+Shift+E" = spawn "noctalia msg panel-toggle session";
    "Mod+Shift+W" = spawn "noctalia msg panel-toggle wallpaper";
    "Mod+O" = "overview-toggle";
    "Pause" = "overview-toggle";
    "Mod+K" = { action = "window-close"; repeat = false; };
    "Mod+Escape" = "session-quit";
    "Mod+Shift+F" = "window-toggle-maximize";
    "Mod+Z" = "window-toggle-maximize-to-edges";
    "Mod+Ctrl+F" = "window-toggle-fullscreen";
    "Mod+Shift+T" = "window-toggle-floating";
    "Mod+MouseMiddle" = "window-toggle-floating";
    "Mod+R" = "window-cycle-primary-extent";
    "Mod+Left" = "window-focus-or-output-left";
    "Mod+Right" = "window-focus-or-output-right";
    "Mod+Up" = "window-focus-or-output-up";
    "Mod+Down" = "window-focus-or-output-down";
    "Mod+Shift+Left" = "column-move-left";
    "Mod+Shift+Right" = "column-move-right";
    "Mod+Shift+Up" = "window-move-up";
    "Mod+Shift+Down" = "window-move-down";
    "Ctrl+Alt+Left" = "workspace-previous";
    "Ctrl+Alt+Right" = "workspace-next";
    "Alt+Tab" = spawn "noctalia msg window-switcher";
    "Mod+Tab" = "window-focus-previous";
    "Mod+T" = "scratchpad-toggle:terminal";
    "Mod+V" = "scratchpad-toggle:volume";
    "Mod+X" = "scratchpad-toggle:notepad";
    "Mod+A" = spawn "noctalia msg config-reload";
    "Mod+Shift+A" = spawn "noctalia msg bar-toggle";
    "Mod+F7" = spawn "sioyek-keyboard-lights";
    "Print" = spawn "noctalia msg screenshot-region";
    "Shift+Print" = spawn "noctalia msg screenshot-fullscreen all";
    "Ctrl+Print" = spawn "noctalia msg screenshot-fullscreen pick";
    "Alt+Print" = spawn "noctalia msg screenshot-window";
    "F5" = control "brightness-down";
    "F6" = control "brightness-up";
    "XF86MonBrightnessDown" = control "brightness-down";
    "XF86MonBrightnessUp" = control "brightness-up";
    "XF86AudioRaiseVolume" = control "volume-up";
    "XF86AudioLowerVolume" = control "volume-down";
    "XF86AudioMute" = control "volume-mute";
    "XF86AudioMicMute" = control "mic-mute";
    "XF86AudioPlay" = control "media toggle";
    "XF86AudioPause" = control "media toggle";
    "XF86AudioNext" = control "media next";
    "XF86AudioPrev" = control "media previous";
  } // {
    "Mod+Shift+Escape" = spawn stopRecordingCommand;
    "F1" = spawn lockCommand;
    "Mod+L" = spawn lockCommand;
    "Ctrl+Alt+L" = { action = "spawn:${lockCommand}"; allow_when_locked = true; repeat = false; };
    "F7" = spawn displayCycleCommand;
    "XF86Display" = spawn displayCycleCommand;
    "F8" = spawn "${displayCycleCommand} input";
  } // builtins.listToAttrs (lib.concatMap (n: [
    { name = "Mod+${toString n}"; value = "workspace-switch:${toString n}"; }
    { name = "Mod+Shift+${toString n}"; value = "window-move-to-workspace:${toString n}"; }
  ]) (lib.range 1 9));
  scratchpad = [
    { name = "terminal"; spawn_when_empty = "kitty --class kitty-dropterm"; }
    { name = "volume"; spawn_when_empty = "pavucontrol"; }
    { name = "notepad"; spawn_when_empty = "xed --standalone"; }
  ];
  window_rule = [
    { match.app_id = "^dev.noctalia.Noctalia$"; default_floating = true; default_floating_size_px = { width = 1020; height = 900; }; }
    { match.app_id = "^kitty-dropterm$"; default_scratchpad = "terminal"; default_floating_size_px = { width = 1400; height = 800; }; }
    { match.app_id = "^(org.pulseaudio.pavucontrol|pavucontrol)$"; default_scratchpad = "volume"; default_floating_size_px = { width = 650; height = 850; }; }
    { match.app_id = "^(xed|org.x.editor)$"; default_scratchpad = "notepad"; default_floating_size_px = { width = 960; height = 950; }; }
  ];
  layer_rule = [ { match.namespace = "^noctalia-.*$"; blur = true; blur_ignore_alpha = 0.5; } ];
}
