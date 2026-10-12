{ config, lib, osConfig ? null, pkgs, scrambleHostName ? null, ... }:
let
  home = config.home.homeDirectory;
  ready = "${home}/.config/rclone/scramble-ready";
  publicReady = "${home}/.config/rclone/scramble-public-ready";
  mounted = "${home}/Scramble Private";
  publicMounted = "${home}/Scramble Public";
  rclone = "${pkgs.rclone}/bin/rclone";
  syncScript = pkgs.writeShellScript "scramble-private-sync" (
    builtins.replaceStrings [ "@RCLONE@" ] [ rclone ]
      (builtins.readFile ../scripts/scramble-private-sync)
  );
  hostName = if osConfig != null then osConfig.networking.hostName else scrambleHostName;
  cliHost = hostName != "M90aPro";
  backend = if cliHost then "scramble-webdav.service" else "scramble-desktop.service";
  scrambleDesktop =
    let
      pname = "scramble-desktop";
      version = "1.0.40";
      src = pkgs.fetchurl {
        url = "https://electron-auto-update.s3.de.io.cloud.ovh.net/Scramble_linux_x86_64.AppImage?versionId=1791756323.915028";
        name = "Scramble-${version}-x86_64.AppImage";
        hash = "sha256-Rl3WZoIbRsjFO98EciZoBLM8r2dTR7MI/6Yx1f1N9Bo=";
      };
      appimageContents = pkgs.appimageTools.extractType2 {
        inherit pname version src;
        postExtract = ''
          chmod u+w "$out/resources/app.asar"
          ${pkgs.asar}/bin/asar extract "$out/resources/app.asar" "$TMPDIR/scramble-app"
          (
            cd "$TMPDIR/scramble-app"
            ${pkgs.patch}/bin/patch -p1 --fuzz=0 < ${../patches/scramble-desktop-tray.patch}
          )
          ${pkgs.asar}/bin/asar pack "$TMPDIR/scramble-app" "$out/resources/app.asar"
        '';
      };
    in
    pkgs.appimageTools.wrapAppImage {
      inherit pname version;
      src = appimageContents;
      nativeBuildInputs = [ pkgs.makeWrapper ];
      extraInstallCommands = ''
        wrapProgram $out/bin/scramble-desktop \
          --add-flags "--no-sandbox --password-store=gnome-libsecret" \
          --set-default SCRAMBLE_CONTROL "${home}/.local/bin/scramble-control" \
          --set-default SCRAMBLE_LAUNCHER "${home}/.local/bin/scramble-launch"
        install -Dm444 ${appimageContents}/scramble-desktop.desktop \
          $out/share/applications/scramble-desktop.desktop
        cp -r ${appimageContents}/usr/share/icons $out/share/
        substituteInPlace $out/share/applications/scramble-desktop.desktop \
          --replace-fail 'Exec=AppRun --no-sandbox' "Exec=${home}/.local/bin/scramble-launch"
      '';
      meta = {
        description = "Scramble Cloud desktop client";
        homepage = "https://info.scramble.cloud/en/downloads/";
        license = lib.licenses.unfree;
        platforms = [ "x86_64-linux" ];
        mainProgram = "scramble-desktop";
      };
    };
  controlScript = pkgs.writeShellScript "scramble-control" (
    builtins.replaceStrings
      [ "@BACKEND@" "@RCLONE@" "@DESKTOP@" "@PATH@" ]
      [ backend rclone "${scrambleDesktop}/bin/scramble-desktop"
        (lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep pkgs.systemd pkgs.util-linux pkgs.libnotify pkgs.xdg-utils pkgs.kitty ]) ]
      (builtins.readFile ../scripts/scramble-control)
  );
  launchScript = pkgs.writeShellScript "scramble-launch" (
    builtins.replaceStrings [ "@SYSTEMCTL@" "@DESKTOP@" ]
      [ "${pkgs.systemd}/bin/systemctl" "${scrambleDesktop}/bin/scramble-desktop" ]
      (builtins.readFile ../scripts/scramble-launch)
  );
