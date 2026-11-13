{ inputs, pkgs, lib, ... }:
{
  environment.systemPackages = [
    inputs.hyprfm.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
  services.gvfs.enable = lib.mkDefault true;
  services.udisks2.enable = lib.mkDefault true;
}
