# Portable SSD - boots on any x86_64 UEFI machine
{ config, lib, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "PortableSSD";

  # Portable UEFI: don't touch host firmware, install to fallback EFI path
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  boot.loader.grub.efiInstallAsRemovable = true;

  # Remove NVIDIA from initrd — not every machine has it
  boot.initrd.kernelModules = lib.mkForce [];
  boot.extraModulePackages = lib.mkForce [];
  boot.kernelParams = lib.mkForce [
    "quiet"
    "splash"
    "boot.shell_on_fail"
    "udev.log_priority=3"
    "rd.systemd.show_status=auto"
    "systemd.swap=0"
  ];

  # Disable plymouth on unknown hardware (GPU drivers may vary)
  boot.plymouth.enable = lib.mkForce false;
}
