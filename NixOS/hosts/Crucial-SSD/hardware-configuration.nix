# Hardware configuration for Crucial 1TB External SSD
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "xhci_pci" "ehci_pci" "ohci_pci" "ahci" "nvme" "uas" "sd_mod"
    "usb_storage" "usbhid" "sdhci_pci" "rtsx_pci_sdmmc"
    "thunderbolt" "mmc_block"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" "kvm-amd" ];
  boot.extraModulePackages = [ ];

  boot.initrd.luks.devices."cryptroot".device = "/dev/disk/by-uuid/77595ddf-4ac1-4521-a712-25f2dfaa02c3";

  # The root filesystem (ext4 today, btrfs subvolumes after the migration)
  # lives in layouts.nix; the LUKS container above is the same for both.

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/42F5-D6BF";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
