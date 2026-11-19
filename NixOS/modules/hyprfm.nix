{ inputs, pkgs, lib, ... }:
{
  # hyprfm's overlay builds pkgs.hyprfm against this system's nixpkgs, so it
  # shares the desktop's Qt. Its built-in terminal needs zig_0_17 at build
  # time; while our nixpkgs lacks it the overlay takes zig from hyprfm's own
  # nixpkgs pin (flake.nix: no follows), and the terminal is built in.
  nixpkgs.overlays = [ inputs.hyprfm.overlays.default ];

  environment.systemPackages = [
    pkgs.hyprfm
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
