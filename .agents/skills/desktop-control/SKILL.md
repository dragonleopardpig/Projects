---
name: desktop-control
description: >-
  Rules, file locations, IPC commands, and workflows for administering this system's
  NixOS flake, Umbriel Wayland compositor, and Noctalia desktop shell.
  Use when asked to inspect or modify system settings, wallpapers, themes, keybindings,
  scratchpads, terminal configs, or troubleshoot system rebuilds.
---

# Desktop Control & System Administration Guide

This system runs **NixOS** with the **Umbriel** Wayland compositor and the **Noctalia Suite** desktop shell.

## 1. Architecture & File Layout

* **NixOS Flake Repository**: `/home/thinky/Projects/NixOS`
  * System Configuration: `/home/thinky/Projects/NixOS/configuration.nix`
  * User / Home Manager: `/home/thinky/Projects/NixOS/home.nix`
  * Rebuild Script: `/home/thinky/Projects/NixOS/rebuild.sh`
* **Noctalia Suite & Umbriel Compositor**: `/home/thinky/Projects/NixOS/noctalia/suite`
  * Compositor Keybinds, Rules & Scratchpads: `/home/thinky/Projects/NixOS/noctalia/suite/umbriel.nix`
  * Shell Settings (Bar, Panels, Plugins): `/home/thinky/Projects/NixOS/noctalia/suite/settings.nix`
  * Theme & Color Palettes: `/home/thinky/Projects/NixOS/noctalia/suite/theme.nix`
* **Local User Overrides (Immediate Effect)**:
  * Compositor Overrides: `~/.config/umbriel/overrides.toml` (auto-included by Umbriel; changes apply on save or via `umbriel msg config-reload`).

## 2. Live Shell & Compositor Controls (IPC)

Noctalia and Umbriel expose rich command-line interfaces for live management without requiring a reboot:

### Noctalia Desktop Shell (`noctalia msg`)
* **Reload configuration**: `noctalia msg config-reload`
* **Switch wallpaper**: `noctalia msg wallpaper-random` or `noctalia msg wallpaper-set <path>`
* **Switch color scheme**: `noctalia msg color-scheme-set <source> <name>`
* **Toggle dark/light theme**: `noctalia msg theme-mode-toggle`
* **Open launcher / panels**: `noctalia msg panel-toggle launcher` / `clipboard` / `session`
* **Send notifications**: `notify-send "Title" "Message"`

### Umbriel Wayland Compositor (`umbriel msg`)
* **Validate configuration**: `umbriel config validate -c ~/.config/umbriel/config.toml`
* **Reload compositor settings**: `umbriel msg config-reload`
* **Toggle scratchpads**: `umbriel msg scratchpad-toggle:<name>` (e.g. `terminal`, `volume`, `notepad`, `agent`)

## 3. Theming & Customization Rules

1. **Declarative First**: When making permanent changes, update the files in `/home/thinky/Projects/NixOS` and test via `rebuild.sh`.
2. **Immediate Testing**: For compositor keybinds or scratchpad adjustments, you can draft them in `~/.config/umbriel/overrides.toml` and run `umbriel msg config-reload` to test them instantly.
3. **Safety & Rollbacks**: Never edit `/nix/store` directly. NixOS ensures atomic generations; if an update fails, use `nixos-rebuild rollback`.
