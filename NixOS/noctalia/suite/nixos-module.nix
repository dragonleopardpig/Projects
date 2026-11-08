{ suite, pkgs }:
let desktopPkgs = pkgs;
in { config, lib, pkgs, ... }:
let
  cfg = config.desktop.noctaliaSuite;
  hyprlandAgsSession = pkgs.runCommand "hyprland-ags-session" {
    passthru.providedSessions = [ "hyprland-ags" ];
  } ''
    mkdir -p $out/share/wayland-sessions
    cat > $out/share/wayland-sessions/hyprland-ags.desktop <<EOF
    [Desktop Entry]
    Name=Hyprland + AGS
    Comment=Previous Hyprland desktop with the AGS bar
    Exec=${lib.getExe pkgs.uwsm} start -F -- /run/current-system/sw/bin/start-hyprland
    Type=Application
    DesktopNames=Hyprland
    EOF
  '';
in {
  options.desktop.noctaliaSuite = {
    enable = lib.mkEnableOption "the Noctalia Suite desktop session";
    greeter.enable = lib.mkEnableOption "Noctalia Greeter in place of SDDM";
  };
  config = lib.mkIf cfg.enable (lib.mkMerge [ {
    environment.systemPackages = [ (lib.lowPrio suite.suiteTools) ];
    fonts.packages = [ desktopPkgs.inter desktopPkgs.nerd-fonts.jetbrains-mono ];
    environment.etc = {
      "noctalia-suite/session-enabled".text = "Noctalia Suite login integration enabled\n";
    };
    services.displayManager.sessionPackages = [ suite.sessionEntry hyprlandAgsSession ];
    systemd.packages = [ suite.umbriel ];
    systemd.user.services.umbriel = {
      restartIfChanged = false;
      enableDefaultPath = false;
      serviceConfig.ExecStart = [
        ""
        "${lib.getExe suite.drmLauncher} ${lib.getExe suite.umbriel} -c ${suite.sessionCompositorConfig}"
      ];
    };
    # The pinned Noctalia authenticates through the existing PAM login stack.
    security.polkit.enable = true;
    networking.networkmanager.enable = lib.mkDefault true;
    hardware.bluetooth.enable = lib.mkDefault true;
    hardware.i2c.enable = lib.mkDefault true;
    services.upower.enable = lib.mkDefault true;
    services.power-profiles-daemon.enable = lib.mkDefault true;
    xdg.portal = {
      enable = true;
      extraPortals = [ desktopPkgs.xdg-desktop-portal-umbriel pkgs.xdg-desktop-portal-gtk ];
      config.umbriel = {
        default = [ "umbriel" "gtk" ];
        "org.freedesktop.impl.portal.FileChooser" = [ "gtk" ];
      };
    };
    # The main configuration pins these to Hyprland/wayland-1. Both desktop
    # sessions publish their actual display into the user manager at startup.
    systemd.user.services.xdg-desktop-portal.serviceConfig.Environment = lib.mkForce [
      "XDG_SESSION_TYPE=wayland"
    ];
    systemd.user.services.xdg-desktop-portal-gtk.serviceConfig.Environment = lib.mkForce [
      "GDK_BACKEND=wayland" "XDG_SESSION_TYPE=wayland"
    ];
  } {
    # Let the systemd module assemble these inside its immutable user-units
    # directory. They also apply when Home Manager supplies the base unit.
    systemd.user.services = lib.genAttrs [ "ags" "swaync" "hypridle" "hyprpolkitagent" ] (_: {
      overrideStrategy = "asDropin";
      unitConfig.ConditionEnvironment = "!XDG_CURRENT_DESKTOP=umbriel";
    });
  } (lib.mkIf cfg.greeter.enable {
    services.displayManager.sddm.enable = lib.mkForce false;
    systemd.services.sddm-random-theme.enable = false;
    services.accounts-daemon.enable = true;
    services.greetd = {
      enable = true;
      settings.default_session.command = "${pkgs.coreutils}/bin/env XDG_DATA_DIRS=${config.services.displayManager.sessionData.desktops}/share ${lib.getExe suite.drmLauncher} ${suite.greeter}/bin/noctalia-greeter-session";
    };
    systemd.tmpfiles.rules = [
      "d /var/lib/noctalia-greeter 0750 greeter greeter -"
      "L+ /var/lib/noctalia-greeter/greeter.toml - - - - ${suite.greeterSettings}"
    ];
  }) ]);
}