in
{
  # Credentials and the crypt keys stay in a mode-600 runtime rclone.conf,
  # outside the Nix store and this repository.
  home.packages = [ pkgs.rclone scrambleDesktop ] ++ lib.optionals cliHost [ pkgs.nodejs ];

  home.file.".local/bin/scramble-host-prepare" = {
    source = ../scripts/scramble-host-prepare;
    executable = true;
  };
  home.file.".local/bin/scramble-sync-init" = {
    source = ../scripts/scramble-sync-init;
    executable = true;
  };
  home.file.".local/bin/scramble-transfer-crypt" = {
    source = ../scripts/scramble-transfer-crypt;
    executable = true;
  };
  home.file.".local/bin/scramble-sync-status" = {
    source = ../scripts/scramble-sync-status;
    executable = true;
  };
  home.file.".local/bin/scramble-control" = {
    source = controlScript;
    executable = true;
  };
  home.file.".local/bin/scramble-launch" = {
    source = launchScript;
    executable = true;
  };

  home.activation.scrambleBookmarks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${pkgs.python3}/bin/python3 - <<'PY'
    from pathlib import Path

    home = Path.home()
    bookmarks = home / '.config/gtk-3.0/bookmarks'
    entries = [
        (home / 'Documents/Scramble Public', 'Scramble Public Sync'),
        (home / 'Documents/Scramble Sync', 'Scramble Private Sync'),
        (home / 'Scramble Public', 'Scramble Public Cloud (read-only)'),
        (home / 'Scramble Private', 'Scramble Private Cloud (read-only)'),
    ]
    content = bookmarks.read_text() if bookmarks.exists() else ""
    existing = {line.split()[0] for line in content.splitlines() if line.strip()}
    additions = []
    for directory, label in entries:
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        if directory.as_uri() not in existing:
            additions.append(directory.as_uri() + ' ' + label)
    if additions:
        bookmarks.parent.mkdir(parents=True, exist_ok=True)
        with bookmarks.open('a') as file:
            if content and not content.endswith('\n'):
                file.write('\n')
            file.write('\n'.join(additions) + '\n')
    PY
  '';

  systemd.user.services.scramble-private-sync = {
    Unit = {
      Description = "Two-way sync of one encrypted Scramble folder";
      Wants = [ "network-online.target" backend ];
      After = [ "network-online.target" backend ];
      ConditionPathExists = ready;
    };
    Service = {
      Type = "oneshot";
      Environment = [ "RCLONE_CONFIG=${home}/.config/rclone/rclone.conf" ];
      ExecStart = "${syncScript}";
    };
  };

  systemd.user.services.scramble-desktop = {
    Unit = {
      Description = "Scramble Desktop with tray controls";
      After = [ "graphical-session-pre.target" ];
      PartOf = [ "graphical-session.target" ];
      Wants = [ "scramble-session.service" ];
    };
    Service = {
      Type = "notify";
      NotifyAccess = "all";
      ExecStart = "${scrambleDesktop}/bin/scramble-desktop";
      TimeoutStartSec = "60s";
      Restart = "on-failure";
      RestartSec = 10;
    };
  };

  systemd.user.services.scramble-session = {
    Unit = {
      Description = "Connect Scramble cloud views and initialize available sync folders";
      After = [ "scramble-desktop.service" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${controlScript} start-sync";
      TimeoutStartSec = "infinity";
    };
  };

  systemd.user.timers.scramble-private-sync = {
    Unit.Description = "Check the encrypted Scramble folder every five minutes";
    Timer = {
      OnActiveSec = "1min";
      OnUnitInactiveSec = "5min";
      AccuracySec = "30s";
      Unit = "scramble-private-sync.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  systemd.user.services.scramble-private-mount = {
    Unit = {
      Description = "Decrypted read-only view of the encrypted Scramble folder";
      Wants = [ "network-online.target" backend ];
      After = [ "network-online.target" backend ];
      ConditionPathExists = ready;
    };
    Service = {
      Type = "notify";
      Environment = [ "RCLONE_CONFIG=${home}/.config/rclone/rclone.conf" ];
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p '${mounted}'";
      ExecStart = "${rclone} mount scramble_private:Current '${mounted}' --webdav-encoding=Colon --read-only --vfs-cache-mode=off --umask=077 --poll-interval=0 --dir-cache-time=30s";
      ExecStop = "/run/wrappers/bin/fusermount3 -u '${mounted}'";
      Restart = "on-failure";
      RestartSec = 10;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.scramble-public-sync = {
    Unit = {
      Description = "Two-way sync of the public Scramble folder";
      Wants = [ "network-online.target" backend ];
      After = [ "network-online.target" backend ];
      ConditionPathExists = publicReady;
    };
    Service = {
      Type = "oneshot";
      Environment = [ "RCLONE_CONFIG=${home}/.config/rclone/rclone.conf" ];
      ExecStart = "${syncScript} public";
    };
  };

  systemd.user.timers.scramble-public-sync = {
    Unit.Description = "Check the public Scramble folder every five minutes";
    Timer = {
      OnActiveSec = "1min";
      OnUnitInactiveSec = "5min";
      AccuracySec = "30s";
      Unit = "scramble-public-sync.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  systemd.user.services.scramble-public-mount = {
    Unit = {
      Description = "Read-only view of the existing Scramble cloud files";
      Wants = [ "network-online.target" backend ];
      After = [ "network-online.target" backend ];
      ConditionPathExists = "${home}/.config/rclone/rclone.conf";
    };
    Service = {
      Type = "notify";
      Environment = [ "RCLONE_CONFIG=${home}/.config/rclone/rclone.conf" ];
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p '${publicMounted}'";
      ExecStart = "${rclone} mount scramble_drive: '${publicMounted}' --webdav-encoding=Colon --read-only --vfs-cache-mode=off --umask=077 --poll-interval=0 --dir-cache-time=30s";
      ExecStop = "/run/wrappers/bin/fusermount3 -u '${publicMounted}'";
      Restart = "on-failure";
      RestartSec = 10;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.scramble-webdav = lib.mkIf cliHost {
    Unit = {
      Description = "Scramble Cloud local WebDAV server";
      Wants = [ "network-online.target" ];
      After = [ "network-online.target" ];
      ConditionPathExists = "${home}/.config/scramble-webdav.env";
    };
    Service = {
      Type = "simple";
      EnvironmentFile = "${home}/.config/scramble-webdav.env";
      Environment = [ "PATH=${lib.makeBinPath [ pkgs.nodejs pkgs.coreutils ]}:/run/current-system/sw/bin" ];
      ExecStart = "${home}/.local/share/scramble-cli/node_modules/.bin/scramble-cli webdav --host 127.0.0.1 --port 1900 --username scramble";
      Restart = "on-failure";
      RestartSec = 10;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
