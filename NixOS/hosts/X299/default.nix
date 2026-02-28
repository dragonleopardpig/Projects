# X299 Desktop - Host-specific configuration
{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./nvidia.nix
    ./egrabber.nix
  ];

  networking.hostName = "X299";

  # DDC/CI backlight for external monitors (X299 has no built-in panel)
  boot.kernelModules = [ "ddcci_backlight" ];
  boot.extraModulePackages = [ config.boot.kernelPackages.ddcci-driver ];

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