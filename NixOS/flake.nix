# Unified flake.nix for X299 and M90aPro
{
  description = "NixOS configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    grub2-themes.url = "github:vinceliuice/grub2-themes";
    hyprland.url = "github:hyprwm/Hyprland";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hyprpanel = {
      url = "github:Jas-SinghFSU/HyprPanel";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    elephant.url = "github:abenz1267/elephant";
    walker = {
      url = "github:abenz1267/walker";
      inputs.elephant.follows = "elephant";
    };
  };

  outputs = inputs@{ nixpkgs, grub2-themes, home-manager, disko, ... }:
    let
      protonvpnOverlay = final: prev: {
        protonvpn-gui = prev.protonvpn-gui.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [
            ./patches/protonvpn-systray.patch
          ];
        });

        megasync = prev.megasync.overrideAttrs (old:
          let
            appSrc = prev.fetchFromGitHub {
              owner = "dragonleopardpig";
              repo = "MEGAsync";
              rev = "742448b50a1feb0e23e013b325c65ad9b980d5a0";
              hash = "sha256-UITUrAAfYgoRxVLu9CZixmRlkXoJY3zYfooIE1kjQB4=";
            };
            sdkSrc = prev.fetchFromGitHub {
              owner = "meganz";
              repo = "sdk";
              rev = "de912523770668d323605a2ee280085cd891c2c5";
              hash = "sha256-ySybl03npZDQK71EB7Ezte5/2caLw+xovivp+55hUPw=";
            };
          in {
            version = "6.2.1-742448b";
            src = prev.runCommand "megasync-6.2.1-742448b-source" { } ''
              cp -r ${appSrc} $out
              chmod -R +w $out
              mkdir -p $out/src/MEGASync/mega
              cp -r ${sdkSrc}/. $out/src/MEGASync/mega
              chmod -R +w $out/src/MEGASync/mega
            '';

            patches = (old.patches or [ ]) ++ [
              ./patches/megasync-hyprland.patch
              ./patches/megasync-sync-header-labels.patch
            ];

            postPatch = ''
              substituteInPlace src/MEGASync/mega/cmake/modules/sdklib_libraries.cmake \
                --replace-fail "target_link_libraries(SDKlib PRIVATE ICU::i18n ICU::uc ICU::data)" \
                                "target_link_libraries(SDKlib PUBLIC ICU::i18n ICU::uc ICU::data)" \
                --replace-fail "target_link_libraries(SDKlib PRIVATE ICU::uc ICU::data)" \
                                "target_link_libraries(SDKlib PUBLIC ICU::uc ICU::data)"

              ${prev.python3}/bin/python <<'PY'
              from pathlib import Path
              path = Path("src/MEGASync/CMakeLists.txt")
              text = path.read_text()
              if "find_package(ICU COMPONENTS i18n uc data REQUIRED)" not in text:
                  text = text.replace(
                      "target_link_libraries(MEGAsync",
                      "find_package(ICU COMPONENTS i18n uc data REQUIRED)\n\ntarget_link_libraries(MEGAsync",
                      1,
                  )
              marker = "    Qt5::QuickWidgets"
              replacement = "    Qt5::QuickWidgets\n    ICU::i18n\n    ICU::uc\n    ICU::data"
              if replacement not in text:
                  text = text.replace(marker, replacement, 1)
              path.write_text(text)
              PY

              for file in $(find src/ -type f \( -iname configure -o -iname \*.sh \) ); do
                substituteInPlace "$file" --replace-warn "/bin/bash" "${prev.stdenv.shell}"
              done
            '';

            buildInputs = (old.buildInputs or [ ]) ++ (with prev; [
              dbus
              glib
              gtk3
              libappindicator-gtk3
              libnotify
              libx11
              libxext
              libxfixes
              libxrender
            ]);

            cmakeFlags = (old.cmakeFlags or [ ]) ++ [
              (prev.lib.cmakeBool "ENABLE_ISOLATED_GFX" false)
            ];
          });
      };

      mkSystem = hostModule: nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          {
            nixpkgs.overlays = [ protonvpnOverlay ];
          }
          ./configuration.nix
          hostModule
          disko.nixosModules.disko
          grub2-themes.nixosModules.default
          home-manager.nixosModules.home-manager
          {
            home-manager.backupFileExtension = "bak";
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;

            home-manager.users.thinky = {
              imports = [
                ./home.nix
              ];
            };
            home-manager.extraSpecialArgs = { inherit inputs; };
          }
        ];
      };
    in {
      # X299 Desktop Configuration
      nixosConfigurations.X299 = mkSystem ./hosts/X299;

      # X299 Desktop (external SSD clone)
      nixosConfigurations.X299-SSD = mkSystem ./hosts/X299-SSD;

      # M90aPro Laptop Configuration
      nixosConfigurations.M90aPro = mkSystem ./hosts/M90aPro;

      # Standalone home-manager configurations (optional)
      homeConfigurations."thinky@X299" = home-manager.lib.homeManagerConfiguration {
        # you need this line
        extraSpecialArgs = { inherit inputs; };
        modules = [
          ./home.nix
        ];
      };

      homeConfigurations."thinky@M90aPro" = home-manager.lib.homeManagerConfiguration {
        # you need this line
        extraSpecialArgs = { inherit inputs; };
        modules = [
          ./home.nix
        ];
      };
    };
}
