{ config, lib, pkgs, ... }:
let
  home = config.home.homeDirectory;
  rclone = "${pkgs.rclone}/bin/rclone";
  mountPoint = "${home}/Proton Drive";

  pythonEnv = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);

  protonDriveOfficialWrapper = pkgs.writeShellApplication {
    name = "proton-drive";
    runtimeInputs = [
      pkgs.libsecret
      pkgs.glib
      pkgs.coreutils
    ];
    text = ''
      export LD_LIBRARY_PATH="${pkgs.libsecret}/lib:${pkgs.glib.out}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      if [ -x "$HOME/.local/share/protondrive/bin/proton-drive" ]; then
        exec "$HOME/.local/share/protondrive/bin/proton-drive" "$@"
      else
        echo "Error: Proton official CLI binary not found at $HOME/.local/share/protondrive/bin/proton-drive" >&2
        echo "Run 'protondrive bootstrap --proton-drive --yes' to install it." >&2
        exit 1
      fi
    '';
  };

  protonDriveGoWrapper = pkgs.writeShellApplication {
    name = "protondrive";
    runtimeInputs = [
      pkgs.libsecret
      pkgs.glib
      pkgs.rclone
      pkgs.coreutils
    ];
    text = ''
      export PATH="$HOME/.local/bin:${pkgs.libsecret}/bin:${pkgs.rclone}/bin:$HOME/.local/share/protondrive/bin:$PATH"
      export LD_LIBRARY_PATH="${pkgs.libsecret}/lib:${pkgs.glib.out}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      export PROTONDRIVE_PROTON_BIN="$HOME/.local/bin/proton-drive"
      export PROTONDRIVE_RCLONE_BIN="${pkgs.rclone}/bin/rclone"
      export PROTONDRIVE_UNSAFE_SESSION_BRIDGE="1"
      if [ -x "/home/thinky/Projects/Protondrive-for-Linux/protondrive" ]; then
        exec "/home/thinky/Projects/Protondrive-for-Linux/protondrive" "$@"
      elif [ -x "$HOME/.local/share/protondrive/bin/protondrive" ]; then
        exec "$HOME/.local/share/protondrive/bin/protondrive" "$@"
      else
        echo "Error: protondrive binary not found." >&2
        exit 1
      fi
    '';
  };

  protondriveControl = pkgs.writeShellApplication {
    name = "protondrive-control";
    runtimeInputs = [
      pythonEnv
      pkgs.gtk3
      pkgs.gsettings-desktop-schemas
      pkgs.adwaita-icon-theme
      pkgs.hicolor-icon-theme
      pkgs.libayatana-appindicator
      pkgs.libnotify
      pkgs.librsvg
      pkgs.rclone
      pkgs.libsecret
      pkgs.glib
      pkgs.kitty
      pkgs.bash
      pkgs.nemo-with-extensions
      pkgs.coreutils
      pkgs.procps
    ];
    text = ''
      export PATH="$HOME/.local/bin:${pkgs.libsecret}/bin:${pkgs.rclone}/bin:$HOME/.local/share/protondrive/bin:$PATH"
      export LD_LIBRARY_PATH="${pkgs.libsecret}/lib:${pkgs.glib.out}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      export PROTONDRIVE_PROTON_BIN="$HOME/.local/bin/proton-drive"
      export PROTONDRIVE_RCLONE_BIN="${pkgs.rclone}/bin/rclone"
      export PROTONDRIVE_UNSAFE_SESSION_BRIDGE="1"
      export GI_TYPELIB_PATH="${pkgs.lib.makeSearchPath "lib/girepository-1.0" (map pkgs.lib.getLib [
        pkgs.gtk3
        pkgs.pango
        pkgs.gdk-pixbuf
        pkgs.at-spi2-core
        pkgs.harfbuzz
        pkgs.glib
        pkgs.gobject-introspection
        pkgs.libayatana-appindicator
      ])}''${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
      export GDK_PIXBUF_MODULE_FILE=${pkgs.librsvg}/${pkgs.gdk-pixbuf.binaryDir}/loaders.cache
      export PROTONDRIVE_ICONS_DIR="${../assets/protondrive-icons}"
      export XDG_DATA_DIRS="${pkgs.lib.concatStringsSep ":" [
        "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}"
        "${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}"
        "${pkgs.adwaita-icon-theme}/share"
        "${pkgs.hicolor-icon-theme}/share"
      ]}''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
      if [ -f "$HOME/Projects/NixOS/scripts/protondrive-sync.py" ]; then
        exec python3 "$HOME/Projects/NixOS/scripts/protondrive-sync.py" "$@"
      else
        exec python3 ${../scripts/protondrive-sync.py} "$@"
      fi
    '';
  };
