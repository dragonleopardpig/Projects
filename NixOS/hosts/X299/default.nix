# X299 Desktop - Host-specific configuration
{ config, lib, pkgs, ... }:
let
  localEuresysSources = /home/thinky/Projects/NixOS/modules/egrabber/sources.nix;
in
{
  imports = [
    ./hardware-configuration.nix
    ./nvidia.nix
    ../../modules/egrabber/egrabber.nix
  ] ++ lib.optional (builtins.pathExists localEuresysSources)
    localEuresysSources;

  networking.hostName = "X299";
  hardware.euresys.enable = true;

  # DDC/CI backlight for external monitors (X299 has no built-in panel).
  # delay=500 (ms) is the *probe-time* setting — the default 60 is too
  # tight for the Dell P2719H; its MCU returns corrupted DDC/CI bytes
  # (`invalid DDC/CI response, xor 0xbf`) and the driver fails with
  # -ENODEV. 500 ms gives the monitor time to assemble a clean response
  # so /sys/class/backlight/ddcci* registers. After probe, ddcci-setup
  # drops delay to 0 so runtime writes (F5/F6, waybar scroll/click on
  # custom/brightness) finish in ~30 ms instead of ~500 ms.
  boot.kernelModules = [ "ddcci_backlight" ];
  boot.extraModulePackages = [ config.boot.kernelPackages.ddcci-driver ];
  boot.extraModprobeConfig = ''
    options ddcci delay=500
  '';

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
        # Wait for ddcci-backlight probe (slow at delay=500), then drop
        # the inter-command delay to 0 so runtime brightness writes are fast.
        for _ in $(seq 1 30); do
          if ls /sys/class/backlight/ddcci* >/dev/null 2>&1; then break; fi
          sleep 1
        done
        echo 0 > /sys/module/ddcci/parameters/delay || true
      '';
    };
  };
}
