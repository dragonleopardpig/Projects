# Portable SSD - boots on any x86_64 UEFI machine
#
# Machine-specific filesystem UUIDs remain in hardware-configuration.nix;
# reusable portability settings live in ../universal-boot.nix.
{ pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ../universal-boot.nix
  ];

  # Noctalia Greeter in place of SDDM (defaults to Noctalia Suite, keeping
  # Hyprland available), matching M90aPro and CRUCIAL-SSD.
  desktop.noctaliaSuite.greeter.enable = true;

  networking.hostName = "PortableSSD";

  # Wipe / on every boot; see modules/impermanence.nix for what survives.
  custom.impermanence.enable = true;

  # PortableSSD is the rescue system for migrating CRUCIAL-SSD to the same
  # layout (hosts/Crucial-SSD/MIGRATE.md).
  environment.systemPackages = [ (pkgs.callPackage ../../packages/crucial-btrfs-migrate.nix { }) ];
}
