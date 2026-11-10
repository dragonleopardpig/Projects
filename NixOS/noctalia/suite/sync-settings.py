#!/usr/bin/env python3
"""
Sync Noctalia Suite runtime state with declarative NixOS/Home Manager config.
Prunes stale declarative sections (e.g. [bar.main]) from settings.toml so that
declarative Nix configurations take precedence, while preserving genuine user
runtime state (wallpaper rotation, lockscreen layout, etc.).
"""

import os
import re
import subprocess
import sys

def prune_declarative_overrides():
    state_home = os.environ.get("NOCTALIA_STATE_HOME") or os.path.expanduser("~/.local/state/noctalia-suite")
    settings_file = os.path.join(state_home, "noctalia", "settings.toml")
    if not os.path.isfile(settings_file):
        return

    try:
        with open(settings_file, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return

    # Sections managed declaratively in settings.nix that must not be masked by GUI state
    declarative_sections = {"bar.main"}

    out = []
    skip = False
    modified = False

    for line in lines:
        header_match = re.match(r"^\s*\[([a-zA-Z0-9_.\-\"\@]+)\]", line)
        if header_match:
            sec = header_match.group(1).strip("\"'")
            skip = sec in declarative_sections or any(sec.startswith(f"{s}.") for s in declarative_sections)
            if skip:
                modified = True
                continue
        if not skip:
            out.append(line)

    if modified:
        try:
            with open(settings_file, "w", encoding="utf-8") as f:
                f.writelines(out)
        except OSError as e:
            print(f"[sync-settings] Warning: could not write {settings_file}: {e}", file=sys.stderr)

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
