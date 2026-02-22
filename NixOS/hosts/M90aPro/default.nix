# M90aPro Laptop - Host-specific configuration
{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./nvidia-prime.nix
  ];

  networking.hostName = "M90aPro";
}