# Opt-in "erase your darlings": the btrfs root subvolume is replaced with an
# empty one on every boot, and only what is listed here survives.
#
# Imported by every host through flake.nix but inert until a host sets
# `custom.impermanence.enable = true;` (PortableSSD only, for now).
#
# Expected btrfs layout (see hosts/PortableSSD/disko.nix):
#   @root    -> /         wiped every boot (old copies kept in old_roots/)
#   @nix     -> /nix      kept
#   @persist -> /persist  kept; system state bind-mounted from here
#   @home    -> /home     kept (whole /home survives; tighten later if wanted)
#
# Before the first boot the password hashes MUST exist, or nobody can log in:
#   sudo mkdir -p /mnt/persist/passwords
#   mkpasswd -m yescrypt | sudo tee /mnt/persist/passwords/thinky
#   sudo cp /mnt/persist/passwords/thinky /mnt/persist/passwords/root
#   sudo chmod 600 /mnt/persist/passwords/*
{ config, lib, utils, ... }:
let
  cfg = config.custom.impermanence;
  deviceUnit = "${utils.escapeSystemdPath cfg.device}.device";
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
  };

  config = lib.mkIf cfg.enable {
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
        umount /btrfs_tmp
      '';
    };

    fileSystems.${cfg.persistDir}.neededForBoot = true;

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
        "/var/lib/sddm"
        "/var/lib/noctalia-greeter"
        "/var/lib/always-on"
        "/var/lib/cups"
        "/var/lib/upower"
        "/var/lib/power-profiles-daemon"
        "/var/lib/udisks2"
        "/var/lib/containers"
        { directory = "/var/lib/private"; mode = "0700"; }
      ];
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
  };
}
