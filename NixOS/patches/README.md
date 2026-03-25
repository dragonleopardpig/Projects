# ProtonVPN systray patch

This directory contains the local patch that makes `protonvpn-gui` work
reliably in the Hyprland + HyprPanel setup used by this NixOS config.

## Problem

With upstream `protonvpn-gui 4.15.0`, the tray icon behavior was broken on
the newer Hyprland/HyprPanel stack:

- the tray icon could fail to appear
- HyprPanel could crash/restart when ProtonVPN registered its tray item
- right-click menu rendering was inconsistent
- `Show` / `Hide` state could drift from the actual window visibility

The issue was not just missing tray libraries. The main breakage came from
ProtonVPN's StatusNotifierItem / DBusMenu implementation interacting badly
with HyprPanel's tray backend.

## How this config fixes it

`../flake.nix` overrides `pkgs.protonvpn-gui` and applies
`protonvpn-systray.patch` during the normal package build.

`../home.nix` then launches plain `protonvpn-app` directly. There is no
runtime wrapper, local monkeypatch script, or custom tray launcher anymore.

## What the patch changes

The patch modifies ProtonVPN's Python source in these areas:

- `tray_icon.py`
  - fixes StatusNotifierItem property typing
  - fixes DBusMenu `GetLayout()` structure typing
  - cleans separator item DBus export
- `tray_indicator.py`
  - adds `StatusNotifierWatcher` detection fallback
  - handles tray setup failures more cleanly
  - avoids emitting hidden connect/disconnect entries
  - reduces bogus separators
  - keeps tray `Show` / `Hide` menu state aligned with window visibility
- `tray_icon.py`
  - re-registers the tray item when the tray host disappears and comes back
  - fixes ProtonVPN tray recovery after HyprPanel restarts

## Files involved

- `protonvpn-systray.patch`
- `../flake.nix`
- `../home.nix`

## Rebuilding

On a host that uses this repo:

```bash
sudo nixos-rebuild switch --flake /home/thinky/Projects/NixOS#M90aPro
```

or:

```bash
sudo nixos-rebuild switch --flake /home/thinky/Projects/NixOS#X299
```

## If ProtonVPN updates upstream

If `protonvpn-gui` changes version in nixpkgs, the patch may stop applying.

When that happens:

1. inspect the new upstream `tray_icon.py` and `tray_indicator.py`
2. rebase or regenerate `protonvpn-systray.patch`
3. rebuild the target host

If upstream eventually merges equivalent fixes, this patch can be removed and
the overlay in `../flake.nix` can be dropped.

## When this patch can be removed

An upstream merge is not enough by itself. This NixOS config builds
`protonvpn-gui` from nixpkgs, so the patch is only removable when nixpkgs is
packaging a ProtonVPN source version that already includes equivalent fixes.

Practical checklist:

1. confirm ProtonVPN merged the relevant upstream fixes
2. confirm your nixpkgs `protonvpn-gui` package has updated to a version that
   includes them
3. remove the overlay and local patch temporarily
4. rebuild
5. verify the tray still works correctly without the local patch

Only after that should this patch and the overlay in `../flake.nix` be deleted.
