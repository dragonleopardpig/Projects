# Hardware configuration for PortableSSD
# Broad module set for portability across different machines
{ config, lib, modulesPath, ... }:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # Broad initrd modules for portability across varied hardware
  boot.initrd.availableKernelModules = [
    "xhci_pci" "ehci_pci" "ahci" "nvme" "uas" "sd_mod"
    "usb_storage" "usbhid" "sdhci_pci" "rtsx_pci_sdmmc"
  ];
  boot.initrd.kernelModules = [];
  boot.kernelModules = [ "kvm-intel" "kvm-amd" ];
  boot.extraModulePackages = [];

  # LUKS encryption
  boot.initrd.luks.devices."cryptroot".device = "/dev/disk/by-uuid/4dcda817-861e-426d-90ed-1099c9de0d74";

  fileSystems."/" = {
    device = "/dev/mapper/cryptroot";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/931F-04BC";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [];
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
