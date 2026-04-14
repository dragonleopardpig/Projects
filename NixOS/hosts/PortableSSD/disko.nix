# Disko config for PortableSSD — used for initial partitioning only
# Run: sudo nix run github:nix-community/disko -- --mode disko ./hosts/PortableSSD/disko.nix
{
  disko.devices.disk.portable = {
    type = "disk";
    device = "/dev/sdc";
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
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
        data = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "vfat";
          };
        };
      };
    };
  };
}
