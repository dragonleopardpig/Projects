{ pkgs, shell }:
let
  inherit (pkgs) lib;
  toml = pkgs.formats.toml { };
  theme = import ./theme.nix { inherit pkgs; };
  umbriel = pkgs.umbriel.overrideAttrs (previous: {
    patches = (previous.patches or [ ]) ++ [ ./keyboard-only-wake.patch ];
  });
  lockAndBlank = pkgs.writeShellApplication {
    name = "noctalia-lock-and-blank";
    runtimeInputs = [ shell umbriel pkgs.systemd pkgs.jq pkgs.coreutils ];
    text = ''
      if [ "''${1:-}" != --inhibited ]; then
        # A closed lid must not turn monitor power-off into machine suspend.
        exec systemd-inhibit --what=handle-lid-switch --mode=block \
          --who="Noctalia lock" --why="Keep the locked desktop awake while displays are off" \
          "$0" --inhibited
      fi
      noctalia msg session lock
      # Noctalia waits for an acknowledged safe lock frame before powering off.
      noctalia msg dpms-off
      screens_off() {
        umbriel outputs --json | jq -e 'any(.[]; .enabled and (.powered | not))' >/dev/null
      }
      for _ in {1..50}; do
        screens_off && break
        sleep 0.1
      done
      # Release the lid inhibitor when a keyboard wakes the displays, or when
      # the compositor exits. Pointer activity does not power them back on.
      while screens_off; do sleep 0.5; done
    '';
  };
  greeter = pkgs.noctalia-greeter;
  drmLauncher = pkgs.writeShellApplication {
    name = "noctalia-drm-launch";
    text = builtins.readFile ./gpu-selection.sh + ''
      configure_drm_devices
      exec "$@"
    '';
  };
  lockPowerTest = pkgs.writeShellApplication {
    name = "noctalia-lock-power-test";
    runtimeInputs = [ shell umbriel drmLauncher lockAndBlank pkgs.dbus pkgs.jq pkgs.coreutils pkgs.util-linux pkgs.wlrctl pkgs.wtype ];
    text = builtins.readFile ./test-lock-power.sh;
  };
  gpuSelectionCheck = pkgs.runCommand "noctalia-gpu-selection-checked" {
    nativeBuildInputs = [ pkgs.bash ];
  } ''
    bash ${./gpu-selection-test.sh} ${./gpu-selection.sh}
    touch $out
  '';
  displayCycle = pkgs.writeShellApplication {
    name = "noctalia-display-cycle";
    runtimeInputs = [ umbriel shell pkgs.jq pkgs.libnotify pkgs.ddcutil pkgs.gawk ];
    text = builtins.readFile ./display-cycle.sh;
  };
  stopRecording = pkgs.writeShellApplication {
    name = "noctalia-stop-recording";
    runtimeInputs = [ pkgs.procps pkgs.coreutils pkgs.libnotify ];
    text = builtins.readFile ./stop-recording.sh;
  };
  suiteTools = pkgs.symlinkJoin {
    name = "noctalia-suite-tools";
    paths = [ shell umbriel greeter pkgs.foot pkgs.wl-clipboard pkgs.libnotify ];
  };
  shellConfig = toml.generate "noctalia-suite.toml" (import ./settings.nix {
    themeName = theme.name;
    inherit (theme) wallpaper;
  });
  configHome = pkgs.runCommand "noctalia-suite-config" { } ''
    mkdir -p $out/noctalia/palettes
    cp ${shellConfig} $out/noctalia/config.toml
    cp ${theme.palette} $out/noctalia/palettes/${theme.name}.json
  '';
  shellRunner = pkgs.writeShellApplication {
    name = "noctalia-suite-shell";
    runtimeInputs = [ suiteTools pkgs.coreutils pkgs.ddcutil pkgs.brightnessctl ];
    text = ''
      export NOCTALIA_CONFIG_HOME=${configHome}
      user_config_home="''${XDG_CONFIG_HOME:-$HOME/.config}/noctalia-suite"
      if [ -f "$user_config_home/noctalia/config.toml" ]; then
        export NOCTALIA_CONFIG_HOME="$user_config_home"
      fi
      export FONTCONFIG_FILE=${theme.fontConfig}
      export NOCTALIA_STATE_HOME="''${XDG_STATE_HOME:-$HOME/.local/state}/noctalia-suite"
      export NOCTALIA_DATA_HOME="''${XDG_DATA_HOME:-$HOME/.local/share}/noctalia-suite"
      exec noctalia
    '';
  };
  compositorConfig = toml.generate "umbriel-suite.toml" (import ./umbriel.nix {
    inherit lib pkgs;
    shellCommand = lib.getExe shellRunner;
    terminalCommand = "${lib.getExe pkgs.foot} --config=${theme.terminalConfig}";
    displayCycleCommand = lib.getExe displayCycle;
    stopRecordingCommand = lib.getExe stopRecording;
    lockCommand = lib.getExe lockAndBlank;
    inherit (theme) dark neon;
  });
  # Keep the suite defaults declarative and display preferences user-writable.
  # Includes are merged before this small entrypoint, in the order shown.
  userCompositorConfig = toml.generate "umbriel-user.toml" {
    include.files = [ compositorConfig ];
    include.optional.files = [ "~/.config/umbriel/outputs.toml" ];
  };
  userCompositorService = pkgs.writeText "umbriel-user-config.conf" ''
    [Service]
    ExecStart=
    ExecStart=${lib.getExe drmLauncher} ${lib.getExe umbriel} -c %h/.config/umbriel/config.toml
  '';
  greeterSettings = toml.generate "greeter-suite.toml" (import ./greeter-settings.nix { inherit theme; });
  validatedSuite = pkgs.runCommand "noctalia-suite-validated" { } ''
    test -f ${gpuSelectionCheck}
    export NOCTALIA_STATE_HOME="$TMPDIR/noctalia-suite-validation"
    export NOCTALIA_CONFIG_HOME=${configHome}
    ${lib.getExe shell} config validate ${shellConfig}
    ${lib.getExe umbriel} config validate -c ${compositorConfig}
    ${lib.getExe umbriel} config validate -c ${userCompositorConfig}
    ${lib.getExe pkgs.foot} --check-config --config=${theme.terminalConfig}
    touch $out
  '';
  suiteConfig = pkgs.runCommand "noctalia-suite-configs" { } ''
    mkdir -p $out/session
    cp ${shellConfig} $out/session/noctalia.toml
    cp ${compositorConfig} $out/session/umbriel.toml
    cp ${greeterSettings} $out/greeter.toml
    cp ${theme.palette} $out/${theme.name}.json
    cp ${theme.wallpaper} $out/wallpaper.png
  '';
  suiteSession = pkgs.writeShellApplication {
    name = "noctalia-suite-session";
    runtimeInputs = [ suiteTools pkgs.dbus pkgs.systemd ];
    text = ''
      test -f ${validatedSuite}
      if [ -n "''${WAYLAND_DISPLAY:-}" ] || [ -n "''${DISPLAY:-}" ]; then
        echo "Start Noctalia Suite from a TTY or login manager." >&2
        exit 1
      fi
      if [ ! -f /etc/noctalia-suite/session-enabled ]; then
        echo "Install the optional NixOS suite module first; it wires the session and portals." >&2
        exit 1
      fi
      unset HYPRLAND_INSTANCE_SIGNATURE SWAYSOCK NIRI_SOCKET UWSM_ID
      export XDG_CURRENT_DESKTOP=umbriel XDG_SESSION_DESKTOP=umbriel XDG_SESSION_TYPE=wayland
      # The host's graphical-session services may already be active (user lingering).
      # Stop only known conflicting services, and restore their previous active state.
      stopped=()
      restore_services() {
        for unit in "''${stopped[@]}"; do systemctl --user start "$unit" || true; done
      }
      trap restore_services EXIT
      for unit in ags.service swaync.service hypridle.service hyprpolkitagent.service; do
        if systemctl --user is-active --quiet "$unit"; then
          systemctl --user stop "$unit"
          stopped+=("$unit")
        fi
      done
      # The optional module sets umbriel.service's ExecStart to our config.
      # Upstream's launcher manages session targets and clears stale display
      # variables when the compositor exits.
      start-umbriel "$@"
    '';
  };
  sessionEntry = pkgs.runCommand "noctalia-suite-session-entry" {
    passthru.providedSessions = [ "noctalia-suite" ];
  } ''
    mkdir -p $out/share/wayland-sessions
    cat > $out/share/wayland-sessions/noctalia-suite.desktop <<EOF
    [Desktop Entry]
    Name=Noctalia Suite
    Comment=Umbriel with the native Noctalia desktop
    Exec=${lib.getExe suiteSession}
    Type=Application
    DesktopNames=umbriel
    EOF
  '';
in {
  inherit suiteTools suiteSession suiteConfig validatedSuite greeterSettings sessionEntry;
  inherit umbriel greeter drmLauncher gpuSelectionCheck userCompositorConfig userCompositorService lockPowerTest;
  sessionCompositorConfig = compositorConfig;
  userShellConfig = shellConfig;
  inherit theme;
}
