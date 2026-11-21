# M90aPro system disk for the impermanent btrfs layout (hosts/M90aPro/MIGRATE.md).
#
# The disk is named by its serial on purpose: the three Samsung NVMe drives in
# this machine change /dev/nvmeXn1 numbers between boots (2026-11-20/21:
# nvme0n1 and nvme2n1 swapped), and one of them is Windows.
#
#   S7XLNE0Y733872  this disk: ESP + swap + LUKS "cryptpool" -> btrfs
#   S7XLNE0Y733865  the ext4 system until the migration; later the second pool
#                   member (hosts/M90aPro/pool.nix).  NOT declared here, so this
#                   file can never wipe it.
#   S7XLNE0Y733874  Windows.  Never touched.
#
# Swap is a partition with a fresh random key each boot: btrfs refuses a
# swapfile once the filesystem spans two devices.
#
# The mapper is "cryptpool", not "cryptroot": the migration runs from the
# PortableSSD, whose own root is already /dev/mapper/cryptroot.
{ lib, ... }:
let
  btrfsOpts = [ "compress=zstd" "noatime" ];
in
{
  disko.devices.disk.m90 = {
    type = "disk";
    device = lib.mkDefault "/dev/disk/by-id/nvme-SAMSUNG_MZVL8256HFJD-00BLL_S7XLNE0Y733872";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "fmask=0077" "dmask=0077" ];
          };
        };
        swap = {
          size = "16G";
          content = {
            type = "swap";
            randomEncryption = true;
          };
        };
        root = {
          size = "100%";
          content = {
            type = "luks";
            name = "cryptpool";
            settings.allowDiscards = true;
            # Written by `m90-btrfs-migrate format` (RAM only), removed after.
            passwordFile = "/dev/shm/m90-luks-key";
            content = {
              type = "btrfs";
              extraArgs = [ "-f" "-L" "nixos-m90" ];
              subvolumes = {
                "@root" = { mountpoint = "/"; mountOptions = btrfsOpts; };
                "@nix" = { mountpoint = "/nix"; mountOptions = btrfsOpts; };
                "@persist" = { mountpoint = "/persist"; mountOptions = btrfsOpts; };
                "@home" = { mountpoint = "/home"; mountOptions = btrfsOpts; };
              };
            };
          };
        };
      };
    };
  };
}
