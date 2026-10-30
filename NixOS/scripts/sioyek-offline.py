import hashlib
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile


def offline_path(argument, home):
    path = Path(os.path.abspath(os.path.expanduser(argument)))
    private = home / "Scramble Private"
    mappings = (
        (home / "Scramble Public/References", private / "References"),
        (home / "Scramble Public/PublicSync/Current", private),
        (home / "Documents/Scramble References", private / "References"),
        (home / "Documents/Scramble Public", private),
        (home / "Documents/Scramble Sync", private),
        (home / "Scramble Public/Misc", private / "Misc"),
    )
    for remote_root, local_root in mappings:
        if path.is_relative_to(remote_root):
            local_path = local_root / path.relative_to(remote_root)
            return str(local_path) if local_path.is_file() else None
    if path.is_relative_to(home / "Scramble Public"):
        return None
    recovery_root = home / ".cache/sioyek-recovery"
    if path.is_relative_to(recovery_root):
        local_path = private / "References" / path.relative_to(recovery_root)
        if local_path.is_file():
            return str(local_path)
    return argument


def migrate_session(data_directory, home):
    session = data_directory / "last_document_path.txt"
    if not session.is_file():
        return
    original = session.read_text()
    lines = []
    for line in original.splitlines():
        if line.startswith("[window]") or not line:
            lines.append(line)
            continue
        local_path = offline_path(line, home)
        if local_path is not None and Path(local_path).is_file():
            lines.append(local_path)
    updated = "\n".join(lines) + ("\n" if lines else "")
    if updated != original:
        backup = session.with_name(session.name + ".before-offline.bak")
        if not backup.exists():
            shutil.copy2(session, backup)
        with tempfile.NamedTemporaryFile(mode="w", dir=data_directory, delete=False) as temporary:
            temporary.write(updated)
        os.replace(temporary.name, session)


def migrate_history(data_directory, home):
    database = data_directory / "local.db"
    if not database.is_file():
        return
    connection = sqlite3.connect(database, timeout=2)
    try:
        updates = []
        for identifier, original_path, checksum in connection.execute(
            "SELECT id, path, hash FROM document_hash"
        ):
            local_path = offline_path(original_path, home)
            if local_path is None or local_path == original_path:
                continue
            with open(local_path, "rb") as document:
                local_checksum = hashlib.file_digest(document, "md5").hexdigest()
            if local_checksum == checksum:
                updates.append((local_path, identifier))
        if updates:
            backup = database.with_name(database.name + ".before-offline.bak")
            if not backup.exists():
                with sqlite3.connect(backup) as backup_connection:
                    connection.backup(backup_connection)
            with connection:
                for local_path, identifier in updates:
                    result = connection.execute(
                        "UPDATE OR IGNORE document_hash SET path = ? WHERE id = ?",
                        (local_path, identifier),
                    )
                    if result.rowcount == 0:
                        connection.execute("DELETE FROM document_hash WHERE id = ?", (identifier,))
    finally:
        connection.close()


def qt_platform(environment):
    override = environment.get("QT_QPA_PLATFORM")
    if override:
        return override
    display = environment.get("WAYLAND_DISPLAY")
    if display:
        display_path = Path(display)
        if not display_path.is_absolute():
            runtime_directory = environment.get("XDG_RUNTIME_DIR")
            if not runtime_directory:
                return "xcb"
            display_path = Path(runtime_directory) / display_path
        if display_path.is_socket():
            return "wayland"
    return "xcb"


def main(arguments):
    home = Path.home()
    converted = []
    for argument in arguments:
        local_path = offline_path(argument, home)
        if local_path is None:
            message = (
                f"No offline copy of {Path(argument).name}. "
                "Let Scramble finish downloading, then reopen it from Scramble Private."
            )
            print(message, file=sys.stderr)
            if shutil.which("notify-send"):
                subprocess.run(["notify-send", "Sioyek", message], check=False)
            return 1
        converted.append(local_path)
    data_directory = Path(os.environ.get("XDG_DATA_HOME", home / ".local/share")) / "sioyek"
    try:
        migrate_session(data_directory, home)
        migrate_history(data_directory, home)
    except (OSError, sqlite3.Error) as error:
        print(f"Could not update Sioyek's offline paths: {error}", file=sys.stderr)
        return 1
    trace = Path(os.environ.get("XDG_STATE_HOME", home / ".local/state")) / "sioyek/ui.log"
    trace.parent.mkdir(parents=True, exist_ok=True)
    os.environ["SIOYEK_UI_TRACE"] = str(trace)
    os.environ["QT_QPA_PLATFORM"] = qt_platform(os.environ)
    binary = os.environ.get("SIOYEK_BINARY", "/run/current-system/sw/bin/sioyek")
    os.execv(binary, ["sioyek", *converted])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
