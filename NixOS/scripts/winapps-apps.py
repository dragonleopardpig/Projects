#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
import uuid


DATA = Path.home() / ".local/share/winapps"
APPLICATIONS = Path.home() / ".local/share/applications"
CATALOG = DATA / "app-catalog.json"
STATE = Path.home() / ".local/state/winapps/app-shortcuts.json"
COMMAND = os.environ.get("WINAPPS_COMMAND", "winapps")
DEFAULT_ICON = Path(os.environ.get("WINAPPS_DEFAULT_ICON", "/dev/null"))


def write_atomic(path, contents):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".winapps-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            output.write(contents)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def load_state():
    return json.loads(STATE.read_text()) if STATE.exists() else {}


def load_catalog():
    if not CATALOG.exists():
        return {"apps": []}
    catalog = json.loads(CATALOG.read_text(encoding="utf-8-sig"))
    return catalog


def desktop_context():
    if not shutil.which("hyprctl"):
        return None, "WinApps"
    result = subprocess.run(["hyprctl", "clients", "-j"], capture_output=True, text=True, timeout=5)
    if result.returncode != 0:
        return None, "WinApps"
    clients = json.loads(result.stdout)
    for client in clients:
        if client["class"] == "Microsoft Windows":
            return client["workspace"]["id"], "WinApps"
    for client in clients:
        if client["class"].startswith("Microsoft "):
            return None, client["class"]
    return None, "WinApps"


def info_text(name, executable, arguments=""):
    values = {
        "NAME": name,
        "FULL_NAME": name.replace(",", " "),
        "WIN_EXECUTABLE": executable,
        "WIN_ARGUMENTS": arguments,
        "CATEGORIES": "Utility;X-WinApps;",
        "MIME_TYPES": "",
    }
    return "".join(f"{key}={shlex.quote(value)}\n" for key, value in values.items())


def refresh():
    token = uuid.uuid4().hex
    workspace, remote_class = desktop_context()
    script = r'''
$ErrorActionPreference = 'Stop'
$destination = '\\tsclient\home\.local\share\winapps\app-catalog.json'
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    if (Test-Path '\\tsclient\home\.local\share\winapps') { break }
    Start-Sleep -Seconds 1
}
try {
    $entries = @(Get-StartApps | Where-Object { $_.Name -and $_.AppID } | Sort-Object Name |
        ForEach-Object { @{ name = $_.Name; app_id = $_.AppID } })
    $result = @{ token = 'TOKEN'; scanned = (Get-Date).ToString('o'); apps = $entries }
} catch {
    $result = @{ token = 'TOKEN'; apps = @(); error = $_.Exception.Message }
}
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $destination -Encoding UTF8
'''.replace("TOKEN", token)
    encoded = base64.b64encode(script.encode("utf-16le")).decode("ascii")
    scan_directory = DATA / "apps/winapps-catalog"
    write_atomic(scan_directory / "info", info_text(
        remote_class, r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
        f"-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand {encoded}",
    ))
    if DEFAULT_ICON.is_file():
        shutil.copyfile(DEFAULT_ICON, scan_directory / "icon.svg")
    subprocess.run([COMMAND, "cleanrdp"], capture_output=True, timeout=10)
    for tracking in DATA.glob("FreeRDP_Process_*.cproc"):
        identifier = tracking.name.removeprefix("FreeRDP_Process_").removesuffix(".cproc")
        if not identifier.isdecimal():
            continue
        try:
            process_name = Path(f"/proc/{identifier}/comm").read_text().strip()
            if "freerdp" in process_name:
                os.kill(int(identifier), signal.SIGTERM)
        except (OSError, ProcessLookupError):
            pass
    time.sleep(1)
    with (DATA / "app-catalog-scan.log").open("w") as log:
        os.chmod(log.name, 0o600)
        subprocess.Popen([COMMAND, "winapps-catalog"], stdout=log, stderr=log)
    progress = subprocess.Popen(
        ["zenity", "--progress", "--title=Windows Apps", "--pulsate", "--no-cancel",
         "--auto-close", "--text=Reading the Windows Start menu.\n"
         "The Windows viewer may reconnect; running Windows applications are not closed."],
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True,
    )
    try:
        deadline = time.monotonic() + 360
        while time.monotonic() < deadline:
            try:
                catalog = json.loads(CATALOG.read_text(encoding="utf-8-sig"))
                if catalog.get("token") == token:
                    os.chmod(CATALOG, 0o600)
                    if catalog.get("error"):
                        raise ValueError(catalog["error"])
                    return catalog
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(0.5)
        raise ValueError("Windows did not return an app list. Check ~/.local/share/winapps/app-catalog-scan.log.")
    finally:
        if progress.poll() is None:
            try:
                progress.communicate("100\n", timeout=5)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                progress.terminate()
        if workspace is not None:
            subprocess.run(
                ["hyprctl", "dispatch", "exec", f"[workspace {workspace} silent] {shlex.quote(COMMAND)} windows"],
                capture_output=True, text=True, timeout=10,
            )


