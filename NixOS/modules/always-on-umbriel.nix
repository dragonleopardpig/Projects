# ALWAYS-ON MODE UNDER UMBRIEL -- the Noctalia session (asked 2026-11-05: "please redo for
# Umbriel"). Under Hyprland the night look (home.nix: ~/.local/bin/night-look -- locked on pure
# black, the monitor's brightness and contrast taken to 0 over DDC/CI, its signal KEPT) hung on
# hypridle's timers, and the AGS bar's tea cup switched the mode. Under umbriel hypridle and AGS
# do not run (noctalia/suite/nixos-module.nix), and Noctalia's own idle lock shows its lock screen
# over the wallpaper. So, in always-on mode only:
#
#   * IDLE: swayidle (umbriel speaks ext-idle-notify) brings on the night look after 15 minutes
#     -- swaylock black (umbriel speaks ext-session-lock) and dimmed -- and puts the monitor back on
#     any input; Noctalia's own idle lock is switched off for as long as the mode is on, so the two
#     never race for the lock. Out of always-on mode Noctalia's idle is as configured.
#   * THE BAR'S CUP: a local Noctalia plugin (noctalia/suite/plugins/always-on): either click
#     runs `always-on-toggle`; its glyph a cup when the mode is off, an infinity when on. It
#     follows `always-on-status-watch` below, so `always-on on` typed in a terminal shows too.
#     (It was a Custom Button until 2026-11-20, its glyph set by config-set: every change of
#     that config rebuilt the button, so it vanished and came back on each click.)
#   * F1 / Mod+L: the suite's lock-and-blank goes to the night look in always-on mode
#     (noctalia/suite/default.nix) -- a monitor powered off drops its signal, which is what the
#     night look exists to avoid.
#
# The watcher and the status stream follow the logind drop-in: woken by inotify the moment it
# appears or goes; every 5 s anyway, as a fallback.
{ lib, pkgs, ... }:
let
  dropin = "/run/systemd/logind.conf.d/50-always-on.conf";
  idleUnit = "always-on-night-idle";
  userPath = [ "/run/wrappers" "/etc/profiles/per-user/thinky" "/run/current-system/sw" ];

  toggle = pkgs.writeShellScriptBin "always-on-toggle" ''
    # (always-on re-runs itself under sudo, which asks no password here)
    if [ -e ${dropin} ]; then
      exec /run/current-system/sw/bin/always-on off
    fi
    exec /run/current-system/sw/bin/always-on on
  '';

  # (exit 0 = an event, 2 = the time passed; 1 = no folder or no inotify: poll instead)
  waitForChange = seconds: ''
    ${pkgs.inotify-tools}/bin/inotifywait -qq -t ${toString seconds} \
      -e create -e delete -e moved_to -e moved_from ${builtins.dirOf dropin} 2>/dev/null
    [ "$?" -ne 1 ] || sleep 5
  '';

  # For the bar's cup: {"on": true|false} at once, then on every change of the mode.
  statusWatch = pkgs.writeShellScriptBin "always-on-status-watch" ''
    set -u
    was=""
    while true; do
      now=false
      [ -e ${dropin} ] && now=true
      if [ "$now" != "$was" ]; then
        # (the bar gone: nobody reads any more)
        printf '{"on": %s}\n' "$now" || exit 0
        was=$now
      fi
      ${waitForChange 30}
    done
  '';

  watch = pkgs.writeShellScript "always-on-umbriel-watch" ''
    set -u
    was=""
    while true; do
      now=off
      [ -e ${dropin} ] && now=on
      if [ "$now" != "$was" ]; then
        if [ "$now" = on ]; then
          noctalia msg config-set idle.behavior.lock.enabled false >/dev/null 2>&1 || true
          systemctl --user start ${idleUnit}.service || true
        else
          systemctl --user stop ${idleUnit}.service || true
          noctalia msg config-set idle.behavior.lock.enabled true >/dev/null 2>&1 || true
          # (anything left dimmed put back)
          "$HOME/.local/bin/night-look" off || true
        fi
        was=$now
      fi
      ${waitForChange 5}
    done
  '';
in
{
  environment.systemPackages = [ toggle statusWatch pkgs.swayidle ];

  systemd.user.services.always-on-umbriel = {
    description = "Always-on mode followed under umbriel: the night look on idle, the bar's cup";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    unitConfig.ConditionEnvironment = "XDG_CURRENT_DESKTOP=umbriel";
    path = userPath;
    serviceConfig = {
      ExecStart = watch;
      Restart = "always";
      RestartSec = 5;
    };
  };

  # Started and stopped by the watcher; never on its own.
  systemd.user.services.${idleUnit} = {
    description = "Always-on nights under umbriel: idle brings on the night look";
    unitConfig.ConditionEnvironment = "XDG_CURRENT_DESKTOP=umbriel";
    path = userPath;
    serviceConfig = {
      ExecStart = "${pkgs.swayidle}/bin/swayidle -w "
        + "timeout 900 '%h/.local/bin/night-look leave' "
        + "resume '%h/.local/bin/night-look off'";
      Restart = "on-failure";
    };
  };
}
