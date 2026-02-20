# X299 Desktop - Host-specific configuration
{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./nvidia.nix
  ];

  networking.hostName = "X299";
}