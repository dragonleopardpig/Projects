# Noctalia Suite desktop

This module integrates Noctalia Shell 5.4.1, Umbriel's pinned 2026-10-16
snapshot, and Noctalia Greeter 1.7.0. The flake locks their packages separately
from the host's nixpkgs. Every host offers Noctalia Suite and the previous
Hyprland + AGS desktop at login. M90aPro and CRUCIAL-SSD use Noctalia Greeter;
the other hosts retain SDDM.

The desktop provides the launcher, taskbar, centered active-window title,
right-side clock, clipboard history, notifications, tray, screenshots, media,
network, Bluetooth, power profiles, and monitor brightness controls. The
existing AGS desktop remains separate; its widgets are not required by the
Noctalia session. There are no installed trial or preview launchers.

## Integration

The shared `mkSystem` configuration imports the NixOS and Home Manager modules
and enables the suite for every host. Hosts that use Noctalia Greeter set:

```nix
desktop.noctaliaSuite.greeter.enable = true;
```

The greeter option replaces SDDM with greetd. The module registers the Umbriel
session/portal units and a **Hyprland + AGS** login entry. AGS, swaync,
hypridle, and hyprpolkitagent stay out of the Umbriel session. The previous
Hyprland configuration starts AGS as before. The session wrapper stops conflicting
services, and restores their previous active state when the session ends.
Upstream `start-umbriel` manages the session targets and environment cleanup.

Home Manager supplies `~/.config/umbriel/config.toml`, which includes the
immutable suite defaults followed by the optional writable
`~/.config/umbriel/outputs.toml`. A user service drop-in selects that entrypoint
on every login. The ASUS VP327Q has a saved scale of `1.25` by monitor identity.
The compositor, GTK, and X11 use the blue Hyprland logo pointer at size 24.
The pinned Xcursor theme is built from the extracted Hyprland logo graphics;
Adwaita supplies the text, resize, and other semantic cursor shapes.
Noctalia's palette/config files live under `~/.config/noctalia-suite/noctalia`;
its GUI overrides and encrypted data use the separate `noctalia-suite` state
and data profiles. The Secret Service provides the storage key.

On activation, the settings sync removes only saved `bar.main.start`, `center`
and `end` overrides so the Nix-defined widget order takes effect. GUI appearance
choices, including bar opacity, and per-monitor settings persist across rebuilds.
The sync runs after Home Manager links the new configuration.

Tray context menus temporarily place their bar on the overlay layer and retain
exclusive keyboard focus. Menus stay above application windows while moving
through menu items or across their edges. Closing the menu restores the bar's
configured layer and keyboard mode, including its normal fullscreen behavior.

## Bar icons: colours and Pin / Unpin

Every bar icon has its own neon colour (`theme.nix` `barAccents`, assigned in
`settings.nix`): no two are alike, and neighbours differ clearly. Each one
reads at 4.5:1 or better even with the bar at 60% opacity over a bright
wallpaper. The `barIcons` check measures all three (CIEDE2000 and WCAG
contrast) and fails the build on a repeat or a colour too dark for the bar.
The power button stays white. A plugin icon changes colour only for a failure
(red), or the AI widget while it waits for an answer.

**Right click any icon** for Noctalia's native menu (the tray's look) with
what the icon can do, then **Unpin from bar**: **Open …** (what a click does),
the icon's own right-click action (built-in icons, labelled as in the settings'
action picker), and the entries its plugin declares in `plugin.toml`
(`menu = [{ label, action }]`). The tooltip steps aside while the menu is open.

| Icon | Its menu, before Unpin |
|---|---|
| Volume | Open Volume, Toggle mute |
| Network | Open Network, Toggle network connection |
| Bluetooth | Open Bluetooth, Toggle Bluetooth |
| Notifications | Open Notifications, Toggle Do Not Disturb |
| Clock, Weather, … | Open Clock, Open Weather, … |
| Backup | Open Backup Status, Back up now, Stop backup, Browse backups, Show log |
| rsync | Open Rsync Status, Sync now, Show log |
| rclone | Open Rclone Status, Open rclone GUI |
| GPU | Display settings, Arrange displays |
| Always-on | Always-on on / off |
| AI agent | Show / hide the agent |

