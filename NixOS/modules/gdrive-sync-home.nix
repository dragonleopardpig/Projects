{ config, lib, pkgs, ... }:
let
  home = config.home.homeDirectory;
  rclone = "${pkgs.rclone}/bin/rclone";
  mountPoint = "${home}/Google Drive";

  pythonEnv = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);

  gdriveControl = pkgs.writeShellApplication {
    name = "gdrive-control";
    runtimeInputs = [
      pythonEnv
      pkgs.gtk3
      pkgs.libayatana-appindicator
      pkgs.libnotify
      pkgs.librsvg
      pkgs.rclone
      pkgs.nemo-with-extensions
      pkgs.coreutils
      pkgs.procps
    ];
    text = ''
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
      export GDRIVE_ICONS_DIR="${../assets/gdrive-icons}"
      exec python3 ${../scripts/gdrive-sync.py} "$@"
    '';
  };
in
{
  home.packages = [
    gdriveControl
  ];

  # Wrapper symlink for convenience
  home.file.".local/bin/gdrive-tray" = {
    source = "${gdriveControl}/bin/gdrive-control";
    executable = true;
    force = true;
  };

  # Custom scalable icons for Google Drive tray and settings
  home.file.".local/share/icons/hicolor/scalable/apps/gdrive.svg" = {
    source = ../assets/gdrive-icons/gdrive.svg;
    force = true;
  };
  home.file.".local/share/icons/hicolor/scalable/apps/gdrive-syncing.svg" = {
    source = ../assets/gdrive-icons/gdrive-syncing.svg;
    force = true;
  };
  home.file.".local/share/icons/hicolor/scalable/apps/gdrive-paused.svg" = {
    source = ../assets/gdrive-icons/gdrive-paused.svg;
    force = true;
  };
  home.file.".local/share/icons/hicolor/scalable/apps/gdrive-error.svg" = {
    source = ../assets/gdrive-icons/gdrive-error.svg;
    force = true;
  };

  # Nemo Context Menu Action
  xdg.dataFile."nemo/actions/sync_google_drive.nemo_action".text = ''
    [Nemo Action]
    Active=true
    Name=Sync with Google Drive
    Comment=Add this folder to Google Drive sync list
    Exec=${gdriveControl}/bin/gdrive-control add "%F"
    Icon-Name=folder-google-drive
    Selection=s
    Extensions=dir;
    Quote=double
  '';

  # Desktop Application Launcher
  xdg.desktopEntries.gdrive-settings = {
    name = "Google Drive Settings";
    comment = "Configure Google Drive sync folders and cloud mount";
    exec = "${gdriveControl}/bin/gdrive-control settings";
    icon = "folder-google-drive";
    terminal = false;
    categories = [ "Utility" "Settings" "FileTools" ];
  };

  # GTK Sidebar Bookmarks in Nemo
  home.activation.cloudBookmarks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${pkgs.python3}/bin/python3 - <<'PY'
    from pathlib import Path
    import subprocess

    home = Path.home()
    bookmarks = home / '.config/gtk-3.0/bookmarks'
    
    entries = [
        (home / 'Google Drive', 'Google Drive', 'folder-google-drive'),
        (home / 'MEGA', 'MEGA', 'megasync'),
        (home / 'Filen', 'Filen', 'filen-desktop'),
    ]

    for d, label, icon in entries:
        d.mkdir(parents=True, exist_ok=True, mode=0o755)
        try:
            subprocess.run(["${pkgs.glib}/bin/gio", "set", str(d), "metadata::custom-icon-name", icon], check=False)
        except Exception:
            pass

    content = bookmarks.read_text(encoding='utf-8') if bookmarks.exists() else ""
    lines = [l.strip() for l in content.splitlines() if l.strip()]
    seen = {l.split()[0] for l in lines}
    additions = []

    for d, label, _ in entries:
        uri = d.as_uri()
        if uri not in seen:
            additions.append(f"{uri} {label}")
            seen.add(uri)

    if additions:
        bookmarks.parent.mkdir(parents=True, exist_ok=True)
        with bookmarks.open('a', encoding='utf-8') as f:
            if content and not content.endswith('\n'):
                f.write('\n')
            f.write('\n'.join(additions) + '\n')
    PY
  '';

  # Systemd User Service: Google Drive FUSE Mount
  systemd.user.services.gdrive-mount = {
    Unit = {
      Description = "Google Drive FUSE mount for Nemo and file access";
      Wants = [ "network-online.target" ];
      After = [ "graphical-session.target" "network-online.target" ];
      ConditionPathExists = "${home}/.config/rclone/rclone.conf";
    };
    Service = {
      Type = "notify";
      Environment = [ "RCLONE_CONFIG=${home}/.config/rclone/rclone.conf" ];
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p '${mountPoint}'";
      ExecStart = "${rclone} mount gdrive: '${mountPoint}' --vfs-cache-mode=full --vfs-cache-max-size=10G --vfs-cache-max-age=24h --umask=077 --dir-cache-time=1m";
      ExecStop = "/run/wrappers/bin/fusermount3 -u '${mountPoint}'";
      Restart = "on-failure";
      RestartSec = 10;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  # Systemd User Service: MEGA Cloud FUSE Mount
  systemd.user.services.mega-mount = {
    Unit = {
      Description = "MEGA Cloud FUSE mount for Nemo and file access";
      Wants = [ "network-online.target" ];
      After = [ "graphical-session.target" "network-online.target" ];
      ConditionPathExists = "${home}/.config/rclone/rclone.conf";
    };
    Service = {
      Type = "notify";
      Environment = [ "RCLONE_CONFIG=${home}/.config/rclone/rclone.conf" ];
      ExecCondition = "${pkgs.writeShellScript "check-mega-remote" ''
        ${rclone} listremotes | ${pkgs.gnugrep}/bin/grep -qx 'mega:'
      ''}";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p '${home}/MEGA'";
      ExecStart = "${rclone} mount mega: '${home}/MEGA' --vfs-cache-mode=full --vfs-cache-max-size=10G --vfs-cache-max-age=24h --umask=077 --dir-cache-time=1m";
      ExecStop = "/run/wrappers/bin/fusermount3 -u '${home}/MEGA'";
      Restart = "on-failure";
      RestartSec = 10;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  # Systemd User Service: Google Drive Tray Icon & Sync Daemon
  systemd.user.services.gdrive-tray = {
    Unit = {
      Description = "Google Drive Tray Indicator and Auto-Sync Daemon";
      After = [ "graphical-session.target" "tray.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionPathExists = "${home}/.config/rclone/rclone.conf";
    };
    Service = {
      ExecStart = "${gdriveControl}/bin/gdrive-control tray";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
