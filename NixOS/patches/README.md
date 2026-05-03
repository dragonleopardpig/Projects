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

## ProtonVPN tray fix — mostly removed

The previous `protonvpn-systray.patch` is gone. Equivalent fixes have
landed upstream in `proton-vpn` v4.15.x / v4.16.1:

- SNI/DBusMenu typing fixes: `tray_icon.py` now returns properly typed
  `dbus.Int32 / Dictionary("sv") / Array("(ia{sv}av)")` from `GetLayout`,
  and `dbus.String("")` for unknown SNI properties.
- Tray host detection: upstream `TrayAvailabilityDetection` queries
  `org.kde.StatusNotifierWatcher` directly via `NameHasOwner`
  (commits `0f351813`, `7feca9d5`, `bf654667`).
- Menu state vs window visibility: upstream commit
  `0d6aa810` keeps `Show` / `Hide` aligned with the window state, with
  follow-up `2151ab40 [VPNLINUX-1638]`.

Once nixpkgs ships a `proton-vpn` package with these fixes (it does at
v4.15.3+), no override is needed.

The one fix that has **not** landed upstream yet is re-registering the
SNI item when the tray host (HyprPanel) restarts. The split patch for
that lives in `upstream/0004-reregister-tray-item-when-host-restarts.patch`
and is tracked in <https://github.com/ProtonVPN/proton-vpn-gtk-app/pull/157>.
If that PR is merged or the bug stops happening in practice, the file
can be deleted too.

## Rebuilding

```bash
sudo nixos-rebuild switch --flake /home/thinky/Projects/NixOS#M90aPro
```
