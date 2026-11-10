#!/usr/bin/env python3
"""
Sync Nix-managed bar widget placement without discarding GUI preferences.
Only start/center/end in bar.main belong to settings.nix; bar appearance,
per-monitor overrides and other runtime state remain user-writable.
"""

import os
from collections.abc import MutableMapping
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

import tomlkit
from tomlkit.exceptions import ParseError


def prune_declarative_overrides():
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
        bar = document.get("bar")
        main = bar.get("main") if isinstance(bar, MutableMapping) else None
        if not isinstance(main, MutableMapping):
            return False
        layout_keys = {"start", "center", "end"} & main.keys()
        if not layout_keys:
            return False
        for key in layout_keys:
            del main[key]

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
    prune_declarative_overrides()
    reload_desktop()