def normalize(name):
    return re.sub(r"[^a-z0-9]", "", name.lower().removeprefix("microsoft "))


def existing_names():
    names = set()
    for info in (DATA / "apps").glob("*/info"):
        if (info.parent / "managed-by-winapps-apps").exists() or info.parent.name == "winapps-catalog":
            continue
        for line in info.read_text().splitlines():
            if line.startswith(("NAME=", "FULL_NAME=")):
                try:
                    values = shlex.split(line.split("=", 1)[1])
                    if len(values) == 1:
                        names.add(normalize(values[0]))
                except ValueError:
                    pass
    return names


def cached_icons():
    cache = DATA / "detected"
    entries = []
    pending = {}
    if cache.exists():
        for line in cache.read_text(encoding="utf-8-sig").splitlines():
            match = re.fullmatch(r'(NAMES|EXES|ICONS)\+=\("(.*)"\)', line)
            if not match:
                continue
            key, value = match.groups()
            pending[key] = value
            if key == "ICONS" and all(field in pending for field in ("NAMES", "EXES", "ICONS")):
                entries.append(pending)
                pending = {}
    return entries


def app_key(app_id):
    return "picked-" + hashlib.sha256(app_id.encode()).hexdigest()[:16]


def install_shortcut(app, icons):
    key = app_key(app["app_id"])
    directory = DATA / "apps" / key
    marker = directory / "managed-by-winapps-apps"
    if directory.exists() and not marker.exists():
        raise ValueError(f"Refusing to replace an unmanaged app: {directory}")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    icon_path = directory / "icon.svg"
    shutil.copyfile(DEFAULT_ICON, icon_path)
    family = app["app_id"].split("!", 1)[0].rsplit("_", 1)[0].lower()
    for candidate in icons:
        if normalize(candidate["NAMES"].split(" [", 1)[0]) == normalize(app["name"]) or (
            "!" in app["app_id"] and f"\\{family}_" in candidate["EXES"].lower()
        ):
            try:
                data = base64.b64decode(candidate["ICONS"], validate=True)
                if data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) < 2_000_000:
                    icon_path.unlink()
                    icon_path = directory / "icon.png"
                    icon_path.write_bytes(data)
                    break
            except ValueError:
                pass
    name = app["name"].replace("\n", " ").replace("\r", " ")
    write_atomic(directory / "info", info_text(
        name, r"C:\Windows\explorer.exe", f'"shell:AppsFolder\\{app["app_id"]}"',
    ))
    write_atomic(marker, "winapps-apps\n")
    desktop = (
        "[Desktop Entry]\nType=Application\n"
        f"Name={name} (Windows)\nComment=Windows app through WinApps\n"
        f"Exec={shlex.quote(COMMAND)} {key}\nIcon={icon_path}\nTerminal=false\n"
        f"StartupWMClass={name.replace(',', ' ')}\n"
        "Categories=Utility;X-WinApps;\nKeywords=Windows;WinApps;\n"
        "X-WinApps-ManagedBy=winapps-apps\n"
    )
    write_atomic(APPLICATIONS / f"winapps-{key}.desktop", desktop)
    return {"name": name, "key": key}


