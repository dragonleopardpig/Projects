# M90aPro Laptop - Host-specific configuration
{ inputs, lib, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./nvidia-prime.nix
    ../../modules/strata.nix
    inputs.noctalia-suite.nixosModules.suite
  ];

  # Noctalia Suite desktop (Shell, Umbriel, Greeter + Strata), as on CRUCIAL-SSD.
  desktop.noctaliaSuite = {
    enable = true;
    greeter.enable = true;
  };
  home-manager.users.thinky.imports = [ inputs.noctalia-suite.homeManagerModules.suite ];

  networking.hostName = "M90aPro";

  # Quiet splash boot.  This lives per-host rather than in configuration.nix so
  # that portable images can stay verbose (see hosts/universal-boot.nix).
  boot.kernelParams = [ "quiet" "splash" "rd.systemd.show_status=auto" ];


  # Enable swap on laptop to avoid OOM during rebuilds
  swapDevices = lib.mkForce [
    { device = "/swapfile"; size = 16384; }
  ];
}
