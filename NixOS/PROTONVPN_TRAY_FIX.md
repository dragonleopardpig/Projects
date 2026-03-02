# ProtonVPN GUI + Systray Fix (Hyprland 0.53 + HyprPanel)

This documents the exact procedure implemented to make the **ProtonVPN GUI** and **systray icon** work after upgrading to Hyprland 0.53.

## Overview

Root cause:
- ProtonVPN registers a StatusNotifierItem (SNI) with **absolute SVG paths** and a **DBusMenu**, which caused HyprPanel’s `libastal-tray` to **crash**.
- HyprPanel was running but its tray backend crashed repeatedly, so the icon appeared briefly then disappeared.

Fix strategy:
1. Keep HyprPanel’s tray enabled (so the tray area renders).
2. Patch ProtonVPN at runtime via `sitecustomize` to:
   - use **theme icon names** instead of absolute SVG paths
   - **disable DBusMenu** (`ItemIsMenu=false`, `Menu=/`), which prevents HyprPanel’s tray crash
3. Provide local theme icons so those names resolve.
4. Start ProtonVPN through a wrapper that injects the patch.

---

## Step 1: Add local theme icons for ProtonVPN

Copy Proton’s SVGs into the local icon theme so names like `proton-vpn-connected` resolve:

```
~/.local/share/icons/hicolor/scalable/apps/proton-vpn-connected.svg
~/.local/share/icons/hicolor/scalable/apps/proton-vpn-disconnected.svg
~/.local/share/icons/hicolor/scalable/apps/proton-vpn-error.svg
~/.local/share/icons/hicolor/scalable/apps/proton-vpn-sign.svg
```

These are copied from the ProtonVPN package’s assets.

---

## Step 2: Add a runtime patch via sitecustomize

Create:
```
~/.local/lib/protonvpn-patch/sitecustomize.py
```

This patch does 3 things:
1. Replaces tray icon paths with theme names:
   - `proton-vpn-connected`
   - `proton-vpn-disconnected`
   - `proton-vpn-error`
2. Registers SNI using object-path + retry.
3. Disables DBusMenu in the SNI properties to avoid HyprPanel crashes.

Key changes in the patch:
- `TrayIndicator.CONNECTED_ICON` etc replaced with theme icon names.
- `_StatusNotifierItem.Get` + `GetAll` wrapped to return:
  - `ItemIsMenu = false`
  - `Menu = /`

---

## Step 3: Wrap ProtonVPN launcher

Create:
```
~/.local/bin/protonvpn-tray
```

Wrapper exports:
- `PYTHONPATH` pointing at the patch directory and ProtonVPN site-packages
- `GDK_BACKEND=x11` to keep GUI stable on Wayland

Then launch ProtonVPN via this wrapper (not directly).

---

## Step 4: Keep HyprPanel systray enabled

In `~/Projects/NixOS/home.nix`, ensure the bar layout includes systray:

```
right = [ "network" "volume" "battery" "systray" "clock" "notifications" ];
```

---

## Step 5: Autostart ProtonVPN with the wrapper

In `home.nix` Hyprland `exec-once`:

```
"~/.local/bin/protonvpn-tray"
```

---

## Step 6: Rebuild and restart

```
~/Projects/NixOS/rebuild.sh switch X299
systemctl --user restart hyprpanel.service
```

Then restart ProtonVPN if needed:

```
pkill -f protonvpn-app
nohup ~/.local/bin/protonvpn-tray >/tmp/protonvpn.log 2>&1 &
```

---

## Verification

Confirm ProtonVPN registers a tray item and HyprPanel stays alive:

1. HyprPanel running:
```
systemctl --user status hyprpanel.service
```

2. SNI registered:
```
busctl --user get-property org.kde.StatusNotifierWatcher \
  /StatusNotifierWatcher org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems
```

3. ProtonVPN SNI properties (expect IconName = proton-vpn-connected, ItemIsMenu = false):
```
busctl --user call :<proton_sni_unique> /StatusNotifierItem \
  org.freedesktop.DBus.Properties GetAll s org.kde.StatusNotifierItem
```

---

## Files Modified / Added

- `~/Projects/NixOS/home.nix`
  - systray enabled in bar layout
  - protonvpn autostart uses wrapper
- `~/.local/lib/protonvpn-patch/sitecustomize.py`
- `~/.local/bin/protonvpn-tray`
- `~/.local/share/icons/hicolor/scalable/apps/proton-vpn-*.svg`

---

## Notes

- The patch is runtime-only and does **not** modify the ProtonVPN package itself.
- If ProtonVPN updates, the patch should still work unless internals change.
- If HyprPanel updates its tray backend, you can re-enable DBusMenu later.
