# Hardware configuration for PortableSSD
# Broad module set for portability across different machines
{ config, lib, modulesPath, ... }:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # Broad initrd modules for portability across varied hardware.
  # Covers USB3/USB2, SATA/AHCI, NVMe, USB mass-storage (this disk is likely
  # external), Thunderbolt/USB4 enclosures, and SD/eMMC readers.
  boot.initrd.availableKernelModules = [
    "xhci_pci" "ehci_pci" "ohci_pci" "ahci" "nvme" "uas" "sd_mod"
    "usb_storage" "usbhid" "sdhci_pci" "rtsx_pci_sdmmc"
    "thunderbolt" "mmc_block"
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

  # DHCP on every wired/wireless interface by default, so the disk gets an
  # address on whatever NIC the host has (NetworkManager still manages WiFi).
  networking.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
