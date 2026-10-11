{ config, lib, osConfig ? null, pkgs, scrambleHostName ? null, ... }:
let
  home = config.home.homeDirectory;
  ready = "${home}/.config/rclone/scramble-ready";
  mounted = "${home}/Scramble Private";
  rclone = "${pkgs.rclone}/bin/rclone";
  syncScript = pkgs.writeShellScript "scramble-private-sync" (
    builtins.replaceStrings [ "@RCLONE@" ] [ rclone ]
      (builtins.readFile ../scripts/scramble-private-sync)
  );
  hostName = if osConfig != null then osConfig.networking.hostName else scrambleHostName;
  cliHost = hostName != "M90aPro";
in
{
  # Credentials and the crypt keys stay in a mode-600 runtime rclone.conf,
  # outside the Nix store and this repository.
  home.packages = [ pkgs.rclone ] ++ lib.optionals cliHost [ pkgs.nodejs ];

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

  systemd.user.services.scramble-private-sync = {
    Unit = {
      Description = "Two-way sync of one encrypted Scramble folder";
      Wants = [ "network-online.target" (if cliHost then "scramble-webdav.service" else "scramble-desktop.service") ];
      After = [ "network-online.target" (if cliHost then "scramble-webdav.service" else "scramble-desktop.service") ];
      ConditionPathExists = ready;
    };
    Service = {
      Type = "oneshot";
      Environment = [ "RCLONE_CONFIG=${home}/.config/rclone/rclone.conf" ];
      ExecStart = "${syncScript}";
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
      Wants = [ "network-online.target" (if cliHost then "scramble-webdav.service" else "scramble-desktop.service") ];
      After = [ "network-online.target" (if cliHost then "scramble-webdav.service" else "scramble-desktop.service") ];
      ConditionPathExists = ready;
    };
    Service = {
      Type = "notify";
      Environment = [ "RCLONE_CONFIG=${home}/.config/rclone/rclone.conf" ];
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p '${mounted}'";
      ExecStart = "${rclone} mount scramble_private:Current '${mounted}' --read-only --vfs-cache-mode=off --umask=077 --poll-interval=0 --dir-cache-time=30s";
      ExecStop = "/run/wrappers/bin/fusermount3 -u '${mounted}'";
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
