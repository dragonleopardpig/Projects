# Disko config for PortableSSD.
#
# Imported by default.nix, so it also generates the fileSystems / LUKS entries
# (no UUIDs needed: disko addresses partitions by GPT label).
#
# Formatting ERASES THE WHOLE DISK.  Check the device first and pass it on the
# command line rather than trusting the default below:
#   lsblk -o NAME,SIZE,MODEL,TRAN
#   sudo nix run github:nix-community/disko -- --mode destroy,format,mount \
#     --argstr device /dev/disk/by-id/usb-XXXX ./hosts/PortableSSD/disko.nix
# See INSTALL.md for the full procedure.
{ lib, device ? "/dev/sdc", ... }:
let
  btrfsOpts = [ "compress=zstd" "noatime" ];
in
{
  disko.devices.disk.portable = {
    type = "disk";
    device = lib.mkDefault device;
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "10G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "fmask=0077" "dmask=0077" ];
          };
        };
        root = {
          size = "90G";
          content = {
            type = "luks";
            name = "cryptroot";
            settings.allowDiscards = true;
            passwordFile = "/tmp/luks-password";
            content = {
              type = "btrfs";
              extraArgs = [ "-f" "-L" "nixos" ];
              # @root is replaced on every boot by modules/impermanence.nix.
              subvolumes = {
                "@root" = { mountpoint = "/"; mountOptions = btrfsOpts; };
                "@nix" = { mountpoint = "/nix"; mountOptions = btrfsOpts; };
                "@persist" = { mountpoint = "/persist"; mountOptions = btrfsOpts; };
                "@home" = { mountpoint = "/home"; mountOptions = btrfsOpts; };
              };
            };
          };
        };
        data = {
          size = "100%";
          # Microsoft basic data; without this disko defaults to "Linux
          # filesystem", which Windows ignores (won't assign a drive letter).
          type = "0700";
          content = {
            type = "filesystem";
            format = "vfat";
          };
        };
      };
    };
  };
}
