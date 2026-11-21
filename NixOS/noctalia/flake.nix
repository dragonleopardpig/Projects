{
  description = "Noctalia Suite desktop: Shell, Umbriel, and Greeter";

  nixConfig = {
    extra-substituters = [ "https://noctalia.cachix.org" ];
    extra-trusted-public-keys = [ "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4=" ];
  };

  inputs.noctalia.url = "github:noctalia-dev/noctalia/cachix";

  outputs = { self, noctalia }:
    let
      system = "x86_64-linux";
      pkgs = noctalia.inputs.nixpkgs.legacyPackages.${system};
      lib = pkgs.lib;
      shell = noctalia.packages.${system}.default.overrideAttrs (previous: {
        patches = (previous.patches or [ ]) ++ [
          ./suite/noctalia-umbriel-ipc.patch
          ./suite/fullscreen-launcher.patch
          ./suite/tray-menu-modal-layer.patch
          # Tooltips for the bar buttons that had none (launcher, media, control
          # center, caffeine, notifications, session).
          ./suite/bar-widget-tooltips.patch
          # Unpinned bar widgets (plugins/bar-pins: `[widget.<name>] enabled = false`) sit in
          # the tray's down-arrow drawer beside the unpinned tray icons; click runs the
          # widget's left action, right click its right action (the Pin/Unpin menu).
          ./suite/tray-drawer-unpinned-widgets.patch
        ];
      });
      suite = import ./suite { inherit pkgs shell; };
    in {
      packages.${system} = {
        default = suite.suiteSession;
        noctalia = shell;
        inherit (suite) suiteSession suiteConfig validatedSuite suiteTools drmLauncher lockPowerTest syncSettings agentStatus agentHooks gpuStatus rsyncStatus rcloneStatus displayCycle;
        umbriel = suite.umbriel;
        greeter = suite.greeter;
      };
      apps.${system} = {
        default = { type = "app"; program = lib.getExe suite.suiteSession; };
        session = { type = "app"; program = lib.getExe suite.suiteSession; };
        check-lock = { type = "app"; program = lib.getExe suite.lockPowerTest; };
      };
      checks.${system} = {
        suite = suite.validatedSuite;
        gpuSelection = suite.gpuSelectionCheck;
        syncSettings = suite.syncSettingsCheck;
        agentStatus = suite.agentStatusCheck;
        gpuStatus = suite.gpuStatusCheck;
        rsyncStatus = suite.rsyncStatusCheck;
        rsyncStatusPlugin = suite.rsyncStatusPluginCheck;
        rcloneStatus = suite.rcloneStatusCheck;
        rcloneStatusPlugin = suite.rcloneStatusPluginCheck;
        backupStatusPlugin = suite.backupStatusPluginCheck;
        pluginGlyphs = suite.pluginGlyphsCheck;
        barPinsPlugin = suite.barPinsPluginCheck;
        barIcons = suite.barIconsCheck;
        pluginLint = suite.pluginLintCheck;
        alwaysOnPlugin = suite.alwaysOnPluginCheck;
      };
      nixosModules.suite = import ./suite/nixos-module.nix { inherit suite pkgs; };
      homeManagerModules.suite = { lib, ... }: {
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
        xdg.dataFile."noctalia-suite/noctalia/plugins/kitty-control" = {
          source = ./suite/plugins/kitty-control;
          force = true;
        };
        xdg.dataFile."noctalia-suite/noctalia/plugins/agent-status" = {
          source = ./suite/plugins/agent-status;
        };
        xdg.dataFile."noctalia-suite/noctalia/plugins/gpu-status" = {
          source = ./suite/plugins/gpu-status;
          force = true;
        };
        xdg.dataFile."noctalia-suite/noctalia/plugins/always-on" = {
          source = ./suite/plugins/always-on;
          force = true;
        };
        xdg.dataFile."noctalia-suite/noctalia/plugins/rsync-status" = {
          source = ./suite/plugins/rsync-status;
          force = true;
        };
        xdg.dataFile."noctalia-suite/noctalia/plugins/rclone-status" = {
          source = ./suite/plugins/rclone-status;
          force = true;
        };
        # Its helper, backup-pool, comes with the host's backup (hosts/M90aPro/backup.nix);
        # on hosts without one the icon hides itself.
        xdg.dataFile."noctalia-suite/noctalia/plugins/backup-status" = {
          source = ./suite/plugins/backup-status;
          force = true;
        };
        xdg.dataFile."noctalia-suite/noctalia/plugins/bar-pins" = {
          source = ./suite/plugins/bar-pins;
          force = true;
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
