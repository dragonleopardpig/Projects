# Root filesystem layouts for CRUCIAL-SSD.
#
#   btrfs -- the disk since 2026-11-20 (MIGRATE.md): btrfs subvolumes inside
#            the LUKS container, / wiped on every boot (modules/impermanence.nix),
#            dev artifacts cleaned, dependency environments
#            (.devenv/.venv/node_modules) kept.
#   ext4  -- the layout before it: ext4 inside LUKS, everything persists.  Only
#            for a rollback (MIGRATE.md) until the staging image is released.
#
# If this setting ever disagrees with the running disk, the impermanence
# pre-switch check refuses the switch.
#
# No disko here on purpose: this disk also holds CRUCIALDATA (sda3) and the
# WinApps partition (sda4); a disko spec run by mistake would erase them.
{ config, lib, ... }:
let
  luksRoot = "/dev/mapper/cryptroot";
  btrfsOpts = [ "compress=zstd" "noatime" ];
  subvol = name: extra: {
    device = luksRoot;
    fsType = "btrfs";
    options = [ "subvol=${name}" ] ++ extra;
  };
in
{
  options.custom.crucialLayout = lib.mkOption {
    type = lib.types.enum [ "ext4" "btrfs" ];
    default = "btrfs";
    description = "Root filesystem layout of the CRUCIAL-SSD disk (see hosts/Crucial-SSD/MIGRATE.md).";
  };

  config = lib.mkMerge [
    (lib.mkIf (config.custom.crucialLayout == "ext4") {
      fileSystems."/" = {
        device = luksRoot;
        fsType = "ext4";
      };
      swapDevices = [ { device = "/var/lib/swapfile"; size = 16384; } ];
    })

    (lib.mkIf (config.custom.crucialLayout == "btrfs") {
      fileSystems."/" = subvol "@root" btrfsOpts;
      fileSystems."/nix" = subvol "@nix" btrfsOpts;
      fileSystems."/persist" = subvol "@persist" btrfsOpts;
      fileSystems."/home" = subvol "@home" btrfsOpts;
      # No compression: the swap module makes the file with
      # `btrfs filesystem mkswapfile` (NOCOW), which swap on btrfs requires.
      fileSystems."/swap" = subvol "@swap" [ "noatime" ];
      swapDevices = [ { device = "/swap/swapfile"; size = 16384; } ];

      custom.impermanence = {
        enable = true;
        # Kraken/trident gates need their devenv right after a reboot, and
        # trident's venv alone is 5.7G of wheels; these don't grow anyway.
        cleanDevEnvironments = false;
      };
    })
  ];
}
