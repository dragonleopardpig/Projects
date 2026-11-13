{ inputs, pkgs, lib, ... }:
{
  environment.systemPackages = [
    inputs.hyprfm.packages.${pkgs.stdenv.hostPlatform.system}.default
    pkgs.gvfs
    pkgs.exiftool
    pkgs.ntfs3g
    pkgs.usbmuxd
    pkgs.libimobiledevice
  ];
  services.gvfs.enable = lib.mkDefault true;
  services.udisks2.enable = lib.mkDefault true;
  services.usbmuxd.enable = lib.mkDefault true;
}
