# ProtonVPN upstream submission guide

This folder contains a split version of the local ProtonVPN tray fix, prepared
for upstream review against `proton-vpn-gtk-app`.

Files:

- `0001-fix-sni-and-dbusmenu-typing.patch`
- `0002-improve-tray-host-detection.patch`
- `0003-clean-up-tray-menu-state.patch`

The first two are the strongest upstream candidates. The third is useful, but
it is more behavioral/UI-oriented and may need discussion with maintainers.

## Recommended PR split

### PR 1: SNI / DBusMenu correctness

Use:

- `0001-fix-sni-and-dbusmenu-typing.patch`

Scope:

- fix typed StatusNotifierItem properties
- fix DBusMenu `GetLayout()` return structure
- clean separator export for DBus consumers

Suggested title:

`fix: make tray SNI/DBusMenu responses type-correct`

### PR 2: tray host detection and setup failure handling

Use:

- `0002-improve-tray-host-detection.patch`

Scope:

- detect `org.kde.StatusNotifierWatcher` directly
- handle tray setup failures without crashing the app path
- improve GNOME extension detection fallback

Suggested title:

`fix: improve tray detection outside GNOME and fail gracefully`

### PR 3: tray menu polish

Use:

- `0003-clean-up-tray-menu-state.patch`

Scope:

- avoid extra separators
- omit hidden connect/disconnect entries from the exported menu
- keep `Show` / `Hide` aligned with actual window visibility

Suggested title:

`fix: keep tray menu state aligned with window visibility`

## Practical workflow

### 1. Start from a clean upstream clone

```bash
cd ~/proton-vpn-gtk-app
git fetch origin
git checkout main
git pull --ff-only
```

If the project uses another default branch, use that instead of `main`.

### 2. Check whether upstream already merged overlapping work

Before applying anything, search the current tree for:

- `_get_sni_properties`
- `NameHasOwner`
- `StatusNotifierWatcher`
- `GetLayout`

If equivalent fixes already exist, do not submit duplicate patches. Rebase the
remaining changes onto the current upstream state.

### 3. Create one branch per PR

Example:

```bash
git checkout -b fix/tray-dbus-typing
```

### 4. Apply one patch

Example for PR 1:

```bash
git apply ~/Projects/NixOS/patches/upstream/0001-fix-sni-and-dbusmenu-typing.patch
```

If it applies cleanly:

```bash
git diff
git add proton/vpn/app/gtk/widgets/main/tray_icon.py
git commit -m "fix: make tray SNI/DBusMenu responses type-correct"
```

Then repeat the same process for PR 2 and PR 3 on fresh branches.

If `git apply` fails, the code drifted upstream. In that case:

1. inspect the reject context
2. re-apply the logical change manually
3. commit the updated version instead of forcing the old patch

## Validation to do before opening the PR

At minimum:

```bash
python3 -m py_compile \
  proton/vpn/app/gtk/widgets/main/tray_icon.py \
  proton/vpn/app/gtk/widgets/main/tray_indicator.py
```

Also test runtime behavior on a tray host that implements SNI/DBusMenu.

Useful checks:

- tray icon appears
- tray host does not crash when ProtonVPN starts
- right-click menu renders
- `Show` / `Hide` tracks the real window state

## What to tell maintainers

For PR 1:

- some tray hosts are strict about SNI and DBusMenu typing
- malformed or weakly typed responses can break tray icon rendering or crash
  tray consumers

For PR 2:

- non-GNOME environments often expose tray support through
  `org.kde.StatusNotifierWatcher`
- detection should not be GNOME-extension-only

For PR 3:

- hidden entries and unconditional separators produce odd menus on stricter
  tray hosts
- menu visibility should track the actual window state, not only tray clicks

## Suggested order

Open PRs in this order:

1. `0001`
2. `0002`
3. `0003`

That order gives maintainers the protocol fixes first, then the environment
detection fix, and only then the UI/menu cleanup.

## After submission

If upstream accepts equivalent fixes:

1. remove the local Nix patch from `~/Projects/NixOS/patches/protonvpn-systray.patch`
2. remove the `protonvpn-gui` overlay from `~/Projects/NixOS/flake.nix`
3. rebuild the hosts normally
