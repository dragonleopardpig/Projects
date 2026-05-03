# Local package patches

This directory contains source patches applied via the `localOverlay` in
`../flake.nix`.

## Active patches

### `swappy-multi-mime-clipboard.patch`

Makes `swappy` offer the screenshot in multiple image MIME types via the GTK
clipboard (PNG, BMP, TIFF, JPEG) so that other apps and Wayland-side
clipboard consumers can paste it without conversion.

Upstream PR: <https://github.com/jtheoof/swappy/pull/221> (open, no traction).

### `megasync-hyprland.patch` and `megasync-sync-header-labels.patch`

Make MEGAsync usable on Hyprland/Wayland and improve sync/backup table
contrast. Built on top of a local fork of MEGAsync (see the `megasync`
override in `../flake.nix`).

Upstream PRs (all open, no traction yet):

- <https://github.com/meganz/MEGAsync/pull/1124>
- <https://github.com/meganz/MEGAsync/pull/1125>
- <https://github.com/meganz/MEGAsync/pull/1126>

### `upstream/0004-reregister-tray-item-when-host-restarts.patch`

Re-register the StatusNotifierItem when the tray host (HyprPanel)
restarts. Without this, the ProtonVPN tray icon disappears after every
HyprPanel reload and never comes back. Applied to `proton-vpn` via the
`localOverlay` in `../flake.nix`.

Upstream PR: <https://github.com/ProtonVPN/proton-vpn-gtk-app/pull/157>
(open against `stable`, no traction yet). Drop the override and this
patch as soon as the PR lands and the new `proton-vpn` reaches nixpkgs.

### `upstream/0008-dbusmenu-children-as-variants.patch`

Make ProtonVPN's `_DBusMenuService.GetLayout` send children as the
spec-conformant `av` (array of variants) instead of `a(ia{sv}av)`
(array of structs). The struct-array form is silently accepted by
permissive tray hosts (KDE, waybar) but trips the strict GVariant
format `(i@a{sv}@av)` used by HyprPanel's astal-tray, segfaulting the
panel the moment ProtonVPN's tray menu is read.

Fix is a 5-line change in `tray_icon.py`: empty children arrays use
`signature="v"`, and each child `dbus.Struct` carries `variant_level=1`
so dbus-python wraps it as a variant on the wire. Same shape that the
method's own `out_signature="u(ia{sv}av)"` already declares.

No upstream PR yet — submitting alongside #157. Drop this and the
override entry above once both fixes land in nixpkgs's `proton-vpn`.

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
