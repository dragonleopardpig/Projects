# Noctalia Suite desktop

This module integrates Noctalia Shell 5.4.1, Umbriel's pinned 2026-10-16
snapshot, and Noctalia Greeter 1.7.0. The flake locks their packages separately
from the host's nixpkgs. The CRUCIAL-SSD configuration enables the suite and
greeter; Hyprland remains available as a login session.

The desktop provides the launcher, taskbar, centered active-window title,
right-side clock, clipboard history, notifications, tray, screenshots, media,
network, Bluetooth, power profiles, and monitor brightness controls. The
existing AGS desktop remains separate; its widgets are not required by the
Noctalia session. There are no installed trial or preview launchers.

## Integration

Add `inputs.noctalia-suite.nixosModules.suite` to a host and enable:

```nix
desktop.noctaliaSuite = {
  enable = true;
  greeter.enable = true;
};
home-manager.users.thinky.imports = [ inputs.noctalia-suite.homeManagerModules.suite ];
```

The greeter option replaces SDDM with greetd. The module registers the Umbriel
session/portal units and keeps AGS, swaync, hypridle, and hyprpolkitagent out of
its graphical session. The session wrapper stops already-running conflicting
services, and restores their previous active state when the session ends.
Upstream `start-umbriel` manages the session targets and environment cleanup.

Home Manager supplies `~/.config/umbriel/config.toml`, which includes the
immutable suite defaults followed by the optional writable
`~/.config/umbriel/outputs.toml`. A user service drop-in selects that entrypoint
on every login. The ASUS VP327Q has a saved scale of `1.25` by monitor identity.
Noctalia's palette/config files live under `~/.config/noctalia-suite/noctalia`;
its GUI overrides and encrypted data use the separate `noctalia-suite` state
and data profiles. The Secret Service provides the storage key.

## Appearance and scaling

[OLO-Neon](theme/README.md) uses teal control fills with dark text, mint/cyan
secondary colors, and magenta window outlines and orbital wallpaper curves.
Inter is the UI font; Foot uses JetBrains Mono. The active task title occupies
the bar's center, with date and time on the right.

Native-resolution Xwayland and XSETTINGS keep X11 applications sharp at
fractional display scales. At 4K/125%, X11 sees 3840x2160 with 120-DPI fonts,
rather than an enlarged 3072x1728 framebuffer. This matches the previous
Hyprland force-zero-scaling behavior. Changing this option requires a new login.
WinApps' Windows desktop scale is 125% for its next viewer connection.

## Hardware and locking

The native compositor and greeter share `noctalia-drm-launch`. It discovers
DRM cards with render nodes, prefers a card with connected displays, and uses
the firmware boot GPU to break ties. Other render-capable cards remain
available for their outputs. This excludes renderless simpledrm without fixed
GPU numbers, PCI addresses, or hostnames. Explicit `WLR_DRM_DEVICES` or
`WLR_RENDER_DRM_DEVICE` overrides are respected. NVIDIA's existing fbdev
workaround remains in the host configuration.

Brightness selects a kernel backlight for the relevant panel or DDC/CI for an
external display. [The shortcut reference](SHORTCUTS.md) documents display
switching and the familiar application/window shortcuts.

F1, Super+L, and Ctrl+Alt+L lock before powering monitors off. Noctalia waits
for an acknowledged safe lock frame. The helper holds a lid-switch inhibitor
while displays are dark. A local Umbriel patch restricts DPMS wake to keyboard
presses; pointer activity still resets idle timers. Automatic idle blanking is
disabled, while the 15-minute idle lock remains enabled.

The pinned Shell sends Umbriel actions using `cmd=action`; the pinned compositor
accepts `cmd=msg` with `arg`. A small Shell patch adapts that transport,
including targeted window actions, preserving the lock-frame acknowledgement
before requesting power-off. Review this patch when updating either input.

## Validation and diagnostics

From the `noctalia` directory:

```sh
nix flake check path:. --accept-flake-config
nix run path:.#check-lock --accept-flake-config
```

The build checks Noctalia/Umbriel/Foot configs and GPU-selection fixtures. The
lock/power check runs the real Shell, compositor and F1 helper on a headless
display, with private session/system buses and temporary state. It verifies
locking, power-off, mouse inactivity and keyboard wake while leaving the host
desktop alone.

Inspect the real session with `systemctl --user status umbriel`,
`journalctl --user -u umbriel -b`, and `umbriel outputs`. Preserve a working
NixOS generation when updating compositor or greeter integration.

References: [Shell on NixOS](https://docs.noctalia.dev/noctalia/getting-started/nixos/),
[Umbriel](https://docs.noctalia.dev/umbriel/),
[Greeter installation](https://docs.noctalia.dev/greeter/installation/).
