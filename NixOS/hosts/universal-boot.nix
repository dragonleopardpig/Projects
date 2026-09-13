# Hardware-neutral settings shared by portable NixOS installations.
#
# Each host importing this module supplies its own hardware-configuration.nix
# for the root/LUKS/EFI UUIDs.  Everything here is deliberately independent of
# the machine on which the external drive happens to boot.
{ config, lib, pkgs, ... }:
{
  # Include firmware for Wi-Fi, Bluetooth, and GPUs commonly encountered on
  # x86_64 machines.  The required unfree firmware is narrowly allowed by the
  # shared configuration.
  hardware.enableAllFirmware = true;

  # Keep 32-bit GL/Vulkan available for Steam, Wine, and other 32-bit apps.
  hardware.graphics.enable32Bit = lib.mkDefault true;

  # The drive may be connected to either an Intel or AMD computer.
  hardware.cpu.intel.updateMicrocode = lib.mkDefault true;
  hardware.cpu.amd.updateMicrocode = lib.mkDefault true;

  # NetworkManager handles Wi-Fi; this also gives unknown wired interfaces a
  # sensible DHCP default.
  networking.useDHCP = lib.mkDefault true;

  # Avoid a large disk-backed swap file on portable roots.
  swapDevices = lib.mkForce [];

  # Install GRUB at EFI/BOOT/BOOTX64.EFI, the standard UEFI fallback path, and
  # never add an entry to whichever computer's firmware happens to be active.
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  boot.loader.grub.efiInstallAsRemovable = true;

  # Put drivers for common internal and external root-device controllers in
  # the initrd.  The per-drive hardware file can add more without narrowing
  # this baseline.
  boot.initrd.availableKernelModules = [
    "xhci_pci" "ehci_pci" "ohci_pci" "ahci" "nvme" "uas" "sd_mod"
    "usb_storage" "usbhid" "sdhci_pci" "rtsx_pci_sdmmc"
    "thunderbolt" "mmc_block" "virtio_pci" "virtio_blk" "virtio_scsi"
  ];

  # The shared desktop configuration includes NVIDIA for the fixed hosts.
  # Portable systems must instead let the initrd and kernel discover the GPU.
  boot.initrd.kernelModules = lib.mkForce [];
  boot.extraModulePackages = lib.mkForce [ config.boot.kernelPackages.ddcci-driver ];
  boot.kernelModules = [ "kvm-intel" "kvm-amd" "ddcci_backlight" ];

  # Keep early boot diagnostic output visible.  This is particularly useful
  # when a USB enclosure or controller is unsupported on a new computer.
  boot.kernelParams = lib.mkForce [
    "loglevel=7"
    "boot.shell_on_fail"
    "udev.log_priority=3"
    "rd.systemd.show_status=yes"
    "systemd.swap=0"
  ];
  boot.initrd.verbose = lib.mkForce true;
  boot.plymouth.enable = lib.mkForce false;

  # Probe external monitors for DDC/CI brightness control.  It is harmless on
  # computers without such a monitor.
  systemd.services.ddcci-setup = {
    description = "Setup ddcci backlight devices for external monitors";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
      ExecStart = pkgs.writeShellScript "ddcci-setup" ''
        for bus in /sys/bus/i2c/devices/i2c-*/; do
          echo "ddcci 0x37" > "$bus/new_device" 2>/dev/null || true
        done
      '';
    };
  };
}
