# Upstream submission split patches

This folder holds split, single-topic patches prepared for upstream PRs.
The combined local fixes that are still actively applied to the build
live one directory up; this folder is the reference material used to
open and maintain upstream PRs.

## ProtonVPN — `proton-vpn-gtk-app`

PRs 1–3 in the original plan have effectively landed upstream in
`proton-vpn` v4.15.x / v4.16.1, so their split files were deleted.

Still tracked:

- `0004-reregister-tray-item-when-host-restarts.patch`
  - Watches `org.kde.StatusNotifierWatcher` owner changes and
    re-registers the SNI item when the tray host comes back. Recovers
    the ProtonVPN tray icon after HyprPanel restarts.
  - PR: <https://github.com/ProtonVPN/proton-vpn-gtk-app/pull/157>

## MEGAsync — `meganz/MEGAsync`

Three open PRs against MEGAsync, no comments yet:

- `0005-wayland-tray-and-popup-behavior.patch`
  PR: <https://github.com/meganz/MEGAsync/pull/1124>
- `0006-wayland-dialog-surfacing-and-layout.patch`
  PR: <https://github.com/meganz/MEGAsync/pull/1125>
- `0007-sync-header-label-contrast.patch`
  PR: <https://github.com/meganz/MEGAsync/pull/1126>

The combined patches that are actually applied during build live in
`../megasync-hyprland.patch` and `../megasync-sync-header-labels.patch`.

## Workflow

To rebase a split patch on top of current upstream:

```bash
cd ~/proton-vpn-gtk-app   # or ~/MEGAsync
git fetch origin
git checkout main         # or master
git pull --ff-only

git checkout -b fix/<topic>
git apply ~/Projects/NixOS/patches/upstream/<file>.patch
# fix any rejects manually, then
git commit -a -m "fix: <topic>"
```

If `git apply` fails, the upstream code drifted. Re-apply the logical
change manually instead of forcing the old patch.

Validation:

```bash
python3 -m py_compile \
  proton/vpn/app/gtk/widgets/main/tray_icon.py \
  proton/vpn/app/gtk/widgets/main/tray_indicator.py
```

Behavioral check (ProtonVPN): start `protonvpn-app`, restart HyprPanel
(or your tray host), confirm the tray item reappears without restarting
the app.
