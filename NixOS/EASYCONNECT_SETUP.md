# EasyConnect (Sangfor) on NixOS — Reproducible Setup

This document records the working setup for EasyConnect on NixOS (Hyprland/Wayland), including the exact download source, NixOS config hooks, and the minimal commands to reproduce on another host (e.g., M90aPro).

## Download

Get the official `.deb` from Sangfor and place it in `~/Downloads`:

```text
https://download.sangfor.com.cn/download/product/sslvpn/pkg/linux_767/EasyConnect_x64_7_6_7_3.deb
```

Expected local path:

```text
~/Downloads/EasyConnect_x64_7_6_7_3.deb
```

## What this setup does

- Extracts the `.deb` into `~/.local/opt/easyconnect`.
- Uses a **FHS env** to run the binary with the needed GTK/X11 libs on NixOS.
- Builds **Pango 1.43** and injects it into EasyConnect’s private runtime.
- Starts **EasyMonitor** (required background service).
- Fixes **GUI font rendering** by applying a **per-app fontconfig** (Noto CJK + WenQuanYi),
  without changing the system locale or desktop fonts.
- Fixes Electron hardcoded file paths by:
  - Adding `~/.../sangfor/Web` symlink to `resources/Web`.
  - Extracting `src/` from `app.asar` into `EasyConnect/src` so preload/IPC modules resolve.
  - Extracting JS dependencies using **Node 20** to avoid asar extraction issues.
- Adds a **Walker-visible app entry** with icon.

## Reproduce on M90aPro (or any host)

1) Ensure the .deb exists:

```sh
ls -la ~/Downloads/EasyConnect_x64_7_6_7_3.deb
```

2) Rebuild with the correct host target:

```sh
/home/thinky/Projects/NixOS/rebuild.sh switch M90aPro
```

3) Build the bundled Pango runtime (one-time):

```sh
~/.local/bin/easyconnect-pango
```

4) First run (extract + fixup + launch):

```sh
~/.local/bin/easyconnect-deb
```

## Fonts (GUI boxes / missing Chinese text)

EasyConnect is forced to use a **private fontconfig** so the GUI renders Chinese text correctly
without changing the system locale or overall desktop fonts.

Where it lives:

```text
~/.local/share/easyconnect-fonts/fonts.conf
```

The launcher (`~/.local/bin/easyconnect-deb`) exports:

```text
FONTCONFIG_FILE=~/.local/share/easyconnect-fonts/fonts.conf
FONTCONFIG_PATH=~/.local/share/easyconnect-fonts
```

Font sources prioritized for EasyConnect:

- `Noto Sans CJK SC`
- `WenQuanYi Micro Hei`
- `Noto Sans CJK TC/JP`
- `DejaVu Sans`

If you ever see boxes again:

```sh
fc-cache -f
~/.local/bin/easyconnect-deb
```

## Notes

- After the first successful run, the `.deb` file is **no longer required**. You can safely delete it.
- If you update to a new `.deb`, just place it in `~/Downloads` and run `~/.local/bin/easyconnect-deb` again.
- The EasyConnect launcher in Walker should appear as **“EasyConnect”** with the EasyConnect icon.

## Troubleshooting

- If the app fails to launch, inspect the log:

```sh
cat ~/.local/state/easyconnect.log
```

- Ensure the background service is running:

```sh
systemctl status EasyMonitor --no-pager
```

- If `EasyMonitor` isn’t running:

```sh
sudo systemctl enable --now EasyMonitor
```

## One-shot installer script

To automate everything (rebuild + Pango + first run):

```sh
/home/thinky/Projects/NixOS/easyconnect-install.sh
```

Optional: specify a host explicitly:

```sh
/home/thinky/Projects/NixOS/easyconnect-install.sh X299-SSD
```
