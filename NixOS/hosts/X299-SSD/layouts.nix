# Root filesystem layouts for X299-SSD (the same as hosts/Crucial-SSD/layouts.nix).
#
#   btrfs -- after hosts/X299-SSD/MIGRATE.md: btrfs subvolumes inside the LUKS
#            container, / wiped on every boot (modules/impermanence.nix), dev
#            artifacts AND dependency environments cleaned (this disk is a spare
#            and the Projects mirror; nothing on it needs a warm devenv).
#   ext4  -- the layout before it: ext4 inside LUKS, everything persists.  Only
#            for a rollback (MIGRATE.md) until the staging image is released.
#
# The migration also gives the disk CRUCIAL-SSD's partition style: p1 EFI,
# p2 LUKS root, p3 DATA, p4 Virtual Windows (WinApps).  The LUKS UUID and the
# ESP's volume id stay, so the devices below hold for both layouts.
#
# If this setting ever disagrees with the running disk, the impermanence
# pre-switch check refuses the switch.
#
# No disko here on purpose: this disk also holds DATA and the WinApps
# partition; a disko spec run by mistake would erase them.
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
  options.custom.x299Layout = lib.mkOption {
    type = lib.types.enum [ "ext4" "btrfs" ];
    default = "ext4";
    description = "Root filesystem layout of the X299-SSD disk (see hosts/X299-SSD/MIGRATE.md).";
  };

  config = lib.mkMerge [
    (lib.mkIf (config.custom.x299Layout == "ext4") {
      fileSystems."/" = {
        device = luksRoot;
        fsType = "ext4";
      };
      swapDevices = [ { device = "/var/lib/swapfile"; size = 16384; } ];
    })

    (lib.mkIf (config.custom.x299Layout == "btrfs") {
      fileSystems."/" = subvol "@root" btrfsOpts;
      fileSystems."/nix" = subvol "@nix" btrfsOpts;
      fileSystems."/persist" = subvol "@persist" btrfsOpts;
      fileSystems."/home" = subvol "@home" btrfsOpts;
      # No compression: the swap module makes the file with
      # `btrfs filesystem mkswapfile` (NOCOW), which swap on btrfs requires.
      fileSystems."/swap" = subvol "@swap" [ "noatime" ];
      swapDevices = [ { device = "/swap/swapfile"; size = 16384; } ];

      custom.impermanence.enable = true;
    })
  ];
}
