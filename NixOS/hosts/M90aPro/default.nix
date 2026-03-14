# M90aPro Laptop - Host-specific configuration
{ lib, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./nvidia-prime.nix
  ];

  networking.hostName = "M90aPro";

  # Enable swap on laptop to avoid OOM during rebuilds
  swapDevices = lib.mkForce [
    { device = "/swapfile"; size = 16384; }
  ];
}
