{ lib, config, inputs, pkgs, ... }:
{
  home.username = "thinky";
  home.homeDirectory = "/home/thinky";
  xdg.userDirs = {
    enable = true;
    createDirectories = true;
  };

  xdg.desktopEntries.euresys-studio = {
    name = "eGrabber Studio";
    exec = "euresys-fhs -c \"QT_QPA_PLATFORM=xcb /opt/euresys/egrabber/studio/studio\"";
    icon = "euresys-studio";
    comment = "Euresys eGrabber Studio for CoaxLink/GrabLink frame grabbers";
    categories = [ "Utility" "Engineering" ];
    terminal = false;
  };

  home.file.".local/share/icons/hicolor/256x256/apps/euresys-studio.png" = {
    source = ./assets/euresys-studio.png;
  };

  xdg.desktopEntries.sioyek-xcb = {
    name = "Sioyek";
    exec = "/home/thinky/.local/bin/sioyek-xcb %f";
    icon = "sioyek";
    comment = "Sioyek PDF viewer (XWayland)";
    mimeType = [ "application/pdf" ];
    categories = [ "Office" "Viewer" ];
  };

  xdg.desktopEntries.mayo-xcb = {
    name = "Mayo";
    exec = "/home/thinky/.local/bin/mayo-xcb %f";
    icon = "mayo";
    comment = "Mayo STEP/IGES viewer (XWayland software GL)";
    mimeType = [ "model/step" "model/iges" "application/step" ];
    categories = [ "Graphics" "Engineering" "Science" ];
    terminal = false;
  };

  xdg.desktopEntries.gmsh-xcb = {
    name = "Gmsh";
    exec = "/home/thinky/.local/bin/gmsh-xcb %f";
    icon = "gmsh";
    comment = "Gmsh mesh/CAD viewer (XWayland software GL)";
    mimeType = [ "model/step" "model/iges" "application/step" ];
    categories = [ "Graphics" "Engineering" "Science" ];
    terminal = false;
  };

  xdg.desktopEntries.f3d-xcb = {
    name = "F3D";
    exec = "/home/thinky/.local/bin/f3d-xcb %f";
    icon = "f3d";
    comment = "F3D viewer (XWayland software GL)";
    mimeType = [ "model/step" "model/iges" "application/step" "model/stl" "model/obj" ];
    categories = [ "Graphics" "Engineering" "Science" ];
    terminal = false;
  };

  xdg.desktopEntries.paraview-xcb = {
    name = "ParaView";
    exec = "/home/thinky/.local/bin/paraview-xcb %f";
    icon = "paraview";
    comment = "ParaView (XWayland software GL)";
    mimeType = [ "model/step" "model/iges" "application/step" ];
    categories = [ "Graphics" "Engineering" "Science" ];
    terminal = false;
  };

  xdg.desktopEntries.freecad = {
    name = "FreeCAD";
    exec = "/home/thinky/.local/bin/freecad-opaque %f";
    icon = "freecad";
    comment = "FreeCAD (opaque Qt style)";
    categories = [ "Graphics" "Engineering" "Science" ];
    terminal = false;
  };

  home.file.".local/bin/nemo-x11" = {
    executable = true;
    text = ''
      #!/bin/sh
      export GDK_BACKEND=x11
      export QT_QPA_PLATFORM=xcb
      exec nemo "$@"
    '';
  };

  xdg.desktopEntries.nemo-x11 = {
    name = "Nemo";
    exec = "/home/thinky/.local/bin/nemo-x11 %U";
    icon = "nemo";
    comment = "Nemo file manager (XWayland)";
    categories = [ "Utility" "FileManager" ];
    terminal = false;
  };

  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "inode/directory" = [ "nemo-x11.desktop" ];
      "application/pdf" = [ "sioyek-xcb.desktop" ];
      "image/png" = [ "imv-dir.desktop" ];
      "image/jpeg" = [ "imv-dir.desktop" ];
      "image/gif" = [ "imv-dir.desktop" ];
      "image/webp" = [ "imv-dir.desktop" ];
      "image/bmp" = [ "imv-dir.desktop" ];
      "image/svg+xml" = [ "imv-dir.desktop" ];
      "text/plain" = [ "xed.desktop" ];
      "text/markdown" = [ "xed.desktop" ];
    };
  };
  
  xdg.configFile."uwsm/env".source = "${config.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh";
  xdg.configFile."distrobox/distrobox.conf".force = true;
  xdg.configFile."distrobox/distrobox.conf".text = ''
    container_additional_volumes="/nix/store:/nix/store:ro /etc/profiles/per-user:/etc/profiles/per-user:ro /etc/static/profiles/per-user:/etc/static/profiles/per-user:ro"
  '';
  xdg.configFile."Kvantum/kvantum.kvconfig".text = ''
    [General]
    theme=KvArcDark
  '';
  
  # Pyprland configuration
  xdg.configFile."pypr/config.toml".text = ''
    [pyprland]
    plugins = [
      "scratchpads",
      "magnify",
      "expose",
          ]

    [scratchpads.term]
    command = "kitty --class kitty-dropterm"
    animation = "fromTop"
    size = "75% 60%"

    [scratchpads.notepad]
    command = "xed"
    animation = "fromRight"
    size = "50% 70%"
    lazy = true

    [scratchpads.volume]
    command = "pavucontrol"
    animation = "fromRight"
    size = "40% 90%"
    lazy = true
  '';

  # Waypaper configuration for random image rotation via swww
  xdg.configFile."waypaper/config.ini".force = true;
  xdg.configFile."waypaper/config.ini".text = ''
    [Settings]
    language = en
    folder = ~/Pictures/Wallpapers
    monitors = All
    wallpaper = ~/Pictures/Wallpapers/Sollee.png
    show_path_in_tooltip = True
    backend = swww
    fill = fill
    sort = name
    color = #ffffff
    subfolders = False
    all_subfolders = False
    show_hidden = False
    show_gifs_only = False
    post_command =
    number_of_columns = 3
    swww_transition_type = any
    swww_transition_step = 90
    swww_transition_angle = 0
    swww_transition_duration = 2
    swww_transition_fps = 60
    mpvpaper_sound = False
    mpvpaper_options =
    use_xdg_state = False
    zen_mode = False
  '';

  home.file.".face.icon".source = ./assets/face.png;

  # Sioyek wrapper: force XWayland to avoid NVIDIA Wayland window mapping issues
  home.file.".local/bin/sioyek-xcb" = {
    executable = true;
    text = ''
      #!/bin/sh
      exec env QT_QPA_PLATFORM=xcb sioyek "$@"
    '';
  };

  # Mayo wrapper: force XWayland + software GL to avoid QRhiGles2 context failures
  home.file.".local/bin/mayo-xcb" = {
    executable = true;
    text = ''
      #!/bin/sh
      export QT_QPA_PLATFORM=xcb
      export XDG_SESSION_TYPE=x11
      export QT_XCB_GL_INTEGRATION=none
      export LIBGL_DRI3_DISABLE=1
      export LIBGL_ALWAYS_SOFTWARE=1
      export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
      export QT_OPENGL=software
      export QT_QUICK_BACKEND=software
      exec mayo "$@"
    '';
  };

  # Lark .deb runner: extract to ~/.local/opt and run inside FHS env
  home.file.".local/bin/lark-deb" = {
    executable = true;
    text = ''
      #!/bin/sh
      set -eu

      DEB_PATH="$HOME/Downloads/Lark-linux_x64-7.59.12.deb"
      APP_DIR="$HOME/.local/opt/lark"

      if [ ! -f "$DEB_PATH" ]; then
        echo "Lark .deb not found at: $DEB_PATH"
        exit 1
      fi

      mkdir -p "$APP_DIR"
      ${pkgs.dpkg}/bin/dpkg -x "$DEB_PATH" "$APP_DIR"

      if [ ! -x "$APP_DIR/opt/Lark/lark" ]; then
        echo "Lark binary not found at: $APP_DIR/opt/Lark/lark"
        exit 1
      fi

      exec fhs -c "$APP_DIR/opt/Lark/lark" -- "$@"
    '';
  };

  xdg.desktopEntries.lark-deb = {
    name = "Lark (deb)";
    exec = "/home/thinky/.local/bin/lark-deb";
    icon = "lark";
    comment = "Lark .deb via FHS environment";
    categories = [ "Network" "Chat" "Office" ];
    terminal = false;
  };


  # Gmsh wrapper: force XWayland + software GL
  home.file.".local/bin/gmsh-xcb" = {
    executable = true;
    text = ''
      #!/bin/sh
      export QT_QPA_PLATFORM=xcb
      export XDG_SESSION_TYPE=x11
      export QT_XCB_GL_INTEGRATION=none
      export LIBGL_DRI3_DISABLE=1
      export LIBGL_ALWAYS_SOFTWARE=1
      export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
      exec gmsh "$@"
    '';
  };

  # F3D wrapper: force XWayland + software GL
  home.file.".local/bin/f3d-xcb" = {
    executable = true;
    text = ''
      #!/bin/sh
      export QT_QPA_PLATFORM=xcb
      export XDG_SESSION_TYPE=x11
      export QT_XCB_GL_INTEGRATION=none
      export LIBGL_DRI3_DISABLE=1
      export LIBGL_ALWAYS_SOFTWARE=1
      export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
      exec f3d "$@"
    '';
  };

  # ParaView wrapper: force XWayland + software GL
  home.file.".local/bin/paraview-xcb" = {
    executable = true;
    text = ''
      #!/bin/sh
      export QT_QPA_PLATFORM=xcb
      export XDG_SESSION_TYPE=x11
      export QT_XCB_GL_INTEGRATION=none
      export LIBGL_DRI3_DISABLE=1
      export LIBGL_ALWAYS_SOFTWARE=1
      export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
      exec paraview "$@"
    '';
  };

  # FreeCAD wrapper: force opaque Qt style (avoid transparent background)
  home.file.".local/bin/freecad-opaque" = {
    executable = true;
    text = ''
      #!/bin/sh
      # Force XWayland + opaque Qt style to avoid transparency under Wayland/Kvantum
      export QT_QPA_PLATFORM=xcb
      export XDG_SESSION_TYPE=x11
      export XDG_CURRENT_DESKTOP=X-Generic
      export QT_QPA_PLATFORMTHEME=
      export QT_STYLE_OVERRIDE=Fusion
      # Avoid GLX/DRI3 compositor transparency issues on NVIDIA + XWayland
      export QT_XCB_GL_INTEGRATION=none
      export LIBGL_DRI3_DISABLE=1
      export QT_OPENGL=desktop
      export QT_QUICK_BACKEND=software
      # Force Qt to avoid alpha/transparent surfaces
      export QT_X11_NO_MITSHM=1
      export QT_AUTO_SCREEN_SCALE_FACTOR=0
      export QML_DISABLE_DISK_CACHE=1
      export QSG_RHI_BACKEND=software
      export GDK_BACKEND=x11
      export NO_AT_BRIDGE=1
      exec FreeCAD "$@"
    '';
  };

  home.file.".local/bin/screenshot" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -eu
      grim -g "$(slurp)" - | swappy -f -
    '';
  };

  home.file.".local/bin/brightness-ctl" = {
    executable = true;
    text = ''
      #!/bin/sh
      # Pick the right backlight device: prefer intel_backlight (laptop), fall back to ddcci (desktop)
      if [ -d /sys/class/backlight/intel_backlight ]; then
        DEV=intel_backlight
      else
        DEV=$(ls /sys/class/backlight/ | grep -m1 ddcci)
      fi

      case "$1" in
        up)   brightnessctl -d "$DEV" set +10% ;;
        down) brightnessctl -d "$DEV" set 10%- ;;
        *)    echo "Usage: brightness-ctl {up|down}"; exit 0 ;;
      esac
    '';
  };

  home.file.".local/bin/random-wallpaper" = {
    executable = true;
    text = ''
      #!/bin/sh
      set -eu

      WALLPAPER_DIR="$HOME/Pictures/Wallpapers"

      if [ ! -d "$WALLPAPER_DIR" ]; then
        exit 0
      fi

      wallpaper="$(
        find "$WALLPAPER_DIR" -maxdepth 1 -type f \
          \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
          | shuf -n 1
      )"

      if [ -z "$wallpaper" ]; then
        exit 0
      fi

      swww img "$wallpaper" \
        --transition-type any \
        --transition-step 90 \
        --transition-angle 0 \
        --transition-duration 2
    '';
  };

  # Daily wallpaper downloader script (Bing + NASA APOD)
  home.file.".local/bin/wallpaper-of-the-day" = {
    executable = true;
    text = ''
      #!/bin/sh
      set -eu

      WALLPAPER_DIR="$HOME/Pictures/Wallpapers"
      TODAY=$(date +%Y-%m-%d)
      mkdir -p "$WALLPAPER_DIR"

      # --- Bing Wallpaper of the Day ---
      echo "Fetching Bing wallpaper..."
      if ! BING_JSON=$(curl -sf "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=en-US"); then
        echo "Warning: Failed to fetch Bing metadata (network/DNS?)"
      else
        BING_DATE=$(echo "$BING_JSON" | jq -r '.images[0].startdate' | sed 's/\(....\)\(..\)\(..\)/\1-\2-\3/')
        BING_PATH=$(echo "$BING_JSON" | jq -r '.images[0].url')
        BING_FILE="$WALLPAPER_DIR/bing-$BING_DATE.jpg"
        if [ ! -f "$BING_FILE" ]; then
          if [ -n "$BING_PATH" ] && [ "$BING_PATH" != "null" ]; then
            # Try UHD first, fall back to the default URL
            BING_UHD=$(echo "$BING_PATH" | sed 's/1920x1080/UHD/g')
            if curl -sf "https://www.bing.com$BING_UHD" -o "$BING_FILE"; then
              echo "Saved: $BING_FILE"
            elif curl -sf "https://www.bing.com$BING_PATH" -o "$BING_FILE"; then
              echo "Saved: $BING_FILE"
            else
              echo "Warning: Failed to download Bing wallpaper"
              rm -f "$BING_FILE"
            fi
          else
            echo "Warning: Could not parse Bing image URL"
          fi
        else
          echo "Bing wallpaper already exists: $BING_FILE"
        fi
      fi

      # --- NASA Astronomy Picture of the Day ---
      echo "Fetching NASA APOD..."
      # Use DEMO_KEY by default; set NASA_API_KEY env var for your own key
      NASA_KEY="''${NASA_API_KEY:-DEMO_KEY}"
      if ! NASA_JSON=$(curl -sf "https://api.nasa.gov/planetary/apod?api_key=$NASA_KEY&thumbs=true"); then
        echo "Warning: Failed to fetch NASA APOD metadata (network/DNS or API limit?)"
      else
        NASA_DATE=$(echo "$NASA_JSON" | jq -r '.date')
        MEDIA_TYPE=$(echo "$NASA_JSON" | jq -r '.media_type')
        NASA_FILE="$WALLPAPER_DIR/nasa-apod-$NASA_DATE.jpg"
        if [ ! -f "$NASA_FILE" ]; then
          if [ "$MEDIA_TYPE" = "image" ]; then
            # Prefer hdurl, fall back to url
            NASA_URL=$(echo "$NASA_JSON" | jq -r '.hdurl // .url')
            if [ -n "$NASA_URL" ] && [ "$NASA_URL" != "null" ]; then
              if curl -sf --retry 2 --retry-delay 5 "$NASA_URL" -o "$NASA_FILE"; then
                echo "Saved: $NASA_FILE"
              else
                echo "Warning: Failed to download NASA APOD image from $NASA_URL"
                rm -f "$NASA_FILE"
              fi
            else
              echo "Warning: Could not parse NASA APOD image URL"
            fi
          else
            echo "NASA APOD is a video today; attempting to download"
            NASA_URL=$(echo "$NASA_JSON" | jq -r '.url // empty')
            NASA_THUMB=$(echo "$NASA_JSON" | jq -r '.thumbnail_url // empty')
            NASA_VIDEO_FILE="$WALLPAPER_DIR/nasa-apod-$NASA_DATE.mp4"
            if command -v yt-dlp >/dev/null 2>&1 && [ -n "$NASA_URL" ]; then
              if [ ! -f "$NASA_VIDEO_FILE" ]; then
                if yt-dlp -o "$NASA_VIDEO_FILE" "$NASA_URL"; then
                  echo "Saved: $NASA_VIDEO_FILE"
                else
                  echo "Warning: Failed to download NASA APOD video from $NASA_URL"
                  rm -f "$NASA_VIDEO_FILE"
                  NASA_URL=""
                fi
              else
                echo "NASA APOD video already exists: $NASA_VIDEO_FILE"
              fi
            fi
            if [ -n "$NASA_THUMB" ] && [ -z "$NASA_URL" ]; then
              NASA_FILE="$WALLPAPER_DIR/nasa-apod-$NASA_DATE.jpg"
              if [ ! -f "$NASA_FILE" ]; then
                if curl -sf --retry 2 --retry-delay 5 "$NASA_THUMB" -o "$NASA_FILE"; then
                  echo "Saved thumbnail: $NASA_FILE"
                else
                  echo "Warning: Failed to download NASA APOD thumbnail"
                  rm -f "$NASA_FILE"
                fi
              else
                echo "NASA APOD thumbnail already exists: $NASA_FILE"
              fi
            elif [ -z "$NASA_URL" ]; then
              echo "Warning: No video URL or thumbnail available for NASA APOD"
            fi
          fi
        else
          echo "NASA APOD already exists: $NASA_FILE"
        fi
      fi
    '';
  };

  gtk = {
    enable = true;
    theme = { name = "Orchis-Dark"; package = pkgs.orchis-theme; };
    iconTheme = { name = "Tela-circle"; package = pkgs.tela-circle-icon-theme; };
    cursorTheme = { name = "Adwaita"; package = pkgs.adwaita-icon-theme; };
  };

  qt = {
    enable = true;
    platformTheme.name = "kvantum";
    style.name = "kvantum";
  };

  wayland.windowManager.hyprland = {
    enable = true;
    systemd = {
      # disable the systemd integration, as it conflicts with uwsm.
      enable = false;
      variables = [ "--all" ];
    };
    extraConfig = ''
    env = XDG_CURRENT_DESKTOP,Hyprland
    env = XDG_SESSION_TYPE,wayland
    env = XDG_SESSION_DESKTOP,Hyprland
    env = GTK_IM_MODULE,
    env = QT_IM_MODULE,
    windowrule = tile = true, match:class = sioyek
  '';
    settings = {
      general = {
        gaps_in = 0; # Inner gaps
        gaps_out = 0; # Outer gaps
        border_size = 3;
        layout = "dwindle";
        "col.active_border" = "rgb(00FFFF)";
        "col.inactive_border" = "rgb(202020)";
        resize_on_border = true;
        extend_border_grab_area = 20;
      };
      decoration = {
        inactive_opacity = 0.9;
        dim_inactive = true;
        dim_strength = 0.1;
      };
      animations = {
        workspace_wraparound = true;
      };
      input = {
        follow_mouse = 1;
      };
      "$mod" = "SUPER";
      bind =
        [
          "$mod, F, exec, firefox"
          "$mod, Q, exec, kitty"
          "$mod, E, exec, emacs"
          "$mod, P, exec, protonvpn-app"
          "$mod, W, exec, walker"
          "$mod, B, exec, kitty -e btop"
          "$mod, N, exec, /home/thinky/.local/bin/nemo-x11"
          "$mod, S, exec, ~/.local/bin/sioyek-xcb"
          "$mod, Y, exec, kitty -e yazi"
          "$mod, Escape, exit,"
          "$mod, K, killactive,"
          "$mod, M, movetoworkspacesilent, special:minimized"
          "$mod SHIFT, M, togglespecialworkspace, minimized"
          "$mod, left, movefocus, l"
          "$mod, right, movefocus, r"
          "$mod, up, movefocus, u"
          "$mod, down, movefocus, d"
          "$mod SHIFT, F, fullscreen, 1"
          '', Print, exec, ~/.local/bin/screenshot''
          ", XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"
          ", XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
          ", XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
          ", XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"
          ", XF86AudioNext, exec, playerctl next"
          ", XF86AudioPause, exec, playerctl play-pause"
          ", XF86AudioPlay, exec, playerctl play-pause"
          ", XF86AudioPrev, exec, playerctl previous"
          ", F1, exec, sleep 0.1 && hyprctl dispatch dpms off && hyprlock"
          ", F7, exec, ddcutil setvcp 60 0x11"
          ", F8, exec, ddcutil setvcp 60 0x0f"
          ", F6, exec, ~/.local/bin/brightness-ctl up"
          ", F5, exec, ~/.local/bin/brightness-ctl down"
          ",XF86MonBrightnessUp, exec, ~/.local/bin/brightness-ctl up"
          ",XF86MonBrightnessDown, exec, ~/.local/bin/brightness-ctl down"
          "CTRL ALT, left, workspace, -1"
          "CTRL ALT, right, workspace, +1"
          "ALT, Tab, cyclenext, hist"
          "$mod, Tab, cyclenext, prev"
          # Pyprland
          "$mod, T, exec, pypr toggle term"
          "$mod, V, exec, pypr toggle volume"
          "$mod, X, exec, pypr toggle notepad"
          "$mod, Z, exec, pypr zoom"
          ", Pause, exec, pypr expose"
          ''$mod SHIFT, Escape, exec, pkill -SIGINT -f wf-recorder && sleep 1 && bash -c 'p=$(cat /tmp/last_recording_path 2>/dev/null); notify-send "Recording stopped" "Saved to: $p" -i video-x-generic -a "Screen Recorder" -t 10000 --action="scriptAction:-xdg-open $(dirname "$p")=Open Directory" --action="scriptAction:-xdg-open $p=Play"' ''
        ]
        ++ (
          # workspaces
          # binds $mod + [shift +] {1..9} to [move to] workspace {1..9}
          builtins.concatLists (builtins.genList (i:
            let ws = i + 1;
            in [
              "$mod, code:1${toString i}, workspace, ${toString ws}"
              "$mod SHIFT, code:1${toString i}, movetoworkspace, ${toString ws}"
            ]
          )
            9)
        );
      bindm = [
        # mouse movements
        "$mod, mouse:272, movewindow"
        "$mod, mouse:273, resizewindow"
        "$mod ALT, mouse:272, resizewindow"
      ];
      bindl = [
        ", F7, exec, ddcutil setvcp 60 0x11"
        ", F8, exec, ddcutil setvcp 60 0x0f"
      ];
      bindc =[
        "$mod, mouse:274, togglefloating"
      ];
      input = {
        natural_scroll = true;
        # other input settings...
      };
      # monitor = "DP-3,1920x1080@60,0x0,1";
      # Autostart programs
      exec-once = [ "uwsm app -- pypr"
                    "protonvpn-app"
                    "~/.local/bin/random-wallpaper"
                    "while true; do sleep 60; ~/.local/bin/random-wallpaper; done"
                    "systemctl --user start hyprpolkitagent"
                    "solaar --window=hide"
                  ];
      misc = {
        mouse_move_enables_dpms = true;
        key_press_enables_dpms = true;
      };
    };
  };

  programs.hyprpanel = {
    package = inputs.hyprpanel.packages.${pkgs.stdenv.hostPlatform.system}.default;
    enable = true;
    settings = {
      bar.layouts = {
        "*" = {
          left = [ "dashboard" "workspaces" "media"];
          middle = [ "windowtitle" ];
          right = [ "network" "volume"
                    "battery" "systray" "clock" "notifications" ];
        };
      };
      bar.launcher.autoDetectIcon = true;
      bar.workspaces.show_icons = true;
      menus.clock.weather.unit = "metric";
      menus.clock.weather.location = "Singapore";
      # Weather API key is stored in ~/.config/secrets/weather-api-key
      # The activation script below will read it and update config.json at runtime
      menus.clock.weather.key = "PLACEHOLDER_WILL_BE_REPLACED";
      menus.dashboard.directories.enabled = true;
      menus.dashboard.shortcuts.left.shortcut1 = {
        icon = "󰈹";
        tooltip = "Firefox";
        command = "firefox";
      };
      menus.dashboard.shortcuts.left.shortcut2 = {
        icon = "";
        tooltip = "Terminal";
        command = "kitty";
      };
      menus.dashboard.shortcuts.left.shortcut3 = {
        icon = "";
        tooltip = "Emacs";
        command = "emacs";
      };
      menus.dashboard.shortcuts.right.shortcut3 = {
        icon = "󰄀";
        tooltip = "Screenshot";
        command = "~/.local/bin/screenshot";
      };
      menus.dashboard.shortcuts.left.shortcut4 = {
        icon = "";
        tooltip = "Search Apps";
        command = "walker";
      };
      #menus.dashboard.stats.enable_gpu = true;  # Causes system freeze on NVIDIA
      theme = {
        bar.transparent = true;
        bar.outer_spacing = "0em";
        bar.buttons.enableBorders = true;
        font = {
          name = "Inter";
          size = "13px";
        };
      };
    };
  };

  services.udiskie = {
    enable = true;
    automount = true;
    notify = true;
    tray = "auto";
    settings = {
      program_options = {
        file_manager = "/home/thinky/.local/bin/nemo-x11";
      };
    };
  };

  services.hypridle.enable = true;
  services.hypridle.settings = {
    general = {
      after_sleep_cmd = "hyprctl dispatch dpms on";
      ignore_dbus_inhibit = false;
      lock_cmd = "hyprlock";
    };

    listener = [
      {
        timeout = 900;
        on-timeout = "hyprlock";
      }
      {
        timeout = 1200;
        on-timeout = "hyprctl dispatch dpms off";
        on-resume = "hyprctl dispatch dpms on";
      }
    ];
  };

  programs.hyprlock = {
    enable = true;
  };

  # Packages that should be installed to the user profile.
  home.packages = with pkgs; [
    swappy
    pyprland
    pavucontrol
    xed-editor
    sioyek
    wf-recorder
    mpv
    mpvpaper
    gnome-disk-utility
  ];

  # basic configuration of git, please change to your own
  programs.git = {
    enable = true;
    settings.user.name = "dragonleopardpig";
    settings.user.email = "dragonleopardpig@gmail.com";
  };

  # starship - an customizable prompt for any shell
  programs.starship.enable = true;
  programs.starship.settings = {
    add_newline = false;
    format = "$shlvl$username$hostname$nix_shell$git_branch$git_commit$git_state$git_status$directory$jobs$cmd_duration$all$character";
    shlvl = {
      disabled = false;
      #symbol = "ﰬ";
      style = "bright-red bold";
    };
    shell = {
      disabled = true;
      format = "$indicator";
      fish_indicator = "";
      bash_indicator = "[BASH](yellow) ";
      zsh_indicator = "[ZSH](bright-white) ";
    };
    username = {
      disabled = false;
      show_always = true;
      style_user = "bright-purple bold";
      style_root = "bright-red bold";
    };
    hostname = {
      disabled = false;
      style = " #F28C28 bold";
      ssh_only = false;
    };
    nix_shell = {
      symbol = "";
      format = "[$symbol$name]($style) ";
      style = "bright-purple bold";
    };
    git_branch = {
      only_attached = true;
      format = "[$symbol$branch]($style) ";
      # symbol = "שׂ";
      style = "bright-yellow bold";
    };
    git_commit = {
      only_detached = true;
      format = "[ﰖ$hash]($style) ";
      style = "bright-yellow bold";
    };
    git_state = {
      style = "bright-purple bold";
    };
    git_status = {
      style = "bright-green bold";
    };
    directory = {
      style = "bright-cyan bold";
      truncation_length = 10;
      truncate_to_repo = false;
    };
    cmd_duration = {
      format = "[$duration]($style) ";
      style = "bright-blue";
    };
    jobs = {
      style = "bright-green bold";
    };
    character = {
      success_symbol = "[\\$](bright-green bold)";
      error_symbol = "[\\$](bright-red bold)";
    };
  };

  programs.kitty = {
    enable = true;
    font = {
      size = 9; # Replace with your desired size
      name = "JetBrainsMono Nerd Font";
    };
    settings = {
      confirm_os_window_close = 0;
      dynamic_background_opacity = true;
      enable_audio_bell = false;
      mouse_hide_wait = "-1.0";
      window_padding_width = 10;
      background_opacity = "0.8";
      background_blur = 5;
    };
    extraConfig = ''
    map ctrl+shift+equal change_font_size all +0.5                          
    map ctrl+shift+minus change_font_size all -0.5
    map alt+w copy_to_clipboard
    map ctrl+y paste_from_clipboard

    # Optional: Copy on select
    copy_on_select yes
  '';
  };

  programs.bash = {
    enable = true;
    enableCompletion = true;
    # TODO add your custom bashrc here
    bashrcExtra = ''
      export PATH="$PATH:$HOME/bin:$HOME/.local/bin:$HOME/go/bin"
    '';

    # set some aliases, feel free to add more or remove some
    shellAliases = {
      ls = "eza --icons=always --group-directories-first --sort=extension";
      gc = "git commit -m";
      rebuild = "~/Projects/NixOS/rebuild.sh";
      btop = "btop";
    };
    initExtra = ''
      fastfetch
    '';
  };

  programs.yazi = {
    enable = true;
    shellWrapperName = "y";
    settings = {
      mgr = {
        ratio = [
          1
          3
          4
        ];
        sort_by = "extension";
        sort_sensitive = true;
        sort_reverse = false;
        sort_dir_first = true;
        linemode = "none";
        show_hidden = true;
        show_symlink = true;
      };

      preview = {
        image_filter = "lanczos3";
        image_quality = 90;
        tab_size = 1;
        max_width = 600;
        max_height = 900;
        cache_dir = "";
        ueberzug_scale = 1;
        ueberzug_offset = [
          0
          0
          0
          0
        ];
      };

      tasks = {
        micro_workers = 5;
        macro_workers = 10;
        bizarre_retry = 5;
      };
    };
  };

  # Systemd user service + timer for daily wallpaper downloads
  systemd.user.services.wallpaper-of-the-day = {
    Unit = {
      Description = "Download daily wallpapers from Bing and NASA APOD";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "%h/.local/bin/wallpaper-of-the-day";
    };
  };

  systemd.user.timers.wallpaper-of-the-day = {
    Unit = {
      Description = "Daily wallpaper download timer";
    };
    Timer = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };

  # Install firefox.
  programs.firefox.enable = true;

  programs.btop = {
    enable = true;
    package = pkgs.btop-cuda;
    settings = {
      theme_background = false;
      shown_boxes = "cpu gpu0 mem net proc";
      shown_gpus = "nvidia intel";
      show_gpu_info = "On";
      proc_left = true;
      proc_full_left = true;
      cpu_bottom = false;
      show_disks = true;
      save_config_on_exit = false;
    };
  };

  programs.fzf = {
    enable = true;
    enableBashIntegration = true;
    defaultOptions = [ "--height 40%" "--border" ];
  };

  programs.bat.enable = true;

  programs.eza = {
    enable = true;
    enableBashIntegration = false; # custom alias in programs.bash
  };

  programs.ripgrep = {
    enable = true;
    arguments = [ "--smart-case" "--hidden" "--glob=!.git" ];
  };

  programs.direnv = {
    enable = true;
    enableBashIntegration = true;
    nix-direnv.enable = true;
  };

  programs.fastfetch = {
    enable = true;
    settings = {
      logo = {
        source = "nixos";
        padding.top = 1;
        color = {
          "1" = "#ff8bd1";
          "2" = "#8ed8ff";
          "3" = "#f06ccf";
          "4" = "#77c7ff";
          "5" = "#d95fe6";
          "6" = "#a990ff";
          "7" = "#b57cff";
          "8" = "#c68cff";
          "9" = "#d59bff";
        };
      };
      display.separator = " 󰑃  ";
      modules = [
        "break"
        { type = "os"; key = "󰣇 DISTRO"; keyColor = "yellow"; }
        { type = "kernel"; key = "│ ├󰒋"; keyColor = "yellow"; }
        { type = "packages"; key = "│ ├󰏖"; keyColor = "yellow"; }
        { type = "shell"; key = "│ └󰆍"; keyColor = "yellow"; }
        { type = "wm"; key = "󱂬 DE/WM"; keyColor = "blue"; }
        { type = "wmtheme"; key = "│ ├󰉼"; keyColor = "blue"; }
        { type = "icons"; key = "│ ├󰀻"; keyColor = "blue"; }
        { type = "cursor"; key = "│ ├󰇀"; keyColor = "blue"; }
        { type = "terminalfont"; key = "│ ├󰛖"; keyColor = "blue"; }
        { type = "terminal"; key = "│ └"; keyColor = "blue"; }
        { type = "host"; key = "󰌢 SYSTEM"; keyColor = "green"; }
        { type = "cpu"; key = "│ ├󰻠"; keyColor = "green"; }
        { type = "gpu"; key = "│ ├󰻑"; format = "{2}"; keyColor = "green"; }
        { type = "display"; key = "│ ├󰍹"; keyColor = "green"; compactType = "original-with-refresh-rate"; }
        { type = "memory"; key = "│ ├󰾆"; keyColor = "green"; }
        { type = "swap"; key = "│ ├󰓡"; keyColor = "green"; }
        { type = "uptime"; key = "│ ├󰅐"; keyColor = "green"; }
        { type = "display"; key = "│ └󰍹"; keyColor = "green"; }
        { type = "sound"; key = " AUDIO"; format = "{2}"; keyColor = "magenta"; }
        { type = "player"; key = "│ ├󰥠"; keyColor = "magenta"; }
        { type = "media"; key = "│ └󰝚"; keyColor = "magenta"; }
        { type = "colors"; paddingLeft = 2; symbol = "circle"; }
        "break"
      ];
    };
  };
  programs.jq.enable = true;
  programs.pandoc.enable = true;
  programs.feh.enable = true;
  programs.nnn.enable = true;
  programs.htop.enable = true;



  imports = [
    inputs.walker.homeManagerModules.default
  ];

  programs.walker = {
    enable = true;
    runAsService = true;
  };

  home.activation.createProjectsDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "$HOME/Projects"
    ${pkgs.glib}/bin/gio set "$HOME/Projects" metadata::custom-icon-name folder-development || true
  '';

  home.activation.makeHyprpanelConfigWritable = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    if [ -L "$HOME/.config/hyprpanel/config.json" ]; then
      cp --remove-destination "$(readlink "$HOME/.config/hyprpanel/config.json")" "$HOME/.config/hyprpanel/config.json"
      chmod u+w "$HOME/.config/hyprpanel/config.json"
    fi
    # Inject the weather API key from secrets file
    if [ -f "$HOME/.config/secrets/weather-api-key" ] && [ -f "$HOME/.config/hyprpanel/config.json" ]; then
      API_KEY=$(cat "$HOME/.config/secrets/weather-api-key" | tr -d '\n')
      ${pkgs.jq}/bin/jq --arg key "$API_KEY" '.menus.clock.weather.key = $key' "$HOME/.config/hyprpanel/config.json" > "$HOME/.config/hyprpanel/config.json.tmp"
      mv "$HOME/.config/hyprpanel/config.json.tmp" "$HOME/.config/hyprpanel/config.json"
    fi
    # Restart HyprPanel so it picks up the injected key (file monitor may miss it due to race)
    if ${pkgs.procps}/bin/pgrep -f hyprpanel >/dev/null 2>&1; then
      ${pkgs.procps}/bin/pkill -f hyprpanel || true
      sleep 1
      ${pkgs.coreutils}/bin/nohup uwsm app -- hyprpanel >/dev/null 2>&1 &
    fi
  '';

  home.activation.refreshWalkerIcons = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    if [ -d "$HOME/.local/share/icons/hicolor" ]; then
      ${pkgs.gtk3}/bin/gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" || true
    fi
    if ${pkgs.systemd}/bin/systemctl --user is-active walker >/dev/null 2>&1; then
      ${pkgs.systemd}/bin/systemctl --user restart walker || true
    fi
  '';
  home.stateVersion = "25.11";
}
