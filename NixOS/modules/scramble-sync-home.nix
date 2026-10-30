{ config, lib, osConfig ? null, pkgs, scrambleHostName ? null, ... }:
let
  home = config.home.homeDirectory;
  ready = "${home}/.config/rclone/scramble-private-v2-ready";
  cloudMounted = "${home}/Scramble Cloud";
  rclone = "${pkgs.rclone}/bin/rclone";
  syncScript = pkgs.writeShellScript "scramble-private-sync" (
    builtins.replaceStrings [ "@RCLONE@" ] [ rclone ]
      (builtins.readFile ../scripts/scramble-private-sync)
  );
  consolidateScript = pkgs.writeShellScript "scramble-consolidate" ''
    export PATH="${lib.makeBinPath [ pkgs.coreutils pkgs.systemd pkgs.rclone ]}:$PATH"
    unset LD_LIBRARY_PATH LD_PRELOAD
    exec ${pkgs.python3}/bin/python3 ${../scripts/scramble-consolidate.py} "$@"
  '';
  hostName = if osConfig != null then osConfig.networking.hostName else scrambleHostName;
  cliHost = hostName != "M90aPro";
  backend = if cliHost then "scramble-webdav.service" else "scramble-desktop.service";
  scrambleDesktop =
    let
      pname = "scramble-desktop";
      version = "1.0.42";
      src = pkgs.fetchurl {
        urls = [
          "https://electron-auto-update.s3.de.io.cloud.ovh.net/Scramble_linux_x86_64.AppImage?versionId=1793133317.866797"
          "https://electron-auto-update.s3.de.io.cloud.ovh.net/Scramble_linux_x86_64.AppImage"
        ];
        name = "Scramble-${version}-x86_64.AppImage";
        hash = "sha512-aQuicNwWWaXCxA8aHMqp7o3Z/x7FD+lZ7RGVG37h69ZMhyu6YpAMCGSKhOe31VszOhL+Sf6TfybVcAWamJDNyw==";
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
          ${pkgs.nodejs}/bin/node --check "$TMPDIR/scramble-app/electron/main.js"
          ${pkgs.nodejs}/bin/node --check "$TMPDIR/scramble-app/electron/window.js"
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
        mkdir -p $out/nix-support
        ln -s ${src} $out/nix-support/upstream-installer.AppImage
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
        (lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep pkgs.systemd pkgs.util-linux pkgs.libnotify pkgs.xdg-utils pkgs.kitty pkgs.python3 pkgs.rclone ]) ]
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
  home.file.".local/bin/scramble-consolidate" = {
    source = consolidateScript;
    executable = true;
  };
  home.file.".local/bin/scramble-transfer-crypt" = {
    source = ../scripts/scramble-transfer-crypt;
    executable = true;
  };
  home.file.".local/bin/scramble-sync-status" = {
    source = ../scripts/scramble-sync-status;
    executable = true;
    force = true;
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
    retired = {
        (home / path).as_uri() for path in [
            'Documents/Scramble Public', 'Documents/Scramble Sync',
            'Documents/Scramble References', 'Scramble Public', 'Scramble Private',
        ]
    }
    content = bookmarks.read_text() if bookmarks.exists() else ""
    lines = [line for line in content.splitlines() if not line.split() or line.split()[0] not in retired]
    lines.append((home / 'Scramble Private').as_uri() + ' Scramble Private')
    bookmarks.parent.mkdir(parents=True, exist_ok=True)
    bookmarks.write_text('\n'.join(lines) + '\n')
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
      TimeoutStartSec = "infinity";
    };
  };

  systemd.user.services.scramble-cloud-mount = {
    Unit = {
      Description = "Read-only view of the Scramble cloud account";
      Wants = [ "network-online.target" backend ];
      After = [ "graphical-session.target" "network-online.target" backend ];
      PartOf = [ "graphical-session.target" ];
      ConditionPathExists = "${home}/.config/rclone/rclone.conf";
    };
    Service = {
      Type = "notify";
      Environment = [ "RCLONE_CONFIG=${home}/.config/rclone/rclone.conf" ];
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p -m 700 '${cloudMounted}'";
      ExecStart = "${rclone} mount scramble_drive: '${cloudMounted}' --devname='Scramble Cloud' --webdav-encoding=Colon --read-only --vfs-cache-mode=off --umask=077 --poll-interval=0 --dir-cache-time=15s --contimeout=10s --timeout=1m";
      ExecStop = "/run/wrappers/bin/fusermount3 -u '${cloudMounted}'";
      TimeoutStopSec = "30s";
      Restart = "on-failure";
      RestartSec = 10;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.scramble-desktop = {
    Unit = {
      Description = "Scramble Desktop with tray controls";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      Wants = [ "scramble-session.service" ];
    };
    Service = {
      Type = "notify";
      NotifyAccess = "all";
      ExecStart = "${scrambleDesktop}/bin/scramble-desktop --start-in-tray";
      TimeoutStartSec = "60s";
      Restart = "on-failure";
      RestartSec = 10;
    };
    Install.WantedBy = [ "graphical-session.target" ];
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
    Unit = {
      Description = "Check the single encrypted Scramble folder every five minutes";
      ConditionPathExists = ready;
    };
    Timer = {
      OnActiveSec = "1min";
      OnUnitInactiveSec = "5min";
      AccuracySec = "30s";
      Unit = "scramble-private-sync.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  systemd.user.services.scramble-consolidate = {
    Unit = {
      Description = "Safely consolidate all Scramble files into the encrypted private folder";
      Wants = [ "network-online.target" backend ];
      After = [ "network-online.target" backend ];
      PartOf = [ "graphical-session.target" ];
      ConditionPathExists = "${home}/.config/rclone/rclone.conf";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${consolidateScript}";
      TimeoutStartSec = "infinity";
      TimeoutStopSec = "90s";
      KillSignal = "SIGINT";
      Restart = "on-failure";
      RestartSec = "60s";
    };
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
