# Portable SSD - boots on any x86_64 UEFI machine
#
# Machine-specific filesystem UUIDs remain in hardware-configuration.nix;
# reusable portability settings live in ../universal-boot.nix.
{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../universal-boot.nix
  ];

  networking.hostName = "PortableSSD";
}