in
{
  home.packages = [
    protondriveControl
    protonDriveOfficialWrapper
    protonDriveGoWrapper
    pkgs.libsecret
  ];

  # Wrapper symlinks for convenience
  home.file.".local/bin/proton-drive" = {
    source = "${protonDriveOfficialWrapper}/bin/proton-drive";
    executable = true;
    force = true;
  };

  home.file.".local/bin/protondrive" = {
    source = "${protonDriveGoWrapper}/bin/protondrive";
    executable = true;
    force = true;
  };

  home.file.".local/bin/protondrive-control" = {
    source = "${protondriveControl}/bin/protondrive-control";
    executable = true;
    force = true;
  };

  home.file.".local/bin/protondrive-tray" = {
    source = "${protondriveControl}/bin/protondrive-control";
    executable = true;
    force = true;
  };

  # Real-time status query tool for AGS bar and CLI
  home.file.".local/bin/protondrive-sync-status" = {
    source = ../scripts/protondrive-sync-status.py;
    executable = true;
    force = true;
  };

  # Custom scalable icons for Proton Drive tray, launchers, and Nemo
  home.file.".local/share/icons/hicolor/scalable/apps/protondrive.svg" = {
    source = ../assets/protondrive-icons/protondrive.svg;
    force = true;
  };
  home.file.".local/share/icons/hicolor/scalable/apps/proton-drive.svg" = {
    source = ../assets/protondrive-icons/protondrive.svg;
    force = true;
  };
  home.file.".local/share/icons/hicolor/scalable/apps/folder-protondrive.svg" = {
    source = ../assets/protondrive-icons/protondrive.svg;
    force = true;
  };
  home.file.".local/share/icons/hicolor/scalable/places/folder-protondrive.svg" = {
    source = ../assets/protondrive-icons/protondrive.svg;
    force = true;
  };
  home.file.".local/share/icons/hicolor/scalable/places/folder-proton-drive.svg" = {
    source = ../assets/protondrive-icons/protondrive.svg;
    force = true;
  };

  home.file.".local/share/icons/Tela-circle/scalable/apps/protondrive.svg" = {
    source = ../assets/protondrive-icons/protondrive.svg;
    force = true;
  };
  home.file.".local/share/icons/Tela-circle/scalable/apps/proton-drive.svg" = {
    source = ../assets/protondrive-icons/protondrive.svg;
    force = true;
  };
  home.file.".local/share/icons/Tela-circle/scalable/places/folder-protondrive.svg" = {
    source = ../assets/protondrive-icons/protondrive.svg;
    force = true;
  };
  home.file.".local/share/icons/Tela-circle/scalable/places/folder-proton-drive.svg" = {
    source = ../assets/protondrive-icons/protondrive.svg;
    force = true;
  };
  home.file.".local/share/icons/Tela-circle-dark/scalable/places/folder-protondrive.svg" = {
    source = ../assets/protondrive-icons/protondrive.svg;
    force = true;
  };
  home.file.".local/share/icons/Tela-circle-light/scalable/places/folder-protondrive.svg" = {
    source = ../assets/protondrive-icons/protondrive.svg;
    force = true;
  };

  home.file.".local/share/icons/hicolor/scalable/apps/protondrive-syncing.svg" = {
    source = ../assets/protondrive-icons/protondrive-syncing.svg;
    force = true;
  };
  home.file.".local/share/icons/hicolor/scalable/apps/protondrive-paused.svg" = {
    source = ../assets/protondrive-icons/protondrive-paused.svg;
    force = true;
  };
  home.file.".local/share/icons/hicolor/scalable/apps/protondrive-error.svg" = {
    source = ../assets/protondrive-icons/protondrive-error.svg;
    force = true;
  };

  # Nemo Context Menu Actions
  xdg.dataFile."nemo/actions/sync_proton_drive.nemo_action".text = ''
    [Nemo Action]
    Active=true
    Name=Sync with Proton Drive
    Comment=Add this folder to Proton Drive sync list
    Exec=/home/thinky/.local/bin/protondrive-control add "%F"
    Icon-Name=protondrive
    Selection=s
    Extensions=dir;
    Conditions=exec /home/thinky/.local/bin/protondrive-control not-synced %F;
    Quote=double
  '';

  xdg.dataFile."nemo/actions/unsync_proton_drive.nemo_action".text = ''
    [Nemo Action]
    Active=true
    Name=Remove from Proton Drive Sync
    Comment=Remove this folder from Proton Drive sync list
    Exec=/home/thinky/.local/bin/protondrive-control remove "%F"
    Icon-Name=edit-delete
    Selection=s
    Extensions=dir;
    Conditions=exec /home/thinky/.local/bin/protondrive-control is-synced %F;
    Quote=double
  '';

  # Desktop Application Launchers
  xdg.desktopEntries.protondrive-tray = {
    name = "Proton Drive";
    comment = "Start Proton Drive sync and tray indicator";
    exec = "${protondriveControl}/bin/protondrive-control tray";
    icon = "protondrive";
    terminal = false;
    categories = [ "Utility" "Network" "FileTools" ];
  };

  xdg.desktopEntries.protondrive-settings = {
    name = "Proton Drive Settings";
    comment = "Configure Proton Drive sync folders and cloud mount";
    exec = "${protondriveControl}/bin/protondrive-control settings";
    icon = "protondrive";
    terminal = false;
    categories = [ "Utility" "Settings" "FileTools" ];
  };

  # GTK Sidebar Bookmarks in Nemo
  home.activation.protondriveBookmarks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${pkgs.python3}/bin/python3 - <<'PY'
    from pathlib import Path
    import subprocess

    home = Path.home()
    bookmarks = home / '.config/gtk-3.0/bookmarks'
    d = home / 'Proton Drive'
    d.mkdir(parents=True, exist_ok=True, mode=0o755)

    try:
        subprocess.run(["${pkgs.glib}/bin/gio", "set", str(d), "metadata::custom-icon-name", "protondrive"], check=False)
        icon_file = f"file://{home}/.local/share/icons/hicolor/scalable/apps/protondrive.svg"
        subprocess.run(["${pkgs.glib}/bin/gio", "set", str(d), "metadata::custom-icon", icon_file], check=False)
    except Exception:
        pass

    content = bookmarks.read_text(encoding='utf-8') if bookmarks.exists() else ""
    uri = d.as_uri()
    if uri not in content:
        bookmarks.parent.mkdir(parents=True, exist_ok=True)
        with bookmarks.open('a', encoding='utf-8') as f:
            if content and not content.endswith('\n'):
                f.write('\n')
            f.write(f"{uri} Proton Drive\n")
    PY
  '';

  # Systemd User Service: Proton Drive FUSE Mount
  systemd.user.services.protondrive-mount = {
    Unit = {
      Description = "Proton Drive FUSE mount for Nemo and file access";
      Wants = [ "network-online.target" ];
      After = [ "graphical-session.target" "network-online.target" ];
      ConditionPathExists = "${home}/.config/rclone/rclone.conf";
      StartLimitIntervalSec = 300;
      StartLimitBurst = 3;
    };
    Service = {
      Type = "notify";
      Environment = [ "RCLONE_CONFIG=${home}/.config/rclone/rclone.conf" ];
      ExecCondition = "${pkgs.writeShellScript "check-protondrive-remote" ''
        set -eu
        ${rclone} listremotes | ${pkgs.gnugrep}/bin/grep -qx 'protondrive:'
        # Prevent rclone from using empty tokens or hammering the Proton auth API
        ${pkgs.gnugrep}/bin/grep -q 'client_refresh_token = ..*' "${home}/.config/rclone/rclone.conf"
      ''}";
      ExecStartPre = [
        "-/run/wrappers/bin/fusermount3 -u -z '${mountPoint}'"
        "${pkgs.coreutils}/bin/mkdir -p '${mountPoint}'"
      ];
      ExecStart = "${rclone} mount protondrive: '${mountPoint}' --vfs-cache-mode=full --vfs-cache-max-size=10G --vfs-cache-max-age=24h --umask=077 --dir-cache-time=1m";
      ExecStop = "/run/wrappers/bin/fusermount3 -u -z '${mountPoint}'";
      Restart = "on-failure";
      RestartSec = 30;
      RestartMaxDelaySec = 300;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  # Systemd User Service: Proton Drive Tray Icon & Sync Daemon
  systemd.user.services.protondrive-tray = {
    Unit = {
      Description = "Proton Drive Tray Indicator and Auto-Sync Daemon";
      After = [ "graphical-session.target" "tray.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${protondriveControl}/bin/protondrive-control tray";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
