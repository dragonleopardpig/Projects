# M90aPro Laptop - Host-specific configuration
{ lib, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./nvidia-prime.nix
  ];

  networking.hostName = "M90aPro";

  # Quiet splash boot.  This lives per-host rather than in configuration.nix so
  # that portable images can stay verbose (see hosts/universal-boot.nix).
  boot.kernelParams = [ "quiet" "splash" "rd.systemd.show_status=auto" ];


  # Enable swap on laptop to avoid OOM during rebuilds
  swapDevices = lib.mkForce [
    { device = "/swapfile"; size = 16384; }
  ];
}
