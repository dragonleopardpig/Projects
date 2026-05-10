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
    "systemd.swap=0"
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
