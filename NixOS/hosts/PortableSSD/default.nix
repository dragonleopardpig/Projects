# Portable SSD - boots on any x86_64 UEFI machine
#
# Machine-specific filesystem UUIDs remain in hardware-configuration.nix;
# reusable portability settings live in ../universal-boot.nix.
{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ../universal-boot.nix
  ];

  networking.hostName = "PortableSSD";

  # Wipe / on every boot; see modules/impermanence.nix for what survives.
  custom.impermanence.enable = true;
}
