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

**Desktop**: Hyprland compositor with UWSM session manager, SDDM login screen (sddm-astronaut-theme, pixel_sakura variant), Xwayland enabled

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
- Wallpaper timer: Daily fetch from Bing and NASA APOD

**Helper scripts** (installed to `~/.local/bin`):
- `sioyek-xcb`: Forces Sioyek PDF viewer to use XWayland
- `screenshot`: grim + slurp + swappy pipeline
- `brightness-ctl`: Unified brightness (intel_backlight or ddcci fallback)
- `wallpaper-of-the-day`: Fetches Bing daily + NASA APOD wallpapers

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

## NVIDIA Notes

**X299**: Single NVIDIA GPU with modesetting, power management, and CUDA. An activation script creates `~/.local/share/cuda` symlink for IDE integration.

**M90aPro**: NVIDIA Prime Sync mode (both GPUs always on). To switch to Offload mode for better battery life, edit `hosts/M90aPro/nvidia-prime.nix` -- comment out `sync.enable` and uncomment the offload block.

## Important Notes

- Flake builds ignore `/etc/nixos/` entirely -- this directory is the single source of truth
- Timezone: Asia/Singapore
- State version: 25.11
- Unfree packages allowed, Nix flakes enabled, daily garbage collection (3 days retention)
- Weather API key must be placed at `~/.config/secrets/weather-api-key`
