# M90aPro Laptop - Host-specific configuration
{ lib, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./layouts.nix
    ./backup.nix
    ./nvidia-prime.nix
  ];

  # Noctalia Suite desktop (Shell, Umbriel, Greeter + Strata), as on CRUCIAL-SSD.
  desktop.noctaliaSuite.greeter.enable = true;

  networking.hostName = "M90aPro";

  # Quiet splash boot.  This lives per-host rather than in configuration.nix so
  # that portable images can stay verbose (see hosts/universal-boot.nix).
  boot.kernelParams = [ "quiet" "splash" "rd.systemd.show_status=auto" ];

  # Swap (the /swapfile on ext4, a partition on btrfs) is in layouts.nix.

  # X299-SSD is migrated from here (hosts/X299-SSD/MIGRATE.md); drop this after its
  # `release-stage`.
  environment.systemPackages = [ (pkgs.callPackage ../../packages/x299-btrfs-migrate.nix { }) ];

  # The pool has no second copy of its data (pool.nix): warn on the desktop as
  # soon as an SSD's SMART health turns bad, while its files can still be read.
  services.smartd = {
    enable = true;
    notifications.systembus-notify.enable = true;
  };
}
