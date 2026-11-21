# M90aPro Laptop - Host-specific configuration
{ lib, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./layouts.nix
    ./nvidia-prime.nix
  ];

  # Noctalia Suite desktop (Shell, Umbriel, Greeter + Strata), as on CRUCIAL-SSD.
  desktop.noctaliaSuite.greeter.enable = true;

  networking.hostName = "M90aPro";

  # Quiet splash boot.  This lives per-host rather than in configuration.nix so
  # that portable images can stay verbose (see hosts/universal-boot.nix).
  boot.kernelParams = [ "quiet" "splash" "rd.systemd.show_status=auto" ];

  # Swap (the /swapfile on ext4, a partition on btrfs) is in layouts.nix.
}
