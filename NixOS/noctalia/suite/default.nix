{ pkgs, shell, pluginInputs }:
let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  toml = pkgs.formats.toml { };
  theme = import ./theme.nix { inherit pkgs; };
  umbriel = pkgs.umbriel.overrideAttrs (previous: {
    patches = (previous.patches or [ ]) ++ [ ./keyboard-only-wake.patch ];
  });
  lockAndBlank = pkgs.writeShellApplication {
    name = "noctalia-lock-and-blank";
    runtimeInputs = [ shell umbriel pkgs.systemd pkgs.jq pkgs.coreutils ];
    text = ''
      # ALWAYS-ON MODE (modules/always-on-umbriel.nix): the night look -- this same lock screen
      # and screen-off, by ~/.local/bin/night-look, which also puts things back on unlock; the
      # mode already has logind ignore the lid, so no inhibitor here.
      if [ -e /run/systemd/logind.conf.d/50-always-on.conf ]; then
        exec "$HOME/.local/bin/night-look" on
      fi
      if [ "''${1:-}" != --inhibited ]; then
        # A closed lid must not turn monitor power-off into machine suspend.
        exec systemd-inhibit --what=handle-lid-switch --mode=block \
          --who="Noctalia lock" --why="Keep the locked desktop awake while displays are off" \
          "$0" --inhibited
      fi
      noctalia msg session lock
      # Noctalia waits for an acknowledged safe lock frame before powering off.
      noctalia msg dpms-off
      # The keyboard's lights out with the screens, back when a key wakes them
      # (~/.local/bin/night-look keys-dark / keys-back; asked 2026-11-23).
      "$HOME/.local/bin/night-look" keys-dark || true
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
      "$HOME/.local/bin/night-look" keys-back || true
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
  # End to end, on a private headless desktop with a real pointer: the native Pin/Unpin
  # menus on the bar and in the tray's down-arrow drawer (tray-drawer-unpinned-widgets.patch).
  trayDrawerTest = pkgs.writeShellApplication {
    name = "noctalia-tray-drawer-test";
    runtimeInputs = [ shell umbriel drmLauncher pkgs.dbus pkgs.jq pkgs.coreutils pkgs.util-linux pkgs.imagemagick pkgs.wlrctl ];
    text = builtins.readFile ./test-tray-drawer.sh;
  };
  gpuSelectionCheck = pkgs.runCommand "noctalia-gpu-selection-checked" {
    nativeBuildInputs = [ pkgs.bash ];
  } ''
    bash ${./gpu-selection-test.sh} ${./gpu-selection.sh}
    touch $out
  '';
  displayCycleCheck = pkgs.runCommand "noctalia-display-cycle-checked" {
    nativeBuildInputs = [ pkgs.python3 ];
  } ''
    python3 ${./test-display-cycle.py} ${./display-cycle.py}
    touch $out
  '';
  displayCycle = pkgs.writeShellApplication {
    name = "noctalia-display-cycle";
    runtimeInputs = [ umbriel pkgs.python3 pkgs.libnotify pkgs.ddcutil pkgs.coreutils ];
    text = ''
      exec python3 ${./display-cycle.py} "$@"
    '';
  };
  stopRecording = pkgs.writeShellApplication {
    name = "noctalia-stop-recording";
    runtimeInputs = [ pkgs.procps pkgs.coreutils pkgs.libnotify ];
    text = builtins.readFile ./stop-recording.sh;
  };
  killWindowCheck = pkgs.runCommand "noctalia-kill-window-checked" {
    nativeBuildInputs = [ pkgs.python3 ];
  } ''
    python3 ${./test-kill-window.py} ${./kill-window.py}
    touch $out
  '';
  killWindow = pkgs.writeShellApplication {
    name = "noctalia-kill-window";
    runtimeInputs = [ umbriel pkgs.slurp pkgs.python3 pkgs.libnotify ];
    text = ''
      exec python3 ${./kill-window.py} "$@"
    '';
  };
  sgHolidaysUpdate = pkgs.writeShellApplication {
    name = "sg-holidays-update";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      exec python3 ${./sg-holidays-update.py} "$@"
    '';
  };
  sgHolidaysUpdateCheck = pkgs.runCommand "sg-holidays-update-checked" {
    nativeBuildInputs = [ pkgs.python3 ];
  } ''
    python3 ${./test-sg-holidays-update.py} ${./sg-holidays-update.py}
    touch $out
  '';
  lunarCalendarCheck = pkgs.runCommand "noctalia-lunar-calendar-checked" {
    nativeBuildInputs = [ pkgs.stdenv.cc ];
  } ''
    cp -r ${shell.src} src && chmod -R u+w src
    patch -d src -p1 -s < ${./calendar-lunar-overlay.patch}
    $CXX -std=c++23 -O2 -Wall -Wextra -I src/src \
      src/src/shell/calendar/lunar_calendar.cpp \
      ${./test-lunar-calendar.cpp} \
      -o test-lunar-calendar
    ./test-lunar-calendar
    touch $out
  '';
  agentStatus = pluginInputs.agent-status.packages.${system}.helper;
  agentHooks = pluginInputs.agent-status.packages.${system}.hooks;
  agentStatusCheck = pluginInputs.agent-status.checks.${system}.helper;
  gpuStatus = pluginInputs.gpu-status.lib.mkHelper { inherit pkgs umbriel; };
  gpuStatusCheck = pluginInputs.gpu-status.checks.${system}.helper;
  rsyncStatus = pluginInputs.rsync-status.packages.${system}.helper;
  rsyncStatusCheck = pluginInputs.rsync-status.checks.${system}.helper;
  rsyncStatusPluginCheck = pluginInputs.rsync-status.checks.${system}.plugin;
  rcloneStatus = pluginInputs.rclone-control.packages.${system}.helper;
  rcloneStatusCheck = pluginInputs.rclone-control.checks.${system}.helper;
  rcloneStatusPluginCheck = pluginInputs.rclone-control.checks.${system}.plugin;
  # The backup icon (plugins/backup-status): hidden without the helper, the percentage while
  # it runs, Run/Stop/Browse and the settings form call `backup-pool` (scripts/backup-pool.py,
  # tested with the M90aPro backup in the main flake: tests/test-backup-pool.py, m90-backup).
  backupStatusPluginCheck = pluginInputs.backup-status.checks.${system}.plugin;
  pluginsDir = pkgs.runCommand "noctalia-local-plugins" { } ''
    mkdir -p $out
    cp -r ${pluginInputs.agent-status.lib.pluginDir} $out/agent-status
    cp -r ${pluginInputs.always-on.lib.pluginDir} $out/always-on
    cp -r ${pluginInputs.backup-status.lib.pluginDir} $out/backup-status
    cp -r ${pluginInputs.gpu-status.lib.pluginDir} $out/gpu-status
    cp -r ${pluginInputs.kitty-control.lib.pluginDir} $out/kitty-control
    cp -r ${pluginInputs.rclone-control.lib.pluginDir} $out/rclone-status
    cp -r ${pluginInputs.rsync-status.lib.pluginDir} $out/rsync-status
  '';
  # Noctalia's own lint of every local plugin: a manifest it rejects leaves the plugin
  # silently missing from the bar (a menu panel once lacked max_height).  The
  # self-test first proves such a manifest fails.
  pluginLintCheck = pkgs.runCommand "noctalia-plugin-lint-checked" { } ''
    export HOME="$TMPDIR" XDG_CONFIG_HOME="$TMPDIR/config" XDG_STATE_HOME="$TMPDIR/state"
    cp -r ${pluginsDir}/backup-status bad && chmod -R u+w bad
    sed -i '/^max_height = /d' bad/plugin.toml
    if ${lib.getExe shell} plugins lint bad > bad.log 2>&1; then
      echo "self-test: a panel without max_height passed the lint"; exit 1
    fi
    grep -q 'requires max_height' bad.log
    ${lib.getExe shell} plugins lint ${pluginsDir}/*/
    touch $out
  '';
  # Every bar icon has its own neon colour (no two alike, neighbours clearly apart) and the
  # Pin/Unpin menu on right click.  The self-test first proves a repeated colour and one too
  # dark for the see-through bar both fail.
  barIconsCheck = pkgs.runCommand "noctalia-bar-icons-checked" {
    nativeBuildInputs = [ pkgs.python3 ];
  } ''
    icons() {
      python3 ${./check-bar-icons.py} --plugins ${pluginsDir} "$@"
    }
    sed 's/^color = "#4DA9FF"$/color = "#CCFF00"/' ${shellConfig} > repeated.toml
    sed 's/^color = "#4DA9FF"$/color = "#2A3BA0"/' ${shellConfig} > dark.toml
    if cmp -s repeated.toml ${shellConfig}; then
      echo "self-test: the volume colour was not found to change"; exit 1
    fi
    if icons --config repeated.toml 2> bad.log; then
      echo "self-test: a repeated colour was not caught"; exit 1
    fi
    grep -q "too alike" bad.log
    if icons --config dark.toml 2> dark.log; then
      echo "self-test: a colour too dark for the bar was not caught"; exit 1
    fi
    grep -q "too dark on the bar" dark.log
    icons --config ${shellConfig}
    touch $out
  '';
  # Every glyph name the plugins, helpers and bar settings use is one Noctalia knows (an
  # unknown one draws a skull).  The self-test first proves a bad name is caught.
  pluginGlyphsCheck = pkgs.runCommand "noctalia-plugin-glyphs-checked" {
    nativeBuildInputs = [ pkgs.python3 ];
  } ''
    glyphs() {
      python3 ${./check-plugin-glyphs.py} \
        --tabler ${shell}/share/noctalia/assets/fonts/tabler.json \
        --registry ${shell.src}/lib/render/text/glyph_registry.cpp "$@"
    }
    cp -r ${pluginsDir} plugins && chmod -R u+w plugins
    printf 'ui.button({ glyph = "rotate-ccw" })\n' >> plugins/rsync-status/panel.luau
    if glyphs --plugins plugins 2> bad.log; then
      echo "self-test: an unknown glyph was not caught"; exit 1
    fi
    grep -q "unknown glyph 'rotate-ccw'" bad.log
    glyphs --plugins ${pluginsDir} ${./settings.nix} \
      ${pluginInputs.gpu-status.lib.helperScript} \
      ${pluginInputs.rsync-status.lib.helperScript} \
      ${pluginInputs.rclone-control.lib.helperScript} \
      ${pluginInputs.agent-status.lib.helperScript}
    touch $out
  '';
  # The always-on cup (plugins/always-on): a click shows the new glyph at once, a failed
  # switch puts it back, a terminal `always-on off` reaches it through the status stream.
  alwaysOnPluginCheck = pluginInputs.always-on.checks.${system}.plugin;
  syncPython = pkgs.python3.withPackages (ps: [ ps.tomlkit ]);
  syncSettings = pkgs.writeShellApplication {
    name = "noctalia-sync-settings";
    runtimeInputs = [ suiteTools syncPython ];
    text = ''
      exec python3 ${./sync-settings.py} --config ${shellConfig} "$@"
    '';
  };
  syncSettingsCheck = pkgs.runCommand "noctalia-sync-settings-checked" {
    nativeBuildInputs = [ syncPython ];
  } ''
    python3 ${./test-sync-settings.py} ${./sync-settings.py}
    touch $out
  '';
  suiteTools = pkgs.symlinkJoin {
    name = "noctalia-suite-tools";
    paths = [ shell umbriel greeter pkgs.foot pkgs.wl-clipboard pkgs.libnotify displayCycle killWindow sgHolidaysUpdate gpuStatus rsyncStatus rcloneStatus ];
  };
  shellConfig = toml.generate "noctalia-suite.toml" (import ./settings.nix {
    themeName = theme.name;
    inherit (theme) wallpaper barAccents;
    launcherIcon = "${pkgs.nixos-icons}/share/icons/hicolor/scalable/apps/nix-snowflake-white.svg";
    killWindowCommand = lib.getExe killWindow;
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
    killWindowCommand = lib.getExe killWindow;
    agentCommand = "${lib.getExe agentStatus} run";
    lockCommand = lib.getExe lockAndBlank;
    inherit (theme) dark neon;
  });
  # Keep the suite defaults declarative and display preferences user-writable.
  # Includes are merged before this small entrypoint, in the order shown.
  userCompositorConfig = toml.generate "umbriel-user.toml" {
    include.files = [ compositorConfig ];
    include.optional.files = [ "~/.config/umbriel/outputs.toml" "~/.config/umbriel/overrides.toml" ];
  };
  userCompositorService = pkgs.writeText "umbriel-user-config.conf" ''
    [Service]
    ExecStart=
    ExecStart=${lib.getExe drmLauncher} ${lib.getExe umbriel} -c %h/.config/umbriel/config.toml
  '';
  greeterSettings = toml.generate "greeter-suite.toml" (import ./greeter-settings.nix { inherit theme; });
  validatedSuite = pkgs.runCommand "noctalia-suite-validated" { } ''
    test -f ${gpuSelectionCheck}
    test -f ${displayCycleCheck}
    test -f ${killWindowCheck}
    test -f ${sgHolidaysUpdateCheck}
    test -f ${lunarCalendarCheck}
    test -f ${gpuStatusCheck}
    test -f ${rsyncStatusCheck}
    test -f ${rsyncStatusPluginCheck}
    test -f ${rcloneStatusCheck}
    test -f ${rcloneStatusPluginCheck}
    test -f ${backupStatusPluginCheck}
    test -f ${pluginGlyphsCheck}
    test -f ${barIconsCheck}
    test -f ${pluginLintCheck}
    test -f ${alwaysOnPluginCheck}
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
  inherit suiteTools suiteSession suiteConfig validatedSuite greeterSettings sessionEntry syncSettings syncSettingsCheck;
  inherit agentStatus agentHooks agentStatusCheck gpuStatus gpuStatusCheck rsyncStatus rsyncStatusCheck rsyncStatusPluginCheck rcloneStatus rcloneStatusCheck rcloneStatusPluginCheck backupStatusPluginCheck pluginGlyphsCheck barIconsCheck pluginLintCheck displayCycle displayCycleCheck killWindow killWindowCheck sgHolidaysUpdate sgHolidaysUpdateCheck lunarCalendarCheck alwaysOnPluginCheck;
  inherit umbriel greeter drmLauncher gpuSelectionCheck userCompositorConfig userCompositorService lockPowerTest trayDrawerTest;
  sessionCompositorConfig = compositorConfig;
  userShellConfig = shellConfig;
  inherit theme;
}
