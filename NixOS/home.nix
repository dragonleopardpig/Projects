{ lib, config, osConfig, inputs, pkgs, ... }:
let
  # On X299 / X299-SSD the monitor uses DDC/CI. ddcci_backlight does bind
  # (see boot.extraModprobeConfig), but every i2c transaction to the
  # monitor's MCU is ~75 ms — too slow for waybar's draggable slider,
  # which fires many value-changed events per drag and queues writes
  # faster than they drain. So those hosts use a custom indicator
  # + scroll/click instead of `backlight/slider`. Everything else
  # (M90aPro's intel_backlight, PortableSSD's whatever it boots on)
  # keeps the real slider.
  useScrollIndicator =
    osConfig.networking.hostName == "X299"
    || osConfig.networking.hostName == "X299-SSD";
  nemoMegaLibraryPath = lib.makeLibraryPath [
    pkgs.nemo
    pkgs.glib
  ];
  megasyncWalkerIcon = pkgs.runCommand "megasync-walker-icon.png"
    { nativeBuildInputs = [ pkgs.imagemagick ]; } ''
    magick "${pkgs.megasync.src}/src/MEGAUpdater/app_ico.ico[0]" -resize 256x256 "PNG32:$out"
  '';
  # Python with lunarcalendar for the custom/lunar waybar module.
  pythonLunar = pkgs.python3.withPackages (ps: [ ps.lunarcalendar ]);
  # Tree-sitter grammars built by Nix (json/python/html/css/bash/…), matched
  # to emacs-pgtk's ABI.  Replaces manual `treesit-install-language-grammar`:
  # ~/Projects/emacs/preload.el loads the generated ~/.emacs.d/nix-tree-sitter.el
  # below, which adds this dir to `treesit-extra-load-path`.  magik/rust stay
  # as the prebuilt .so in ~/Projects/emacs/tree-sitter/.
  emacsTreesitGrammars =
    (pkgs.emacsPackagesFor pkgs.emacs-pgtk).treesit-grammars.with-all-grammars;
