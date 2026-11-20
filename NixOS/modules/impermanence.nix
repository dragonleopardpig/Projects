# Opt-in "erase your darlings": the btrfs root subvolume is replaced with an
# empty one on every boot, and only what is listed here survives.
#
# Imported by every host through flake.nix but inert until a host sets
# `custom.impermanence.enable = true;` (PortableSSD; CRUCIAL-SSD once migrated,
# see hosts/Crucial-SSD/MIGRATE.md).
#
# Expected btrfs layout (see hosts/PortableSSD/disko.nix):
#   @root        -> /               wiped every boot (old copies kept in old_roots/)
#   @nix         -> /nix            kept
#   @persist     -> /persist        kept; system state bind-mounted from here
#   @home        -> /home           kept (whole /home survives; tighten later if wanted)
#   @tmp         -> /tmp            deleted outright every boot (tmpSubvolume)
#   @dev-scratch -> /var/cache/dev  deleted outright every boot (cleanDevArtifacts)
# The initrd creates @tmp and @dev-scratch itself, so they need no disko entry.
#
# On every host (enabled or not) a pre-switch check refuses to switch/boot into
# a configuration whose impermanence setting does not match the running root,
# so a plain `nixos-rebuild switch` cannot lock passwords or break boot while a
# host is being migrated.  Override with NIXOS_NO_CHECK=1.
#
# Before the first boot the password hashes MUST exist, or nobody can log in:
#   sudo mkdir -p /mnt/persist/passwords
#   mkpasswd -m yescrypt | sudo tee /mnt/persist/passwords/thinky
#   sudo cp /mnt/persist/passwords/thinky /mnt/persist/passwords/root
#   sudo chmod 600 /mnt/persist/passwords/*
{ config, lib, pkgs, utils, ... }:
let
  cfg = config.custom.impermanence;
  deviceUnit = "${utils.escapeSystemdPath cfg.device}.device";
  targetGroup = config.users.users.${cfg.devTargetUser}.group or "users";
  targetHome = config.users.users.${cfg.devTargetUser}.home or "/home/${cfg.devTargetUser}";
  userScratch = "${cfg.devScratchDir}/${cfg.devTargetUser}";
  scratchSubdirs = [
    "cargo-build"
    "cargo-home"
    "bun"
    "direnv"
    "pycache"
    "uv"
    "pip"
    "npm"
    "ruff"
    "mypy"
    "ccache"
    "gradle"
    "go"
    "go/pkg"
    "go/pkg/mod"
    "go/build"
  ];
  cleanDevChecked = pkgs.runCommand "impermanence-clean-dev-checked" {
    nativeBuildInputs = [ pkgs.python3 ];
  } ''
    python3 ${../tests/test-impermanence-clean-dev.py} ${./impermanence-clean-dev.py}
    touch $out
  '';
  cleanDevScript = pkgs.writeShellApplication {
    name = "clean-dev-cache";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      test -e ${cleanDevChecked}
      exec python3 ${./impermanence-clean-dev.py} \
        --home-dir ${lib.escapeShellArg targetHome} \
        --projects-dir ${lib.escapeShellArg cfg.devProjectsDir} \
        ${lib.optionalString (!cfg.cleanDevEnvironments) "--keep-environments"} \
        "$@"
    '';
  };

  # Runs before every switch-to-configuration (switch, boot, test, check).
  # $2 is the action.  The wanted state is baked in from this configuration.
  layoutGuard = ''
    action="''${2-}"
    if [ "$action" = dry-activate ]; then
      exit 0
    fi
    root_fs=$(${pkgs.util-linux}/bin/findmnt -no FSTYPE / 2>/dev/null || true)
    root_opts=$(${pkgs.util-linux}/bin/findmnt -no OPTIONS / 2>/dev/null || true)
    running=no
    if [ "$root_fs" = btrfs ]; then
      case ",$root_opts," in
        *,subvol=/@root,*) running=yes ;;
      esac
    fi
    want=${if cfg.enable then "yes" else "no"}
    if [ "$running" != "$want" ]; then
      echo "impermanence-layout: refusing '$action'."
      if [ "$want" = yes ]; then
        echo "  This configuration wipes / on every boot (btrfs subvol=@root), but the"
        echo "  running root is $root_fs ($root_opts)."
        echo "  Switching would lock the passwords (/persist/passwords) and the next boot"
        echo "  would not find its root.  Migrate the disk first (hosts/Crucial-SSD/MIGRATE.md)."
      else
        echo "  The running root is the impermanent btrfs subvol=@root, but this"
        echo "  configuration expects a plain root; booting it would not find /."
      fi
      echo "  To override (you know the disk already matches): NIXOS_NO_CHECK=1"
      exit 1
    fi
  '';
