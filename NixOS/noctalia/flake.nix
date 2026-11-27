{
  description = "Noctalia Suite desktop: Shell, Umbriel, and Greeter";

  nixConfig = {
    extra-substituters = [ "https://noctalia.cachix.org" ];
    extra-trusted-public-keys = [ "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4=" ];
  };

  inputs = {
    noctalia.url = "github:noctalia-dev/noctalia/cachix";
    noctalia-agent-status = { url = "github:dragonleopardpig/noctalia-agent-status"; inputs.nixpkgs.follows = "noctalia/nixpkgs"; };
    noctalia-always-on = { url = "github:dragonleopardpig/noctalia-always-on"; inputs.nixpkgs.follows = "noctalia/nixpkgs"; };
    noctalia-backup-status = { url = "github:dragonleopardpig/noctalia-backup-status"; inputs.nixpkgs.follows = "noctalia/nixpkgs"; };
    noctalia-gpu-status = { url = "github:dragonleopardpig/noctalia-gpu-status"; inputs.nixpkgs.follows = "noctalia/nixpkgs"; };
    noctalia-kitty-control = { url = "github:dragonleopardpig/noctalia-kitty-control"; inputs.nixpkgs.follows = "noctalia/nixpkgs"; };
    noctalia-rclone-control = { url = "github:dragonleopardpig/noctalia-rclone-control"; inputs.nixpkgs.follows = "noctalia/nixpkgs"; };
    noctalia-rsync-status = { url = "github:dragonleopardpig/noctalia-rsync-status"; inputs.nixpkgs.follows = "noctalia/nixpkgs"; };
  };

  outputs = { self, noctalia, noctalia-agent-status, noctalia-always-on, noctalia-backup-status, noctalia-gpu-status, noctalia-kitty-control, noctalia-rclone-control, noctalia-rsync-status }:
    let
      system = "x86_64-linux";
      pkgs = noctalia.inputs.nixpkgs.legacyPackages.${system};
      lib = pkgs.lib;
      pluginInputs = {
        agent-status = noctalia-agent-status;
        always-on = noctalia-always-on;
        backup-status = noctalia-backup-status;
        gpu-status = noctalia-gpu-status;
        kitty-control = noctalia-kitty-control;
        rclone-control = noctalia-rclone-control;
        rsync-status = noctalia-rsync-status;
      };
      shell = noctalia.packages.${system}.default.overrideAttrs (previous: {
        patches = (previous.patches or [ ]) ++ [
          ./suite/noctalia-umbriel-ipc.patch
          ./suite/fullscreen-launcher.patch
          ./suite/tray-menu-modal-layer.patch
          # Tooltips for the bar buttons that had none (launcher, media, control
          # center, caffeine, notifications, session).
          ./suite/bar-widget-tooltips.patch
          # Pin / Unpin for every bar widget: `actions.right = "widget-menu"` opens a native
          # menu (the widget's own right-click action, then Unpin from bar); an unpinned widget
          # (`[widget.<name>] enabled = false`) sits in the tray's down-arrow drawer, where a
          # click runs its left action and a right click offers Pin to bar.
          ./suite/tray-drawer-unpinned-widgets.patch
          # Chinese lunar calendar overlay (dates, 24 solar terms, traditional festivals) and
          # wider local vdir sync window for multi-year holiday feeds.
          ./suite/calendar-lunar-overlay.patch
        ];
      });
      suite = import ./suite { inherit pkgs shell pluginInputs; };
    in {
      packages.${system} = {
        default = suite.suiteSession;
        noctalia = shell;
        inherit (suite) suiteSession suiteConfig validatedSuite suiteTools drmLauncher lockPowerTest syncSettings agentStatus agentHooks gpuStatus rsyncStatus rcloneStatus displayCycle killWindow sgHolidaysUpdate;
        umbriel = suite.umbriel;
        greeter = suite.greeter;
      };
      apps.${system} = {
        default = { type = "app"; program = lib.getExe suite.suiteSession; };
        session = { type = "app"; program = lib.getExe suite.suiteSession; };
        check-lock = { type = "app"; program = lib.getExe suite.lockPowerTest; };
        check-tray-drawer = { type = "app"; program = lib.getExe suite.trayDrawerTest; };
      };
      checks.${system} = {
        suite = suite.validatedSuite;
        gpuSelection = suite.gpuSelectionCheck;
        killWindow = suite.killWindowCheck;
        sgHolidaysUpdate = suite.sgHolidaysUpdateCheck;
        lunarCalendar = suite.lunarCalendarCheck;
        syncSettings = suite.syncSettingsCheck;
        agentStatus = suite.agentStatusCheck;
        gpuStatus = suite.gpuStatusCheck;
        rsyncStatus = suite.rsyncStatusCheck;
        rsyncStatusPlugin = suite.rsyncStatusPluginCheck;
        rcloneStatus = suite.rcloneStatusCheck;
        rcloneStatusPlugin = suite.rcloneStatusPluginCheck;
        backupStatusPlugin = suite.backupStatusPluginCheck;
        pluginGlyphs = suite.pluginGlyphsCheck;
        barIcons = suite.barIconsCheck;
        pluginLint = suite.pluginLintCheck;
        alwaysOnPlugin = suite.alwaysOnPluginCheck;
      };
      nixosModules.suite = import ./suite/nixos-module.nix { inherit suite pkgs; };
      homeManagerModules.suite = { lib, ... }:
        let
          sgHolidayFiles = builtins.readDir ./suite/calendars/sg-holidays;
          sgHolidayDataFiles = lib.mapAttrs' (name: _: {
            name = "noctalia-suite/calendars/sg-holidays/${name}";
            value = {
              source = ./suite/calendars/sg-holidays/${name};
              force = true;
            };
          }) sgHolidayFiles;
        in {
        xdg.configFile."umbriel/config.toml" = {
          source = suite.userCompositorConfig;
          force = true;
        };
        xdg.configFile."systemd/user/umbriel.service.d/zz-noctalia-user-config.conf" = {
          source = suite.userCompositorService;
          force = true;
        };
        xdg.configFile."noctalia-suite/noctalia/config.toml" = {
          source = suite.userShellConfig;
          force = true;
        };
        xdg.configFile."noctalia-suite/noctalia/palettes/OLO-Neon.json" = {
          source = suite.theme.palette;
          force = true;
        };
        xdg.dataFile = sgHolidayDataFiles // {
          "noctalia-suite/noctalia/plugins/kitty-control" = {
            source = noctalia-kitty-control.lib.pluginDir;
            force = true;
          };
          "noctalia-suite/noctalia/plugins/agent-status" = {
            source = noctalia-agent-status.lib.pluginDir;
            force = true;
          };
          "noctalia-suite/noctalia/plugins/gpu-status" = {
            source = noctalia-gpu-status.lib.pluginDir;
            force = true;
          };
          "noctalia-suite/noctalia/plugins/always-on" = {
            source = noctalia-always-on.lib.pluginDir;
            force = true;
          };
          "noctalia-suite/noctalia/plugins/rsync-status" = {
            source = noctalia-rsync-status.lib.pluginDir;
            force = true;
          };
          "noctalia-suite/noctalia/plugins/rclone-status" = {
            source = noctalia-rclone-control.lib.pluginDir;
            force = true;
          };
          # Its helper, backup-pool, comes with the host's backup (hosts/M90aPro/backup.nix);
          # on hosts without one the icon hides itself.
          "noctalia-suite/noctalia/plugins/backup-status" = {
            source = noctalia-backup-status.lib.pluginDir;
            force = true;
          };
        };
        systemd.user.services.sg-holidays-update = {
          Unit = {
            Description = "Update Singapore public holidays from MOM for Noctalia calendar";
            After = [ "network-online.target" ];
          };
          Service = {
            Type = "oneshot";
            ExecStart = "${lib.getExe suite.sgHolidaysUpdate} --live-only --quiet";
          };
        };
        systemd.user.timers.sg-holidays-update = {
          Unit.Description = "Monthly check for new Singapore public holiday calendars";
          Timer = {
            OnCalendar = "monthly";
            Persistent = true;
            RandomizedDelaySec = "1h";
          };
          Install.WantedBy = [ "timers.target" ];
        };
        home.file.".local/bin/noctalia-agent-status".source = lib.getExe suite.agentStatus;
        home.file.".local/bin/noctalia-gpu-status".source = lib.getExe suite.gpuStatus;
        home.file.".local/bin/noctalia-rsync-status".source = lib.getExe suite.rsyncStatus;
        home.file.".local/bin/noctalia-rclone-status".source = lib.getExe suite.rcloneStatus;
        home.file.".gemini/config/hooks.json".source = suite.agentHooks;
        home.activation.syncNoctaliaSuite = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
          ${lib.getExe suite.syncSettings} || true
        '';
      };
    };
}