def remove_shortcut(record):
    key = record["key"]
    if not re.fullmatch(r"picked-[0-9a-f]{16}", key):
        raise ValueError("Invalid managed shortcut identifier.")
    directory = DATA / "apps" / key
    marker = directory / "managed-by-winapps-apps"
    if not marker.exists():
        raise ValueError(f"Not a managed app: {directory}")
    desktop = APPLICATIONS / f"winapps-{key}.desktop"
    if desktop.exists() and "X-WinApps-ManagedBy=winapps-apps" in desktop.read_text():
        desktop.unlink()
    for filename in ("info", "icon.svg", "icon.png", "managed-by-winapps-apps"):
        (directory / filename).unlink(missing_ok=True)
    try:
        directory.rmdir()
    except OSError:
        pass


def apply_selection(apps, selected):
    managed = load_state()
    existing = existing_names()
    icons = cached_icons()
    for app in apps:
        if app["app_id"] in selected and normalize(app["name"]) not in existing:
            managed[app["app_id"]] = install_shortcut(app, icons)
            write_atomic(STATE, json.dumps(managed, indent=2) + "\n")
    for app_id in list(managed):
        if app_id not in selected:
            remove_shortcut(managed.pop(app_id))
            write_atomic(STATE, json.dumps(managed, indent=2) + "\n")
    if shutil.which("update-desktop-database"):
        subprocess.run(["update-desktop-database", str(APPLICATIONS)], capture_output=True)


def gui():
    while True:
        catalog = load_catalog()
        managed = load_state()
        existing = existing_names()
        scanned = catalog.get("error") or catalog.get("scanned", "not scanned yet")
        arguments = [
            "yad", "--list", "--checklist", "--title=Choose Windows Apps", "--width=800", "--height=600",
            f"--text=Choose installed Windows apps to show independently in AGS/Walker.\n"
            f"Last scan: {scanned}\n"
            "Unchecking removes only this picker's shortcuts, not Windows software.\n"
            "Existing Office shortcuts are kept. Some apps do not support RemoteApp.",
            "--column=Show", "--column=Application", "--column=Status", "--column=App ID",
            "--hide-column=4", "--print-column=4", "--separator=\n", "--search-column=2",
            "--button=Refresh from Windows:10", "--button=Cancel:1", "--button=Apply selection:0",
        ]
        for app in catalog["apps"]:
            already = normalize(app["name"]) in existing
            arguments.extend([
                "TRUE" if app["app_id"] in managed or already else "FALSE",
                app["name"], "Existing shortcut (kept)" if already else "Managed here", app["app_id"],
            ])
        selected = subprocess.run(arguments, capture_output=True, text=True)
        if selected.returncode == 10:
            consent = subprocess.run([
                "zenity", "--question", "--title=Refresh Windows Apps", "--default-cancel",
                "--text=Read the Windows Start menu now?\nWindows starts if needed. "
                "An existing Windows viewer briefly reconnects; apps are not closed.",
            ])
            if consent.returncode == 0:
                refresh()
            continue
        if selected.returncode != 0:
            return
        apply_selection(catalog["apps"], set(selected.stdout.splitlines()))
        subprocess.run([
            "zenity", "--info", "--title=Windows Apps", "--text=Windows shortcuts updated.\n"
            "Search for the app name followed by (Windows) in AGS/Walker.\n"
            "Launching one may take over the shared Windows desktop connection.",
        ])
        return


def main():
    parser = argparse.ArgumentParser(description="Choose Windows apps to expose as NixOS launchers.")
    parser.add_argument("command", choices=("gui", "refresh", "list"), nargs="?", default="gui")
    arguments = parser.parse_args()
    try:
        if arguments.command == "refresh":
            print(json.dumps(refresh()))
        elif arguments.command == "list":
            print(json.dumps(load_catalog()))
        else:
            gui()
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        if arguments.command == "gui":
            subprocess.run(["zenity", "--error", "--title=Windows Apps", f"--text={error}"])
        else:
            parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
