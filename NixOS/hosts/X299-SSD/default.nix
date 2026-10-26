# The former X299 clone now uses the same hardware-neutral boot policy as the
# PortableSSD host.  Its own hardware-configuration.nix retains this Buffalo
# drive's LUKS and EFI UUIDs.
{ pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../universal-boot.nix
    ./nvidia.nix
    ../../modules/winapps.nix
  ];

  networking.hostName = "X299-SSD";

  fileSystems."/mnt/winapps" = {
    device = "/dev/disk/by-uuid/fe0516c1-a263-495f-b22d-ef205ead9203";
    fsType = "ext4";
    options = [ "nosuid" "nodev" "nofail" "x-systemd.device-timeout=10s" ];
  };

  systemd.services.winapps-storage = {
    description = "Prepare Windows VM storage";
    wantedBy = [ "multi-user.target" ];
    requires = [ "mnt-winapps.mount" ];
    after = [ "mnt-winapps.mount" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      test "$(${pkgs.util-linux}/bin/findmnt -n -o UUID --mountpoint /mnt/winapps)" = fe0516c1-a263-495f-b22d-ef205ead9203
      ${pkgs.coreutils}/bin/install -d -m 0700 -o thinky -g users /mnt/winapps/windows
    '';
  };

  swapDevices = [
    { device = "/var/lib/swapfile"; size = 16384; }
  ];
}
