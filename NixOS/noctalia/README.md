# Noctalia bar trial

This is a separate, pinned Noctalia v5 project for the current Hyprland
desktop. It does not change `../home.nix`, the login autostart, or the
installed AGS bar. The trial keeps AGS running with only its bar hidden, so
its custom drawers and controls remain usable.

## Try it

From this directory, in a terminal inside Hyprland:

```sh
nix run path:. --accept-flake-config
```

Noctalia takes over the top bar while this command runs. Press **Ctrl+C** in
that terminal to close Noctalia and restore the AGS bar. The runner checks
that AGS is running before it starts. The Noctalia config and GUI state are
kept in a separate trial profile; they do not overwrite `~/.config/noctalia`.

If you are not in this directory, use
`nix run path:/home/thinky/Projects/NixOS/noctalia --accept-flake-config`.

Build and validate without launching the bar:

```sh
nix build path:.#validatedConfig --accept-flake-config --no-link
nix build path:. --accept-flake-config --no-link
```

## Feature map

The bar uses Noctalia's own layout: launcher, workspaces, and a running-app
taskbar on the left; clock in the center; weather and a compact control group
on the right. The system tray opens as a drawer. CPU/RAM/disk/temperature
details are in Noctalia Control Center's **System** tab. Failure and print
indicators appear only when they need attention.

| AGS feature | Noctalia trial |
| --- | --- |
| App drawer | Noctalia launcher; right-click its button for the AGS drawer |
| Hyprland workspaces and active window | Native workspace switcher and running-app taskbar |
| CPU, RAM, disk, CPU temperature | Native System tab in Noctalia Control Center |
| Failed systemd units | Local plugin; hidden when there are none |
| MPRIS | Native media widget |
| Network, Bluetooth, volume, battery, power profile | Native widgets in one control group |
| Keyboard lock state and privacy | Native status widgets, hidden when inactive |
| System tray | Native drawer |
| Singapore weather and forecast | Native widget; click opens Noctalia's Weather tab, which can show its cached forecast during a network outage |
| Clock, lunar calendar, public and school holidays | Click clock for Noctalia's calendar; right-click for the existing AGS lunar/holiday calendar |
| Notifications and Do Not Disturb | Local plugin controls the existing swaync service |
| Idle inhibitor and always-on remote mode | Local plugin: left click toggles hypridle, right click toggles always-on |
| Print queue | Local plugin; hidden when empty, click opens AGS Printers & Scanners |
| Noctalia Control Center | Adjustments button opens Home; status widgets open their own tabs |
| AGS Control Center | Tool button opens the original panel for display scale, mouse, WinApps, printers and scanners |
| Volume, microphone, brightness, display scale, mouse speed, WinApps, Bluetooth, power profile, printers, scanners | Existing AGS Control Center remains available; Noctalia also offers its native controls where supported |
| Power menu | Left click power button opens wlogout; right click opens Noctalia's session menu |

The Hyprland shortcuts, display-cycle scripts, screenshot controls, swaync
service, and other desktop services remain those of the current system.

Control Center opens near a clicked bar widget. Clicking Network opens its
Network tab; the adjustments button opens Home. The `C` and `N` lock-key indicators mean
Caps Lock and Num Lock. They are status indicators, so they appear only while
the corresponding key is active and do not toggle on click. The weather widget
opens Noctalia's Weather tab and can display its last cached forecast while
the weather service is unreachable.

## Files

- `flake.nix`: pinned Noctalia package, isolated profile, validation, and
  reversible launcher.
- `settings.nix`: bar layout and built-in widgets.
- `plugin/ags_bridge/`: the four status/controls missing from Noctalia's
  built-in widgets.

## Installed components

This project builds and runs **Noctalia Shell** for the trial. The desktop
still runs **Hyprland** as its compositor and **SDDM** as its login manager.
**Umbriel**, Noctalia's separate compositor, and **Noctalia Greeter** are not
installed. The only enabled Noctalia plugin is this project's local
`thinky/ags_bridge`; the upstream plugin catalogs have not been enabled.

Noctalia's GUI saves trial overrides under
`~/.local/state/noctalia-native-trial/noctalia/settings.toml`. The earlier
AGS-like trial profile remains under `~/.local/state/noctalia-trial/`.
If an edited setting
seems to override `settings.nix`, remove that override while Noctalia is
stopped. The upstream source used for API review is cloned separately at
`~/Projects/noctalia-upstream`; this project builds from the revision pinned
in `flake.lock`.
