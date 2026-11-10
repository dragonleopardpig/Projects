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
        ];
      });
      suite = import ./suite { inherit pkgs shell; };
    in {
      packages.${system} = {
        default = suite.suiteSession;
        noctalia = shell;
        inherit (suite) suiteSession suiteConfig validatedSuite suiteTools drmLauncher lockPowerTest;
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
        home.activation.syncNoctaliaSuite = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          ${lib.getExe suite.syncSettings} || true
        '';
      };
    };
}