An unpinned icon moves into the tray's **down-arrow drawer**, beside the
unpinned tray icons and in its own colour. There a click does what the icon
did on the bar, and a right click opens the same menu, every entry included,
ending with **Pin to bar** while the drawer stays open. The down arrow shows whenever something is unpinned.
Noctalia's drawer and menus only know tray icons, so
`tray-drawer-unpinned-widgets.patch` adds the bar icons to them;
`nix run path:./noctalia#check-tray-drawer` clicks through it all on a private
headless desktop. The tray's items and the taskbar's apps keep their own
Pin/Unpin.

Unpinning saves `widget.<icon>.enabled = false` in the GUI settings
(`~/.local/state/noctalia-suite/noctalia/settings.toml`), so it survives
restarts and rebuilds. From a terminal:
`noctalia msg config-set widget.clock.enabled true`.

## Desktop agent

The **AI** widget beside the workspaces toggles the same Antigravity scratchpad
as **Super+C**. It shows **Working**, **Waiting** (a question needs an answer),
**Done** or **Error**, in its own colour (Waiting and Error stand out). The agent retains fully
automatic tool permissions. **Super+Shift+C** detaches its window as before.

Antigravity's global lifecycle hooks in `~/.gemini/config/hooks.json` call
`~/.local/bin/noctalia-agent-status`. The bridge handles simultaneous conversations
and detects exited processes using PID plus process start time. Status files live
under `$XDG_RUNTIME_DIR/noctalia-agent`, contain only lifecycle/workspace metadata,
and never store prompts, tool arguments or transcripts. A completed or interrupted
session remains visible for ten minutes after its process exits. Restart an
already-running agent to load newly installed hooks.

The Bash `rebuild` helper preserves the rebuild's failure code even through `tee`
and an optional agent handoff. Its pipeline option is local to the function;
accepting the existing handoff prompt launches the agent with automatic permissions.
Regression checks can be run with `bash scripts/test-rebuild-agent.sh` from the
NixOS directory, and the status bridge is included in the Suite flake checks.

## Appearance and scaling

The official Emacs template is enabled and generates `noctalia-theme.el` in
Emacs's themes directory. `Projects/emacs/noctalia.el` loads it after startup;
the template uses the Emacs server to reload colors when the palette changes.
F4 remains available for manually selecting the existing light/dark themes.

[OLO-Neon](theme/README.md) uses teal control fills with dark text, mint/cyan
secondary colors, and magenta window outlines and orbital wallpaper curves.
Inter is the UI font; Foot uses JetBrains Mono. The active task title occupies
the bar's center, with date and time on the right. The bar meets the top edge.

Umbriel uses dwindle by default. Window opening, closing, and workspace changes
pick a shader transition using a stable random value for each transition.
Noctalia chooses a random image from `~/Pictures/Wallpapers` every minute and
randomizes its wallpaper transition. The existing Home Manager daily timer
downloads Bing's image and NASA APOD into that folder. The OLO wallpaper remains
the fallback when the folder is empty.

The sky-blue NixOS snowflake opens the native launcher, also bound to
**Super+Space**. Its full-screen, eight-column icon grid starts with all
applications alphabetically, with search above the grid, categories, recent
apps and optional pins. Click
an app or search and press Enter; Escape or clicking outside closes it. This
preserves the AGS app-drawer workflow within Noctalia's own themed panel.
The local launcher patch exposes `shell.launcher.fullscreen`, using the native
panel fill sizing on both axes. It respects the output's reserved bar space,
uses larger icons, and keeps search, category browsing and keyboard navigation.

Native-resolution Xwayland and XSETTINGS keep X11 applications sharp at
fractional display scales. At 4K/125%, X11 sees 3840x2160 with 120-DPI fonts,
rather than an enlarged 3072x1728 framebuffer. This matches the previous
Hyprland force-zero-scaling behavior. Changing this option requires a new login.
WinApps' Windows desktop scale is 125% for its next viewer connection.
Under Umbriel, WinApps maps its viewer normally and then applies compositor
fullscreen. This avoids the pinned compositor's initial X11 fullscreen path,
which can report a visible viewer while rendering only wallpaper. Opening
Windows again switches to and focuses the existing connection.

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

The build checks Noctalia/Umbriel/Foot configs, GPU-selection fixtures and
preservation of GUI preferences during settings sync. The
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
