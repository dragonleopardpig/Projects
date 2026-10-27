#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time


CONFIG_DIRECTORY = Path.home() / ".config/winapps"
MEMORY_FILE = CONFIG_DIRECTORY / "memory.env"
GIB = 1024**3
SHUTDOWN_TIMEOUT = 180
VIEWER_TIMEOUT = 360
LAUNCH_LOG = Path.home() / ".local/state/winapps/windows-launch.log"
VIEWER_LOG = Path.home() / ".local/share/winapps/freerdp-windows.log"


def host_memory():
    values = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        name, value = line.split(":", 1)
        if name in ("MemTotal", "MemAvailable"):
            values[name] = int(value.split()[0]) * 1024
    return values


def limits():
    maximum = host_memory()["MemTotal"] // GIB - 4
    if maximum < 4:
        raise ValueError("Windows needs at least 4 GiB plus 4 GiB reserved for NixOS.")
    return 4, maximum


def host_cpus():
    try:
        return len(os.sched_getaffinity(0))
    except AttributeError:
        return os.cpu_count() or 1


def configured_settings():
    settings = {"ram_gib": 4, "cpus": 4, "desktop_scale": 100, "fullscreen": False}
    if not MEMORY_FILE.exists():
        return settings
    seen = set()
    for line in MEMORY_FILE.read_text().splitlines():
        if not line.strip():
            continue
        memory = re.fullmatch(r"WINAPPS_RAM_SIZE=(\d+)G", line.strip())
        processors = re.fullmatch(r"WINAPPS_CPU_CORES=(\d+)", line.strip())
        scale = re.fullmatch(r"WINAPPS_DESKTOP_SCALE=(\d+)", line.strip())
        fullscreen = re.fullmatch(r"WINAPPS_FULLSCREEN=([01])", line.strip())
        if memory:
            key, amount = "ram_gib", int(memory.group(1))
        elif processors:
            key, amount = "cpus", int(processors.group(1))
        elif scale:
            key, amount = "desktop_scale", int(scale.group(1))
        elif fullscreen:
            key, amount = "fullscreen", int(fullscreen.group(1))
        else:
            raise ValueError(f"Invalid Windows resource setting in {MEMORY_FILE}")
        minimum = 4 if key == "ram_gib" else 0 if key == "fullscreen" else 1
        if key in seen or amount < minimum:
            raise ValueError(f"Invalid or duplicate Windows resource setting in {MEMORY_FILE}")
        seen.add(key)
        settings[key] = bool(amount) if key == "fullscreen" else amount
    if not 100 <= settings["desktop_scale"] <= 500:
        raise ValueError("Windows desktop scale must be between 100% and 500%.")
    return settings


def status():
    configured = configured_settings()
    details = {
        "configured_gib": configured["ram_gib"],
        "configured_cpus": configured["cpus"],
        "configured_desktop_scale": configured["desktop_scale"],
        "configured_fullscreen": configured["fullscreen"],
        "running_gib": None,
        "running_cpus": None,
        "state": "unknown",
        "pending": False,
        "host_available_gib": round(host_memory()["MemAvailable"] / GIB, 1),
        "host_cpus": host_cpus(),
    }
    result = subprocess.run(
        ["podman", "inspect", "WinApps"], capture_output=True, text=True, timeout=10
    )
    if result.returncode == 0:
        container = json.loads(result.stdout)[0]
        details["state"] = container["State"]["Status"]
        if details["state"] in ("running", "paused", "restarting"):
            for entry in container["Config"]["Env"]:
                match = re.fullmatch(r"RAM_SIZE=(\d+)G", entry)
                if match:
                    details["running_gib"] = int(match.group(1))
                match = re.fullmatch(r"CPU_CORES=(\d+)", entry)
                if match:
                    details["running_cpus"] = int(match.group(1))
    elif "no such" in result.stderr.lower():
        details["state"] = "not created"
    details["pending"] = any(
        details[running] is not None and details[running] != details[saved]
        for running, saved in (
            ("running_gib", "configured_gib"),
            ("running_cpus", "configured_cpus"),
        )
    )
    return details


