# Portable SSD - boots on any x86_64 UEFI machine
#
# Goal: feature-identical to the M90aPro generation (same desktop, services and
# home config — all of which live in the shared ./configuration.nix + ./home.nix)
# but with hardware specifics generalised so the disk boots on most modern
# machines. The deliberate difference from M90aPro is that we do NOT import
# nvidia-prime.nix (its hard-coded NVIDIA bus IDs + proprietary driver would
# break a non-NVIDIA host); generic modesetting (i915 / amdgpu / nouveau) is
# used instead.
{ config, lib, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "PortableSSD";

  # ── Portability: hardware coverage for arbitrary machines ──
  # All firmware (not just the redistributable subset) so WiFi/Bluetooth/GPU on
  # whatever host we boot has its blobs present. The extra unfree firmware this
  # pulls in is whitelisted in configuration.nix's allowUnfreePredicate.
  hardware.enableAllFirmware = true;

  # 32-bit GL/Vulkan parity with M90aPro (Steam, wine, 32-bit apps). The base
  # hardware.graphics.enable is already turned on by programs.hyprland.
  hardware.graphics.enable32Bit = lib.mkDefault true;

  # CPU microcode for either vendor, since the disk may land on Intel or AMD.
  hardware.cpu.intel.updateMicrocode = lib.mkDefault true;
  hardware.cpu.amd.updateMicrocode = lib.mkDefault true;

  # Swap parity with M90aPro: a swapfile keeps nixos-rebuild from OOM-ing on
  # low-RAM hosts. It lives on the encrypted root, so it travels with the disk.
  swapDevices = lib.mkForce [
    { device = "/swapfile"; size = 16384; }
  ];

  # Portable UEFI: don't touch host firmware, install to fallback EFI path
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  boot.loader.grub.efiInstallAsRemovable = true;

  # Remove NVIDIA from initrd — not every machine has it
  boot.initrd.kernelModules = lib.mkForce [];
  # Keep ddcci-driver so DDC/CI monitors get a /sys/class/backlight entry
  # (the X299 hosts also load this; if no DDC monitor is present, the module
  # simply doesn't bind to anything — harmless on portable boots).
  boot.extraModulePackages = lib.mkForce [ config.boot.kernelPackages.ddcci-driver ];
  boot.kernelModules = [ "ddcci_backlight" ];
  boot.kernelParams = lib.mkForce [
    "quiet"
    "splash"
    "boot.shell_on_fail"
    "udev.log_priority=3"
    "rd.systemd.show_status=auto"
  ];

  # Disable plymouth on unknown hardware (GPU drivers may vary)
  boot.plymouth.enable = lib.mkForce false;

  # Probe every i2c bus for a DDC/CI monitor (mirrors X299 setup).
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
