#!/usr/bin/env python3
"""
Sync Nix-managed bar placement and widget colors without discarding GUI preferences.
Bar appearance, per-monitor overrides and other runtime state remain user-writable.
"""

import argparse
import os
from collections.abc import MutableMapping
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

import tomlkit
from tomlkit.exceptions import ParseError


def prune_widget_order(document):
    bar = document.get("bar")
    main = bar.get("main") if isinstance(bar, MutableMapping) else None
    if not isinstance(main, MutableMapping):
        return False
    keys = {"start", "center", "end"} & main.keys()
    for key in keys:
        del main[key]
    return bool(keys)


def prune_widget_colors(document, managed_config):
    if managed_config is None:
        return False
    managed = tomlkit.parse(Path(managed_config).read_text(encoding="utf-8")).get("widget")
    widgets = document.get("widget")
    if not isinstance(managed, MutableMapping) or not isinstance(widgets, MutableMapping):
        return False
    changed = False
    for name, settings in managed.items():
        saved = widgets.get(name)
        if not isinstance(settings, MutableMapping) or not isinstance(saved, MutableMapping):
            continue
        keys = {"icon_color"} & settings.keys()
        if "color" in settings:
            # An icon-specific GUI color also masks the managed foreground.
            keys |= {"color", "icon_color"}
        for key in keys & saved.keys():
            del saved[key]
            changed = True
    return changed


def prune_plugin_glyph_overrides(document, managed_config):
    """A plugin widget draws its own glyph and tooltip; saved values for them are leftovers.

    The always-on cup was a custom button whose watcher saved its glyph and tooltip with
    `noctalia msg config-set`. Now that it is a plugin, those saved keys mean nothing, so
    they go, for any widget the managed config makes a plugin widget ("<plugin>:<widget>").
    """
    if managed_config is None:
        return False
    managed = tomlkit.parse(Path(managed_config).read_text(encoding="utf-8")).get("widget")
    widgets = document.get("widget")
    if not isinstance(managed, MutableMapping) or not isinstance(widgets, MutableMapping):
        return False
    changed = False
    for name, settings in managed.items():
        saved = widgets.get(name)
        if not isinstance(settings, MutableMapping) or not isinstance(saved, MutableMapping):
            continue
        if ":" not in str(settings.get("type", "")):
            continue
        for key in {"glyph", "tooltip"} & saved.keys():
            del saved[key]
            changed = True
        if changed and not saved:
            del widgets[name]
    return changed


def prune_plugin_list(document, managed_config):
    """A saved plugin list hides the managed plugins, so ones added in Nix never load.

    Noctalia takes `plugins.enabled` from the GUI state over the config's list. On M90aPro
    a list saved on 2026-11-09, before the local plugins existed, hid agent-status,
    gpu-status, always-on, rsync-status and rclone-status. The managed plugins always load
    now; plugins enabled only in the GUI stay, after them.
    """
    if managed_config is None:
        return False
    managed = tomlkit.parse(Path(managed_config).read_text(encoding="utf-8")).get("plugins")
    plugins = document.get("plugins")
    if not isinstance(managed, MutableMapping) or not isinstance(plugins, MutableMapping):
        return False
    managed_enabled = managed.get("enabled")
    saved = plugins.get("enabled")
    if not isinstance(managed_enabled, list) or not isinstance(saved, list):
        return False
    managed_names = [str(name) for name in managed_enabled]
    saved_names = [str(name) for name in saved]
    gui_only = [name for name in saved_names if name not in managed_names]
    if not gui_only:
        del plugins["enabled"]
        if not plugins:
            del document["plugins"]
        return True
    merged = managed_names + gui_only
    if saved_names == merged:
        return False
    plugins["enabled"] = merged
    return True


def prune_declarative_overrides(managed_config=None):
    state_home = os.environ.get("NOCTALIA_STATE_HOME") or os.path.join(
        os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
        "noctalia-suite",
    )
    settings_file = Path(state_home, "noctalia", "settings.toml").resolve()
    temporary_file = None
    try:
        if not settings_file.is_file():
            return False
        original = settings_file.read_text(encoding="utf-8")
        document = tomlkit.parse(original)
        layout_changed = prune_widget_order(document)
        colors_changed = prune_widget_colors(document, managed_config)
        glyphs_changed = prune_plugin_glyph_overrides(document, managed_config)
        plugins_changed = prune_plugin_list(document, managed_config)
        if not (layout_changed or colors_changed or glyphs_changed or plugins_changed):
            return False

        # Keep comments/formatting and replace atomically, so the shell's file
        # watcher never reads a truncated settings file. Preserve its permissions.
        mode = stat.S_IMODE(settings_file.stat().st_mode)
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=settings_file.parent,
            prefix=".settings-", delete=False,
        ) as stream:
            temporary_file = Path(stream.name)
            os.fchmod(stream.fileno(), mode)
            stream.write(tomlkit.dumps(document))
        if settings_file.read_text(encoding="utf-8") != original:
            raise RuntimeError("settings changed during sync; leaving the newer preferences intact")
        temporary_file.replace(settings_file)
        return True
    except (OSError, ParseError, RuntimeError) as error:
        print(f"[sync-settings] Warning: leaving {settings_file} unchanged: {error}", file=sys.stderr)
        return False
    finally:
        if temporary_file is not None:
            temporary_file.unlink(missing_ok=True)


def reload_desktop():
    uid = os.getuid()
    user_rundir = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{uid}"
    os.environ["XDG_RUNTIME_DIR"] = user_rundir

    noctalia_sock = os.path.join(user_rundir, "noctalia-wayland-0.sock")
    if os.path.exists(noctalia_sock):
        try:
            subprocess.run(["noctalia", "msg", "config-reload"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            pass

    umbriel_sock = os.path.join(user_rundir, "umbriel-wayland-0.sock")
    if os.path.exists(umbriel_sock):
        try:
            subprocess.run(["umbriel", "msg", "config-reload"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            pass

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True,
                        help="Nix-managed Noctalia configuration supplying widget colors")
    arguments = parser.parse_args()
    prune_declarative_overrides(arguments.config)
    reload_desktop()
