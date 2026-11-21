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
    # The same NVIDIA setup as CRUCIAL-SSD, so F7's display modes and the
    # NVIDIA-first GPU choice for external screens work here too: on the
    # Predator (RTX 5070 Ti) and the Lenovo (RTX 4050) HDMI is wired to the
    # dGPU, which nouveau cannot drive properly.  No PCI bus IDs (unlike
    # M90aPro's nvidia-prime.nix); on machines without NVIDIA it never binds.
    ../X299-SSD/nvidia.nix
  ];

  # Noctalia Greeter in place of SDDM (defaults to Noctalia Suite, keeping
  # Hyprland available), matching M90aPro and CRUCIAL-SSD.
  desktop.noctaliaSuite.greeter.enable = true;

  networking.hostName = "PortableSSD";

  # Wipe / on every boot; see modules/impermanence.nix for what survives.
  custom.impermanence.enable = true;

  # PortableSSD is the rescue system for migrating CRUCIAL-SSD and M90aPro to
  # the same layout (hosts/Crucial-SSD/MIGRATE.md, hosts/M90aPro/MIGRATE.md).
  environment.systemPackages = [
    (pkgs.callPackage ../../packages/crucial-btrfs-migrate.nix { })
    (pkgs.callPackage ../../packages/m90-btrfs-migrate.nix { })
  ];
}