in
{
  options.custom.impermanence = {
    enable = lib.mkEnableOption "wiping the btrfs root subvolume on every boot";

    device = lib.mkOption {
      type = lib.types.str;
      default = "/dev/mapper/cryptroot";
      description = "Block device holding the btrfs filesystem with the @root subvolume.";
    };

    persistDir = lib.mkOption {
      type = lib.types.str;
      default = "/persist";
      description = "Mount point of the subvolume that keeps state across boots.";
    };

    keepOldRootsDays = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 14;
      description = ''
        Wiped roots are moved to old_roots/ on the top-level subvolume instead of
        being deleted at once, so a forgotten file can still be recovered.  They
        are deleted after this many days.
      '';
    };

    tmpSubvolume = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Mount /tmp from a separate @tmp subvolume that the initrd deletes and
        recreates outright on every boot.  Otherwise /tmp lives on @root and a
        wiped root keeps its /tmp in old_roots/ for keepOldRootsDays.  While
        running, systemd's own tmp.conf still ages /tmp files out after 10 days.
      '';
    };

    cleanDevEnvironments = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        With cleanDevArtifacts, also remove dependency environments
        (.devenv, .direnv, .venv/venv, node_modules) under devProjectsDir on
        every boot.  Set false where they are costly to rebuild: then only
        stale .devenv/shell-*.sh scripts are pruned, and direnv layouts stay
        in the project instead of the wiped scratch volume.
      '';
    };

    cleanDevArtifacts = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Redirect regenerable dev/build caches onto an immediately-wiped
        @dev-scratch subvolume and scrub non-source build/environment artifacts
        under devProjectsDir and user caches on every boot.
      '';
    };

    devScratchDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/cache/dev";
      description = "Mount point for the immediately-wiped @dev-scratch btrfs subvolume.";
    };

    devTargetUser = lib.mkOption {
      type = lib.types.str;
      default = "thinky";
      description = "User whose Projects/ and home tool caches are scrubbed on boot.";
    };

    devProjectsDir = lib.mkOption {
      type = lib.types.str;
      default = "/home/thinky/Projects";
      description = "Projects directory scrubbed on boot for regenerable build/env artifacts.";
    };
  };

  config = lib.mkMerge [
  { system.preSwitchChecks.impermanence-layout = layoutGuard; }

  (lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.boot.initrd.systemd.enable;
        message = "custom.impermanence needs boot.initrd.systemd.enable = true.";
      }
      {
        assertion = (config.fileSystems."/".fsType or null) == "btrfs";
        message = "custom.impermanence needs / on btrfs (subvol=@root).";
      }
    ];

    boot.supportedFilesystems = [ "btrfs" ];

    # Runs in the initrd after LUKS is unlocked and before / is mounted.
    boot.initrd.systemd.services.rollback-root = {
      description = "Replace btrfs @root with an empty subvolume";
      wantedBy = [ "initrd.target" ];
      requires = [ deviceUnit ];
      after = [ deviceUnit ];
      before = [ "sysroot.mount" ];
      unitConfig.DefaultDependencies = "no";
      serviceConfig.Type = "oneshot";
      script = ''
        set -eu
        mkdir -p /btrfs_tmp
        mount -t btrfs -o subvol=/ ${cfg.device} /btrfs_tmp

        if [ -e /btrfs_tmp/@root ]; then
          mkdir -p /btrfs_tmp/old_roots
          stamp=$(date --date="@$(stat -c %Y /btrfs_tmp/@root)" "+%Y-%m-%d_%H-%M-%S")
          # Two boots within the same second would collide.
          [ -e "/btrfs_tmp/old_roots/$stamp" ] && stamp="$stamp-$$"
          mv /btrfs_tmp/@root "/btrfs_tmp/old_roots/$stamp"
        fi

        # Nested subvolumes (e.g. created by podman or systemd-machined)
        # must be removed before their parent.
        delete_subvolume_recursively() {
          local IFS=$'\n'
          for sub in $(btrfs subvolume list -o "$1" | cut -f 9- -d ' '); do
            delete_subvolume_recursively "/btrfs_tmp/$sub"
          done
          btrfs subvolume delete "$1"
        }

        now=$(date +%s)
        for old in /btrfs_tmp/old_roots/*; do
          [ -e "$old" ] || continue
          age=$(( now - $(stat -c %Y "$old") ))
          if [ "$age" -gt ${toString (cfg.keepOldRootsDays * 86400)} ]; then
            delete_subvolume_recursively "$old" || true
          fi
        done

        btrfs subvolume create /btrfs_tmp/@root
        ${lib.optionalString cfg.tmpSubvolume ''
          if [ -e /btrfs_tmp/@tmp ]; then
            delete_subvolume_recursively /btrfs_tmp/@tmp
          fi
          btrfs subvolume create /btrfs_tmp/@tmp
          chmod 1777 /btrfs_tmp/@tmp
        ''}
        ${lib.optionalString cfg.cleanDevArtifacts ''
          if [ -e /btrfs_tmp/@dev-scratch ]; then
            delete_subvolume_recursively /btrfs_tmp/@dev-scratch
          fi
          btrfs subvolume create /btrfs_tmp/@dev-scratch
        ''}
        umount /btrfs_tmp
      '';
    };

    fileSystems.${cfg.persistDir}.neededForBoot = true;
    # Mount @home in initrd too so initrd user activation hits @home
    # instead of creating an empty /home/thinky on @root and overmounting later.
    fileSystems."/home".neededForBoot = true;

    fileSystems."/tmp" = lib.mkIf cfg.tmpSubvolume {
      device = cfg.device;
      fsType = "btrfs";
      options = [ "subvol=@tmp" "compress=zstd" "noatime" ];
    };

    fileSystems.${cfg.devScratchDir} = lib.mkIf cfg.cleanDevArtifacts {
      device = cfg.device;
      fsType = "btrfs";
      options = [ "subvol=@dev-scratch" "compress=zstd" "noatime" ];
    };

    systemd.tmpfiles.rules = lib.mkIf cfg.cleanDevArtifacts (
      [
        "d ${cfg.devScratchDir} 0755 root root -"
        "d ${userScratch} 0700 ${cfg.devTargetUser} ${targetGroup} -"
      ]
      ++ map (sub: "d ${userScratch}/${sub} 0700 ${cfg.devTargetUser} ${targetGroup} -") scratchSubdirs
    );

    environment.sessionVariables = lib.mkIf cfg.cleanDevArtifacts {
      # Not CARGO_TARGET_DIR: a shared target dir breaks scripts that expect
      # ./target/release/<bin> (strata, spacedrive) and makes concurrent builds
      # of different projects lock and evict each other.  build-dir (cargo
      # >= 1.91) moves only the bulky intermediates, one dir per workspace;
      # final binaries stay in ./target (removed at boot by the sweep).
      CARGO_BUILD_BUILD_DIR = "${userScratch}/cargo-build/{workspace-path-hash}";
      CARGO_HOME = "${userScratch}/cargo-home";
      BUN_INSTALL_CACHE_DIR = "${userScratch}/bun";
      PYTHONPYCACHEPREFIX = "${userScratch}/pycache";
      UV_CACHE_DIR = "${userScratch}/uv";
      PIP_CACHE_DIR = "${userScratch}/pip";
      NPM_CONFIG_CACHE = "${userScratch}/npm";
      RUFF_CACHE_DIR = "${userScratch}/ruff";
      MYPY_CACHE_DIR = "${userScratch}/mypy";
      CCACHE_DIR = "${userScratch}/ccache";
      GRADLE_USER_HOME = "${userScratch}/gradle";
      GOMODCACHE = "${userScratch}/go/pkg/mod";
      GOCACHE = "${userScratch}/go/build";
    };

    environment.systemPackages = lib.mkIf cfg.cleanDevArtifacts [ cleanDevScript ];
    system.extraDependencies = lib.mkIf cfg.cleanDevArtifacts [ cleanDevChecked ];

    # ONCE PER BOOT, never in a running session: as a plain oneshot it went back to
    # inactive after the boot run, and every `nixos-rebuild switch` started it again
    # (11-20 on CRUCIAL-SSD: 07:53, 09:03, 09:25 -- a fresh hyprfm build/ and the
    # caches went with it).  It now stays active once run, a switch never restarts
    # it, and a stamp in /run (gone at the next boot) skips any later start, even
    # after a failed run.
    systemd.services.impermanence-clean-dev = lib.mkIf cfg.cleanDevArtifacts {
      description = "Wipe regenerable development artifacts before user login";
      wantedBy = [ "multi-user.target" ];
      restartIfChanged = false;
      unitConfig.ConditionPathExists = "!/run/impermanence-clean-dev.done";
      requires = [ "home.mount" ];
      after = [ "home.mount" "local-fs.target" ];
      before = [
        "systemd-user-sessions.service"
        "home-manager-${cfg.devTargetUser}.service"
        "multi-user.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.devTargetUser;
        Group = targetGroup;
        # ("+": as root, outside the sandbox below)
        ExecStartPre = "+${pkgs.coreutils}/bin/touch /run/impermanence-clean-dev.done";
        ExecStart = "${lib.getExe cleanDevScript} --verbose";
        ProtectSystem = "strict";
        ReadWritePaths = [ "-${targetHome}" "-${cfg.devProjectsDir}" ];
        NoNewPrivileges = true;
      };
    };

    # Trash is user data, so it is never emptied at boot; items trashed more
    # than 30 days ago go daily.  trash-empty reads each item's DeletionDate,
    # unlike a tmpfiles age rule, which would purge old files inside a
    # directory trashed today.
    systemd.user.services.trash-age = lib.mkIf cfg.cleanDevArtifacts {
      description = "Remove items trashed more than 30 days ago";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.trash-cli}/bin/trash-empty -f 30";
      };
    };
    systemd.user.timers.trash-age = lib.mkIf cfg.cleanDevArtifacts {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };

    # /etc/shadow is wiped, so passwords must come from the persisted hashes.
    users.mutableUsers = false;
    users.users.thinky.hashedPasswordFile = "${cfg.persistDir}/passwords/thinky";
    users.users.root.hashedPasswordFile = "${cfg.persistDir}/passwords/root";

    environment.persistence.${cfg.persistDir} = {
      hideMounts = true;
      directories = [
        "/var/log"
        "/var/lib/nixos" # uid/gid allocations; losing it reshuffles ids
        "/var/lib/systemd/coredump"
        "/var/lib/systemd/timers"
        "/var/lib/systemd/backlight"
        "/var/lib/systemd/rfkill"
        "/var/lib/bluetooth"
        "/var/lib/NetworkManager"
        "/etc/NetworkManager/system-connections"
        "/var/lib/AccountsService"
        "/var/lib/always-on"
        "/var/lib/cups"
        "/var/lib/upower"
        "/var/lib/power-profiles-daemon"
        "/var/lib/udisks2"
        "/var/lib/containers"
        { directory = "/var/lib/private"; mode = "0700"; }
      ]
      ++ lib.optional config.services.displayManager.sddm.enable {
        directory = "/var/lib/sddm";
        user = "sddm";
        group = "sddm";
        mode = "0750";
      }
      ++ lib.optional (config.desktop.noctaliaSuite.greeter.enable or false) {
        directory = "/var/lib/noctalia-greeter";
        user = "greeter";
        group = "greeter";
        mode = "0750";
      }
      ++ lib.optional config.services.usbmuxd.enable "/var/lib/lockdown";
      files = [ "/etc/machine-id" ]
        ++ lib.optionals config.services.openssh.enable [
          "/etc/ssh/ssh_host_ed25519_key"
          "/etc/ssh/ssh_host_ed25519_key.pub"
          "/etc/ssh/ssh_host_rsa_key"
          "/etc/ssh/ssh_host_rsa_key.pub"
        ];
    };

    # sudo would otherwise show its lecture after every reboot.
    security.sudo.extraConfig = "Defaults lecture = never";
  })
  ];
}
