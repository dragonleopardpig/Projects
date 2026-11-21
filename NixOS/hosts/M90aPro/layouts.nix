# Root filesystem layouts for M90aPro (procedure: hosts/M90aPro/MIGRATE.md).
#
#   btrfs -- the default since 2026-11-21 (MIGRATE.md B0-B4): disko.nix on
#            S7XLNE0Y733872, / wiped on every boot (modules/impermanence.nix),
#            dev artifacts cleaned, dependency environments kept (as on
#            CRUCIAL-SSD).  Later the old disk is added as a second pool member
#            (pool.nix).
#   ext4  -- the system before the migration: ext4 inside LUKS on the Samsung
#            S7XLNE0Y733865, everything persists.  Kept untouched as the
#            fallback (firmware boot entry "NixOS-boot") until that disk joins
#            the pool (Part C).
#
# If this setting ever disagrees with the running disk, the impermanence
# pre-switch check refuses the switch.
{ config, lib, pkgs, ... }:
let
  layout = config.custom.m90Layout;
in
{
  imports = [
    ./disko.nix
    ./pool.nix
  ];

  options.custom.m90Layout = lib.mkOption {
    type = lib.types.enum [ "ext4" "btrfs" ];
    default = "btrfs";
    description = "Root filesystem layout of M90aPro (see hosts/M90aPro/MIGRATE.md).";
  };

  config = lib.mkMerge [
    {
      assertions = [{
        assertion = config.custom.m90Pool.secondDisk -> layout == "btrfs";
        message = "custom.m90Pool.secondDisk needs custom.m90Layout = \"btrfs\".";
      }];
    }

    (lib.mkIf (layout == "ext4") {
      # disko.nix describes the new disk only; nothing of it applies here.
      disko.enableConfig = false;
      fileSystems."/" = {
        device = "/dev/disk/by-uuid/a6606f8d-be76-44e3-9121-bb8c82acb6c9";
        fsType = "ext4";
      };
      fileSystems."/boot" = {
        device = "/dev/disk/by-uuid/6D0B-8E30";
        fsType = "vfat";
        options = [ "fmask=0077" "dmask=0077" ];
      };
      boot.initrd.luks.devices."luks-e4268bbb-c627-4904-b67f-8a76fe0cbf52".device =
        "/dev/disk/by-uuid/e4268bbb-c627-4904-b67f-8a76fe0cbf52";
      # Swap to avoid OOM during rebuilds.
      swapDevices = [ { device = "/swapfile"; size = 16384; } ];
    })

    (lib.mkIf (layout == "btrfs") {
      # fileSystems, the LUKS unlock and the swap partition come from disko.nix.
      # Where `m90-btrfs-migrate format` (disko's script) mounts the new disk.
      disko.rootMountPoint = "/mnt/m90/new";
      custom.impermanence = {
        enable = true;
        device = "/dev/mapper/cryptpool";
        # As on CRUCIAL-SSD: project shells ready right after a reboot.
        cleanDevEnvironments = false;
      };
      # Its own firmware entry: installing must not replace the old disk's
      # "NixOS-boot", the fallback until that disk joins the pool.  The id is
      # per mirroredBoots entry, so this restates nixpkgs' single /boot entry.
      boot.loader.grub.mirroredBoots = lib.mkForce [{
        path = "/boot";
        devices = [ "nodev" ];
        efiBootloaderId = "NixOS-pool";
      }];
      # For `extend-prepare` / `extend` (pool.nix), run on this system.
      environment.systemPackages = [ (pkgs.callPackage ../../packages/m90-btrfs-migrate.nix { }) ];
      # 2026-11-21: the old system disk S7XLNE0Y733865 is now the LUKS partition
      # m90-pool2 (extend-prepare); initrd unlocks it as the second pool member.
      custom.m90Pool.secondDisk = true;
    })
  ];
}
