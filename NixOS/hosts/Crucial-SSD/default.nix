# Crucial 1TB External SSD - identical to X299-SSD
# Uses hardware-neutral universal boot, NVIDIA support, and WinApps.
{ pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../universal-boot.nix
    ../X299-SSD/nvidia.nix
    ../../modules/winapps.nix
    ../../modules/strata.nix
  ];

  desktop.noctaliaSuite.greeter.enable = true;

  networking.hostName = "CRUCIAL-SSD";
  # Keep local references to the clone's former name resolving after renaming.
  networking.hosts."127.0.0.2" = [ "X299-SSD" ];

  fileSystems."/mnt/winapps" = {
    device = "/dev/disk/by-uuid/326619bb-8b95-4d83-825b-b21a6762f518";
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
      test "$(${pkgs.util-linux}/bin/findmnt -n -o UUID --mountpoint /mnt/winapps)" = 326619bb-8b95-4d83-825b-b21a6762f518
      ${pkgs.coreutils}/bin/install -d -m 0700 -o thinky -g users /mnt/winapps/windows
    '';
  };

  swapDevices = [
    { device = "/var/lib/swapfile"; size = 16384; }
  ];
}
