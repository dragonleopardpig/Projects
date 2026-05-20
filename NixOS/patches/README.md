# Local package patches

This directory contains source patches applied via the `localOverlay` in
`../flake.nix`.

## Active patches

### `swappy-multi-mime-clipboard.patch`

Makes `swappy` offer the screenshot in multiple image MIME types via the GTK
clipboard (PNG, BMP, TIFF, JPEG) so that other apps and Wayland-side
clipboard consumers can paste it without conversion.

Upstream PR: <https://github.com/jtheoof/swappy/pull/221> (open, no traction).

### `swappy-save-as-dialog.patch`

Adds a `Save As...` toolbar button and `Ctrl+Shift+S` keybind to `swappy`.
Opens a `GtkFileChooserNative` pre-filled with the configured `save_dir` and
`save_filename_format` (strftime-expanded), so the default action matches the
existing quick-save while still allowing rename/relocate.

Sourced from the `save-as` branch of the local fork
(`git@github.com:dragonleopardpig/swappy.git`), commit `22e39a6`.

### `nwg-drawer-click-outside-to-close.patch`

Makes a plain left-click on the empty background of `nwg-drawer` dismiss the
drawer (macOS Launchpad style). Upstream only closes on right-click or
`Escape`. A `button-press-event` handler on `resultWindow` arms the gesture
and reuses the existing `beenScrolled` flag, so a touch drag-to-scroll that
ends over empty space does not dismiss the drawer. Clicks on an app icon are
consumed by the icon's own handler and never reach this path.

Local feature patch (no upstream PR yet). Patches only `main.go`, so the
`buildGoModule` `vendorHash` is unaffected.

### `megasync-hyprland.patch` and `megasync-sync-header-labels.patch`

Make MEGAsync usable on Hyprland/Wayland and improve sync/backup table
contrast. Built on top of a local fork of MEGAsync (see the `megasync`
override in `../flake.nix`).

Upstream PRs (all open, no traction yet):

- <https://github.com/meganz/MEGAsync/pull/1124>
- <https://github.com/meganz/MEGAsync/pull/1125>
- <https://github.com/meganz/MEGAsync/pull/1126>

### `upstream/0004-reregister-tray-item-when-host-restarts.patch`

Re-register the StatusNotifierItem when the tray host restarts. Without
this, the ProtonVPN tray icon disappears whenever the bar reloads and
never comes back. Applied to `proton-vpn` via the `localOverlay` in
`../flake.nix`.

Upstream PR: <https://github.com/ProtonVPN/proton-vpn-gtk-app/pull/157>
(open against `stable`, no traction yet). Drop the override and this
patch as soon as the PR lands and the new `proton-vpn` reaches nixpkgs.

### `upstream/0008-dbusmenu-children-as-variants.patch`

Full diff of upstream PR #152
(<https://github.com/ProtonVPN/proton-vpn-gtk-app/pull/152>), rebased
on `stable` at proton-vpn v4.16.1. Three correctness fixes in
`tray_icon.py`:

1. **DBusMenu children become spec-conformant `av`.** `GetLayout`
   previously returned children as `a(ia{sv}av)` (array of structs),
   which permissive hosts (KDE, waybar) accept silently but strict
   readers reject with a GVariant assertion, segfaulting the host on
   the first menu read.
2. **Separator entries no longer carry `label`/`enabled` keys.** Some
   hosts draw separators with a thicker style when those fields are
   present in the dict — this is also why the tray menu used to show
   fat dividers between Connect / Show / Quit.
3. **Full SNI property table via shared `_get_sni_properties`.** `Get`
   and `GetAll` now return the standard SNI properties (`IconPixmap`,
   `OverlayIconName`, `ToolTip`, `WindowId`, …) with correct types,
   instead of returning `None`/raw strings for unknown probes.

Drop this patch + the proton-vpn override once #152 lands and the
new package reaches nixpkgs.

The other ProtonVPN fixes that used to live in this directory
(`protonvpn-systray.patch` and split patches `0001`–`0003`) have landed
upstream in `proton-vpn` v4.15.x / v4.16.1 and were deleted:

- SNI/DBusMenu typing fixes in `tray_icon.py` (`dbus.Int32`,
  `Dictionary("sv")`, `Array("(ia{sv}av)")`, `dbus.String("")`).
- Tray host detection via `NameHasOwner` on
  `org.kde.StatusNotifierWatcher` (commits `0f351813`, `7feca9d5`,
  `bf654667`).
- Menu state aligned with window visibility (commit `0d6aa810`,
  follow-up `2151ab40 [VPNLINUX-1638]`).

## Rebuilding

```bash
sudo nixos-rebuild switch --flake /home/thinky/Projects/NixOS#M90aPro
```