in
{
  home.username = "thinky";
  home.homeDirectory = "/home/thinky";
  home.sessionVariables = {
    BROWSER = "firefox";
  };
  xdg.userDirs = {
    enable = true;
    createDirectories = true;
    setSessionVariables = false;
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
    exec = "/home/thinky/.local/bin/sioyek-xcb --new-window %f";
    icon = "sioyek";
    comment = "Sioyek document viewer in a separate window (XWayland)";
    # Sioyek renders through MuPDF, so EPUB is native -- no conversion involved.
    # It has to be declared here or Sioyek never appears as a choice for one.
    mimeType = [
      "application/pdf"
      "application/epub+zip"
      "image/vnd.djvu"
      "image/vnd.djvu+multipage"
      "image/x-djvu"
    ];
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

  xdg.desktopEntries.remmina-xcb = {
    name = "Remmina (X11)";
    exec = "/home/thinky/.local/bin/remmina-xcb %U";
    icon = "remmina";
    comment = "Remmina Remote Desktop (forced X11 for clipboard sync)";
    categories = [ "Network" "RemoteAccess" ];
    terminal = false;
  };

  xdg.desktopEntries.onlyoffice-desktopeditors = {
    name = "ONLYOFFICE";
    exec = "/home/thinky/.local/bin/onlyoffice-desktopeditors %U";
    icon = "onlyoffice-desktopeditors";
    comment = "ONLYOFFICE Desktop Editors (XWayland)";
    genericName = "Document Editor";
    categories = [ "Office" "WordProcessor" "Spreadsheet" "Presentation" ];
    mimeType = [
      "application/msword"
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      "application/vnd.openxmlformats-officedocument.presentationml.presentation"
      "application/vnd.oasis.opendocument.text"
      "application/vnd.oasis.opendocument.spreadsheet"
      "application/vnd.oasis.opendocument.presentation"
      "application/pdf"
      "text/plain"
    ];
    settings = {
      StartupWMClass = "ONLYOFFICE";
    };
    terminal = false;
  };

  home.file.".local/bin/megasync" = {
    executable = true;
    text = ''
      #!/bin/sh
      export QT_QPA_PLATFORM=wayland
      export DO_NOT_UNSET_XDG_SESSION_TYPE=1
      exec ${pkgs.megasync}/bin/megasync "$@"
    '';
  };

  xdg.desktopEntries.megasync = {
    name = "MEGAsync";
    exec = "/home/thinky/.local/bin/megasync";
    icon = "megasync";
    comment = "MEGA Desktop App (Wayland)";
    categories = [ "Network" "FileTransfer" "Utility" ];
    terminal = false;
    settings = {
      StartupWMClass = "nz.co.mega.megasync";
    };
  };

  home.file.".local/share/icons/hicolor/256x256/apps/megasync.png".source = megasyncWalkerIcon;
  home.file.".local/share/icons/hicolor/256x256/apps/MEGAsync.png".source = megasyncWalkerIcon;

  home.file.".local/bin/nemo-x11" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -eu

      DEB_PATH="$HOME/Downloads/nemo-megasync-xUbuntu_24.04_amd64.deb"
      APP_DIR="$HOME/.local/opt/nemo-megasync-deb"
      EXT_DIR="$APP_DIR/usr/lib/x86_64-linux-gnu/nemo/extensions-3.0"
      STAMP="$APP_DIR/.deb-source"

      if [ -f "$DEB_PATH" ]; then
        DEB_ID="$(${pkgs.coreutils}/bin/stat -c '%Y:%s' "$DEB_PATH")"
        mkdir -p "$APP_DIR"
        if [ ! -f "$EXT_DIR/libMEGAShellExtNemo.so" ] || [ ! -f "$STAMP" ] || [ "$(${pkgs.coreutils}/bin/cat "$STAMP" 2>/dev/null || true)" != "$DEB_ID" ]; then
          TMP_DIR="$(${pkgs.coreutils}/bin/mktemp -d "$HOME/.local/opt/nemo-megasync-deb.tmp.XXXXXX")"
          trap '${pkgs.coreutils}/bin/rm -rf "$TMP_DIR"' EXIT
          ${pkgs.dpkg}/bin/dpkg -x "$DEB_PATH" "$TMP_DIR"
          printf '%s\n' "$DEB_ID" > "$TMP_DIR/.deb-source"
          ${pkgs.coreutils}/bin/rm -rf "$APP_DIR"
          ${pkgs.coreutils}/bin/mv "$TMP_DIR" "$APP_DIR"
          trap - EXIT
        fi
        export LD_LIBRARY_PATH="$EXT_DIR:${nemoMegaLibraryPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        export NEMO_EXTENSION_DIR="$EXT_DIR"
        export NEMO_EXTENSION_DIRS="$EXT_DIR"
        export XDG_DATA_DIRS="$APP_DIR/usr/share''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
      fi

      export GDK_BACKEND=x11
      export QT_QPA_PLATFORM=xcb
      exec nemo "$@"
    '';
  };

  home.file.".local/bin/nomacs-x11" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -eu

      export QT_QPA_PLATFORM=xcb
      exec ${pkgs.nomacs}/bin/nomacs "$@"
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

  xdg.desktopEntries.nomacs-x11 = {
    name = "Nomacs";
    exec = "/home/thinky/.local/bin/nomacs-x11 %U";
    icon = "nomacs";
    comment = "Image viewer/editor (XWayland)";
    categories = [ "Graphics" "Viewer" ];
    terminal = false;
    mimeType = [
      "image/png"
      "image/jpeg"
      "image/gif"
      "image/webp"
      "image/bmp"
      "image/svg+xml"
      "image/tiff"
    ];
  };

  home.file.".local/bin/filen-desktop" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -eu

      export XDG_CURRENT_DESKTOP=Hyprland

      # Single-instance guard. Filen-desktop has no single-instance lock, so a
      # second launch spawns a duplicate that registers its OWN tray icon.
      # Quitting one instance then leaves the other's icon orphaned in the bar.
      # If one is already running, reveal its window instead of starting another.
      if ${pkgs.procps}/bin/pgrep -f '@filen/desktop/dist/index\.js' >/dev/null 2>&1; then
        if [ "''${1:-}" != "--hidden" ]; then
          hyprctl dispatch focuswindow 'class:^([Ff]ilen[ -][Dd]esktop)$' >/dev/null 2>&1 || true
        fi
        exit 0
      fi

      # Start Filen as a low-priority background UWSM service so it is stopped
      # with the graphical session. Nice, idle I/O scheduling, and LimitCORE
      # are inherited even when Electron moves a process into its own scope.
      # LimitCORE is essential here: a Filen/Electron exit crash otherwise
      # makes systemd-coredump stream tens of gigabytes and saturate the disk.
      exec ${pkgs.uwsm}/bin/uwsm app \
        -s b \
        -t service \
        -u filen-desktop.service \
        -d "Filen Desktop sync client" \
        -p CPUWeight=20 \
        -p MemoryHigh=4G \
        -p IOWeight=10 \
        -p Nice=10 \
        -p IOSchedulingClass=idle \
        -p LimitCORE=0 \
        -- ${pkgs.filen-desktop}/bin/filen-desktop "$@"
    '';
  };

  xdg.desktopEntries.filen-desktop = {
    name = "Filen Desktop";
    exec = "/home/thinky/.local/bin/filen-desktop";
    icon = "filen-desktop";
    comment = "Encrypted Cloud Storage";
    categories = [ "Network" "FileTransfer" "Utility" ];
    settings = {
      Keywords = "cloud;storage;encrypted;";
      StartupWMClass = "filen-desktop";
    };
    terminal = false;
  };

  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "inode/directory" = [ "nemo-x11.desktop" ];
      "application/pdf" = [ "sioyek-xcb.desktop" ];
      # Without this an EPUB falls through to whatever the system MIME cache
      # picks -- OnlyOffice, here. Nemo's "Set as default" cannot fix that,
      # because this file is a read-only symlink into the Nix store.
      "application/epub+zip" = [ "sioyek-xcb.desktop" ];
      # Native since the sioyek-native-djvu patch; no conversion involved.
      "image/vnd.djvu" = [ "sioyek-xcb.desktop" ];
      "image/vnd.djvu+multipage" = [ "sioyek-xcb.desktop" ];
      "image/x-djvu" = [ "sioyek-xcb.desktop" ];
      "image/png" = [ "nomacs-x11.desktop" ];
      "image/jpeg" = [ "nomacs-x11.desktop" ];
      "image/gif" = [ "nomacs-x11.desktop" ];
      "image/webp" = [ "nomacs-x11.desktop" ];
      "image/bmp" = [ "nomacs-x11.desktop" ];
      "image/svg+xml" = [ "nomacs-x11.desktop" ];
      "text/html" = [ "firefox.desktop" ];
      "x-scheme-handler/http" = [ "firefox.desktop" ];
      "x-scheme-handler/https" = [ "firefox.desktop" ];
      "x-scheme-handler/about" = [ "firefox.desktop" ];
      "x-scheme-handler/unknown" = [ "firefox.desktop" ];
      "text/plain" = [ "xed.desktop" ];
      "text/markdown" = [ "xed.desktop" ];
    };
  };
  
  xdg.configFile."uwsm/env".source = "${config.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh";

  # ── AGS v2 (Astal) config ────────────────────────────────────────────
  # Source files live in NixOS/ags/. We assemble the dir as a single
  # derivation so sibling imports (./widget/Bar, ./style.scss) resolve
  # under the same store path — esbuild follows symlink targets, so
  # per-file xdg.configFile entries each land in their own store path
  # and break relative imports. package.json is generated here because
  # it pins astal-gjs to a nix store path that varies by revision.
  xdg.configFile."ags".source = pkgs.runCommand "ags-config" { } ''
    mkdir -p $out
    cp -r ${./ags}/. $out/
    chmod -R u+w $out
    cat > $out/package.json <<'JSON'
    ${builtins.toJSON {
      name = "astal-shell";
      dependencies.astal = "${pkgs.astal.gjs}/share/astal/gjs";
    }}
    JSON
    # Nix-store absolute paths for the existing Python widgets, baked in at
    # build time so the TSX widgets can poll them without hardcoding paths.
    mkdir -p $out/lib
    cat > $out/lib/paths.ts <<'TS'
    export const HOST = "${osConfig.networking.hostName}";
    // Per-monitor display scaling (Windows-style). Absolute, so it does not
    // depend on the bar inheriting ~/.local/bin on PATH.
    export const DISPLAY_SCALE_CMD = "${config.home.homeDirectory}/.local/bin/display-scale";
    export const WEATHER_CMD =
        "${pkgs.curl}/bin/curl -sf 'https://wttr.in/Singapore?format=%c+%t'";
    // Detailed forecast fetcher for the Weather popup; emits slim JSON.
    export const WEATHER_FETCH_BIN = "${pkgs.python3}/bin/python3";
    export const WEATHER_FETCH_SCRIPT = "${./assets/weather-fetch.py}";
    export const WEATHER_CITY = "Singapore";
    // Calendar month dump: ${pythonLunar}/bin/python3 calendar-month.py YYYY-MM <ics-dir>
    // (The bar's old standalone Lunar/Holiday widgets were replaced by the
    //  calendar popup, which exposes both lunar and event data per-cell.)
    export const CALENDAR_BIN =
        "${pythonLunar}/bin/python3";
    export const CALENDAR_SCRIPT =
        "${./assets/calendar-month.py}";
    export const CALENDAR_ICS_DIR =
        "${./assets/calendars}";
    export const SWAYNC_WATCH = ["swaync-client", "-swb"];
    export const SWAYNC_TOGGLE = "swaync-client -t -sw";
    export const SWAYNC_DND = "swaync-client -d -sw";
    export const WLOGOUT_CMD = "wlogout";
    TS
  '';


  xdg.configFile."swappy/config".text = ''
    [Default]
    save_dir=$HOME/Pictures/Screenshots
    save_filename_format=swappy-%Y%m%d-%H%M%S.png
  '';

  # Sioyek keybindings. Upstream ships all three of these commands unbound.
  # force, because this replaces a hand-edited file that predates being managed.
  # Sioyek only ever writes prefs_user.config (via setconfig), never this file,
  # so a read-only store symlink is safe — but its built-in `keys_user` command
  # opens this path in an editor, and that edit can no longer be saved. Change
  # bindings here instead.
  xdg.configFile."sioyek/keys_user.config".force = true;
  xdg.configFile."sioyek/keys_user.config".text = ''
    # Toggle two page (book spread) mode: pages side-by-side, earlier page on the left.
    # bare `d` is a prefix for db/dh/dp (delete commands), so use Ctrl+d.
    toggle_two_page_mode <C-d>

    # Fit the whole page height into the window. In two page mode an A4 spread is
    # 1191x839pt (aspect 1.42) while a 1920x1080 window is aspect 1.78, so fitting
    # to width makes the spread 1353px tall and the bottom ~20% -- the last one or
    # two lines -- falls outside the window. That reads as a clipped page but is
    # only the viewport.
    fit_to_page_height <C-h>

    # Same, but fits the text block rather than the paper, so margins are trimmed
    # and the type comes out larger. Better on a scan with generous margins.
    # Sioyek rejects the <C-S-h> form: an uppercase letter carries the shift.
    fit_to_page_height_smart <C-H>

    # PageUp/Down step a whole page. Upstream binds them to screen_down/screen_up,
    # which move only move_screen_ratio of a screen (0.5 by default) and so creep
    # half a page at a time. next_page moves by one page height instead, and in two
    # page mode that is exactly one spread, so it stays aligned to page boundaries.
    #
    # Space is deliberately NOT rebound: it keeps upstream's partial scroll, which
    # is what you want for continuous reading and is the safe one when zoomed in
    # past fit-to-height, where whole-page steps would skip the bottom of a page.
    next_page <pagedown>
    previous_page <pageup>

    # Area snapshot: drag a box, get a cropped PNG. Sioyek ships no such command,
    # so _snip is defined in prefs_user.config below.
    _snip s
  '';

  # Sioyek reads a prefs_user.config from both ~/.local/share/sioyek and
  # ~/.config/sioyek, and writes to the last one that exists -- this one. So
  # `setconfig` commands and the settings UI can no longer persist anything;
  # change settings here and rebuild instead. Nothing writes it during normal
  # reading, only an explicit settings change.
  xdg.configFile."sioyek/prefs_user.config".force = true;
  xdg.configFile."sioyek/prefs_user.config".text = ''
    # Custom command names must begin with an underscore. Sioyek prompts for a
    # rectangle because the command mentions %{selected_rect}, then substitutes
    # "page,x0,y0,x1,y1" in page-relative points. It runs the command through
    # QProcess with an argv list, not a shell, so %{file_path} survives spaces
    # in the filename without quoting.
    new_command _snip sioyek-snip %{selected_rect} %{file_path}
  '';

  services.cliphist = {
    enable = true;
    allowImages = true;
  };
  xdg.dataFile."xdg-desktop-portal/portals/gtk.portal".source =
    "${pkgs.xdg-desktop-portal-gtk}/share/xdg-desktop-portal/portals/gtk.portal";
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

  # nwg-drawer (fullscreen Unity/GNOME-Activities-style app grid) — cyberpunk
  # palette matching waybar. Auto-loaded from $XDG_CONFIG_HOME/nwg-drawer/.
  xdg.configFile."nwg-drawer/drawer.css".text = ''
    /* Palette: bg #0a0a0a   card #1a1a1a   border #2a2a2a
       yellow #ffd700   cyan #00ffff   pink #ff69b4
       orange #ff4500   green #32cd32   muted #585858 */

    * {
      font-family: "CaskaydiaCove Nerd Font", "Symbols Nerd Font", sans-serif;
      font-size: 13px;
      color: #ffd700;
    }

    window {
      background-color: rgba(10, 10, 10, 0.92);
    }

    /* Search box at the top of the drawer */
    entry {
      background-color: #1a1a1a;
      color: #ffd700;
      border: 1px solid #2a2a2a;
      border-radius: 10px;
      padding: 8px 14px;
      caret-color: #00ffff;
    }
    entry:focus {
      border: 1px solid #00ffff;
    }
    entry selection {
      background-color: #ff69b4;
      color: #0a0a0a;
    }

    /* App icons + category buttons */
    button, image {
      background: none;
      border: 1px solid transparent;
      border-radius: 12px;
      padding: 6px;
    }
    button:hover {
      background-color: #1a1a1a;
      border: 1px solid #ff69b4;
    }
    button:focus,
    button:active {
      background-color: #1a1a1a;
      border: 1px solid #00ffff;
      color: #00ffff;
    }
    label { color: #ffd700; }

    #category-button {
      margin: 0 8px;
      color: #585858;
    }
    #category-button:hover { color: #ffd700; }

    /* Pinned strip across the top */
    #pinned-box {
      padding-bottom: 8px;
      border-bottom: 1px solid #2a2a2a;
    }

    /* File search results box — nwg-drawer always reserves this widget (grid
       width x 1px) even when empty, so giving it a border/background paints a
       centered bar across the drawer. Keep it chromeless; the result buttons
       below carry their own styling from the button rules above. */
    #files-box {
      padding: 0;
      border: none;
      background: none;
    }

    #math-label {
      font-weight: bold;
      font-size: 16px;
      color: #32cd32;
    }

    tooltip {
      background-color: #0a0a0a;
      border: 1px solid #2a2a2a;
      border-radius: 8px;
    }
    tooltip label { color: #ffd700; padding: 4px; }
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

  # Hide system .desktop entries that duplicate our wrappers in Walker.
  # Each override shadows the system entry by sharing the same desktop ID.
  # FreeCAD: route through freecad-opaque wrapper so launcher-spawned
  # invocations inherit the NVIDIA EGL/GLX env that a plain `FreeCAD`
  # call lacks (otherwise Qt's wayland → xcb fallback can't init GL).
  xdg.desktopEntries."org.freecad.FreeCAD" = {
    name = "FreeCAD";
    genericName = "CAD Application";
    comment = "Feature based Parametric Modeler (XWayland, NVIDIA EGL)";
    exec = "/home/thinky/.local/bin/freecad-opaque %F";
    icon = "org.freecad.FreeCAD";
    categories = [ "Graphics" "Science" "Education" "Engineering" ];
    mimeType = [
      "application/x-extension-fcstd"
      "model/step" "model/step+zip" "model/iges" "application/iges"
      "model/stl" "model/obj" "model/vrml" "model/vnd.collada+xml"
      "image/vnd.dwg" "image/vnd.dxf" "application/vnd.shp"
    ];
    startupNotify = true;
    settings.StartupWMClass = "FreeCAD";
    terminal = false;
  };
  xdg.desktopEntries.sioyek                   = { name = "Sioyek";   exec = "true"; noDisplay = true; };
  xdg.desktopEntries.mayo                     = { name = "Mayo";     exec = "true"; noDisplay = true; };
  xdg.desktopEntries.gmsh                     = { name = "Gmsh";     exec = "true"; noDisplay = true; };
  xdg.desktopEntries.f3d                      = { name = "F3D";      exec = "true"; noDisplay = true; };
  xdg.desktopEntries."f3d-plugin-assimp"      = { name = "F3D";      exec = "true"; noDisplay = true; };
  xdg.desktopEntries."f3d-plugin-hdf"         = { name = "F3D";      exec = "true"; noDisplay = true; };
  xdg.desktopEntries."f3d-plugin-native"      = { name = "F3D";      exec = "true"; noDisplay = true; };
  xdg.desktopEntries."f3d-plugin-occt"        = { name = "F3D";      exec = "true"; noDisplay = true; };
  xdg.desktopEntries."f3d-plugin-usd"         = { name = "F3D";      exec = "true"; noDisplay = true; };
  xdg.desktopEntries."org.paraview.ParaView"  = { name = "ParaView"; exec = "true"; noDisplay = true; };
  xdg.desktopEntries.nemo                     = { name = "Files";    exec = "true"; noDisplay = true; };
  xdg.desktopEntries."org.nomacs.ImageLounge" = { name = "nomacs";   exec = "true"; noDisplay = true; };


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
      # Force XWayland + opaque Qt style to avoid transparency under Wayland/Kvantum.
      # The XCB platform + Fusion style + cleared platform theme gets opaque
      # backgrounds; hardware GL is left alone so FreeCAD's 3D viewport
      # (QOpenGLWidget / Coin3D) can create real GLX contexts on NVIDIA.
      export QT_QPA_PLATFORM=xcb
      export XDG_SESSION_TYPE=x11
      export XDG_CURRENT_DESKTOP=X-Generic
      export QT_QPA_PLATFORMTHEME=
      export QT_STYLE_OVERRIDE=Fusion
      export QT_X11_NO_MITSHM=1
      export QT_AUTO_SCREEN_SCALE_FACTOR=0
      export GDK_BACKEND=x11
      export NO_AT_BRIDGE=1
      # NVIDIA driver via GLVND (also keeps f3d thumbnailer off Mesa)
      export __EGL_VENDOR_LIBRARY_FILENAMES=/run/opengl-driver/share/glvnd/egl_vendor.d/10_nvidia.json
      export __GLX_VENDOR_LIBRARY_NAME=nvidia
      exec ${pkgs.freecad}/bin/FreeCAD "$@"
    '';
  };

  # Remmina wrapper: force X11/XWayland for reliable clipboard sync with remote
  home.file.".local/bin/remmina-xcb" = {
    executable = true;
    text = ''
      #!/bin/sh
      # Force XWayland to ensure clipboard sync bridge works reliably
      export GDK_BACKEND=x11
      export QT_QPA_PLATFORM=xcb
      export XDG_SESSION_TYPE=x11
      # Compatibility flags for X11 clipboard sync
      export QT_X11_NO_MITSHM=1
      export GDK_SCALE=1
      # Ensure clipboard bridge is active by nudging xclip
      if command -v xclip >/dev/null 2>&1; then
        # Sometimes RDP needs the image to be in both CLIPBOARD and PRIMARY
        # We don't change current content here, just ensuring the environment is right
        echo "Starting Remmina in XWayland mode for clipboard compatibility..."
      fi
      exec remmina "$@"
    '';
  };

  # ONLYOFFICE wrapper: avoid Kvantum/XWayland GL issues under Hyprland
  home.file.".local/bin/onlyoffice-desktopeditors" = {
    executable = true;
    text = ''
      #!/bin/sh
      cjk_font_dir="$HOME/.local/share/fonts"
      cjk_font="$cjk_font_dir/wqy-zenhei-onlyoffice.ttc"
      cjk_font_source="${pkgs.wqy_zenhei}/share/fonts/wqy-zenhei.ttc"
      if [ ! -f "$cjk_font" ] || ! cmp -s "$cjk_font_source" "$cjk_font"; then
        mkdir -p "$cjk_font_dir"
        cp -f "$cjk_font_source" "$cjk_font"
        rm -rf "$HOME/.local/share/onlyoffice/desktopeditors/data/fonts"
      fi
      export QT_QPA_PLATFORM=xcb
      export XLIB_SKIP_ARGB_VISUALS=1
      export NO_AT_BRIDGE=1
      unset QT_QPA_PLATFORMTHEME
      export QT_STYLE_OVERRIDE=Fusion
      export QT_X11_NO_MITSHM=1
      exec ${pkgs.onlyoffice-desktopeditors}/bin/onlyoffice-desktopeditors "$@"
    '';
  };

  home.file.".local/bin/screenshot" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -eu
      geometry=$(slurp)
      sleep 0.2
      grim -g "$geometry" - | swappy -f -
    '';
  };

  home.file.".local/bin/screenshot-full" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -eu
      grim - | swappy -f -
    '';
  };

  home.file.".local/bin/screenshot-monitor" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -eu
      out=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .name')
      grim -o "$out" - | swappy -f -
    '';
  };

  home.file.".local/bin/screenshot-window" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -eu
      # Feed all on-screen window rects to slurp; click one to capture it.
      geom=$(hyprctl clients -j \
        | jq -r '.[] | select(.workspace.id >= 0 and .mapped == true and .hidden == false)
                     | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"' \
        | slurp)
      sleep 0.2
      grim -g "$geom" - | swappy -f -
    '';
  };

  home.file.".local/bin/brightness-ctl" = {
    executable = true;
    text = ''
      #!/bin/sh
      # Backlight backend selection (preferred order):
      #   1. a native sysfs panel, by name: intel_backlight (M90aPro),
      #      amdgpu_bl*, nvidia_0 (what the NVIDIA driver exposes once the
      #      panel is routed to the dGPU by the BIOS MUX), then
      #      nvidia_wmi_ec_backlight (Predator Helios Neo 16 in hybrid mode --
      #      its panel hangs off the EC through NVIDIA's WMI bridge, so there
      #      is no intel_backlight at all), acpi_video0; then any other
      #      non-ddcci entry, so an unknown laptop still lands on its panel
      #      instead of falling through to DDC.
      #   2. ddcci* (X299 hosts via ddcci_backlight, ~75 ms per write)
      #   3. ddcutil setvcp 10 (last-ditch; only if no sysfs entry exists)
      pick_dev() {
        for d in intel_backlight amdgpu_bl0 amdgpu_bl1 nvidia_0 nvidia_wmi_ec_backlight acpi_video0; do
          if [ -d "/sys/class/backlight/$d" ]; then echo "$d"; return; fi
        done
        for d in /sys/class/backlight/*/; do
          [ -d "$d" ] || continue
          n=''${d%/}; n=''${n##*/}
          case "$n" in ddcci*) continue ;; esac
          echo "$n"; return
        done
        ls /sys/class/backlight/ 2>/dev/null | grep -m1 ddcci || true
      }

      # Which screen is the user actually looking at?  A laptop panel and an
      # external monitor have completely different controls -- sysfs backlight
      # versus DDC/CI over i2c -- so F5/F6 has to follow focus instead of
      # always dimming the built-in panel.
      focused_mon() {
        hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.focused) | .name' 2>/dev/null || true
      }

      # DDC bus number for a DRM connector.  i915 links an i2c adapter under
      # the connector in sysfs, but the proprietary NVIDIA driver does not, so
      # fall back to asking ddcutil -- which probes every bus and takes about a
      # second, hence the cache.
      ddc_bus() {
        [ -n "$1" ] || return 1
        cache="''${XDG_RUNTIME_DIR:-/tmp}/ddc-bus-$1"
        if [ -s "$cache" ]; then cat "$cache"; return 0; fi
        for d in /sys/class/drm/card*-"$1"/i2c-*; do
          [ -e "$d" ] || continue
          printf '%s\n' "''${d##*/i2c-}" | tee "$cache"
          return 0
        done
        b=$(ddcutil detect --terse 2>/dev/null | awk -v c="$1" '
              /I2C bus:/       { bus = $NF; sub(/.*\/i2c-/, "", bus) }
              /DRM connector:/ { if ($NF ~ ("-" c "$")) { print bus; exit } }')
        [ -n "$b" ] || return 1
        printf '%s\n' "$b" | tee "$cache"
      }

      case "''${1:-}" in
        up|down)
          MON=$(focused_mon)
          case "$MON" in
            ""|eDP-*) DEV=$(pick_dev) ;;
            # External screen: ddcci_backlight is a fast sysfs path where it
            # managed to bind (the X299 desktop).  It does not bind here --
            # ddcci-setup runs long before the NVIDIA i2c bus exists -- so the
            # laptop falls through to speaking DDC/CI directly.
            *)        DEV=$(ls /sys/class/backlight/ 2>/dev/null | grep -m1 ddcci || true) ;;
          esac
          if [ -n "$DEV" ]; then
            [ "$1" = up ] && brightnessctl -d "$DEV" set +10% \
                          || brightnessctl -d "$DEV" set 10%-
          else
            BUS=$(ddc_bus "$MON" || true)
            if [ -z "$BUS" ]; then
              notify-send -a Brightness -i display-brightness -t 2000 \
                "No brightness control" "$MON exposes neither a backlight nor DDC/CI." \
                2>/dev/null || true
              exit 0
            fi
            if [ "$1" = up ]; then ddcutil --bus "$BUS" setvcp 10 + 10
            else                   ddcutil --bus "$BUS" setvcp 10 - 10
            fi || rm -f "''${XDG_RUNTIME_DIR:-/tmp}/ddc-bus-$MON"
            # AGS cannot poll DDC-only monitors without issuing an expensive
            # I2C read every 200 ms, so report the new value explicitly.
            line=$(ddcutil --bus "$BUS" --terse getvcp 10 2>/dev/null || true)
            if [ -n "$line" ]; then
              cur=$(echo "$line" | awk '{print $4}')
              max=$(echo "$line" | awk '{print $5}')
              [ "$max" -gt 0 ] || max=100
              pct=$(( cur * 100 / max ))
              ags request "brightness:$pct" >/dev/null 2>&1 || true
            fi
          fi
          pkill -RTMIN+8 waybar 2>/dev/null || true
          ;;
        status)
          DEV=$(pick_dev)
          if [ -n "$DEV" ]; then
            cur=$(cat "/sys/class/backlight/$DEV/actual_brightness")
            max=$(cat "/sys/class/backlight/$DEV/max_brightness")
          else
            line=$(ddcutil --terse getvcp 10 2>/dev/null || true)
            if [ -z "$line" ]; then
              printf '{"text":"󰃟 ?","tooltip":"no backlight","class":"err"}\n'
              exit 0
            fi
            cur=$(echo "$line" | awk '{print $4}')
            max=$(echo "$line" | awk '{print $5}')
          fi
          [ "$max" -gt 0 ] || max=100
          pct=$(( cur * 100 / max ))
          filled=$(( pct / 10 ))
          bar=""
          i=0
          while [ "$i" -lt 10 ]; do
            if [ "$i" -lt "$filled" ]; then bar="''${bar}█"; else bar="''${bar}░"; fi
            i=$(( i + 1 ))
          done
          printf '{"text":"󰃟 %s %d","tooltip":"Brightness: %d%%\\nScroll to adjust  ·  F5/F6","percentage":%d,"class":"ok"}\n' "$bar" "$pct" "$pct" "$pct"
          ;;
        *) echo "Usage: brightness-ctl {up|down|status}" >&2; exit 1 ;;
      esac
    '';
  };

  # Win+P-style display-mode cycle, bound to F7 / XF86Display.
  #
  # Acer's F7 "display of choice" key only does anything under the Windows
  # Predator driver.  On Linux the Acer WMI hotkeys and Video Bus devices do
  # emit KEY_SWITCHVIDEOMODE (XF86Display), but nothing consumed it, and bare
  # F7 was wired straight to `ddcutil setvcp 60` -- the shared ASUS monitor's
  # input switch from the X299 desktop, which is not a display switch at all.
  #
  # Hardware-detected rather than host-gated on purpose: X299-SSD is a
  # portable drive that boots on whatever is in front of it, so the script
  # asks the compositor what is actually attached.  With no built-in panel
  # (the X299 desktop) there is nothing to cycle, so F7/F8 keep their old job
  # of flipping that monitor's DDC/CI input source between machines.
  # F1: lock the session and blank the screens.
  #
  # The order matters, and it used to be backwards: `dpms off && hyprlock`
  # blanked the outputs and then started the locker -- whose surface has to be
  # shown on every output, so the compositor turned them straight back on a
  # couple of seconds later, with nothing touched.  Verified in isolation that
  # `dpms off` on its own stays off indefinitely, so the locker was the waker.
  # Lock first, wait until it is actually up, and blank after.
  home.file.".local/bin/lock-and-blank" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -eu

      # pgrep -f, not -x: swaylock on NixOS is a C wrapper that execs
      # .swaylock-wrapped, so the process name is never "swaylock" and -x
      # silently never matched -- which made the guard below decide the lock
      # had failed and skip the blanking entirely.  The bracket class keeps the
      # pattern from matching this command's own line.
      if ! pgrep -f '[s]waylock' >/dev/null 2>&1; then
        # --daemonize so this returns once the lock surface is really up, and
        # a dark screen rather than swaylock's default white flash.
        # --indicator-idle-visible matters: without it swaylock draws nothing
        # until a key is pressed, so the screen looks blank and dead and you
        # are typing a password with no evidence anything is listening.
        swaylock --daemonize --color 1e1e2e \
          --indicator-idle-visible \
          --indicator-radius 120 --indicator-thickness 12 \
          --indicator-caps-lock --show-failed-attempts \
          --font-size 24 \
          --inside-color 1e1e2e --ring-color 585b70 \
          --key-hl-color a6e3a1 --bs-hl-color f38ba8 \
          --text-color cdd6f4 --line-color 00000000 \
          --inside-ver-color 1e1e2e --ring-ver-color 89b4fa \
          --inside-wrong-color f38ba8 --ring-wrong-color f38ba8 \
          >/dev/null 2>&1 || true
      fi

      for _ in $(seq 1 40); do
        if pgrep -f '[s]waylock' >/dev/null 2>&1; then break; fi
        sleep 0.1
      done
      sleep 1

      # BLANKING IS DISABLED, and this time it is a kernel problem rather than
      # a locker one.  Blanking makes the external drop its HDMI link, the
      # resulting ACPI notification reaches the NVIDIA driver, and the driver
      # deadlocks in the kernel:
      #
      #   INFO: task kworker blocked on an rw-semaphore
      #     rmapiLockAcquire / RmUnixRmApiPrologue / rm_acpi_notify [nvidia]
      #     acpi_ev_notify_dispatch
      #
      # With the GPU driver wedged nothing can wake the screen, logind cannot
      # even be killed, and the only way out is the power button -- with the
      # filesystem mounted.  A dark screen on lock is not worth that.
      if ! pgrep -f '[s]waylock' >/dev/null 2>&1; then
        notify-send -a Display -i dialog-warning -t 6000 \
          "Lock failed" "swaylock did not start; the screen was left on rather than blanked." \
          >/dev/null 2>&1 || true
      fi

      # NO `dpms off` here, and this is a safety matter rather than a
      # preference.  Blanking makes the external monitor drop its HDMI link
      # (confirmed: `drm: Got a hotplug event for /dev/dri/card1`, and the
      # monitor list briefly goes empty).  The output disappearing underneath
      # hyprlock takes down its Wayland dispatch thread -- it aborts, from
      # CHyprlock::run's fatal path -- which leaves the session locked with a
      # dead locker and no way back in.  That cost a forced reboot.
      #
      # Until the monitor stops dropping its link (its own auto-source-detect
      # / deep-sleep setting is the suspect), locking must not blank.
    '';
  };

  # Ctrl+Alt+Left/Right: step workspaces on the screen you are looking at.
  #
  # Neither of Hyprland's own relative forms does this on two monitors.  Plain
  # `workspace +1` is global: from the external it immediately jumps focus to
  # the laptop, and every new blank workspace gets created over there, so the
  # screen in front of you never changes.  `m+1` is monitor-scoped but only
  # cycles workspaces that monitor already has -- with one, it does nothing at
  # all.  `emptym` picks an empty workspace wherever it lives, which was again
  # the other screen.
  #
  # So: pick the next workspace that is already on this monitor, or failing
  # that the lowest unused number, and pull it here.  Targets are either
  # already on this screen or brand new, so nothing is ever swapped away from
  # the other monitor -- which was the complaint about using
  # focusworkspaceoncurrentmonitor for stepping in the first place.
  # Last line of defence: never leave the session with no enabled display.
  #
  # display-cycle legitimately switches the built-in panel off -- external-only
  # mode, or a closed lid.  If the external is then unplugged or switched off,
  # nothing at all is enabled: the machine looks dead, and the keybinds that
  # would fix it cannot be seen to be pressed.  That has happened twice.
  #
  # Polling rather than the event socket, because it needs no reconnect
  # handling and one hyprctl call every couple of seconds costs nothing.  Two
  # consecutive empty polls are required so that a mode change, which can
  # briefly have nothing enabled, is not mistaken for the real thing.
  home.file.".local/bin/display-rescue" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -u
      empty=0
      while true; do
        sleep 2
        n=$(hyprctl monitors -j 2>/dev/null | jq 'length' 2>/dev/null) || continue
        case "$n" in ""|*[!0-9]*) continue ;; esac
        if [ "$n" -gt 0 ]; then empty=0; continue; fi
        empty=$(( empty + 1 ))
        [ "$empty" -ge 2 ] || continue
        empty=0
        # Switch on everything physically attached, whatever it is.  Getting a
        # picture back matters more than getting the layout right.
        for c in /sys/class/drm/card[0-9]*-*; do
          [ -e "$c/status" ] || continue
          [ "$(cat "$c/status" 2>/dev/null)" = connected ] || continue
          name=''${c##*/}
          name=''${name#*-}
          hyprctl keyword monitor "$name,highres,auto,auto" >/dev/null 2>&1 || true
        done
        # Wait for the outputs to actually be up before dressing them.
        i=0
        while [ "$i" -lt 25 ]; do
          [ "$(hyprctl monitors -j 2>/dev/null | jq 'length' 2>/dev/null)" != "0" ] && break
          sleep 0.2
          i=$(( i + 1 ))
        done
        sleep 1

        # A screen that has just been switched on is bare: it gets an empty
        # workspace, and AGS builds its bars once at startup so it has none
        # either.  Coming back to nothing but wallpaper is barely better than
        # coming back to nothing, so put a usable desktop on it.
        paper=$(awww query 2>/dev/null | sed -n 's/.*currently displaying: image: //p' | head -n1)
        if [ -n "$paper" ] && [ -f "$paper" ]; then
          awww img "$paper" --transition-type none >/dev/null 2>&1 || true
        fi

        mon=$(hyprctl monitors -j 2>/dev/null | jq -r '.[0].name' 2>/dev/null)
        ws=$(hyprctl clients -j 2>/dev/null \
             | jq -r '[.[] | .workspace.id] | map(select(. > 0)) | sort | .[0] // empty' 2>/dev/null)
        if [ -n "''${mon:-}" ] && [ -n "''${ws:-}" ]; then
          hyprctl dispatch focusmonitor "$mon" >/dev/null 2>&1 || true
          hyprctl dispatch focusworkspaceoncurrentmonitor "$ws" >/dev/null 2>&1 || true
        fi

        missing=no
        for m in $(hyprctl monitors -j 2>/dev/null | jq -r '.[].name' 2>/dev/null); do
          hyprctl layers -j 2>/dev/null \
            | jq -e --arg m "$m" '(.[$m].levels["2"] // []) | map(.namespace) | index("gtk-layer-shell")' \
              >/dev/null 2>&1 || missing=yes
        done
        if [ "$missing" = yes ] && pgrep -f 'ags\.js' >/dev/null 2>&1; then
          ags quit >/dev/null 2>&1 || true
          sleep 0.5
          uwsm app -- ags run >/dev/null 2>&1 &
        fi

        notify-send -a Display -i video-display -t 6000 \
          "Display rescued" "No screen was enabled; everything attached was switched back on." \
          >/dev/null 2>&1 || true
      done
    '';
  };

  home.file.".local/bin/ws-step" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -eu
      dir="''${1:-next}"

      mon=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .name')
      cur=$(hyprctl activeworkspace -j | jq -r '.id')
      mine=$(hyprctl workspaces -j | jq -r --arg m "$mon" \
        '[.[] | select(.id > 0 and .monitor == $m) | .id] | sort | .[]')
      all=$(hyprctl workspaces -j | jq -r '[.[] | select(.id > 0) | .id] | sort | .[]')

      target=""
      if [ "$dir" = next ]; then
        for w in $mine; do
          if [ "$w" -gt "$cur" ]; then target="$w"; break; fi
        done
        if [ -z "$target" ]; then
          # Past the last one on this screen: take the lowest unused number
          # ABOVE the current one, so repeated presses keep going forward.
          # Counting from 1 instead made it fall back into a gap left by a
          # workspace that had just been collected, and pressing right twice
          # oscillated between two numbers rather than advancing.
          n=$(( cur + 1 ))
          while echo "$all" | grep -qx "$n"; do n=$(( n + 1 )); done
          target="$n"
        fi
      else
        for w in $mine; do
          if [ "$w" -lt "$cur" ]; then target="$w"; fi
        done
        # Already at the first workspace on this screen: stay put rather than
        # wrapping onto something the other monitor is showing.
        if [ -z "$target" ]; then exit 0; fi
      fi

      hyprctl dispatch focusworkspaceoncurrentmonitor "$target" >/dev/null
    '';
  };

  # Per-monitor scaling -- the equivalent of Windows' display scaling.  The
  # panel keeps its native resolution and everything is drawn larger, so text
  # is bigger AND sharp, rather than a lower resolution upscaled into a blur.
  #
  # Hyprland only accepts a scale that divides the panel into whole pixels, so
  # the available steps are computed per monitor rather than assumed: 1.75 is
  # valid on plenty of screens but not on 3840x2160, and offering it would just
  # produce a config error.  The chosen value is remembered per connector so a
  # display-mode change does not quietly reset it.
  home.file.".local/bin/display-scale" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -eu

      state="''${XDG_STATE_HOME:-$HOME/.local/state}/hypr-monitor-scale"
      mkdir -p "$state"

      # Parse the monitor per subcommand.  `set` takes the value in $2 and the
      # monitor in $3; everything else takes the monitor in $2.  Reading $2 as
      # the monitor unconditionally meant `display-scale set 1.25` treated
      # "1.25" as a connector name, looked up a monitor that does not exist and
      # sent Hyprland `monitor 1.25,highres,nullxnull,1.25` -- so the slider
      # moved and nothing happened.  Passing a monitor explicitly, as the
      # tests did, hid it.
      cmd="''${1:-get}"
      want=""
      case "$cmd" in
        set) want="''${2:-}"; mon="''${3:-}" ;;
        *)   mon="''${2:-}" ;;
      esac
      if [ -z "''${mon:-}" ]; then
        mon=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .name')
      fi
      [ -n "$mon" ] || exit 0

      geom=$(hyprctl monitors all -j | jq -r --arg m "$mon" \
        '[.[] | select(.name == $m)][0] | "\(.width) \(.height)"')
      w=''${geom%% *}; h=''${geom##* }

      # Only scales that divide BOTH dimensions into whole pixels.
      steps() {
        for c in 1.00 1.20 1.25 1.50 1.60 2.00 2.50 3.00; do
          awk -v w="$w" -v h="$h" -v s="$c" 'BEGIN {
            lw = w / s; lh = h / s
            dw = lw - int(lw); dh = lh - int(lh)
            if ((dw < 0.0001 || dw > 0.9999) && (dh < 0.0001 || dh > 0.9999)) print s
          }'
        done
      }

      nearest() {  # snap an arbitrary request onto the nearest valid step
        steps | awk -v want="$1" 'BEGIN { best = ""; bd = 1e9 }
          { d = $1 - want; if (d < 0) d = -d; if (d < bd) { bd = d; best = $1 } }
          END { print best }'
      }

      current() {
        hyprctl monitors -j | jq -r --arg m "$mon" \
          '[.[] | select(.name == $m)][0].scale // 1'
      }

      apply() {
        # Refuse anything that would put a malformed rule in front of Hyprland.
        case "''${1:-}" in ""|*[!0-9.]*) return 0 ;; esac
        pos=$(hyprctl monitors -j | jq -r --arg m "$mon" \
          '[.[] | select(.name == $m)][0] | "\(.x)x\(.y)"')
        case "$pos" in ""|*null*) pos=auto ;; esac
        hyprctl keyword monitor "$mon,highres,$pos,$1" >/dev/null 2>&1 || true
        printf '%s\n' "$1" > "$state/$mon"
        notify-send -a Display -i video-display -t 1500 \
          "$(awk -v s="$1" 'BEGIN { printf "%d%% scale", s * 100 }')" "$mon" \
          >/dev/null 2>&1 || true
      }

      step_by() {  # $1 = +1 or -1
        cur=$(current)
        list=$(steps)
        idx=$(printf '%s\n' "$list" | awk -v c="$cur" '
          { d = $1 - c; if (d < 0) d = -d; if (d < 0.01) { print NR; exit } }')
        [ -n "''${idx:-}" ] || idx=$(printf '%s\n' "$list" | wc -l)
        n=$(( idx + $1 ))
        total=$(printf '%s\n' "$list" | wc -l)
        [ "$n" -ge 1 ] || n=1
        [ "$n" -le "$total" ] || n=$total
        apply "$(printf '%s\n' "$list" | sed -n "''${n}p")"
      }

      case "$cmd" in
        get)    current ;;
        percent) awk -v s="$(current)" 'BEGIN { printf "%d\n", s * 100 }' ;;
        steps)  steps ;;
        up)     step_by 1 ;;
        down)   step_by -1 ;;
        set)    # Validate before snapping: awk reads a non-numeric argument as 0,
                # which nearest() then rounds to the smallest step, so a typo
                # silently set the display to 100% instead of being refused.
                case "$want" in ""|*[!0-9.]*) exit 2 ;; esac
                apply "$(nearest "$want")" ;;
        *)      echo "usage: display-scale {get|percent|steps|up|down|set <scale>} [monitor]" >&2
                exit 2 ;;
      esac
    '';
  };

  home.file.".local/bin/display-cycle" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -eu

      # F7 is easy to press faster than a monitor change settles, and
      # overlapping runs raced each other into a half-applied layout.
      exec 9>"''${XDG_RUNTIME_DIR:-/tmp}/display-cycle.lock"
      flock -n 9 || exit 0

      mons=$(hyprctl monitors all -j)
      internals=$(echo "$mons" | jq -r '.[] | select(.name | startswith("eDP-")) | .name')
      externals=$(echo "$mons" | jq -r '.[] | select(.name | startswith("eDP-") | not) | .name')
      arg="''${1:-}"

      # -- No built-in panel: this is the desktop, keep the DDC/CI input switch --
      if [ -z "$internals" ]; then
        if [ "$arg" = input ]; then ddcutil setvcp 60 "''${2:-0x0f}"
        else                        ddcutil setvcp 60 0x11
        fi
        exit 0
      fi

      # A laptop drives the external monitor itself, so there is no second
      # source to switch to.  Firing F8's input change here would flip the
      # monitor to an input nothing is driving and black it out.  Refuse.
      if [ "$arg" = input ]; then exit 0; fi

      if [ -z "$externals" ]; then
        notify-send -a Display -i video-display -t 2000 \
          "Display: built-in only" "No external monitor is connected."
        exit 0
      fi

      # A closed lid means the built-in panel is not something anyone can look
      # at.  Cycling onto it would move windows to a dead screen, and
      # built-in-only would black the desktop out entirely -- leaving no
      # visible screen to press F7 on to get back.  While the lid is shut and
      # an external is attached, the external is the only mode offered.
      # The glob simply does not match on a machine with no ACPI lid.
      # Every output, captured before the guards below prune $internals.  The
      # generated config must name them ALL: a monitor missing from that file
      # falls back to Hyprland's default `auto` rule and comes back on.
      all_mons="$internals $externals"

      lid=open
      for l in /proc/acpi/button/lid/*/state; do
        if [ -e "$l" ]; then
          case "$(cat "$l" 2>/dev/null)" in *closed*) lid=closed ;; esac
        fi
      done
      # Nothing sets AQ_DRM_DEVICES any more (see the note where it used to be
      # configured), so this is normally inert -- kept because if it ever is
      # set by hand, the built-in panel really cannot be driven.  It would be
      # set only to force rendering onto the GPU that drives the EXTERNAL
      # screen.  Originally: AQ_DRM_DEVICES was set (by ~/.config/uwsm/env-hyprland) to
      # force rendering onto the GPU that drives the EXTERNAL screen.  That
      # direction works; the reverse does not -- frames rendered on the dGPU
      # never land on the Intel-driven built-in panel, which stalls with
      # "drm: Cannot commit when a page-flip is awaiting" and freezes on
      # whatever it last showed.  So while that is in force, the built-in panel
      # is not something we may switch to.  Inherited from Hyprland, since
      # binds run as its children.
      gpu_locked=no
      if [ -n "''${AQ_DRM_DEVICES:-}" ]; then gpu_locked=yes; fi

      lid_forced=no
      lid_off=""
      if [ "$lid" = closed ] || [ "$gpu_locked" = yes ]; then
        # Keep the list so the panel gets actively switched OFF below; just
        # take it out of the running for anything that enables a screen.
        lid_off="$internals"
        internals=""
        arg=external
        lid_forced=yes
      fi

      primary=$(echo "$internals" | head -n1)
      q() { echo "$mons" | jq -r --arg m "$1" --arg f "$2" '.[] | select(.name==$m) | .[$f]'; }

      # Any disabled output tells us which mode we are in now.
      int_off=no; for m in $internals; do if [ "$(q "$m" disabled)" = true ]; then int_off=yes; fi; done
      ext_off=no; for m in $externals; do if [ "$(q "$m" disabled)" = true ]; then ext_off=yes; fi; done
      mirrored=no
      for m in $externals; do if [ "$(q "$m" mirrorOf)" != none ]; then mirrored=yes; fi; done

      if   [ "$ext_off" = yes ];  then cur=internal
      elif [ "$int_off" = yes ];  then cur=external
      elif [ "$mirrored" = yes ]; then cur=mirror
      else                             cur=extend
      fi

      # Win+P order, minus Duplicate: Hyprland drives a mirrored output at the
      # SOURCE monitor's mode rather than scaling to it, and this laptop's
      # 2560x1600 panel is a mode the 4K monitor does not have at all, so the
      # mirror fails and can leave that output disabled.  The rotation sticks
      # to modes that work; `display-cycle mirror` still asks for it explicitly.
      case "$cur" in
        internal) next=extend   ;;
        extend)   next=external ;;
        *)        next=internal ;;
      esac
      # `display-cycle external` etc. jumps straight to one mode.
      case "$arg" in
        internal|external|mirror|extend) next="$arg" ;;
        # `relayout` re-asserts whatever mode is already up.  Monitor
        # positions are runtime state, so every Hyprland config reload throws
        # them away and falls back to the built-in side-by-side rule -- which
        # silently undid the external-above placement and left the laptop
        # sitting to the right of the 4K screen looking like the secondary.
        relayout) next="$cur" ;;
      esac

      # `highres`, not `preferred`.  The two connectors disagree about what is
      # "preferred": routed through the Intel iGPU the laptop panel preferred
      # 2560x1600@240, but on the NVIDIA connector it preferred the same
      # resolution at 60Hz, quietly dropping the panel to a quarter of its
      # refresh rate.  `highres` takes the highest resolution and the fastest
      # mode at it -- 2560x1600@240 here, and 3840x2160@60 on the 4K screen.
      # NOT `highrr`, which would chase refresh over resolution and put that
      # monitor in 1280x1024@75.
      # The external sits physically ABOVE the laptop here, so it is placed
      # with `auto-up` and the cursor crosses upward rather than to the right.
      # Override with DISPLAY_CYCLE_EXTERNAL_SIDE=auto-down|auto-left|auto-right
      # if the monitor ever moves.
      side="''${DISPLAY_CYCLE_EXTERNAL_SIDE:-auto-up}"
      # Honour the per-monitor scale chosen with display-scale.  Without this
      # every mode change and every config reload re-applied `auto` and threw
      # the choice away -- which is what made 150% on the 4K screen not stick.
      # A very high-density panel with no choice recorded gets 1.5 rather than
      # 1.0, because 4K at 100% is unreadable on a desk-sized monitor.
      scale_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/hypr-monitor-scale"
      scale_for() {
        if [ -s "$scale_dir/$1" ]; then cat "$scale_dir/$1"; return; fi
        sw=$(hyprctl monitors all -j | jq -r --arg m "$1" \
          '[.[] | select(.name == $m)][0].width // 0')
        case "''${sw:-0}" in
          ""|*[!0-9]*) echo auto ;;
          *) if [ "$sw" -ge 3840 ]; then echo 1.5; else echo auto; fi ;;
        esac
      }

      on()  { hyprctl keyword monitor "$1,highres,auto,$(scale_for "$1")" >/dev/null; }
      off() { hyprctl keyword monitor "$1,disable" >/dev/null; }

      # Switch every output the target mode needs ON before turning any OFF, so
      # there is never a moment with zero enabled monitors.
      case "$next" in
        extend|mirror) want_on="$internals $externals"; want_off="" ;;
        external)      want_on="$externals";            want_off="$internals" ;;
        internal)      want_on="$internals";            want_off="$externals" ;;
      esac
      want_off="$want_off $lid_off"

      # Note what the screen we are keeping is currently showing, so the
      # workspace shuffle above can be undone.  Prefer the focused screen.
      keep_ws=""
      focus_mon=$(echo "$mons" | jq -r '.[] | select(.focused) | .name')
      for m in $want_on; do
        if [ "$m" = "$focus_mon" ]; then
          keep_ws=$(echo "$mons" | jq -r --arg m "$m" \
            '.[] | select(.name==$m) | .activeWorkspace.id')
          break
        fi
      done
      if [ -z "$keep_ws" ]; then
        for m in $want_on; do
          w=$(echo "$mons" | jq -r --arg m "$m" \
            '.[] | select(.name==$m and .disabled==false) | .activeWorkspace.id')
          if [ -n "$w" ] && [ "$w" != null ]; then keep_ws=$w; break; fi
        done
      fi
      # First just bring the right screens up, using Hyprland's own `auto`
      # placement -- it never overlaps.  Explicit coordinates come afterwards,
      # once modes and scales have actually been resolved.
      #
      # `relayout` skips this entirely.  Re-applying a monitor rule makes
      # Hyprland re-create the output and hand it a fresh workspace, so running
      # it on every config reload walked the workspace numbers up (1 -> 4) and
      # grew the bar.  Nothing is being switched on or off there -- only the
      # positions were lost -- so position them and leave the outputs alone.
      if [ "$arg" != relayout ]; then
        for m in $want_on;  do on  "$m"; done
        for m in $want_off; do off "$m"; done
      fi

      # Nothing below may run until Hyprland has actually applied the layout.
      # `hyprctl keyword` returns immediately, so a blind sleep let AGS
      # enumerate a half-changed monitor set and build bars for the wrong
      # outputs -- that is how a screen ended up with no bar and no wallpaper,
      # still showing the previous layout's framebuffer.
      settle() {
        i=0
        while [ "$i" -lt 40 ]; do
          have=$(hyprctl monitors -j | jq -r '.[].name' | sort | tr '\n' ' ')
          if [ "$have" = "$1" ]; then return 0; fi
          sleep 0.1
          i=$((i + 1))
        done
      }
      settle "$(printf '%s\n' $want_on | sed '/^$/d' | sort | tr '\n' ' ')"

      # Now place everything at explicit coordinates.  `auto`/`auto-up` position
      # a monitor against whatever is already placed, so the layout depended on
      # which mode we were leaving; and anchoring the laptop at 0x0 while the
      # external still sat there made the two overlap for an instant, which
      # Hyprland reports on screen.  Externals are moved to their own row
      # FIRST, so at no point do two monitors occupy the same space.
      logical() {
        hyprctl monitors -j | jq -r --arg m "$1" --arg f "$2" \
          '[.[] | select(.name == $m)]
           | if length == 0 then 0
             else (.[0] | (if $f == "w" then .width else .height end) / .scale | floor)
             end'
      }
      if [ "$next" = extend ] || [ "$next" = mirror ]; then
        iw=0; ih=0
        for m in $internals; do
          iw=$(( iw + $(logical "$m" w) ))
          h=$(logical "$m" h)
          if [ "$h" -gt "$ih" ]; then ih=$h; fi
        done
        x=0
        for m in $externals; do
          w=$(logical "$m" w); h=$(logical "$m" h)
          case "$side" in
            auto-down)  pos="''${x}x''${ih}"      ;;
            auto-left)  pos="-$(( x + w ))x0"   ;;
            auto-right) pos="$(( iw + x ))x0"   ;;
            *)          pos="''${x}x-''${h}"      ;;  # auto-up: bottom edge on y=0
          esac
          hyprctl keyword monitor "$m,highres,$pos,$(scale_for "$m")" >/dev/null
          x=$(( x + w ))
        done
      fi
      # Unquoted $(echo ...) on purpose: it collapses the newline-separated
      # list into spaces, so the membership test below can look for " $m ".
      ext_list=" $(echo $externals) "
      x=0
      for m in $want_on; do
        skip=no
        case "$next" in
          extend|mirror) case "$ext_list" in *" $m "*) skip=yes ;; esac ;;
        esac
        if [ "$skip" = yes ]; then continue; fi
        hyprctl keyword monitor "$m,highres,''${x}x0,$(scale_for "$m")" >/dev/null
        x=$(( x + $(logical "$m" w) ))
      done

      # Deliberately NOT persisting the layout to a sourced config file.
      # That was tried and caused two opposite failures: writing
      # `monitor = eDP-1,disable` bricked the laptop at login whenever the
      # external was off, and removing the disable meant the file's own write
      # tripped Hyprland's autoreload and re-enabled the monitor that had just
      # been switched off.  Positions are re-applied by `display-cycle
      # relayout` from exec on every reload instead, which needs no state on
      # disk and cannot cost a display.

      # Mirroring goes on only once the target is really enabled.  Hyprland
      # ignores a `mirror` rule aimed at a still-disabled monitor, so folding
      # it into the enable step above left the monitor off, stalled `settle`,
      # and stuck the cycle one mode behind.
      if [ "$next" = mirror ]; then
        for m in $externals; do
          hyprctl keyword monitor "$m,highres,auto,$(scale_for "$m"),mirror,$primary" >/dev/null
        done
        sleep 1
        # Verify it actually took.  When the panels share no common mode the
        # request fails silently and the output is left disabled -- losing a
        # screen is far worse than not duplicating, so fall back to extend.
        live() { hyprctl monitors all -j | jq -r --arg m "$1" --arg f "$2" '.[] | select(.name==$m) | .[$f]'; }
        bad=no
        for m in $externals; do
          if [ "$(live "$m" disabled)" = true ] || [ "$(live "$m" mirrorOf)" = none ]; then
            bad=yes
          fi
        done
        if [ "$bad" = yes ]; then
          for m in $internals $externals; do on "$m"; done
          next=extend
          settle "$(printf '%s\n' $internals $externals | sed '/^$/d' | sort | tr '\n' ' ')"
          notify-send -a Display -i video-display -t 3000 \
            "Display: Duplicate unavailable" "These screens share no common mode -- extended instead."
        fi
      fi

      # awww does not re-render when outputs come and go: it can drop the
      # background layer entirely (`awww query` goes empty), leaving the panel
      # showing whatever was already in the framebuffer.  Re-assert the image
      # it is already on -- not a random one, which would make every F7 press
      # change the wallpaper.  'none' completes the transition instantly.
      paper=$(awww query 2>/dev/null | sed -n 's/.*currently displaying: image: //p' | head -n1)
      if [ -n "$paper" ] && [ -f "$paper" ]; then
        awww img "$paper" --transition-type none >/dev/null 2>&1 || true
      else
        ~/.local/bin/random-wallpaper >/dev/null 2>&1 || true
      fi

      # ags/app.ts builds its bars once in main() from App.get_monitors() and
      # never listens for monitor-added, so an output that comes back has no
      # bar.  Check that symptom directly instead of inferring it from the
      # transition: if any enabled monitor is missing its layer-shell bar,
      # restart AGS (the same dance as the $mod+A bind).
      # At login this runs alongside AGS's own exec-once, and killing a bar
      # that is still starting would just fight it -- so the startup call sets
      # DISPLAY_CYCLE_SKIP_AGS and leaves the bars alone.
      bars_missing=no
      if [ -z "''${DISPLAY_CYCLE_SKIP_AGS:-}" ]; then
        for m in $(hyprctl monitors -j | jq -r '.[].name'); do
          if ! hyprctl layers -j \
               | jq -e --arg m "$m" '(.[$m].levels["2"] // []) | map(.namespace) | index("gtk-layer-shell")' \
                 >/dev/null 2>&1; then
            bars_missing=yes
          fi
        done
      fi
      # Only restart a bar that is actually there; at login AGS may not have
      # started yet, and something else is about to start it.
      if [ "$bars_missing" = yes ] && pgrep -f 'ags\.js' >/dev/null 2>&1; then
        ags quit >/dev/null 2>&1 || true
        sleep 0.5
        # 9>&- matters: without it the backgrounded AGS inherits the lock fd
        # and holds the flock for its whole lifetime, so every later F7 press
        # exits at `flock -n` and the cycle appears frozen on one mode.
        uwsm app -- ags run >/dev/null 2>&1 9>&- &
      fi

      # Hyprland migrates a disabled monitor's workspaces onto a surviving
      # screen and brings them to the front, so the screen you were looking at
      # jumps elsewhere.  That migration lands *after* the monitor set settles,
      # so restoring once straight away is not enough -- it gets overwritten.
      # Re-assert at the very end, once nothing else is still moving.
      if [ "$arg" = relayout ]; then keep_ws=""; fi
      if [ -n "$keep_ws" ] && [ "$keep_ws" != null ]; then
        # Wait for the migration to stop moving things, THEN put the workspace
        # back exactly once.  Re-asserting in a loop also fought the user:
        # switching workspace by hand within a few seconds of pressing F7 was
        # dragged straight back, which looked like workspace switching had
        # stopped working altogether.
        prev=""
        i=0
        while [ "$i" -lt 15 ]; do
          now_ws=$(hyprctl activeworkspace -j | jq -r .id)
          if [ "$now_ws" = "$prev" ]; then break; fi
          prev="$now_ws"
          sleep 0.2
          i=$((i + 1))
        done
        if [ "$prev" != "$keep_ws" ]; then
          hyprctl dispatch workspace "$keep_ws" >/dev/null 2>&1 || true
        fi
      fi

      case "$next" in
        extend)   label="Extend";        detail="$(echo $internals $externals)" ;;
        external) label="External only"
                  if [ "$lid_forced" = yes ] && [ "$gpu_locked" = yes ] && [ "$lid" != closed ]; then
                    detail="built-in needs a re-login (rendering is on the dGPU)"
                  elif [ "$lid_forced" = yes ]; then
                    detail="lid closed -- built-in unavailable"
                  else
                    detail="$(echo $externals)"
                  fi ;;
        internal) label="Built-in only"; detail="$(echo $internals)" ;;
        mirror)   label="Duplicate";     detail="mirroring $primary" ;;
      esac
      notify-send -a Display -i video-display -t 2000 "Display: $label" "$detail"
    '';
  };

  # No AQ_DRM_DEVICES here on purpose.  Forcing Hyprland to render on the dGPU
  # did make the 4K external hit a measured 60 FPS instead of 21, but it cost
  # the built-in panel entirely: with rendering on the dGPU that output never
  # completes a frame -- `grim -o eDP-1` blocks indefinitely -- so the laptop
  # screen is frozen and the display cycle has only one mode left to offer.
  # Working screens beat smoother animation, so the render device is left to
  # Hyprland. The external's animation is limited by the cross-GPU copy; that
  # is a driver limitation, not something this config can tune away.

  # jinx-mod.so rebuild helper with rpath baked in.
  # The Emacs ELPA `jinx' package ships a precompiled jinx-mod.so that
  # dlopens libenchant-2.so.2 via LD_LIBRARY_PATH. On NixOS, envrc /
  # devenv buffers replace LD_LIBRARY_PATH and dlopen fails, so we
  # need libenchant pinned into the .so's DT_RPATH. ELPA upgrades
  # periodically replace our patched .so with a fresh prebuilt one.
  # This helper rebuilds with rpath whenever the .so is missing or
  # lacks our marker. All nix-store paths are inlined at build time
  # so the script is self-contained and runnable from any environment
  # (GUI launcher, terminal, anywhere).
  home.file.".local/bin/jinx-rebuild-mod" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -e
      JINX_DIR=$(ls -d ~/.emacs.d/elpa/jinx-* 2>/dev/null | head -1)
      [ -d "$JINX_DIR" ] || exit 0
      cd "$JINX_DIR"

      # Skip if the .so already carries our rpath marker.
      if [ -f jinx-mod.so ] && \
         grep -qa '/run/current-system/sw/lib' jinx-mod.so; then
        exit 0
      fi

      rm -f jinx-mod.so
      ${pkgs.gcc}/bin/gcc \
        -I. \
        -I${pkgs.enchant.dev}/include/enchant-2 \
        -O2 -Wall -Wextra -fPIC -shared \
        -Wl,-rpath,/run/current-system/sw/lib \
        -Wl,-rpath,${pkgs.enchant}/lib \
        -o jinx-mod.so jinx-mod.c \
        -L${pkgs.enchant}/lib -lenchant-2
      echo "jinx-rebuild-mod: rebuilt $JINX_DIR/jinx-mod.so" >&2
    '';
  };

  # Tree-sitter grammar path for Emacs, generated by home-manager.
  # preload.el loads this early (after it requires `treesit`) so every
  # *-ts-mode finds its grammar with no treesit-install / compiler / network.
  home.file.".emacs.d/nix-tree-sitter.el".text = ''
    ;;; nix-tree-sitter.el --- generated by NixOS/home.nix; do not edit. -*- lexical-binding: t; -*-
    ;; Adds the Nix-built tree-sitter grammar bundle to the load path.
    (when (and (fboundp 'treesit-available-p) (treesit-available-p))
      (require 'treesit)
      (add-to-list 'treesit-extra-load-path "${emacsTreesitGrammars}/lib"))
  '';

  # One-shot clean-machine bootstrap for the Emacs setup.  Idempotent:
  # seeds ~/.emacs.d/init.el (only if absent, so Custom's appended lines
  # are never clobbered) and clones the external repos the config loads
  # (~/Projects/emacs/init.el -> scimax; language.el -> lsp/flymake-bridge).
  # Tree-sitter grammars are handled declaratively above, so they are NOT
  # part of this script.  Run once on a new machine: `emacs-bootstrap`.
  home.file.".local/bin/emacs-bootstrap" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail
      git=${pkgs.git}/bin/git
      proj="$HOME/Projects"

      # 1. Seed init.el into the default user-emacs-directory.
      mkdir -p "$HOME/.emacs.d"
      if [ ! -f "$HOME/.emacs.d/init.el" ]; then
        cp "$proj/emacs/init.el" "$HOME/.emacs.d/init.el"
        echo "emacs-bootstrap: seeded ~/.emacs.d/init.el"
      fi

      # 2-4. Clone the repos the config expects under ~/Projects (if missing).
      clone_if_missing() {  # $1 = dir under ~/Projects, $2 = git URL
        if [ ! -e "$proj/$1/.git" ]; then
          echo "emacs-bootstrap: cloning $1 …"
          "$git" clone "$2" "$proj/$1"
        else
          echo "emacs-bootstrap: $1 already present, skipping"
        fi
      }
      clone_if_missing scimax         git@github.com:jkitchin/scimax.git
      clone_if_missing flymake-bridge git@github.com:dragonleopardpig/flymake-bridge.git
      clone_if_missing lsp-bridge     git@github.com:dragonleopardpig/lsp-bridge.git

      echo "emacs-bootstrap: done."
    '';
  };

  home.file.".local/bin/remmina-dnd-watcher" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Auto-toggle swaync Do Not Disturb based on focused window class.
      # When org.remmina.Remmina is focused, enable DnD so notification
      # pop-ups don't appear over the remote desktop; restore on focus
      # change. State file prevents clobbering DnD enabled manually
      # outside of a Remmina session.
      SOCK="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
      STATE="$XDG_RUNTIME_DIR/remmina-dnd.lock"
      [ -S "$SOCK" ] || exit 0

      enable_dnd() {
        [ -e "$STATE" ] && return
        swaync-client --dnd-on >/dev/null 2>&1 && touch "$STATE"
      }
      disable_dnd() {
        [ -e "$STATE" ] || return
        swaync-client --dnd-off >/dev/null 2>&1 && rm -f "$STATE"
      }

      # Seed initial state: if Remmina is already active at startup.
      if hyprctl activewindow -j 2>/dev/null \
           | grep -q '"class": "org.remmina.Remmina"'; then
        enable_dnd
      fi

      while true; do
        socat -U - "UNIX-CONNECT:$SOCK" 2>/dev/null | while IFS= read -r line; do
          case "$line" in
            activewindow\>\>org.remmina.Remmina,*) enable_dnd ;;
            activewindow\>\>*)                     disable_dnd ;;
          esac
        done
        sleep 1
      done
    '';
  };

  home.file.".local/bin/toggle-app" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Toggle a window by Hyprland window class. Class match is case-insensitive
      # substring, so app-set classes like "Blueman-manager" or
      # ".blueman-manager-wrapped" all hit a single short class string.
      #
      # Usage:
      #   toggle-app <class> <command> [args...]          # wraps in kitty (terminal apps)
      #   toggle-app --gui <class> <command> [args...]    # runs <command> directly (GUI apps)
      set -e
      gui=0
      if [ "$1" = "--gui" ]; then gui=1; shift; fi
      class="$1"; shift || true
      if [ -z "$class" ] || [ $# -eq 0 ]; then
        echo "Usage: toggle-app [--gui] <class> <command> [args...]" >&2
        exit 2
      fi
      if hyprctl clients -j 2>/dev/null | grep -qi "\"class\":[[:space:]]*\"[^\"]*$class[^\"]*\""; then
        hyprctl dispatch closewindow "class:(?i).*$class.*" >/dev/null
      else
        if [ "$gui" = 1 ]; then
          exec "$@"
        else
          exec kitty --class="$class" -e "$@"
        fi
      fi
    '';
  };

  home.file.".local/bin/launch-app-drawer" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Toggle nwg-drawer, a fullscreen Unity/GNOME-Activities-style app grid.
      # -ovl uses the overlay layer so it covers waybar; -k enables keyboard
      # input for the search box. Powers commands are tuned for Hyprland.
      if ${pkgs.procps}/bin/pgrep -x nwg-drawer >/dev/null; then
        exec ${pkgs.nwg-drawer}/bin/nwg-drawer -close
      fi
      exec ${pkgs.nwg-drawer}/bin/nwg-drawer \
        -wm hyprland \
        -ovl -k \
        -c 8 -is 64 -spacing 20 \
        -term kitty \
        -fm "$HOME/.local/bin/nemo-x11" \
        -closebtn right \
        -pblock "$HOME/.local/bin/lock-and-blank" \
        -pbexit "hyprctl dispatch exit" \
        -pbsleep "systemctl suspend" \
        -pbreboot "systemctl reboot" \
        -pbpoweroff "systemctl poweroff"
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

      awww img "$wallpaper" \
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
    gtk4.theme = null;
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

    windowrule {
      name = tile-sioyek
      match:class = ^sioyek$
      tile = yes
    }

    windowrule {
      name = swappy-float
      match:class = ^swappy$
      float = yes
      center = yes
      size = 1600 1000
    }

    windowrule {
      name = onlyoffice-float
      match:class = ^(DesktopEditors|ONLYOFFICE|onlyoffice-desktopeditors)$
      float = yes
      center = yes
      size = 1600 960
    }

    windowrule {
      name = filen-desktop-float
      match:class = ^(filen-desktop|Filen Desktop)$
      float = yes
      center = yes
      size = 1440 900
    }

    windowrule {
      name = megasync-add-dialogs-float
      match:class = ^MEGAsync$
      match:title = ^(Add sync|Add backup)$
      float = yes
      center = yes
    }

    windowrule {
      name = megasync-settings-float-by-title
      match:title = ^Settings$
      float = yes
      center = yes
      size = 705 765
    }

    windowrule {
      name = megasync-status-popup-float
      match:class = ^nz\.co\.mega\.megasync$
      match:title = ^MEGAsync$
      float = yes
      center = yes
    }

    windowrule {
      name = megasync-status-popup-float-by-title
      match:title = ^MEGAsync$
      float = yes
      center = yes
    }

    windowrule {
      name = megasync-add-dialogs-float-by-title
      match:title = ^(Add sync|Add backup)$
      float = yes
      center = yes
    }

    windowrule {
      name = megasync-add-backup-size-by-title
      match:title = ^Add backup$
      size = 640 403
    }

    windowrule {
      name = megasync-add-sync-size-by-title
      match:title = ^Add sync$
      size = 640 402
    }

    windowrule {
      name = megasync-add-backup-size
      match:class = ^MEGAsync$
      match:title = ^Add backup$
      size = 640 403
    }

    windowrule {
      name = megasync-add-sync-size
      match:class = ^MEGAsync$
      match:title = ^Add sync$
      size = 640 402
    }
  '';
    settings = {
      general = {
        gaps_in = 0;
        gaps_out = 0;
        border_size = 2;
        layout = "dwindle";
        "col.active_border" = "rgba(ff4fd8ee) rgba(6be8ffee) 45deg";
        "col.inactive_border" = "rgba(182033aa)";
        resize_on_border = true;
        extend_border_grab_area = 20;
      };
      decoration = {
        rounding = 18;
        active_opacity = 0.96;
        inactive_opacity = 0.82;
        fullscreen_opacity = 1.0;
        dim_inactive = true;
        dim_strength = 0.16;
        blur = {
          enabled = true;
          size = 8;
          passes = 3;
          vibrancy = 0.22;
        };
        shadow = {
          enabled = true;
          range = 28;
          render_power = 4;
          color = "rgba(030611bb)";
        };
      };
      animations = {
        enabled = true;
        workspace_wraparound = true;
      };
      bezier = [
        "holo, 0.22, 1, 0.36, 1"
        "reveal, 0.16, 1, 0.3, 1"
      ];
      animation = [
        "windows, 1, 7, holo, slide"
        "windowsOut, 1, 5, reveal, slide"
        "border, 1, 9, default"
        "fade, 1, 6, default"
        "workspaces, 1, 7, holo, slidefade 15%"
      ];
      input = {
        follow_mouse = 1;
        # Natural scrolling everywhere, to match the external mouse — content
        # tracks finger/stick direction. `natural_scroll` here covers mice and
        # the TrackPoint (a pointing stick, treated as a mouse); the touchpad
        # needs its own sub-block as it's a separate libinput category.
        natural_scroll = true;
        touchpad = {
          natural_scroll = true;
        };
      };
      # Explicit per-device override so the TrackPoint's middle-button scroll
      # is natural too (belt-and-suspenders alongside input.natural_scroll).
      device = [
        {
          name = "tpps/2-elan-trackpoint";
          natural_scroll = true;
        }
      ];
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
          "$mod, M, exec, minder"
          "$mod, left, movefocus, l"
          "$mod, right, movefocus, r"
          "$mod, up, movefocus, u"
          "$mod, down, movefocus, d"
          "$mod SHIFT, F, fullscreen, 1"
          "$mod, F7, exec, sh -c 'sioyek-keyboard-lights && notify-send -a Keyboard -i input-keyboard \"Sioyek keyboard palette restored\"'"
          "$mod SHIFT, A, exec, ags request togglebar"
          "$mod, A, exec, sh -c 'ags quit 2>/dev/null; sleep 0.3; uwsm app -- ags run'"
          '', Print, exec, ~/.local/bin/screenshot''
          "SHIFT, Print, exec, ~/.local/bin/screenshot-full"
          "CTRL, Print, exec, ~/.local/bin/screenshot-monitor"
          "ALT, Print, exec, ~/.local/bin/screenshot-window"
          ", XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"
          ", XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
          ", XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
          ", XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"
          ", XF86AudioNext, exec, playerctl next"
          ", XF86AudioPause, exec, playerctl play-pause"
          ", XF86AudioPlay, exec, playerctl play-pause"
          ", XF86AudioPrev, exec, playerctl previous"
          ", F1, exec, ~/.local/bin/lock-and-blank"
          ", F6, exec, ~/.local/bin/brightness-ctl up"
          ", F5, exec, ~/.local/bin/brightness-ctl down"
          ",XF86MonBrightnessUp, exec, ~/.local/bin/brightness-ctl up"
          ",XF86MonBrightnessDown, exec, ~/.local/bin/brightness-ctl down"
          # Bare -1/+1 on purpose.  Every "relative" form Hyprland offers
          # (e+1 relative-open, m+1 relative-on-monitor) refuses to move at
          # all when only one workspace exists, so the arrows did nothing on a
          # fresh session.  The arithmetic form always moves, stepping into a
          # new workspace the way a dynamic-workspace desktop does; Hyprland
          # destroys the empty one again as soon as you leave it.
          # Plain `workspace`, NOT focusworkspaceoncurrentmonitor.  The
          # numbered $mod binds use that one deliberately -- naming a workspace
          # should bring it to the screen you are on -- but applying it to a
          # relative step made the two screens EXCHANGE workspaces whenever the
          # step crossed one living on the other monitor.  The bar then looked
          # unchanged (same set, same highlight moving between them) and the
          # numbering jumped, 1,2,3 turning into 1,2,4 as the vacated workspace
          # was destroyed.  Stepping leaves the other screen alone; focus just
          # follows the workspace to whichever monitor holds it.
          "CTRL ALT, left, exec, ~/.local/bin/ws-step prev"
          "CTRL ALT, right, exec, ~/.local/bin/ws-step next"
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
              # focusworkspaceoncurrentmonitor, not workspace: a workspace is
              # bound to the monitor it lives on, so plain `workspace N` moves
              # FOCUS to whichever monitor already holds N and leaves both
              # screens showing exactly what they showed before -- pressing a
              # number appeared to do nothing at all.  This brings N onto the
              # screen being looked at instead (swapping with what was there).
              "$mod, code:1${toString i}, focusworkspaceoncurrentmonitor, ${toString ws}"
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
        # Rescue: reattach a locker to an orphaned session lock.  bindl, so it
        # still works while locked -- which is the only moment it matters.
        # Needs misc:allow_session_lock_restore above.
        # Points at the script rather than running swaylock inline: this bind's
        # own command line would otherwise contain the locker's name, so the
        # pgrep guard would match itself, conclude a locker was already running
        # and never start one -- exactly when it is needed most.
        "CTRL ALT, L, exec, ~/.local/bin/lock-and-blank"
        # Acer's display-switch key reaches us two ways: as bare F7 when the
        # Predator's Fn-lock is on, and as XF86Display (KEY_SWITCHVIDEOMODE,
        # from the "Acer WMI hotkeys" / "Video Bus" input devices) when Fn is
        # held.  Bind both so the key works either way.
        ", F7, exec, ~/.local/bin/display-cycle"
        ", XF86Display, exec, ~/.local/bin/display-cycle"
        # F8 keeps the DDC/CI input switch, but only on a machine with no
        # built-in panel; display-cycle makes that call at runtime.
        ", F8, exec, ~/.local/bin/display-cycle input 0x0f"
      ];
      bindc =[
        "$mod, mouse:274, togglefloating"
      ];
      # monitor = "DP-3,1920x1080@60,0x0,1";
      # Autostart programs
      # `exec`, not `exec-once`: this also runs on every config reload, which
      # is exactly when the runtime monitor positions are lost.  `relayout`
      # re-applies the mode already in use rather than forcing extend, so a
      # rebuild while on a single screen does not yank the other one back on.
      # SKIP_AGS: at login the bars are still starting, so leave them alone.
      exec = [ "env DISPLAY_CYCLE_SKIP_AGS=1 ~/.local/bin/display-cycle relayout" ];

      exec-once = [ "~/.local/bin/display-rescue"
                    "uwsm app -- pypr"
                    # AGS v2 (Astal) is now the only bar (waybar retired).
                    "uwsm app -- ags run"
                    # swaync is launched by services.swaync (home-manager systemd unit);
                    # do not duplicate here or the unit fails with "instance already running".
                    # awww-daemon must be running before random-wallpaper can talk to it
                    "uwsm app -- awww-daemon"
                    "env GDK_BACKEND=x11 copyq --daemon"
                    "protonvpn-app"
                    # Filen sync client, started straight to the tray. --hidden
                    # suppresses both the launcher and main window (index.js
                    # checks process.argv for it); minimize-to-tray comes from
                    # the filen-desktop overlay patch in flake.nix.
                    # Keep Filen out of the login critical path. Its initial
                    # scan can be I/O-heavy even when no files need syncing.
                    "sleep 15; ~/.local/bin/filen-desktop --hidden"
                    "~/.local/bin/random-wallpaper"
                    "while true; do sleep 60; ~/.local/bin/random-wallpaper; done"
                    "systemctl --user start hyprpolkitagent"
                    "~/.local/bin/remmina-dnd-watcher"
                  ];
      cursor = {
        # Software cursors are required here, not a preference.  Rendering now
        # can happen on the NVIDIA dGPU, but
        # the built-in panel hangs off the Intel iGPU, and a cursor buffer
        # allocated on one GPU cannot be imported into the other's hardware
        # cursor plane -- so the pointer simply stopped being drawn on the
        # laptop screen while the compositor still tracked it perfectly.
        # Hyprland's default here is "auto", which does not catch this case.
        no_hardware_cursors = true;
      };

      xwayland = {
        # Under a fractional monitor scale Hyprland draws X11 clients at 1x
        # and stretches them, which blurred KrakenOS (Tk has no Wayland
        # backend).  With this, X11 clients get the monitor's native pixels
        # and are left to scale themselves: KrakenOS does so via
        # KRAKEN_UI_SCALE, which its devenv derives from the focused
        # monitor's scale.  A no-op on monitors at scale 1.
        force_zero_scaling = true;
      };

      # Keep 1 and 2 alive so the numbering does not grow holes when an empty
      # workspace is collected.  Static, and deliberately not pinned to a
      # particular monitor -- naming connectors here is what a portable image
      # cannot do safely.
      workspace = [
        "1, persistent:true"
        "2, persistent:true"
      ];

      misc = {
        # A session lock whose client has died cannot normally be dismissed --
        # the compositor keeps the session locked and there is nothing left to
        # type into, which has twice meant a forced reboot.  This permits a
        # fresh locker to take over an orphaned lock, which together with the
        # CTRL+ALT+L bind below turns "reboot the machine" into "press a key".
        # hyprlock aborting is the fault; this is the seatbelt.
        allow_session_lock_restore = true;
        mouse_move_enables_dpms = false;
        key_press_enables_dpms = true;
        initial_workspace_tracking = 2;
      };
    };
  };


  # ── Waybar (retired — kept disabled for reference) ──────────────────
  # The active bar is now AGS/Astal (see ags/widget/Bar.tsx). The
  # waybar config below remains as documentation of the modules we
  # ported and isn't started by Hyprland exec-once anymore.
  programs.waybar = {
    enable = false;
    systemd.enable = false;
    settings.mainBar = {
      layer = "top";
      position = "top";
      height = 34;
      spacing = 6;
      margin-top = 0;
      margin-left = 0;
      margin-right = 0;
      modules-left = [
        "custom/launcher" "hyprland/workspaces"
        "cpu" "memory" "disk" "temperature" "systemd-failed-units"
        "mpris"
        (if useScrollIndicator then "custom/brightness" else "backlight/slider")
      ];
      modules-center = [ "hyprland/window" ];
      modules-right = [
        "privacy"
        "network" "wireplumber" "pulseaudio/slider" "battery"
        "idle_inhibitor" "keyboard-state"
        "tray" "custom/weather" "clock" "custom/lunar" "custom/holiday" "custom/notification" "custom/power"
      ];

      "custom/launcher" = {
        format = "";  # NixOS logo
        on-click = "/home/thinky/.local/bin/launch-app-drawer";
        tooltip-format = "Application drawer (fullscreen)";
      };

      "hyprland/workspaces" = {
        format = "{name}";
        on-click = "activate";
        all-outputs = true;
        # Hide Hyprland special workspaces (negative IDs like -98, -97 …)
        ignore-workspaces = [ "^-" ];
      };

      "hyprland/window" = {
        format = "{title}";
        max-length = 90;
        separate-outputs = true;
      };

      mpris = {
        format = "{player_icon} {dynamic}";
        format-paused = "{status_icon} <i>{dynamic}</i>";
        player-icons = {
          default = "▶";
          mpv = "";
          firefox = "";
          spotify = "";
          chromium = "";
        };
        status-icons = { paused = "⏸"; };
        dynamic-len = 40;
        on-click = "playerctl play-pause";
        on-click-right = "playerctl stop";
        on-scroll-up = "playerctl next";
        on-scroll-down = "playerctl previous";
      };

      cpu = {
        format = " {usage}%";
        interval = 5;
        on-click = "~/.local/bin/toggle-app btop btop";
        tooltip-format = "Left: toggle btop";
      };
      memory = {
        format = "󰍛 {percentage}%";
        interval = 10;
        on-click = "~/.local/bin/toggle-app btop btop";
        on-click-right = "~/.local/bin/toggle-app meminfo bash -c 'free -h; echo; ps aux --sort=-%mem | head -20; echo; read -n1 -p \"press any key…\"'";
        tooltip-format = "Left: toggle btop  ·  Right: top memory consumers";
      };
      disk = {
        format = " {percentage_used}%";
        path = "/";
        interval = 60;
        on-click = "~/.local/bin/toggle-app yazi yazi /";
        on-click-right = "~/.local/bin/toggle-app diskinfo bash -c 'df -hT -x tmpfs -x devtmpfs; echo; read -n1 -p \"press any key…\"'";
        tooltip-format = "Left: toggle yazi  ·  Right: df -h";
      };
      temperature = {
        thermal-zone = 7;  # x86_pkg_temp — zone 0 (INT3400) is a stub
        format = " {temperatureC}°C";
        critical-threshold = 85;
        interval = 10;
        on-click = "~/.local/bin/toggle-app sensors bash -c 'watch -n1 sensors'";
        on-click-right = "~/.local/bin/toggle-app btop btop";
        tooltip-format = "Left: toggle sensors  ·  Right: toggle btop";
      };

      "backlight/slider" = {
        min = 0;
        max = 100;
        orientation = "horizontal";
        # Used on M90aPro (intel_backlight, microsecond writes). X299 hosts
        # use the custom indicator below instead — DDC/CI's ~75 ms per
        # transaction makes drag-to-set queue faster than it drains.
      };

      # X299-host fallback: indicator (10-cell unicode bar) + scroll/click.
      # exec reads /sys/class/backlight/ddcci5/actual_brightness, so refresh
      # is fast even with kernel module delay back at 0. Each scroll/click
      # invokes brightness-ctl, which writes sysfs → one i2c transaction.
      # Keyboard control is via F5/F6 (Hyprland binds, independent of focus).
      "custom/brightness" = {
        exec = "~/.local/bin/brightness-ctl status";
        return-type = "json";
        interval = 30;
        signal = 8;
        on-scroll-up = "~/.local/bin/brightness-ctl up";
        on-scroll-down = "~/.local/bin/brightness-ctl down";
        on-click = "~/.local/bin/brightness-ctl up";
        on-click-right = "~/.local/bin/brightness-ctl down";
        tooltip = true;
      };

      "pulseaudio/slider" = {
        min = 0;
        max = 100;
        orientation = "horizontal";
      };

      # Bluetooth is handled by blueman-applet in the systray
      # (services.blueman.enable). Left-click opens blueman-manager,
      # right-click gives the full Bluetooth action menu.

      network = {
        format-wifi = " {essid}";
        format-ethernet = "󰈀 {ipaddr}";
        format-disconnected = "󰤭 off";
        tooltip-format-wifi = "Left: nmtui  ·  Right: ip info\n\n{essid} ({signalStrength}%)\n{ipaddr}/{cidr}\n↓ {bandwidthDownBits}  ↑ {bandwidthUpBits}";
        tooltip-format-ethernet = "Left: nmtui  ·  Right: ip info\n\n{ifname}\n{ipaddr}/{cidr}\n↓ {bandwidthDownBits}  ↑ {bandwidthUpBits}";
        on-click = "~/.local/bin/toggle-app nmtui nmtui";
        on-click-right = "~/.local/bin/toggle-app netinfo bash -c 'ip -c a; echo; ip r; echo; read -n1 -p \"press any key…\"'";
        interval = 5;
      };

      wireplumber = {
        format = "{icon} {volume}%";
        format-muted = "󰖁";
        format-icons = [ "" "" "" ];
        on-click = "pavucontrol";
        on-click-right = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
        on-scroll-up = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+";
        on-scroll-down = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-";
        scroll-step = 5;
      };

      battery = {
        format = "{icon} {capacity}%";
        format-charging = "󰂄 {capacity}%";
        format-plugged = "󰚥 {capacity}%";
        format-icons = [ "󰁺" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰁹" ];
        states = { good = 90; warning = 30; critical = 15; };
        on-click = "~/.local/bin/toggle-app battinfo bash -c 'upower -i $(upower -e | grep -m1 BAT) 2>/dev/null || echo no battery; echo; read -n1 -p \"press any key…\"'";
        tooltip-format = "Left: battery details\n\n{timeTo}\n{power}W";
      };

      idle_inhibitor = {
        format = "{icon}";
        format-icons = {
          activated = "";    # coffee — caffeine on
          deactivated = "";  # zzz — caffeine off
        };
        tooltip-format-activated = "Idle inhibitor active (screen won't blank)";
        tooltip-format-deactivated = "Idle inhibitor inactive";
      };

      keyboard-state = {
        numlock = true;
        capslock = true;
        format = "{name} {icon}";
        format-icons = { locked = ""; unlocked = ""; };
      };

      # Keyboard layout / input method is handled by fcitx5's systray icon.

      "systemd-failed-units" = {
        hide-on-ok = true;
        format = "✗ {nr_failed}";
        system = true;
        user = true;
        on-click = "~/.local/bin/toggle-app failed-units bash -lc 'echo === user ===; systemctl --user --failed; echo; echo === system ===; systemctl --failed; echo; exec bash'";
        on-click-right = "systemctl --user reset-failed; pkexec systemctl reset-failed";
        tooltip-format = "{nr_failed} failed units — left-click: list, right-click: reset";
      };

      privacy = {
        icon-spacing = 4;
        icon-size = 14;
        # transition-duration=0: a non-zero fade triggers a glibmm NULL
        # deref (`segfault at 4c` in libglibmm-2.4) when a PipeWire
        # audio-in node disappears mid-transition — reproducibly hit
        # when Remmina toggles its mic stream.
        transition-duration = 0;
        modules = [
          { type = "screenshare"; tooltip = true; tooltip-icon-size = 24; }
          { type = "audio-in";    tooltip = true; tooltip-icon-size = 24; }
        ];
      };

      tray = {
        icon-size = 18;
        spacing = 8;
      };

      "custom/weather" = {
        # wttr.in: %c=condition icon, %t=temperature
        exec = "${pkgs.curl}/bin/curl -sf 'https://wttr.in/Singapore?format=%c+%t' || echo ''";
        interval = 1800;
        tooltip = true;
        format = "{}";
        on-click = "~/.local/bin/toggle-app wttr bash -c '${pkgs.curl}/bin/curl -s wttr.in/Singapore; echo; read -n1 -p \"press any key…\"'";
        on-click-right = "~/.local/bin/toggle-app wttr-fc bash -c '${pkgs.curl}/bin/curl -s wttr.in/Singapore?2 | less -R'";
      };

      "custom/holiday" = {
        # Reads every *.ics in assets/calendars/. Drop in next year's file
        # (e.g. sg-holidays-2027.ics) and rebuild — no code change needed.
        exec = "${pkgs.python3}/bin/python3 ${./assets/waybar-sg-holidays.py} ${./assets/calendars}";
        return-type = "json";
        interval = 3600;
        format = "{}";
        tooltip = true;
      };

      "custom/lunar" = {
        exec = "${pythonLunar}/bin/python3 ${./assets/waybar-lunar.py}";
        return-type = "json";
        interval = 3600;
        format = "{}";
        tooltip = true;
      };

      clock = {
        format = " {:%a %d %b  %H:%M}";
        format-alt = " {:%Y-%m-%d %H:%M:%S}";
        tooltip-format = "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>";
        calendar = {
          mode = "year";
          mode-mon-col = 3;
          weeks-pos = "right";
          on-scroll = 1;
          format = {
            months   = "<span color='#ff69b4'><b>{}</b></span>";
            days     = "<span color='#ffd700'><b>{}</b></span>";
            weekdays = "<span color='#00ffff'><b>{}</b></span>";
            today    = "<span color='#ff4500'><b>{}</b></span>";
            # Week numbers: dim grey + italic, no bold, so they don't read as dates.
            weeks    = "<span color='#7a7a7a' style='italic' size='smaller'>W{}</span>";
          };
        };
        actions = {
          on-click-right = "mode";
          on-scroll-up = "shift_up";
          on-scroll-down = "shift_down";
        };
      };

      "custom/notification" = {
        tooltip = false;
        format = "{icon}{text}";
        format-icons = {
          notification = " ";
          none = "";
          dnd-notification = " ";
          dnd-none = "";
          inhibited-notification = " ";
          inhibited-none = "";
          dnd-inhibited-notification = " ";
          dnd-inhibited-none = "";
        };
        return-type = "json";
        exec-if = "which swaync-client";
        exec = "swaync-client -swb";
        on-click = "swaync-client -t -sw";
        on-click-right = "swaync-client -d -sw";
        escape = true;
      };

      "custom/power" = {
        format = "⏻";
        tooltip-format = "Power menu (wlogout)";
        on-click = "wlogout";
      };
    };

    style = builtins.readFile ./assets/waybar-style.css;
  };

  # ── swaync (notification daemon + center) ────────────────────────────
  services.swaync = {
    enable = true;
    settings = {
      positionX = "right";
      positionY = "top";
      control-center-margin-top = 6;
      control-center-margin-bottom = 6;
      control-center-margin-right = 6;
      control-center-margin-left = 0;
      notification-2fa-action = true;
      notification-inline-replies = true;
      timeout = 8;
      timeout-low = 4;
      timeout-critical = 0;
      transition-time = 200;
      hide-on-clear = false;
      hide-on-action = true;
      widgets = [ "title" "dnd" "mpris" "notifications" ];
      widget-config = {
        title = {
          text = "Notifications";
          clear-all-button = true;
          button-text = "Clear all";
        };
        dnd = { text = "Do Not Disturb"; };
        mpris = { image-size = 64; image-radius = 8; };
      };
    };
    style = builtins.readFile ./assets/swaync-style.css;
  };

  # ── wlogout (power menu) ─────────────────────────────────────────────
  programs.wlogout = {
    enable = true;
    layout = [
      { label = "lock";     action = "~/.local/bin/lock-and-blank"; text = "Lock";     keybind = "l"; }
      # Each action logs before it acts.  When Shutdown appeared to do nothing
      # there was no way to tell whether the button had fired at all or whether
      # systemctl had refused, and that ambiguity cost a lot of guessing.  A
      # `journalctl -t wlogout` now answers it outright.
      { label = "logout";   action = "logger -t wlogout logout; hyprctl dispatch exit"; text = "Logout";     keybind = "e"; }
      { label = "suspend";  action = "logger -t wlogout suspend; systemctl suspend";     text = "Suspend";     keybind = "s"; }
      { label = "reboot";   action = "logger -t wlogout reboot; systemctl reboot";      text = "Reboot";     keybind = "r"; }
      { label = "shutdown"; action = "logger -t wlogout shutdown; systemctl poweroff";    text = "Shutdown";     keybind = "p"; }
      { label = "hibernate"; action = "logger -t wlogout hibernate; systemctl hibernate";    text = "Hibernate"; keybind = "h"; }
    ];
    style = let
      icons = "${pkgs.wlogout}/share/wlogout/icons";
    in ''
      ${builtins.readFile ./assets/wlogout-style.css}

      #lock      { background-image: url("${icons}/lock.png"); }
      #logout    { background-image: url("${icons}/logout.png"); }
      #suspend   { background-image: url("${icons}/suspend.png"); }
      #reboot    { background-image: url("${icons}/reboot.png"); }
      #shutdown  { background-image: url("${icons}/shutdown.png"); }
      #hibernate { background-image: url("${icons}/hibernate.png"); }
    '';
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
      lock_cmd = "~/.local/bin/lock-and-blank";
    };

    listener = [
      {
        timeout = 900;
        on-timeout = "~/.local/bin/lock-and-blank";
      }
      # Re-enabled.  This was disabled while hyprlock was the locker, because
      # an output vanishing underneath it aborted it and stranded the session;
      # swaylock survives that, and blanking on lock is confirmed working.
      # Leaving it off was also a regression for the other laptops, which never
      # had the problem and were losing idle blanking for no reason.
      # Disabled again: see the kernel deadlock described in lock-and-blank.
      # Walking away for 20 minutes would trip exactly the same NVIDIA hang.
      # {
      #   timeout = 1200;
      #   on-timeout = "hyprctl dispatch dpms off";
      #   on-resume = "hyprctl dispatch dpms on";
      # }
    ];
  };

  # Kept installed but no longer the locker -- see home.packages.  It stays so
  # there is something to fall back on if swaylock ever misbehaves; nothing
  # launches it automatically any more.
  programs.hyprlock = {
    enable = true;
    settings = {
      general = {
        # A stray Enter on an empty field submits an empty password, which PAM
        # records as a failed attempt.  Ignore empty submissions instead.
        ignore_empty_input = true;
      };
      auth.pam = {
        # Authenticate against hyprlock's own PAM stack rather than falling
        # back to `su`'s, which carries pam_rootok, pam_faillock and pam_xauth.
        # Defined by security.pam.services.hyprlock in configuration.nix --
        # pointing at a module with no /etc/pam.d entry would make the session
        # impossible to unlock, so that file is created first.
        module = "hyprlock";
      };
    };
  };

  # Packages that should be installed to the user profile.
  home.packages = with pkgs; [
    # Screen locker.  Replaces hyprlock, which aborted from its Wayland
    # dispatch thread when an output disappeared and left the session locked
    # behind a dead client -- twice costing a forced reboot.  swaylock speaks
    # the same ext-session-lock-v1 protocol, so this is not a downgrade to a
    # mere overlay, and authenticates through libpam against the clean
    # /etc/pam.d/swaylock stack.
    swaylock
    (python3.withPackages (ps: with ps; [ pygobject3 ]))
    gtk3
    gobject-introspection
    # AGS v2 runner; uses astal libraries from nixpkgs. Config lives in
    # ~/.config/ags (symlinked from the NixOS repo via xdg.configFile below).
    # extraPackages puts the astal GIR typelibs on GI_TYPELIB_PATH so the
    # JSX widgets can `import "gi://AstalBattery"` etc. at runtime.
    (ags.override {
      extraPackages = (with pkgs.astal; [
        apps battery bluetooth hyprland mpris network notifd powerprofiles tray wireplumber
      ]) ++ [
        # astal.network wraps libnm — its GIR (NM-1.0) ships with networkmanager.
        pkgs.networkmanager
      ];
    })
    libnotify
    megasync

    swappy
    cliphist
    copyq
    playerctl
    nomacs
    gthumb
    pyprland
    pavucontrol
    xed-editor
    gtk3
    gobject-introspection
    sioyek
    poppler-utils
    wf-recorder
    mpv
    mpvpaper
    gnome-disk-utility
    xdg-desktop-portal-gtk
    nwg-drawer
    # Microsoft discontinued the native Linux Teams client; this is the
    # maintained Electron wrapper around the Teams web app.
    teams-for-linux
    zoom-us
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
      size = 9.5;
      name = "CaskaydiaCove Nerd Font Mono";
    };
    settings = {
      confirm_os_window_close = 0;
      open_url_with = "firefox";
      detect_urls = "yes";
      dynamic_background_opacity = true;
      enable_audio_bell = false;
      mouse_hide_wait = "-1.0";
      window_padding_width = 16;
      background_opacity = "0.72";
      background_blur = 10;
      foreground = "#d9f6ff";
      background = "#07111b";
      selection_foreground = "#07111b";
      selection_background = "#7df9ff";
      cursor = "#ff63d8";
      cursor_text_color = "#07111b";
      active_border_color = "#7df9ff";
      inactive_border_color = "#152334";
      active_tab_background = "#7df9ff";
      active_tab_foreground = "#07111b";
      inactive_tab_background = "#0d1724";
      inactive_tab_foreground = "#7aa6c2";
      active_tab_font_style = "bold";
      color0 = "#07111b";
      color1 = "#ff5ea8";
      color2 = "#4ef2c2";
      color3 = "#ffd166";
      color4 = "#6bc5ff";
      color5 = "#c27dff";
      color6 = "#7df9ff";
      color7 = "#d9f6ff";
      color8 = "#122233";
      color9 = "#ff88bf";
      color10 = "#89ffd7";
      color11 = "#ffe08a";
      color12 = "#8ed3ff";
      color13 = "#d0a6ff";
      color14 = "#a8ffff";
      color15 = "#f2fbff";
    };
    extraConfig = ''
    map ctrl+shift+equal change_font_size all +0.5                          
    map ctrl+shift+minus change_font_size all -0.5
    map alt+w copy_to_clipboard
    map ctrl+y paste_from_clipboard
    tab_bar_style powerline
    tab_powerline_style slanted
    tab_title_template " {index}: {title} "
    shell_integration enabled
    cursor_trail 2
    repaint_delay 5
    input_delay 1

    # Optional: Copy on select
    copy_on_select yes
  '';
  };

  programs.bash = {
    enable = true;
    enableCompletion = true;
    # TODO add your custom bashrc here
    bashrcExtra = ''
      export PATH="$HOME/.local/bin:$HOME/bin:$HOME/go/bin:$PATH"

      # ble.sh: fish-like autosuggestions, syntax highlighting, menu completion.
      # Source --noattach early; attach on first prompt so starship / direnv /
      # kitty integration (all appended later in bashrc) finish setup first.
      if [[ $- == *i* ]]; then
        source ${pkgs.blesh}/share/blesh/ble.sh --noattach

        # Autosuggestion keys (only fire while a ghost suggestion is shown):
        #   Tab   -> accept one word of the suggestion (up to next "/")
        #   Enter -> if the previous keystroke was TAB, drop the remaining
        #            ghost and execute only what's typed; otherwise accept the
        #            whole ghost and execute (the usual fish-style behaviour).
        #            Branch on $LASTWIDGET, which ble.sh sets to the prior
        #            widget's name before invoking ours.
        bleopt complete_auto_wordbreaks=/
        function ble/widget/my/auto_complete/smart-accept {
          if [[ $LASTWIDGET == ble/widget/auto_complete/insert-word ]]; then
            ble/widget/auto_complete/cancel-default
          else
            ble/widget/auto_complete/accept-line
          fi
        }
        ble-bind -m auto_complete -f RET my/auto_complete/smart-accept
        ble-bind -m auto_complete -f C-m my/auto_complete/smart-accept
        ble-bind -m auto_complete -f TAB auto_complete/insert-word
        ble-bind -m auto_complete -f C-i auto_complete/insert-word

        _ble_attach_once() {
          [[ ''${BLE_VERSION-} ]] && ble-attach
          PROMPT_COMMAND=''${PROMPT_COMMAND//_ble_attach_once;/}
          PROMPT_COMMAND=''${PROMPT_COMMAND//;_ble_attach_once/}
          PROMPT_COMMAND=''${PROMPT_COMMAND//_ble_attach_once/}
          unset -f _ble_attach_once
        }
        PROMPT_COMMAND="_ble_attach_once;''${PROMPT_COMMAND-}"
      fi
    '';

    # set some aliases, feel free to add more or remove some
    shellAliases = {
      ls = "eza --icons=always --group-directories-first --sort=extension";
      gc = "git commit -m";
      rebuild = "~/Projects/NixOS/rebuild.sh";
      btop = "btop";
      direnv-fix = "rm -f .devenv/nix-eval-cache.db && direnv reload";
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
      # Persistent=true (below) fires this catch-up run at boot, before the
      # login shell has set PATH — without an explicit PATH the script's
      # first external (`date`) returns 127. Pin enough of the env for
      # curl/jq/yt-dlp/date to resolve regardless of when we run.
      Environment = [
        "PATH=/run/wrappers/bin:/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin:/usr/bin:/bin"
      ];
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
  programs.firefox.configPath = "${config.xdg.configHome}/mozilla/firefox";

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

  programs.fd = {
    enable = true;
    hidden = true;
    ignores = [ ".git/" ];
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
        # Cyberpunk palette matching waybar (one distinct hue per logo
        # stroke). The fastfetch nixos logo only consumes slots 1-6;
        # 7-9 are kept as fallbacks for any other distro logo we might
        # render.
        color = {
          "1" = "#ff69b4";   # pink
          "2" = "#00ffff";   # cyan
          "3" = "#ffd700";   # gold
          "4" = "#ff4500";   # orange
          "5" = "#32cd32";   # green
          "6" = "#ff1493";   # deep magenta
          "7" = "#00ffff";
          "8" = "#ff69b4";
          "9" = "#ffd700";
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

  home.activation.ensureScreenshotDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "$HOME/Pictures/Screenshots"
  '';

  home.activation.refreshWalkerIcons = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    if [ -d "$HOME/.local/share/icons/hicolor" ]; then
      ${pkgs.gtk3}/bin/gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" || true
    fi
    if ${pkgs.systemd}/bin/systemctl --user is-active walker >/dev/null 2>&1; then
      ${pkgs.systemd}/bin/systemctl --user restart walker || true
    fi
  '';
  # ── Nemo "Open Terminal Here" ──
  # Nemo reads the Cinnamon dconf key to decide which terminal to launch.
  # The gsettings schema ID is org.cinnamon.desktop.default-applications.terminal
  # but the actual dconf path is /org/cinnamon/desktop/applications/terminal/.
  dconf.settings."org/cinnamon/desktop/applications/terminal" = {
    exec = "kitty";
    exec-arg = "";
  };

  home.stateVersion = "25.11";
}
