# NixOS Configuration

Flake-based NixOS configuration managing two machines from a single codebase. Both hosts share identical `configuration.nix` and `home.nix` files, with only hardware-specific differences isolated per host.

## Hosts

| | X299 (Desktop) | M90aPro (Laptop) |
|---|---|---|
| GPU | NVIDIA RTX 4070 (single GPU) | Intel iGPU + NVIDIA (Prime Sync) |
| GPU config | `hosts/X299/nvidia.nix` | `hosts/M90aPro/nvidia-prime.nix` |
| CUDA | Enabled with IDE symlink | Not configured |
| Extra hardware | Euresys CoaxLink frame grabber | - |

See also: [Euresys eGrabber on NixOS setup guide](modules/egrabber/EGRABBER-NIXOS-GUIDE.md) for the X299 frame grabber configuration.

## Structure

```
NixOS/
|-- flake.nix              # Flake: defines both hosts, inputs
|-- configuration.nix      # Shared system config (both hosts)
|-- home.nix               # Shared home-manager config (both hosts)
|-- rebuild.sh             # Helper script for rebuilding
|-- assets/                # Plymouth logo, wallpaper, user face
|-- hosts/
|   |-- X299/
|   |   |-- default.nix              # hostname + imports
|   |   |-- hardware-configuration.nix
|   |   +-- nvidia.nix               # Single GPU driver
|   +-- M90aPro/
|       |-- default.nix              # hostname + imports
|       |-- hardware-configuration.nix
|       +-- nvidia-prime.nix         # Dual GPU (Intel + NVIDIA)
|-- modules/
|   +-- egrabber/
|       |-- egrabber.nix             # Euresys frame grabber
|       +-- EGRABBER-NIXOS-GUIDE.md
+-- .gitignore
```

## Flake Inputs

| Input | Purpose |
|---|---|
| `nixpkgs` | nixos-unstable channel |
| `home-manager` | User environment management (as NixOS module) |
| `hyprland` | Wayland compositor |
| `grub2-themes` | GRUB bootloader theming |
| `disko` | Declarative disk partitioning |
| `walker` | Application launcher |

## What's Configured

### System (configuration.nix)

**Boot**: Latest kernel, GRUB with grub2-themes (stylish), Plymouth splash screen (rainbow Nix snowflake)

**Desktop**: Hyprland compositor with UWSM session manager, SDDM login screen (`sddm-astronaut-theme`, random variant per boot via `sddm-random-theme.service` — pulls one of the 10 bundled `Themes/*.conf` and rewrites `metadata.desktop` in `/var/lib/sddm/themes/` before SDDM starts), Xwayland enabled

**Audio**: PipeWire (ALSA + PulseAudio compatible)

**Bluetooth**: Enabled with Blueman, experimental features, fast connectable

**Input method**: Fcitx5 with RIME for Chinese input

**Hardware support**:
- DDC/CI brightness control via ddcci-driver kernel module (with systemd auto-setup service)
- Logitech wireless devices via Solaar (with USB reset service for G502X scroll fix)
- GVFS and UDisks2 for file manager trash/mount support
- CUPS printing

**Installed packages** (highlights):
- **Dev**: Emacs (pgtk), Node.js 24, devenv, claude-code, LSP servers (nix, yaml, json, bash, markdown)
- **Media**: GIMP, Inkscape, FFmpeg, ImageMagick
- **Office**: TexLive (full), OnlyOffice, Hugo
- **CAD**: LibreCAD, FreeCAD
- **Networking**: ProtonVPN, Remmina, nmap, mtr
- **Monitoring**: Mission Center, sysstat, lm_sensors, iotop
- **Wayland tools**: swww, grim, slurp, satty, wl-clipboard
- **Fonts**: Nerd Fonts (Ubuntu, Caskaydia Cove), Noto CJK

### User Environment (home.nix)

**Shell**: Bash with Starship prompt, custom aliases (`ls` = eza, `rebuild` = rebuild.sh, `gc` = git commit)

**Terminal**: Kitty (JetBrainsMono Nerd Font, blur, 80% opacity)

**File manager**: Nemo (default for directories), Yazi (terminal)

**Theming**: Orchis-Dark GTK theme, Tela-circle icons, Adwaita cursor, KvArcDark Kvantum theme

**Hyprland keybindings**:
- `Super+Q` Kitty, `Super+F` Firefox, `Super+E` Emacs, `Super+N` Nemo
- `Super+P` ProtonVPN (XWayland), `Super+W` Walker launcher
- Volume/brightness on XF86 keys and F5/F6
- Screenshots via `grim + slurp + swappy`