def validate_settings(amount, processors, desktop_scale=None, fullscreen=None):
    minimum, maximum = limits()
    if not minimum <= amount <= maximum:
        raise ValueError(f"Choose {minimum}–{maximum} GiB; leave at least 4 GiB for NixOS.")
    if not 1 <= processors <= host_cpus():
        raise ValueError(f"Choose 1–{host_cpus()} vCPUs to stay within the host's available CPUs.")
    if desktop_scale is None:
        desktop_scale = configured_settings()["desktop_scale"]
    if not 100 <= desktop_scale <= 500:
        raise ValueError("Windows desktop scale must be between 100% and 500%.")
    if fullscreen is None:
        fullscreen = configured_settings()["fullscreen"]
    if not isinstance(fullscreen, bool):
        raise ValueError("Fullscreen must be on or off.")
    return amount, processors, desktop_scale, fullscreen


def save_settings(amount, processors, desktop_scale=None, fullscreen=None):
    amount, processors, desktop_scale, fullscreen = validate_settings(
        amount, processors, desktop_scale, fullscreen,
    )
    CONFIG_DIRECTORY.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary_path = tempfile.mkstemp(prefix=".memory-", dir=CONFIG_DIRECTORY)
    try:
        with os.fdopen(descriptor, "w") as output:
            output.write(f"WINAPPS_RAM_SIZE={amount}G\n")
            output.write(f"WINAPPS_CPU_CORES={processors}\n")
            output.write(f"WINAPPS_DESKTOP_SCALE={desktop_scale}\n")
            output.write(f"WINAPPS_FULLSCREEN={int(fullscreen)}\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_path, MEMORY_FILE)
    finally:
        Path(temporary_path).unlink(missing_ok=True)


def dialog(kind, *arguments):
    return subprocess.run(
        ["zenity", kind, "--title=WinApps", "--width=580", *arguments],
        capture_output=True,
        text=True,
    )


def container_state():
    result = subprocess.run(
        ["podman", "inspect", "--format", "{{.State.Status}}", "WinApps"],
        capture_output=True, text=True, timeout=10,
    )
    if result.returncode == 0:
        return result.stdout.strip()
    if "no such" in result.stderr.lower():
        return "not created"
    raise ValueError("Could not check the Windows container. No forced shutdown was performed.")


def windows_viewers():
    result = subprocess.run(["hyprctl", "clients", "-j"], capture_output=True, text=True, timeout=5)
    if result.returncode != 0:
        raise ValueError("Could not check the existing Windows viewer. No additional viewer was opened.")
    return [client for client in json.loads(result.stdout) if client["class"] == "Microsoft Windows"]


def focus_windows(viewer, fullscreen):
    address = viewer["address"]
    if not re.fullmatch(r"0x[0-9a-fA-F]+", address):
        raise ValueError("The existing Windows viewer has an invalid window address.")
    mode = 2 if fullscreen else 0
    focused = subprocess.run(
        ["hyprctl", "--batch", f"dispatch focuswindow address:{address}; "
         f"dispatch fullscreenstate {mode} {mode} set"],
        capture_output=True, text=True, timeout=5,
    )
    if focused.returncode != 0 or any(
        line.strip() != "ok" for line in focused.stdout.splitlines() if line.strip()
    ):
        raise ValueError("Could not apply fullscreen to the Windows viewer.")


def open_windows(fullscreen=None, report=None, selection=None):
    if report is None:
        report = lambda message: None
    if selection is None:
        configured = configured_settings()
        selection = (
            configured["ram_gib"], configured["cpus"], configured["desktop_scale"], configured["fullscreen"],
        )
    if fullscreen is not None:
        selection = (*selection[:3], fullscreen)
    amount, processors, desktop_scale, fullscreen = validate_settings(*selection)
    hyprland = shutil.which("hyprctl") is not None
    if hyprland:
        viewers = windows_viewers()
        if viewers:
            state = container_state()
            if state == "paused":
                resumed = subprocess.run(
                    ["podman", "unpause", "WinApps"], capture_output=True, text=True, timeout=15,
                )
                if resumed.returncode != 0:
                    raise ValueError("Could not resume Windows. The existing viewer was left open.")
            if state in ("running", "paused"):
                focus_windows(viewers[0], fullscreen)
                return "Windows viewer is ready. Reused the existing connection without closing apps."
    LAUNCH_LOG.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(LAUNCH_LOG, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.chmod(LAUNCH_LOG, 0o600)
    environment = os.environ.copy()
    environment.update(
        WINAPPS_RAM_SIZE=f"{amount}G", WINAPPS_CPU_CORES=str(processors),
        WINAPPS_DESKTOP_SCALE=str(desktop_scale), WINAPPS_FULLSCREEN=str(int(fullscreen)),
    )
    with os.fdopen(descriptor, "w") as output:
        process = subprocess.Popen(
            ["winapps", "windows"], stdout=output, stderr=output, start_new_session=True, env=environment,
        )
    if not hyprland:
        return "Windows viewer launch requested."
    started = time.monotonic()
    while True:
        viewers = windows_viewers()
        if viewers:
            focus_windows(viewers[0], fullscreen)
            return "Windows viewer is ready."
        result = process.poll()
        if result is not None:
            raise ValueError(
                f"Windows viewer exited before opening (status {result}). Windows was not stopped.\n"
                f"Connection details: {VIEWER_LOG}\nLauncher details: {LAUNCH_LOG}"
            )
        elapsed = int(time.monotonic() - started)
        if elapsed >= VIEWER_TIMEOUT:
            raise ValueError(
                "The Windows viewer has not appeared yet. Windows was left running.\n"
                f"Check {VIEWER_LOG} and {LAUNCH_LOG}."
            )
        report(f"Waiting for the Windows viewer… {elapsed} s. Windows may still be starting.")
        time.sleep(0.5)


def shutdown_windows(report=None):
    if report is None:
        report = lambda message: None
    state = container_state()
    if state in ("exited", "stopped", "created", "not created"):
        return "Windows is already shut down. No Windows apps are running."
    if state not in ("running", "paused"):
        raise ValueError(f"Windows is {state}. Wait until it finishes starting or stopping, then try again.")
    report("Requesting a normal Windows shutdown. Respond to any unsaved-work prompts in the Windows viewer.")
    if state == "paused":
        report("Resuming Windows so it can shut down normally…")
        resumed = subprocess.run(
            ["podman", "unpause", "WinApps"], capture_output=True, text=True, timeout=15,
        )
        if resumed.returncode != 0:
            raise ValueError("Could not resume Windows to request a normal shutdown.")
    request = subprocess.run(
        ["podman", "exec", "WinApps", "sh", "-c",
         'test -S /run/shm/monitor.sock && printf "system_powerdown\\n" '
         '| nc -q 1 -w 2 -U /run/shm/monitor.sock'],
        capture_output=True, text=True, timeout=15,
    )
    if request.returncode != 0:
        raise ValueError("Could not request a normal Windows shutdown. No forced shutdown was performed.")
    started = time.monotonic()
    while container_state() not in ("exited", "stopped", "not created"):
        elapsed = int(time.monotonic() - started)
        if elapsed >= SHUTDOWN_TIMEOUT:
            raise ValueError(
                "Windows has not finished shutting down. No forced shutdown was performed.\n"
                "Check the Windows viewer for unsaved-work prompts or updates.\n"
                "If Windows is paused, reopen the Windows viewer to resume it."
            )
        report(f"Waiting for Windows to shut down… {elapsed} s. Resolve any save prompts in the Windows viewer.")
        time.sleep(2)
    report("Windows has stopped. Closing its viewer connections…")
    disconnected = subprocess.run(
        ["winapps", "killrdp"], capture_output=True, text=True, timeout=30,
    )
    if disconnected.returncode != 0:
        return "Windows is shut down, but some viewer windows could not be closed. You can close them manually."
    return "Windows and all background Windows apps are shut down. RAM is released. Open Windows to start again."


def gui():
    import gi

    gi.require_version("Gtk", "3.0")
    from gi.repository import Gio, GLib

    GLib.set_prgname("io.github.winapps.Settings")
    GLib.set_application_name("WinApps")
    from gi.repository import Gtk

    details = status()
    minimum, maximum = limits()
    application = Gtk.Application(application_id="io.github.winapps.Settings", flags=Gio.ApplicationFlags.FLAGS_NONE)

    def activate(application):
        existing = application.get_active_window()
        if existing:
            existing.present()
            return
        window = Gtk.ApplicationWindow(application=application, title="WinApps", default_width=640)
        window.set_border_width(16)
        window.set_position(Gtk.WindowPosition.CENTER)
        window.set_icon_name("preferences-system")
        layout = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        window.add(layout)
        header = Gtk.Label(xalign=0, wrap=True, max_width_chars=75)
        layout.pack_start(header, False, False, 0)
        grid = Gtk.Grid(row_spacing=10, column_spacing=20)
        layout.pack_start(grid, False, False, 0)
        fields = {}
        for row, (key, label, value, lower, upper, step) in enumerate((
            ("ram", "RAM (GiB)", details["configured_gib"], minimum, maximum, 1),
            ("cpus", "CPU (vCPUs)", details["configured_cpus"], 1, details["host_cpus"], 1),
            ("scale", "Windows desktop scale (%)", details["configured_desktop_scale"], 100, 500, 25),
        )):
            field = Gtk.SpinButton.new_with_range(lower, upper, step)
            field.set_name(key)
            field.set_numeric(True)
            field.set_value(max(lower, min(upper, value)))
            field.set_hexpand(True)
            fields[key] = field
            grid.attach(Gtk.Label(label=label, xalign=0), 0, row, 1, 1)
            grid.attach(field, 1, row, 1, 1)
        fullscreen = Gtk.CheckButton(label="Fullscreen Windows desktop")
        fullscreen.set_name("fullscreen")
        fullscreen.set_active(details["configured_fullscreen"])
        grid.attach(fullscreen, 0, 3, 2, 1)
        hint = Gtk.Label(
            label="Fullscreen hides the bar only on Windows' workspace.\n"
            "Open Windows uses these inputs without changing defaults.\n"
            "Set as default remembers these values for future launches.\n"
            "CPU/RAM: Shut down all WinApps, then Open Windows.\n"
            "Scale: reconnect the viewer. Fullscreen applies immediately.\n"
            "Shutdown closes ALL Windows apps. Save Windows/Office work first.",
            xalign=0, wrap=True, max_width_chars=75,
        )
        layout.pack_start(hint, False, False, 0)
        buttons = Gtk.Grid(row_spacing=8, column_spacing=8, column_homogeneous=True)
        layout.pack_start(buttons, False, False, 0)
        progress = Gtk.ProgressBar(show_text=True, text="Ready")
        progress.set_name("progress")
        layout.pack_start(progress, False, False, 0)
        message = Gtk.Label(label="Choose values and open Windows. Set as default is optional.",
                            xalign=0, wrap=True, max_width_chars=75, selectable=True)
        message.set_name("status")
        layout.pack_start(message, False, False, 0)
        activity = {"busy": False, "refreshing": False, "confirmed": None}
        controls = [*fields.values(), fullscreen]

        def update_header(updated):
            details.update(updated)
            allocated = (
                f"Allocated: {details['running_gib']} GiB, {details['running_cpus']} vCPUs.\n"
                if details["running_gib"] is not None else ""
            )
            header.set_text(
                f"Windows: {details['state']}.\n{allocated}"
                f"Defaults: {details['configured_gib']} GiB, {details['configured_cpus']} vCPUs.\n"
                f"Host: {details['host_cpus']} logical CPUs; {details['host_available_gib']} GiB RAM available."
            )
            return False

        def report(text):
            GLib.idle_add(message.set_text, text)

        def pulse():
            if not activity["busy"]:
                return False
            progress.pulse()
            return True

        def finish(text, success, updated, selection):
            activity["busy"] = False
            for control in controls:
                control.set_sensitive(True)
            progress.set_fraction(1 if success else 0)
            pending = success and updated and selection is not None and any(
                updated[running] is not None and updated[running] != selected
                for running, selected in (
                    ("running_gib", selection[0]), ("running_cpus", selection[1]),
                )
            )
            if pending:
                text += (
                    f"\nWindows is still allocated {updated['running_gib']} GiB, {updated['running_cpus']} vCPUs. "
                    f"Requested for this launch: {selection[0]} GiB, {selection[1]} vCPUs.\n"
                    "Save your Windows work, click Shut down all WinApps, then Open Windows with these input values. "
                    "Reopening the viewer alone does not change CPU/RAM."
                )
            progress.set_text("Shutdown/start needed" if pending else "Complete" if success else "Action needed")
            message.set_text(text)
            if updated:
                update_header(updated)
            return False

        def run_action(text, operation, selection=None):
            if activity["busy"]:
                return
            activity["busy"] = True
            for control in controls:
                control.set_sensitive(False)
            message.set_text(text)
            progress.set_fraction(0)
            progress.set_text("Working…")
            GLib.timeout_add(100, pulse)

            def worker():
                try:
                    result = operation()
                    updated = status()
                except (OSError, ValueError, subprocess.SubprocessError) as error:
                    GLib.idle_add(finish, str(error), False, None, selection)
                else:
                    GLib.idle_add(finish, result, True, updated, selection)

            threading.Thread(target=worker, daemon=True).start()

        def selected_settings(action):
            for field in fields.values():
                field.update()
            selected = (
                fields["ram"].get_value_as_int(), fields["cpus"].get_value_as_int(),
                fields["scale"].get_value_as_int(), fullscreen.get_active(),
            )
            amount, processors, _, _ = selected
            warnings = []
            additional = max(0, amount - (details["running_gib"] or 0))
            if additional * GIB > host_memory()["MemAvailable"] - 2 * GIB:
                warnings.append("This RAM allocation may cause heavy swapping.")
            if details["host_cpus"] > 1 and processors > max(1, details["host_cpus"] - 2):
                warnings.append("Using nearly all CPUs may make NixOS less responsive.")
            if warnings and activity["confirmed"] != (action, selected):
                activity["confirmed"] = (action, selected)
                message.set_text("\n".join(warnings) + f"\nClick {action} again to confirm these values.")
                progress.set_text("Review warning")
                return None
            activity["confirmed"] = None
            return selected

        def open_desktop(_button):
            selected = selected_settings("Open Windows")
            if selected is None:
                return

            def operation():
                return open_windows(report=report, selection=selected)

            run_action("Opening Windows with the current input values…", operation, selected)

        def set_defaults(_button):
            selected = selected_settings("Set as default")
            if selected is None:
                return
            amount, processors, desktop_scale, selected_fullscreen = selected

            def operation():
                save_settings(amount, processors, desktop_scale, selected_fullscreen)
                return (
                    f"Defaults set: {amount} GiB, {processors} vCPUs, scale {desktop_scale}%, "
                    f"fullscreen {'on' if selected_fullscreen else 'off'}.\n"
                    "Future launches use these defaults unless you change the inputs. "
                    "Windows and its running apps were not changed."
                )

            run_action("Setting default values…", operation)

        def choose_apps(_button):
            def operation():
                subprocess.run(["winapps-apps", "gui"], check=True)
                return "Windows app selection closed. WinApps remains open."

            run_action("Choosing Windows app shortcuts…", operation)

        for column, row, label, callback in (
            (0, 0, "Open Windows", open_desktop),
            (1, 0, "Choose Windows apps…", choose_apps),
            (0, 1, "Set as default", set_defaults),
            (1, 1, "Shut down all WinApps", lambda _button: run_action(
                "Requesting a normal Windows shutdown…", lambda: shutdown_windows(report))),
        ):
            button = Gtk.Button(label=label)
            button.connect("clicked", callback)
            buttons.attach(button, column, row, 1, 1)
            controls.append(button)
        close = Gtk.Button(label="Close")
        close.connect("clicked", lambda _button: window.close())
        controls.append(close)
        layout.pack_start(close, False, False, 0)
        window.connect("delete-event", lambda _window, _event: activity["busy"])

        def refresh():
            if not window.get_visible():
                return False
            if not activity["busy"] and not activity["refreshing"]:
                activity["refreshing"] = True

                def read_status():
                    try:
                        updated = status()
                    except (OSError, ValueError, subprocess.SubprocessError):
                        pass
                    else:
                        GLib.idle_add(update_header, updated)
                    finally:
                        activity["refreshing"] = False

                threading.Thread(target=read_status, daemon=True).start()
            return True

        update_header(details)
        window.show_all()
        GLib.timeout_add_seconds(5, refresh)

    application.connect("activate", activate)
    application.run([])


def main():
    parser = argparse.ArgumentParser(description="Manage WinApps resources, apps, and Windows shutdown.")
    parser.add_argument("command", nargs="?", choices=("gui", "status", "get", "set", "shutdown", "windows"), default="gui")
    parser.add_argument("amount", nargs="?", type=int, help="Windows RAM in GiB")
    parser.add_argument("--cpus", type=int, help="Windows virtual CPU count")
    parser.add_argument("--desktop-scale", type=int, help="Full Windows desktop scale in percent (100–500)")
    parser.add_argument("--fullscreen", choices=("on", "off"), help="Open the full Windows desktop fullscreen")
    arguments = parser.parse_args()
    if arguments.command != "set" and any(value is not None for value in (arguments.amount, arguments.cpus, arguments.desktop_scale, arguments.fullscreen)):
        parser.error("resource values are only valid with set")
    try:
        if arguments.command == "status":
            print(json.dumps(status()))
        elif arguments.command == "get":
            print(configured_settings()["ram_gib"])
        elif arguments.command == "shutdown":
            if not sys.stdin.isatty():
                parser.error("Use the WinApps window for shutdown, or run this command in an interactive terminal.")
            answer = input("Save all Windows/Office work first. Shut down all WinApps? [y/N] ")
            if answer.strip().lower() in ("y", "yes"):
                print(shutdown_windows(print))
        elif arguments.command == "windows":
            print(open_windows(report=print))
        elif arguments.command == "set":
            if all(value is None for value in (arguments.amount, arguments.cpus, arguments.desktop_scale, arguments.fullscreen)):
                parser.error("set requires a RAM amount, --cpus, --desktop-scale, or --fullscreen")
            configured = configured_settings()
            amount = arguments.amount if arguments.amount is not None else configured["ram_gib"]
            processors = arguments.cpus if arguments.cpus is not None else configured["cpus"]
            desktop_scale = arguments.desktop_scale if arguments.desktop_scale is not None else configured["desktop_scale"]
            fullscreen = arguments.fullscreen == "on" if arguments.fullscreen is not None else configured["fullscreen"]
            save_settings(amount, processors, desktop_scale, fullscreen)
            print(f"Saved {amount} GiB, {processors} vCPUs (next full start), desktop scale {desktop_scale}% (next viewer connection), fullscreen {'on' if fullscreen else 'off'} (Open Windows).")
        else:
            gui()
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        if arguments.command == "gui":
            dialog("--error", f"--text={error}")
        else:
            parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
