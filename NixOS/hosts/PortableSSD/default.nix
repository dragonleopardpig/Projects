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

  # No swap on the portable disk. Unlike M90aPro (which has a 16G /swapfile),
  # this root is small and routinely near-full, so a large swapfile fills it on
  # boot — the mkswap service runs out of space, which cascades into a failed
  # home-manager activation (stale bar, apps won't launch) and an unbootable,
  # 100%-full disk. Keep it swapless; rely on RAM/zram instead if ever needed.
  swapDevices = lib.mkForce [];

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
  # Boot loudly on this disk. On 2026-08-20 a boot filled the screen with red
  # text just after the LUKS unlock and then froze. Nothing was recoverable
  # afterwards: the freeze happened before switch-root, so journald's initrd
  # buffer (/run/log/journal, RAM-only until /var is writable) died with the
  # reset — `journalctl --list-boots` has no entry for it at all, and nothing
  # under /var was written during the window. There is no quiet/splash here so
  # that a repeat stays legible on screen long enough to photograph.
  #   loglevel=7              kernel prints warnings too, not just errors —
  #                           a USB root-device dropout shows its run-up
  #   rd.systemd.show_status=yes  name every stage-1 unit, so the last line
  #                           printed identifies where it stopped
  #   boot.shell_on_fail      rescue shell instead of a hard freeze if stage 1
  #                           is what fails
  # udev stays at priority 3: its event spam would scroll the actual failure
  # off-screen, which defeats the point.
  boot.kernelParams = lib.mkForce [
    "loglevel=7"
    "boot.shell_on_fail"
    "udev.log_priority=3"
    "rd.systemd.show_status=yes"
    "systemd.swap=0"
  ];

  # Same reason: the shared config sets this false to hide first-boot output.
  boot.initrd.verbose = lib.mkForce true;

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