**Hyprland autostart**: pyprland, ProtonVPN, swww wallpaper daemon, Solaar, HyprPolkitAgent

**Waybar**: Cyberpunk-themed bar with workspaces, system monitors (cpu/mem/disk/temp), backlight & volume sliders, bluetooth, network, battery, idle inhibitor, keyboard state, language, tray, weather (wttr.in/Singapore), clock, swaync notification toggle, and wlogout power menu. Click handlers use `~/.local/bin/toggle-app` so a second click closes the spawned window.

**Services**:
- hypridle: Auto-lock at 15min, DPMS off at 20min
- hyprlock: Lock screen
- udiskie: Auto-mount removable drives
- Wallpaper timer: Daily images from Bing and NASA APOD (still thumbnails on video days; no video downloads)

**Helper scripts** (installed to `~/.local/bin`):
- `sioyek`: Uses native Wayland when its display socket is available, otherwise X11;
  respects an explicit `QT_QPA_PLATFORM` override.
- `sioyek-xcb`: Explicitly selects X11/XWayland for troubleshooting.
- `screenshot`: grim + slurp + swappy pipeline
- `brightness-ctl`: Unified brightness (intel_backlight or ddcci fallback)
- `wallpaper-of-the-day`: Fetches Bing daily + NASA APOD images, using only still thumbnails for videos

**Desktop entries**: eGrabber Studio (Qt6 XWayland wrapper), Sioyek PDF viewer

## Usage

### Rebuild

```bash
# Auto-detect hostname, switch to new config
./rebuild.sh

# Explicit host and operation
./rebuild.sh switch X299
./rebuild.sh test M90aPro
./rebuild.sh boot X299

# Update flake inputs then rebuild
./rebuild.sh update

# Garbage collect old generations
./rebuild.sh clean
```

Or manually:

```bash
sudo nixos-rebuild switch --flake .#X299
sudo nixos-rebuild switch --flake .#M90aPro
```

### Making Changes

**Both hosts** (most common): Edit `configuration.nix` (system) or `home.nix` (user).

**One host only**: Edit files in `hosts/X299/` or `hosts/M90aPro/`.

### Initial Setup on a New Machine

1. Generate hardware config:
   ```bash
   sudo nixos-generate-config --show-hardware-config > hosts/<HOSTNAME>/hardware-configuration.nix
   ```

2. For dual-GPU laptops, find PCI bus IDs and update `nvidia-prime.nix`:
   ```bash
   lspci | grep VGA
   ```

## Scramble Offline Reading

- `~/Scramble Private` is the only Scramble working folder and Nemo bookmark.
  It is a writable offline directory, not a cloud mount. References, attachments,
  and existing private files synchronize through the original rclone-crypt key.
- `~/Scramble Cloud` is a separate read-only mount under Nemo's Devices for
  browsing the decrypted private cloud folder with the same layout as the
  offline folder. The website retains the encrypted storage and public originals.
- The first launch after upgrading backs up and consolidates the old folders,
  verifies encrypted cloud copies, and then enables one private sync timer.
  Old public cloud originals remain available for rollback until all hosts are updated.
- Sioyek redirects old document paths to the consolidated local files and updates
  matching history entries. The project attachment symlink is migrated too.
- Check progress with `scramble-sync-status` or
  `journalctl --user -u scramble-consolidate.service -f`.
- See [Scramble setup and migration](docs/scramble-sync.md) for recovery backups
  and key-backup requirements.

## Sioyek File Picker

- File matching uses case-insensitive, contiguous filename fragments in any
  order. For example, `op en` or `en op` finds `Optical Engineering`, while `fund`
  matches `Fundamentals` but not scattered `f...u...n...d` letters. Every fragment
  must match. PDF titles/metadata and parent paths are not searched.
- `Ctrl+O` opens the current document's folder; `Ctrl+Shift+O` opens the configured
  default folder. With no document open, `Ctrl+O` uses the default folder too.
- `/` enters the highlighted folder, including a fragment match.
- `Ctrl+N` and `Ctrl+P` move down and up through matching entries.
- `Shift+O` opens recent documents and also supports `Ctrl+N` / `Ctrl+P`, including
  while filtering the list.
- Backspace deletes typed text normally. At the end of a folder path with no text
  selected, it goes up one folder. Other text-editing shortcuts, including Delete
  and `Ctrl+Backspace`, remain available.

## WinApps

`X299-SSD` installs WinApps from the local fork at `~/Projects/winapps`, with
the upstream graphical launcher. The Windows VM uses rootless Podman, initially
four vCPUs and 4 GiB RAM, and a
64 GiB sparse disk. Its container image is pinned by digest. The browser console
and RDP ports listen on localhost only, at `http://127.0.0.1:8006` and port 3389.

