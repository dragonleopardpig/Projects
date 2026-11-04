{
  description = "Noctalia bar trial for the existing AGS/Hyprland desktop";

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
      shell = noctalia.packages.${system}.default;

      # These small widgets keep the AGS-only indicators and controls on the
      # replacement bar without changing the installed NixOS generation.
      plugin = pkgs.runCommand "noctalia-ags-bridge-plugin" { } ''
        mkdir -p $out
        cp -r ${./plugin}/. $out/
      '';

      settings = import ./settings.nix { inherit plugin; };
      rawConfig = (pkgs.formats.toml { }).generate "noctalia-trial.toml" settings;
      configHome = pkgs.runCommand "noctalia-trial-config" { } ''
        mkdir -p $out/noctalia
        cp ${rawConfig} $out/noctalia/config.toml
      '';
      validatedConfig = pkgs.runCommand "noctalia-trial-validated" { } ''
        ${lib.getExe shell} config validate ${rawConfig}
        touch $out
      '';

      trial = pkgs.writeShellApplication {
        name = "noctalia-trial";
        runtimeInputs = [ shell pkgs.jq pkgs.procps pkgs.coreutils pkgs.gnugrep ];
        text = ''
          test -f ${validatedConfig}
          export NOCTALIA_CONFIG_HOME=${configHome}
          # A new trial profile avoids old GUI overrides restoring the AGS-like
          # bar layout after the project switches to its Noctalia layout.
          export NOCTALIA_STATE_HOME="''${XDG_STATE_HOME:-$HOME/.local/state}/noctalia-native-trial"
          export NOCTALIA_DATA_HOME="''${XDG_DATA_HOME:-$HOME/.local/share}/noctalia-native-trial"

          if [ -z "''${WAYLAND_DISPLAY:-}" ]; then
            echo "Start this from the running Hyprland session." >&2
            exit 1
          fi
          if noctalia msg status >/dev/null 2>&1; then
            echo "Noctalia is already running; stop it before starting this trial." >&2
            exit 1
          fi

          # The existing AGS instance owns the original calendar, weather and
          # control-center popups. Keep it alive and hide only its bar.
          ags_pid="$(pgrep -f '^gjs -m /run/user/[0-9]+/ags.js$' | head -n 1 || true)"
          if [ -z "$ags_pid" ]; then
            echo "The AGS instance is not running. Start it first so its custom panels remain available." >&2
            exit 1
          fi
          ags_was_visible=0
          if [ -n "$ags_pid" ] && hyprctl layers -j | jq -e --argjson pid "$ags_pid" \
              '[.[] | .levels[]? | .[]? | select(.pid == $pid and .namespace == "gtk-layer-shell" and .h < 150)] | length > 0' >/dev/null; then
            ags_was_visible=1
            ags request togglebar >/dev/null
          fi

          restore_ags() {
            if [ "$ags_was_visible" = 1 ] && ags list 2>/dev/null | grep -qx astal; then
              # Restore only if AGS's bar is still hidden. This also handles
              # a user manually bringing AGS back during the trial.
              current_pid="$(pgrep -f '^gjs -m /run/user/[0-9]+/ags.js$' | head -n 1 || true)"
              if [ -n "$current_pid" ] && ! hyprctl layers -j | jq -e --argjson pid "$current_pid" \
                  '[.[] | .levels[]? | .[]? | select(.pid == $pid and .namespace == "gtk-layer-shell" and .h < 150)] | length > 0' >/dev/null; then
                ags request togglebar >/dev/null 2>&1 || true
              fi
            fi
          }
          trap restore_ags EXIT
          noctalia
        '';
      };
    in {
      packages.${system} = {
        default = trial;
        inherit plugin validatedConfig;
        noctalia = shell;
      };
      apps.${system}.default = {
        type = "app";
        program = "${lib.getExe trial}";
      };
      checks.${system}.config = validatedConfig;
    };
}
