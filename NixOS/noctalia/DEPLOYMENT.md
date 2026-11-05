# Desktop deployment

The installed Noctalia Suite consists of Shell, Umbriel and Greeter, with Strata
provided by the CRUCIAL-SSD host. The hostname is **CRUCIAL-SSD**;
`Crucial-SSD` remains a compatible flake alias, and the old local hostname
`X299-SSD` remains resolvable.

The AGS bridge trial and nested desktop/greeter previews are retired. The NixOS
module installs only the native suite tools and login session. Configuration
validation and the isolated lock/power regression remain development tools.

## Current deployment

Generation **45** is installed for the next boot, with the retired launchers
absent from its system packages:

```
/nix/store/jaicicaznwn6h5di0lxzr7jagigjs1mk-nixos-system-CRUCIAL-SSD-26.05.20260427.1c3fe55
```

The current source uses OLO-inspired teal control fills with dark text.
Magenta is reserved for window outlines, glow and wallpaper curves. Both
palette variants pass text-contrast checks; the dark primary pair is 11.6:1.
The palette and wallpaper are applied live.

Right-side bar controls use Fastfetch's Kitty colors (gold, sky blue, mint and
lavender), plus neon purple; the power button is white. The blue NixOS
snowflake and Super+Space open a wide native app grid with search, categories
and optional pins, replacing the AGS app-drawer workflow. These preferences
are applied live and saved for future logins.

The desktop's saved scale is 125%. Native-resolution Xwayland and XSETTINGS
are configured for sharp X11 rendering. An isolated 4K/125% session verified
3840x2160 XRandR resolution and 120-DPI fonts. This compositor option requires
a new login; reopen affected X11 applications afterward. WinApps' saved Windows
desktop scale is 125% for its next connection.

WinApps identifies the running compositor, switches to its viewer's workspace
and output, focuses it, and verifies visibility. Existing connections are
reused. The updated GUI's Open Windows button was verified with the viewer
visible and focused. Umbriel launches map the viewer normally before applying
compositor fullscreen: mapping FreeRDP with `/f` could leave only wallpaper on
screen despite the viewer being reported as visible. The corrected GUI was
verified with both a fresh connection and reuse from another workspace, with
Windows visibly rendered fullscreen. Eight launcher regression checks pass.

F1 locks before turning monitors off, with keyboard-only wake. The full
headless Shell/lock-helper/compositor test passed. A separate physical HDMI
power-off/restoration check through Noctalia also passed. The Shell transport
patch is required for the pinned Umbriel IPC format.

Firmware simpledrm was incorrectly selected during the first physical login.
The runtime DRM selector now excludes cards without render nodes, selecting
real GPU rendering for both the desktop and greeter.

## Build and boot

```sh
cd ~/Projects/NixOS
./rebuild.sh boot CRUCIAL-SSD
```

`boot` installs the next-boot generation without restarting the active desktop.
The helper uses a `path:` flake so local files are included before committing.
Select **Noctalia Suite** at the greeter. Hyprland is still available.

## Rollback

Generation **35** is the confirmed working Noctalia boot baseline. Generation
**33** is the older Hyprland desktop with hostname `X299-SSD`. Their closures
are protected by these GC roots:

- `/nix/var/nix/gcroots/noctalia-working-generation-35`
- `/nix/var/nix/gcroots/noctalia-pre-trial-generation-33`

Select either from GRUB's NixOS configurations menu. To restore one as the
boot default, for example generation 35:

```sh
sudo nix-env --profile /nix/var/nix/profiles/system --switch-generation 35
sudo /nix/var/nix/profiles/system/bin/switch-to-configuration boot
```

Root/user data, SSH keys, Nemo/Firefox associations, and the Windows VM storage
are retained. Strata's optional FileManager1 and file-chooser takeover are not
enabled. Other machines should connect using the new hostname or its network
DNS/mDNS name.