Start Windows with `systemctl --user start winapps-vm`, then open its desktop
with `winapps windows`. Stop it with `systemctl --user stop winapps-vm`.
`winapps-vm ps` shows the container state; `winapps-vm logs --tail=50` shows its
installation output. WinApps pauses Windows after five minutes without an
application session and resumes it when an app is opened.

Change CPU and RAM together through **AGS Control Center → WinApps →
Manage…**, the **WinApps** app in AGS/Walker, or
`winapps-settings set 8 --cpus 6` (8 GiB RAM and 6 vCPUs).
The same dialog has **Fullscreen Windows desktop** and **Open Windows**. Opening
reuses and focuses an existing full-desktop viewer, or starts Windows if needed;
it does not create a second viewer when one is already open. The fullscreen
checkbox and the other inputs are read directly when **Open Windows** is clicked;
no save step is required. These launch-time choices do not overwrite defaults.
**Set as default** remembers the current values for future control windows and
launches through the separate Windows shortcut, without opening Windows.
If Windows is already running,
opening or reconnecting its viewer does not change its CPU/RAM allocation.
The manager shows the running allocation separately from defaults and flags
launch-time CPU/RAM requests that cannot be applied to a running VM: save your
work, use **Shut down all WinApps**, then **Open Windows** with the desired inputs
still selected. Windows' Restart does not apply them.
Fullscreen covers AGS
only on Windows' workspace; other workspaces keep their normal bar. The bar
stays on the top layer rather than the overlay layer, and host workspace
shortcuts remain available while Windows is fullscreen. Uncheck fullscreen and
use **Open Windows** to restore windowed mode without disconnecting or restarting
Windows. CLI equivalents: `winapps-settings set --fullscreen on` (or `off`) and
`winapps-settings windows`.
Opening waits for the viewer to actually appear before reporting success. Startup
progress and launch failures stay in the manager. Private diagnostic logs are
stored at `~/.local/state/winapps/windows-launch.log` and
`~/.local/share/winapps/freerdp-windows.log`.
For headless GUI checks, use an explicitly unused high-numbered Xvfb display,
not automatic display selection, which can disturb Xwayland's display socket.
Use `winapps-settings set --cpus 6` to change only CPU allocation.
`winapps-settings status` shows the running allocation and saved defaults. The
defaults are stored in `~/.config/winapps/memory.env` and survive NixOS rebuilds.
Existing RAM-only settings are preserved, with CPU allocation defaulting to four;
`winapps-memory` remains a compatible command alias. All Office
apps share this one VM allocation. Setting defaults never stops Windows: save your Windows
work, choose **Start → Power → Shut down**, and launch Windows again to apply it.
Closing the viewer, pausing the VM, or using Windows' Restart does not apply it.
The same dialog also sets **Windows desktop scale (%)**. Windows' own Display
Scale control is restricted in RDP sessions, so the client requests this scale
on the next full-desktop connection. Close the viewer and reopen **Windows** to
apply scaling without shutting down the VM; some apps may need reopening.
`winapps-settings set --desktop-scale 125` saves 125% without changing RAM/CPU.
This does not alter NixOS scaling or the separate Office RemoteApp scaling.
The control leaves at least 4 GiB RAM for NixOS, limits vCPUs to the host's
available logical CPU count, and warns about memory pressure or assigning nearly
all CPUs. vCPUs share host CPU time; they do not pin or reserve physical cores.
Use **Shut down all WinApps** in the same dialog, or
`winapps-settings shutdown` in an interactive terminal, to request a normal
Windows shutdown. The graphical action shows its warning, progress, elapsed
waiting time, and completion or error message inside the same WinApps window,
without confirmation/completion popups or closing the manager. The CLI asks for
confirmation in the terminal. This closes background Windows apps and releases the VM's RAM once
shutdown completes. Save Windows/Office work first; answer any Windows prompts
in the viewer. A paused VM is resumed first. The controller waits up to three
minutes, but never force-stops Windows on timeout or deletes its disk. If updates
or unsaved-work prompts block shutdown, resolve them inside Windows. Viewer
clients are closed only after Windows stops. Closing the viewer alone does not
shut down Windows. This action does not save pending edits in the settings form.
The fork tracks the actual FreeRDP child under Podman (not its wrapper),
including children created by Podman's worker threads, so active viewers are
not incorrectly treated as idle and auto-paused. It also uses Compose `up`
for stopped containers so changed RAM settings are picked up.
After editing the fork, run `nix flake update winapps` in `~/Projects/NixOS`
before rebuilding; no Git commit is needed to build local changes.

