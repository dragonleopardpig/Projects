# ALWAYS-ON MODE, switched by hand: `always-on on`, `always-on off`, `always-on` (status).
#
# Why (user, 2026-11-02): "setup this host as non-shutdown host for me to access trident and
# Kraken OS claude session chat remotely ... my intention is to leave it on after office hour,
# during office hour, may shutdown to switch to Windows session, any toggle to do this?"
# Remote Control needs no open port -- the sessions reach out over HTTPS -- but each `claude`
# process must keep running, so after hours the machine must not sleep or be switched off by
# accident.
#
# ON:  the lid (on battery too), a brushed power key -- on this Predator it sits in the
#      keyboard's top row -- the suspend and hibernate keys and an idle timeout are all ignored,
#      and systemd-sleep refuses every suspend and hibernate, so a menu's "Suspend" or
#      `systemctl suspend` fails instead of freezing the sessions.
# OFF: the laptop as configuration.nix has it -- the power key powers off, the lid on battery
#      suspends (on mains it is ignored either way).
# Either way a DELIBERATE shutdown or reboot -- the menu, `systemctl poweroff`, rebooting into
# Windows, or holding the power key until the firmware cuts it -- works as always.
#
# How: runtime drop-ins in /run/systemd/{logind,sleep}.conf.d, then `systemctl reload
# systemd-logind` (logind is restartIfChanged = false: a restart under Wayland pulls the DRM and
# input handles from the running session; a reload does not).  The choice is kept in
# /var/lib/always-on/state and put back at every boot, before logind starts; with no state yet
# the mode is off.
{ lib, pkgs, ... }:
let
  logindDropIn = pkgs.writeText "always-on-logind.conf" ''
    [Login]
    HandleLidSwitch=ignore
    HandleLidSwitchDocked=ignore
    HandleLidSwitchExternalPower=ignore
    HandlePowerKey=ignore
    HandleSuspendKey=ignore
    HandleHibernateKey=ignore
    IdleAction=ignore
  '';
  sleepDropIn = pkgs.writeText "always-on-sleep.conf" ''
    [Sleep]
    AllowSuspend=no
    AllowHibernation=no
    AllowHybridSleep=no
    AllowSuspendThenHibernate=no
  '';
  path = lib.makeBinPath [ pkgs.coreutils pkgs.systemd ];
  state = "/var/lib/always-on/state";
  logindFile = "/run/systemd/logind.conf.d/50-always-on.conf";
  sleepFile = "/run/systemd/sleep.conf.d/50-always-on.conf";

  # (as root) the drop-ins in place for "on", gone for "off"; logind told if it is running
  apply = pkgs.writeShellScript "always-on-apply" ''
    set -eu
    export PATH=${path}
    mode=$(cat ${state} 2>/dev/null || echo off)
    if [ "$mode" = on ]; then
      install -D -m 0644 ${logindDropIn} ${logindFile}
      install -D -m 0644 ${sleepDropIn} ${sleepFile}
    else
      rm -f ${logindFile} ${sleepFile}
    fi
    # (--no-block: run as always-on.service, ordered before logind, a waiting reload would wait
    # for this very service to finish -- each blocking the other)
    if systemctl is-active -q systemd-logind.service; then
      systemctl --no-block reload systemd-logind.service
    fi
  '';

  always-on = pkgs.writeShellScriptBin "always-on" ''
    set -eu
    export PATH=${path}:/run/wrappers/bin
    case "''${1:-status}" in
      on|off)
        if [ "$(id -u)" -ne 0 ]; then exec sudo "$0" "$1"; fi
        mkdir -p "$(dirname ${state})"
        echo "$1" > ${state}
        ${apply}
        exec "$0" status
        ;;
      status)
        mode=$(cat ${state} 2>/dev/null || echo off)
        key=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
          org.freedesktop.login1.Manager HandlePowerKey | cut -d'"' -f2)
        lid=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
          org.freedesktop.login1.Manager HandleLidSwitch | cut -d'"' -f2)
        can=$(busctl call org.freedesktop.login1 /org/freedesktop/login1 \
          org.freedesktop.login1.Manager CanSuspend | cut -d'"' -f2)
        if [ "$mode" = on ]; then
          echo "always-on: ON -- stays up for remote sessions; shut down from the menu or"
          echo "  'systemctl poweroff' (power key, lid, suspend keys and idle are ignored)"
        else
          echo "always-on: OFF -- the laptop as usual: the power key powers off, the lid on"
          echo "  battery suspends"
        fi
        echo "  live: power key=$key, lid=$lid, can suspend=$can"
        ;;
      *)
        echo "usage: always-on [on|off|status]" >&2
        exit 2
        ;;
    esac
  '';
in
{
  environment.systemPackages = [ always-on ];

  # Put the last choice back at boot, before logind reads its configuration.
  systemd.services.always-on = {
    description = "Always-on mode, as last switched (always-on on|off)";
    wantedBy = [ "multi-user.target" ];
    before = [ "systemd-logind.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = apply;
    };
  };
}