In the same **WinApps** app, click **Choose Windows apps…** to select
Windows Start-menu apps, including Microsoft Teams, for independent AGS/Walker
launchers. Click **Refresh from Windows** after installing an app; refreshing
briefly reconnects an existing Windows viewer without closing Windows apps.
Selected shortcuts are named **App name (Windows)**, so they remain distinct
from Linux alternatives. Unchecking removes only picker-managed Linux shortcuts;
it does not uninstall Windows software or remove existing Office launchers.
The picker uses Windows application IDs rather than version-specific MSIX paths,
so packaged-app updates do not invalidate their shortcuts. Not every Windows
app supports RemoteApp; use the full desktop for incompatible apps.

RDP uses 100% display scaling and starts at the current monitor's resolution.
The full Windows desktop also resizes its resolution with the client window.
Office RemoteApps float and use click-to-focus without compositor animations.
Their automatic maximize/fullscreen requests are ignored to avoid focus-driven
resize loops; use `Super+Shift+F` to maximize through Hyprland. Only the named
RemoteApp marker window is prevented from taking focus; untitled sign-in dialogs
remain usable. Opening another RemoteApp reconnects the shared
Windows session, which can briefly redraw the other Windows app windows.

Keyboard input uses scancodes rather than forced Unicode events so Windows
shortcuts such as `Ctrl+C`, `Ctrl+V`, and `Win+R` work normally. Clipboard
redirection is explicitly enabled in both directions. Use the Windows input
method for non-English typing inside Windows; pasted Unicode text is supported.
The WinApps FreeRDP client is patched to restore individual physical modifier
keys on focus return, rather than marking both left and right modifiers down.
This prevents workspace switches with `Ctrl+Alt` held from leaving phantom
modifiers that consume letters such as `M` as client shortcuts. Reconnect the
viewer to load the patched client; Windows and its applications can stay running.
After changing RDP flags, reconnect the viewer without shutting down Windows.

Configuration is managed through `modules/winapps.nix` and written to
`~/.config/winapps/`. A generated Windows password is stored separately in
`~/.config/winapps/credentials.env`, with mode `0600`; it is not in the Nix store
or the repository. The Windows username is `thinky`. After installing apps in
Windows, run `winapps-setup --user --setupAllOfficiallySupportedApps` to register
supported app launchers and file associations. Existing generated launchers are
refreshed during Home Manager activation when the package changes, without
rescanning applications or interrupting Windows.

For the first installation, `systemctl --user start --no-block winapps-register`
waits for the Windows RDP port, then verifies app launching and shared-folder
access before registering available apps. It retries startup-related failures
up to five times, but stops if Windows rejects the login or certificate.
Check it with `systemctl --user status winapps-register` or
`journalctl --user -u winapps-register`. This does not install Microsoft Office;
the Office edition must match the user's license.

Microsoft Office is not included or automatically installed. Removing a Linux
app shortcut does not uninstall its Windows application; uninstall the program
inside Windows before removing its generated WinApps shortcuts.

### VM Storage

On `X299-SSD`, the 100 GiB ext4 partition labelled `Virtual Windows` is mounted
at `/mnt/winapps` by UUID `fe0516c1-a263-495f-b22d-ef205ead9203`.
The `winapps-storage` service verifies the mounted filesystem and creates
`/mnt/winapps/windows` with mode `0700`, owned by `thinky:users`.
Use that directory as the Windows container's `/storage` bind mount.

Check the mount with `findmnt /mnt/winapps` and initialization with
`systemctl status winapps-storage`. The WinApps commands and VM service verify
the mounted UUID before accessing storage. The partition is optional for boot;
if it is unavailable, startup fails instead of creating a VM on `/`.

## NVIDIA Notes

**X299**: Single NVIDIA GPU with modesetting, power management, and CUDA. An activation script creates `~/.local/share/cuda` symlink for IDE integration.

**M90aPro**: NVIDIA Prime Sync mode (both GPUs always on). To switch to Offload mode for better battery life, edit `hosts/M90aPro/nvidia-prime.nix` -- comment out `sync.enable` and uncomment the offload block.

## Important Notes

- Flake builds ignore `/etc/nixos/` entirely -- this directory is the single source of truth
- Timezone: Asia/Singapore
- State version: 25.11
- Unfree packages allowed, Nix flakes enabled, daily garbage collection (3 days retention)
- Weather API key must be placed at `~/.config/secrets/weather-api-key`
