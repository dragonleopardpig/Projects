#!/usr/bin/env python3
"""
Proton Drive Sync & Tray Manager for NixOS / Hyprland / Nemo
Manages rclone mount, bidirectional folder syncing (bisync), tray indicator,
settings GUI, and Nemo context actions.
"""

import argparse
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
import time

CONFIG_DIR = Path.home() / ".config/protondrive-sync"
CONFIG_FILE = CONFIG_DIR / "config.json"
DEFAULT_MOUNT_POINT = Path.home() / "Proton Drive"
LOG_FILE = Path.home() / ".local/state/protondrive-sync/sync.log"

# Search paths for custom icons
SCRIPT_DIR = Path(__file__).resolve().parent
ASSET_ICONS = SCRIPT_DIR.parent / "assets/protondrive-icons"
USER_ICONS = Path.home() / ".local/share/icons/hicolor/scalable/apps"


def get_icon_path(name: str) -> str:
    candidates = []
    if "PROTONDRIVE_ICONS_DIR" in os.environ:
        candidates.append(Path(os.environ["PROTONDRIVE_ICONS_DIR"]) / f"{name}.svg")
    candidates.extend([
        USER_ICONS / f"{name}.svg",
        Path.home() / "Projects/NixOS/assets/protondrive-icons" / f"{name}.svg",
        ASSET_ICONS / f"{name}.svg",
        ASSET_ICONS / f"{name}.png",
    ])
    for c in candidates:
        if c.exists():
            return str(c.resolve())
    # Fallback system icon names
    fallbacks = {
        "protondrive": "protondrive",
        "protondrive-syncing": "emblem-synchronizing",
        "protondrive-paused": "media-playback-pause",
        "protondrive-error": "dialog-warning",
    }
    return fallbacks.get(name, "protondrive")


def send_notification(title: str, message: str, icon: str = None, urgency: str = "normal"):
    notify_send = shutil.which("notify-send")
    if notify_send:
        try:
            icon_arg = icon or get_icon_path("protondrive")
            subprocess.run(
                [notify_send, "-a", "Proton Drive", "-i", icon_arg, "-u", urgency, title, message],
                check=False,
            )
        except Exception:
            pass


class ConfigManager:
    """Manages synced folders and sync state in ~/.config/protondrive-sync/config.json"""

    def __init__(self):
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        self.data = self._load()
        self._last_mtime = self._get_mtime()

    def _get_mtime(self) -> float:
        try:
            return CONFIG_FILE.stat().st_mtime
        except Exception:
            return 0.0

    def has_changed_on_disk(self) -> bool:
        return self._get_mtime() != self._last_mtime

    def reload_if_needed(self):
        if self.has_changed_on_disk():
            self.data = self._load()
            self._last_mtime = self._get_mtime()

    def _load(self) -> dict:
        default_config = {
            "remote": "protondrive",
            "mount_point": str(DEFAULT_MOUNT_POINT),
            "auto_sync_interval_minutes": 10,
            "paused": False,
            "notify_on_sync": False,
            "folders": [],
        }
        if CONFIG_FILE.exists():
            try:
                with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                    cfg = json.load(f)
                    default_config.update(cfg)
            except Exception as e:
                print(f"[WARN] Failed to read config: {e}. Using defaults.")
        return default_config

    def save(self):
        try:
            with open(CONFIG_FILE, "w", encoding="utf-8") as f:
                json.dump(self.data, f, indent=2)
            self._last_mtime = self._get_mtime()
        except Exception as e:
            print(f"[ERROR] Failed to save config: {e}")

    def get_folders(self) -> list:
        return self.data.get("folders", [])

    def add_folder(self, local_path: str, remote_path: str, mode: str = "bisync") -> dict:
        self.reload_if_needed()
        local_abs = str(Path(local_path).resolve())
        folders = self.get_folders()

        for f in folders:
            if Path(f["local_path"]).resolve() == Path(local_abs):
                f["remote_path"] = remote_path
                f["mode"] = mode
                f["enabled"] = True
                f["status"] = "idle"
                self.save()
                return f

        entry = {
            "id": f"folder_{int(time.time() * 1000)}",
            "local_path": local_abs,
            "remote_path": remote_path,
            "mode": mode,
            "enabled": True,
            "status": "idle",
            "last_sync": "Never",
            "error": "",
            "resync_needed": True if mode == "bisync" else False,
        }
        folders.append(entry)
        self.data["folders"] = folders
        self.save()
        return entry

    def remove_folder(self, folder_id: str):
        self.reload_if_needed()
        self.data["folders"] = [f for f in self.get_folders() if f["id"] != folder_id]
        self.save()

    def update_folder_status(self, folder_id: str, status: str, last_sync: str = None, error: str = "", resync_needed: bool = False):
        self.reload_if_needed()
        for f in self.get_folders():
            if f["id"] == folder_id:
                f["status"] = status
                if last_sync:
                    f["last_sync"] = last_sync
                f["error"] = error
                f["resync_needed"] = resync_needed
                break
        self.save()


class RcloneOps:
    """Wrapper for rclone commands"""

    @staticmethod
    def rclone_bin() -> str:
        return shutil.which("rclone") or "/run/current-system/sw/bin/rclone"

    @staticmethod
    def fusermount_bin() -> str:
        return "/run/wrappers/bin/fusermount3" if Path("/run/wrappers/bin/fusermount3").exists() else "fusermount3"

    @staticmethod
    def is_mounted(mount_point: str) -> bool:
        p = Path(mount_point).resolve()
        if not p.exists():
            return False
        try:
            with open("/proc/mounts", "r") as f:
                for line in f:
                    parts = line.split()
                    if len(parts) >= 2 and parts[1] == str(p):
                        return True
        except Exception:
            pass
        return os.path.ismount(str(p))

    @classmethod
    def mount_drive(cls, remote: str, mount_point: str) -> tuple[bool, str]:
        if cls.is_mounted(mount_point):
            return True, "Already mounted"
        Path(mount_point).mkdir(parents=True, exist_ok=True)

        # Check systemd user service first
        try:
            res = subprocess.run(["systemctl", "--user", "start", "protondrive-mount"], capture_output=True, text=True, timeout=15)
            if res.returncode == 0:
                cls.ensure_gtk_bookmark(mount_point, "Proton Drive")
                return True, "Mounted successfully via systemd"
        except Exception:
            pass

        rclone = cls.rclone_bin()
        cmd = [
            rclone,
            "mount",
            f"{remote}:",
            str(mount_point),
            "--vfs-cache-mode=full",
            "--vfs-cache-max-size=10G",
            "--vfs-cache-max-age=24h",
            "--umask=077",
            "--dir-cache-time=1m",
            "--daemon",
        ]
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
            if res.returncode == 0:
                cls.ensure_gtk_bookmark(mount_point, "Proton Drive")
                return True, "Mounted successfully"
            return False, res.stderr or "Mount failed"
        except Exception as e:
            return False, str(e)

    @classmethod
    def unmount_drive(cls, mount_point: str) -> tuple[bool, str]:
        if not cls.is_mounted(mount_point):
            return True, "Not mounted"

        try:
            res = subprocess.run(["systemctl", "--user", "stop", "protondrive-mount"], capture_output=True, text=True, timeout=10)
            if res.returncode == 0:
                return True, "Unmounted successfully via systemd"
        except Exception:
            pass

        fuser = cls.fusermount_bin()
        try:
            res = subprocess.run([fuser, "-u", str(mount_point)], capture_output=True, text=True, timeout=10)
            if res.returncode == 0:
                return True, "Unmounted successfully"
            return False, res.stderr or "Unmount failed"
        except Exception as e:
            return False, str(e)

    @staticmethod
    def ensure_gtk_bookmark(path: str, label: str):
        bookmarks = Path.home() / ".config/gtk-3.0/bookmarks"
        uri = Path(path).resolve().as_uri()
        entry = f"{uri} {label}"
        try:
            content = bookmarks.read_text(encoding="utf-8") if bookmarks.exists() else ""
            if uri not in content:
                bookmarks.parent.mkdir(parents=True, exist_ok=True)
                with bookmarks.open("a", encoding="utf-8") as f:
                    if content and not content.endswith("\n"):
                        f.write("\n")
                    f.write(entry + "\n")
        except Exception:
            pass

    @staticmethod
    def _is_pid_alive(pid: int) -> bool:
        if pid <= 0:
            return False
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    @classmethod
    def sync_folder(cls, folder: dict) -> tuple[bool, str]:
        rclone = cls.rclone_bin()
        local_path = folder["local_path"]
        remote_path = folder["remote_path"]
        mode = folder.get("mode", "bisync")
        resync = folder.get("resync_needed", False)

        if not Path(local_path).exists():
            return False, f"Local path '{local_path}' does not exist"

        # Ensure local directory exists
        try:
            Path(local_path).mkdir(parents=True, exist_ok=True)
        except Exception:
            pass

        # Check for active bisync locks for this local path
        if mode == "bisync":
            cache_dir = Path.home() / ".cache/rclone/bisync"
            if cache_dir.exists():
                loc_pattern = local_path.replace("/", "_").strip("_")
                for lck in cache_dir.glob("*.lck"):
                    if loc_pattern in lck.name:
                        try:
                            lck_data = json.loads(lck.read_text(encoding="utf-8"))
                            lck_pid = int(lck_data.get("PID", 0))
                            if lck_pid > 0 and cls._is_pid_alive(lck_pid):
                                return False, f"Sync already in progress (PID {lck_pid})"
                            else:
                                lck.unlink(missing_ok=True)
                        except Exception:
                            pass

        # Ensure remote directory exists before syncing
        if ":" in remote_path:
            try:
                subprocess.run([rclone, "mkdir", remote_path], capture_output=True, text=True, timeout=60)
            except Exception:
                pass

        # Bisync requires --resync on first run, or when explicitly requested
        is_first_sync = folder.get("last_sync") in ("Never", None, "", "null")
        needs_resync = resync or is_first_sync

        if mode == "bisync":
            cmd = [rclone, "bisync", local_path, remote_path, "--max-lock", "15m", "--verbose"]
            if needs_resync:
                cmd.append("--resync")
        elif mode == "sync_up":
            cmd = [rclone, "sync", local_path, remote_path, "--verbose"]
        elif mode == "sync_down":
            cmd = [rclone, "sync", remote_path, local_path, "--verbose"]
        else:
            return False, f"Unknown sync mode: {mode}"

        def run_logged_cmd(command: list[str], timeout_s: int) -> tuple[int, str, str]:
            LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
            log_line = f"[{datetime.datetime.now().isoformat()}] RUN: {' '.join(command)}\n"
            stdout_chunks: list[str] = []
            stderr_chunks: list[str] = []
            with open(LOG_FILE, "a", encoding="utf-8") as log:
                log.write(log_line)
                log.flush()

            proc = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )

            def pump(stream, sink):
                try:
                    for line in iter(stream.readline, ""):
                        sink.append(line)
                        with open(LOG_FILE, "a", encoding="utf-8") as f:
                            f.write(line)
                            f.flush()
                except Exception:
                    pass
                finally:
                    stream.close()

            t_out = threading.Thread(target=pump, args=(proc.stdout, stdout_chunks), daemon=True)
            t_err = threading.Thread(target=pump, args=(proc.stderr, stderr_chunks), daemon=True)
            t_out.start()
            t_err.start()

            try:
                ret = proc.wait(timeout=timeout_s)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
                with open(LOG_FILE, "a", encoding="utf-8") as f:
                    f.write(f"[{datetime.datetime.now().isoformat()}] KILLED: process timed out after {timeout_s}s\n")
                    f.flush()
                raise

            t_out.join(timeout=3)
            t_err.join(timeout=3)
            with open(LOG_FILE, "a", encoding="utf-8") as f:
                f.write(f"EXIT: {ret}\n")
                f.flush()

            return ret, "".join(stdout_chunks), "".join(stderr_chunks)

        timeout_s = 14400 if needs_resync else 3600
        rclone_conf = Path.home() / ".config/rclone/rclone.conf"
        conf_mtime_before = rclone_conf.stat().st_mtime if rclone_conf.exists() else 0.0
        try:
            retcode, stdout_str, stderr_str = run_logged_cmd(cmd, timeout_s)
            conf_mtime_after = rclone_conf.stat().st_mtime if rclone_conf.exists() else 0.0
            if conf_mtime_after > conf_mtime_before and cls.is_mounted(str(DEFAULT_MOUNT_POINT)):
                subprocess.run(
                    ["systemctl", "--user", "restart", "protondrive-mount.service"],
                    check=False,
                    timeout=15,
                )

            if retcode == 0:
                return True, "Sync completed successfully"

            # Auto-retry with --resync if bisync was aborted and needs recovery
            if mode == "bisync" and "--resync" not in cmd and "Must run --resync to recover" in stderr_str:
                retry_cmd = cmd + ["--resync"]
                retcode, stdout_str, stderr_str = run_logged_cmd(retry_cmd, 14400)
                if retcode == 0:
                    return True, "Sync completed successfully"

            # Parse meaningful error message
            error_lines = [
                line.replace("ERROR :", "").strip()
                for line in stderr_str.splitlines()
                if "ERROR :" in line and "Must run --resync to recover" not in line and "Bisync aborted" not in line
            ]
            if error_lines:
                err_msg = error_lines[-1]
            elif stderr_str:
                err_msg = stderr_str.strip().splitlines()[-1]
            else:
                err_msg = f"Sync failed with exit code {retcode}"

            return False, err_msg
        except subprocess.TimeoutExpired:
            return False, "Sync timed out"
        except Exception as e:
            return False, str(e)


# ----------------------------------------------------------------------
# PROTON DRIVE ACCOUNT MANAGEMENT
# ----------------------------------------------------------------------

class AccountManager:
    """Manages Proton Drive account profile, storage quota, and auth flow."""

    ACCOUNT_FILE = CONFIG_DIR / "account.json"
    _mem_cache = None
    _mem_cache_time = 0

    @staticmethod
    def human_readable_bytes(size: int) -> str:
        if size <= 0:
            return "0 B"
        units = ["B", "KB", "MB", "GB", "TB", "PB"]
        idx = 0
        val = float(size)
        while val >= 1024.0 and idx < len(units) - 1:
            val /= 1024.0
            idx += 1
        return f"{val:.1f} {units[idx]}"

    @classmethod
    def get_account_info(cls, remote: str = "protondrive", force: bool = False, max_age_seconds: int = 300) -> dict:
        now = time.time()
        if not force and cls._mem_cache and (now - cls._mem_cache_time) < max_age_seconds:
            return cls._mem_cache

        # Check on-disk cache if not forced
        if not force and cls.ACCOUNT_FILE.exists():
            try:
                cached = json.loads(cls.ACCOUNT_FILE.read_text(encoding="utf-8"))
                age = now - cached.get("updated", 0)
                if age < max_age_seconds:
                    cls._mem_cache = cached
                    cls._mem_cache_time = now
                    return cached
            except Exception:
                pass

        info = cls._fetch_account_info(remote)
        if info.get("logged_in") or not cls.ACCOUNT_FILE.exists():
            try:
                CONFIG_DIR.mkdir(parents=True, exist_ok=True)
                cls.ACCOUNT_FILE.write_text(json.dumps(info, indent=2), encoding="utf-8")
            except Exception:
                pass
        cls._mem_cache = info
        cls._mem_cache_time = now
        return info

    @classmethod
    def _fetch_account_info(cls, remote: str) -> dict:
        default_result = {
            "logged_in": False,
            "name": "",
            "email": "",
            "usage_bytes": 0,
            "limit_bytes": 0,
            "usage_str": "0 B",
            "limit_str": "0 B",
            "percent_str": "0%",
            "percent_float": 0.0,
            "updated": time.time(),
            "error": None,
        }

        try:
            rclone = shutil.which("rclone") or "rclone"
            dump_res = subprocess.run([rclone, "config", "dump"], capture_output=True, text=True, timeout=5)
            if dump_res.returncode != 0:
                default_result["error"] = "rclone not available"
                return default_result

            all_conf = json.loads(dump_res.stdout or "{}")
            remote_conf = all_conf.get(remote)
            if not remote_conf:
                default_result["error"] = f"Account '{remote}' not configured in rclone"
                return default_result

            username = remote_conf.get("username", "")
            if not username or username == "proton-cli-session":
                name = "Proton Account"
                email_display = "Official CLI Session"
            else:
                name = username.split("@")[0] if "@" in username else username
                email_display = username

            # Prefer querying quota via the active FUSE mount's statvfs so we do not
            # spawn a separate `rclone about` process that could rotate Proton's
            # single-use OAuth refresh token out from under `protondrive-mount.service`.
            usage = 0
            limit = 0
            if RcloneOps.is_mounted(str(DEFAULT_MOUNT_POINT)):
                try:
                    st = os.statvfs(DEFAULT_MOUNT_POINT)
                    block = st.f_frsize if st.f_frsize > 0 else max(1, st.f_bsize)
                    total_bytes = st.f_blocks * block
                    avail_bytes = st.f_bavail * block
                    if 0 < total_bytes < (1 << 50):
                        limit = total_bytes
                        usage = max(0, total_bytes - avail_bytes)
                except Exception:
                    pass

            if limit == 0:
                rclone_conf = Path.home() / ".config/rclone/rclone.conf"
                conf_mtime_before = rclone_conf.stat().st_mtime if rclone_conf.exists() else 0.0
                about_res = subprocess.run([rclone, "about", f"{remote}:", "--json"], capture_output=True, text=True, timeout=25)
                conf_mtime_after = rclone_conf.stat().st_mtime if rclone_conf.exists() else 0.0
                if conf_mtime_after > conf_mtime_before and RcloneOps.is_mounted(str(DEFAULT_MOUNT_POINT)):
                    subprocess.run(
                        ["systemctl", "--user", "restart", "protondrive-mount.service"],
                        check=False,
                        timeout=15,
                    )
                if about_res.returncode == 0:
                    try:
                        about_data = json.loads(about_res.stdout)
                        limit = int(about_data.get("total", 0))
                        usage = int(about_data.get("used", 0))
                    except Exception:
                        pass

            pct = (usage / limit * 100) if limit > 0 else 0.0

            return {
                "logged_in": True,
                "name": name,
                "email": email_display,
                "usage_bytes": usage,
                "limit_bytes": limit,
                "usage_str": cls.human_readable_bytes(usage),
                "limit_str": cls.human_readable_bytes(limit) if limit > 0 else "Unlimited",
                "percent_str": f"{pct:.1f}%" if limit > 0 else "N/A",
                "percent_float": min(1.0, max(0.0, usage / limit)) if limit > 0 else 0.0,
                "updated": time.time(),
                "error": None,
            }
        except Exception as e:
            if cls.ACCOUNT_FILE.exists():
                try:
                    return json.loads(cls.ACCOUNT_FILE.read_text(encoding="utf-8"))
                except Exception:
                    pass
            default_result["error"] = str(e)
            return default_result

    @classmethod
    def connect_account(cls, remote: str = "protondrive"):
        """Launches interactive terminal to authenticate with Proton Drive."""
        rclone = shutil.which("rclone") or "rclone"
        terminal = shutil.which("kitty") or "xterm"
        protondrive_bin = shutil.which("protondrive") or str(Path.home() / ".local/bin/protondrive")
        if not Path(protondrive_bin).exists():
            protondrive_bin = str(Path.home() / "Projects/Protondrive-for-Linux/protondrive")

        script = f"""
set -e
echo '============================================================='
echo '          Proton Drive Account Setup & Authentication        '
echo '============================================================='
echo ' Choose your login method:'
echo ''
echo ' 1) Official Browser Login (Recommended - supports 2FA / SSO)'
echo ' 2) Terminal Password Sign-In (Official CLI / rclone)'
echo ' 3) Native rclone Configuration Wizard'
echo '============================================================='
echo ''
read -p "Select option [1-3] (Default: 1): " choice
choice="${{choice:-1}}"

if [ "$choice" = "1" ]; then
    echo ''
    echo '>>> Step 1/3: Launching official Proton browser sign-in...'
    echo '>>> A browser window will open. Complete authentication in your browser.'
    echo ''
    "{protondrive_bin}" --backend proton configure
    echo ''
    echo '>>> Step 2/3: Importing official Proton session into rclone remote "{remote}"...'
    "{protondrive_bin}" --backend rclone configure --from-proton-cli-session
    echo ''
    echo '>>> Step 3/3: Verifying connection & mounting Proton Drive...'
    "{protondrive_bin}" status || true
    protondrive-control mount || true
elif [ "$choice" = "2" ]; then
    echo ''
    echo '>>> Starting interactive Proton CLI configuration...'
    "{protondrive_bin}" --backend auto configure
    protondrive-control mount || true
elif [ "$choice" = "3" ]; then
    echo ''
    echo '>>> Starting rclone configuration wizard...'
    if {rclone} listremotes | grep -qx '{remote}:'; then
        {rclone} config reconnect '{remote}:'
    else
        {rclone} config create '{remote}' protondrive
    fi
    protondrive-control mount || true
fi

echo ''
echo '============================================================='
echo '  Proton Drive setup complete! You can close this window.    '
echo '============================================================='
sleep 2
"""
        cmd = [terminal, "-T", "Proton Drive Account Setup", "--", "bash", "-c", script]
        proc = subprocess.Popen(cmd)
        return proc

    @classmethod
    def disconnect_account(cls, remote: str = "protondrive", mount_point: str = None) -> tuple[bool, str]:
        """Unmounts and disconnects the Proton Drive account."""
        if mount_point:
            RcloneOps.unmount_drive(mount_point)
        try:
            subprocess.run(["systemctl", "--user", "stop", "protondrive-mount.service"], check=False, timeout=5)
        except Exception:
            pass

        rclone = shutil.which("rclone") or "rclone"
        subprocess.run([rclone, "config", "disconnect", f"{remote}:"], capture_output=True, text=True)

        proton_bin = shutil.which("proton-drive") or str(Path.home() / ".local/bin/proton-drive")
        if Path(proton_bin).exists():
            subprocess.run([proton_bin, "auth", "logout"], capture_output=True, text=True)

        cls._mem_cache = None
        cls.clear_cache()
        return True, "Account disconnected successfully"

    @classmethod
    def remove_account(cls, remote: str = "protondrive", mount_point: str = None) -> tuple[bool, str]:
        """Unmounts and completely removes the Proton Drive remote config."""
        if mount_point:
            RcloneOps.unmount_drive(mount_point)
        try:
            subprocess.run(["systemctl", "--user", "stop", "protondrive-mount.service"], check=False, timeout=5)
        except Exception:
            pass

        rclone = shutil.which("rclone") or "rclone"
        subprocess.run([rclone, "config", "delete", remote], capture_output=True, text=True)

        proton_bin = shutil.which("proton-drive") or str(Path.home() / ".local/bin/proton-drive")
        if Path(proton_bin).exists():
            subprocess.run([proton_bin, "auth", "logout"], capture_output=True, text=True)

        secret_tool = shutil.which("secret-tool")
        if secret_tool:
            subprocess.run([secret_tool, "clear", "service", "ch.proton.drive/drive-sdk-cli", "name", "auth-session"], capture_output=True, text=True)

        cls._mem_cache = None
        cls.clear_cache()
        return True, "Account removed successfully"

    @classmethod
    def clear_cache(cls):
        try:
            if cls.ACCOUNT_FILE.exists():
                cls.ACCOUNT_FILE.unlink()
        except Exception:
            pass


# ----------------------------------------------------------------------
# GTK3 GUI COMPONENTS
# ----------------------------------------------------------------------

def run_gui_app(start_mode: str = "tray", extra_arg: str = None):
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk, Gdk, GLib

    GLib.set_prgname("protondrive-settings")
    GLib.set_application_name("Proton Drive Sync")

    config_mgr = ConfigManager()
    mount_point = config_mgr.data.get("mount_point", str(DEFAULT_MOUNT_POINT))
    remote = config_mgr.data.get("remote", "protondrive")

    class AddFolderDialog(Gtk.Dialog):
        def __init__(self, parent, prefilled_path: str = None):
            super().__init__(title="Sync Folder with Proton Drive", transient_for=parent, flags=0)
            self.add_buttons(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL, Gtk.STOCK_OK, Gtk.ResponseType.OK)
            self.set_default_size(520, 260)
            self.set_border_width(12)

            box = self.get_content_area()
            grid = Gtk.Grid(column_spacing=12, row_spacing=12)
            box.add(grid)

            lbl_local = Gtk.Label(label="Local Folder:", xalign=0)
            self.file_chooser = Gtk.FileChooserButton(title="Select Local Folder to Sync", action=Gtk.FileChooserAction.SELECT_FOLDER)
            self.file_chooser.set_hexpand(True)
            if prefilled_path and Path(prefilled_path).is_dir():
                self.file_chooser.set_filename(str(Path(prefilled_path).resolve()))

            lbl_remote = Gtk.Label(label="Proton Drive Folder:", xalign=0)
            self.remote_entry = Gtk.Entry()
            self.remote_entry.set_placeholder_text(f"{remote}:FolderName")

            lbl_mode = Gtk.Label(label="Sync Mode:", xalign=0)
            self.mode_combo = Gtk.ComboBoxText()
            self.mode_combo.append("bisync", "Two-Way Bidirectional Sync (bisync)")
            self.mode_combo.append("sync_up", "One-Way Backup to Cloud (sync_up)")
            self.mode_combo.append("sync_down", "One-Way Mirror from Cloud (sync_down)")
            self.mode_combo.set_active_id("bisync")

            grid.attach(lbl_local, 0, 0, 1, 1)
            grid.attach(self.file_chooser, 1, 0, 1, 1)
            grid.attach(lbl_remote, 0, 1, 1, 1)
            grid.attach(self.remote_entry, 1, 1, 1, 1)
            grid.attach(lbl_mode, 0, 2, 1, 1)
            grid.attach(self.mode_combo, 1, 2, 1, 1)

            def on_folder_set(_btn):
                fn = self.file_chooser.get_filename()
                if fn and not self.remote_entry.get_text():
                    name = Path(fn).name
                    self.remote_entry.set_text(f"{remote}:{name}")

            self.file_chooser.connect("file-set", on_folder_set)
            if prefilled_path:
                on_folder_set(None)

            self.show_all()

        def get_details(self):
            local_path = self.file_chooser.get_filename()
            remote_path = self.remote_entry.get_text().strip()
            if not remote_path and local_path:
                remote_path = f"{remote}:{Path(local_path).name}"
            elif ":" not in remote_path:
                remote_path = f"{remote}:{remote_path}"
            mode = self.mode_combo.get_active_id() or "bisync"
            return local_path, remote_path, mode


    # Handle Nemo Action: 'add'
    if start_mode == "add":
        dialog = AddFolderDialog(None, prefilled_path=extra_arg)
        res = dialog.run()
        if res == Gtk.ResponseType.OK:
            local_path, remote_path, mode = dialog.get_details()
            dialog.destroy()
            if local_path and remote_path:
                entry = config_mgr.add_folder(local_path, remote_path, mode)
                send_notification("Proton Drive Sync", f"Initializing baseline sync for {Path(local_path).name}…")
                def sync_worker():
                    ok, msg = RcloneOps.sync_folder(entry)
                    now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                    if "already in progress" in msg:
                        config_mgr.update_folder_status(entry["id"], "syncing")
                        send_notification("Proton Drive Sync", f"Sync already running for {Path(local_path).name}")
                    elif ok:
                        config_mgr.update_folder_status(entry["id"], "idle", last_sync=now_str, error="", resync_needed=False)
                        send_notification("Proton Drive Sync", f"✔ Successfully synced {Path(local_path).name} to Proton Drive!")
                    else:
                        config_mgr.update_folder_status(entry["id"], "error", last_sync=now_str, error=msg, resync_needed=(entry.get("mode") == "bisync"))
                        send_notification("Proton Drive Sync", f"⚠ Error syncing {Path(local_path).name}: {msg}", urgency="critical")
                    GLib.idle_add(Gtk.main_quit)

                threading.Thread(target=sync_worker, daemon=True).start()
                Gtk.main()
                return
        else:
            dialog.destroy()
        return

    # Handle Nemo Action: 'remove'
    if start_mode == "remove":
        target = str(Path(extra_arg).resolve()) if extra_arg else None
        if not target:
            return
        folder_name = Path(target).name
        folders = config_mgr.get_folders()
        entry = next((f for f in folders if str(Path(f["local_path"]).resolve()) == target), None)
        if not entry:
            return

        dialog = Gtk.MessageDialog(
            transient_for=None,
            flags=0,
            message_type=Gtk.MessageType.QUESTION,
            buttons=Gtk.ButtonsType.OK_CANCEL,
            text=f"Remove '{folder_name}' from Proton Drive Sync?",
        )
        dialog.set_title("Remove from Proton Drive Sync")
        remote_dest = entry.get("remote_path", f"{remote}:{folder_name}")
        dialog.format_secondary_text(
            f"Local Folder: {target}\n"
            f"Proton Drive Destination: {remote_dest}\n\n"
            "This will remove the folder from automatic synchronization.\n"
            "Existing files on your computer and Proton Drive will NOT be deleted."
        )
        dialog.set_default_response(Gtk.ResponseType.CANCEL)
        res = dialog.run()
        dialog.destroy()

        if res == Gtk.ResponseType.OK:
            config_mgr.remove_folder(entry["id"])
            send_notification("Proton Drive Sync", f"Removed '{folder_name}' from Proton Drive sync list.")
        return

    class SettingsWindow(Gtk.Window):
        def __init__(self, tray_ref=None, standalone=False):
            super().__init__(title="Proton Drive Sync Settings")
            self.tray_ref = tray_ref
            self.standalone = standalone
            self.set_default_size(780, 560)
            self.set_position(Gtk.WindowPosition.CENTER)
            self.set_border_width(12)

            main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
            self.add(main_box)

            # Account Frame
            acc_frame = Gtk.Frame(label="Proton Drive Account")
            acc_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14, border_width=10)
            acc_frame.add(acc_box)

            # Left: Icon / Logo
            self.avatar_img = Gtk.Image()
            self.avatar_img.set_pixel_size(48)
            acc_box.pack_start(self.avatar_img, False, False, 0)

            # Middle: Name, Email, Quota, Progress bar
            acc_vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            acc_vbox.set_hexpand(True)
            self.acc_user_lbl = Gtk.Label(xalign=0)
            self.acc_user_lbl.set_use_markup(True)
            self.acc_quota_lbl = Gtk.Label(xalign=0)
            self.acc_quota_lbl.set_use_markup(True)
            self.acc_progress = Gtk.ProgressBar()
            self.acc_progress.set_show_text(False)
            acc_vbox.pack_start(self.acc_user_lbl, False, False, 0)
            acc_vbox.pack_start(self.acc_quota_lbl, False, False, 0)
            acc_vbox.pack_start(self.acc_progress, False, False, 0)
            acc_box.pack_start(acc_vbox, True, True, 0)

            # Right: Action buttons
            self.acc_btn_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            self.btn_switch_acc = Gtk.Button(label="🔄 Switch Account…")
            self.btn_switch_acc.connect("clicked", self.on_switch_account_clicked)
            self.btn_logout_acc = Gtk.Button(label="🚪 Sign Out")
            self.btn_logout_acc.connect("clicked", self.on_logout_account_clicked)
            self.btn_remove_acc = Gtk.Button(label="🗑 Remove")
            self.btn_remove_acc.connect("clicked", self.on_remove_account_clicked)
            self.btn_login_acc = Gtk.Button(label="🔑 Sign In / Setup…")
            self.btn_login_acc.connect("clicked", self.on_switch_account_clicked)

            self.acc_btn_box.pack_start(self.btn_switch_acc, False, False, 0)
            self.acc_btn_box.pack_start(self.btn_logout_acc, False, False, 0)
            self.acc_btn_box.pack_start(self.btn_remove_acc, False, False, 0)
            self.acc_btn_box.pack_start(self.btn_login_acc, False, False, 0)
            acc_box.pack_start(self.acc_btn_box, False, False, 0)

            main_box.pack_start(acc_frame, False, False, 0)

            # Mount status bar
            mount_frame = Gtk.Frame(label="Proton Drive Cloud Mount (Nemo Drag-and-Drop)")
            mount_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12, border_width=8)
            mount_frame.add(mount_box)

            self.mount_status_lbl = Gtk.Label(xalign=0)
            self.mount_status_lbl.set_hexpand(True)
            self.btn_toggle_mount = Gtk.Button(label="Mount")
            self.btn_toggle_mount.connect("clicked", self.on_toggle_mount)
            self.btn_open_mount = Gtk.Button(label="Open in Nemo")
            self.btn_open_mount.connect("clicked", lambda _: subprocess.Popen(["nemo", mount_point]))

            mount_box.pack_start(self.mount_status_lbl, True, True, 0)
            mount_box.pack_start(self.btn_toggle_mount, False, False, 0)
            mount_box.pack_start(self.btn_open_mount, False, False, 0)
            main_box.pack_start(mount_frame, False, False, 0)

            # Synced Folders Frame
            folders_frame = Gtk.Frame(label="Synced Local Folders")
            folders_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, border_width=8)
            folders_frame.add(folders_box)

            self.liststore = Gtk.ListStore(str, bool, str, str, str, str, str)
            self.treeview = Gtk.TreeView(model=self.liststore)

            toggle_rend = Gtk.CellRendererToggle()
            toggle_rend.connect("toggled", self.on_enabled_toggled)
            col_enable = Gtk.TreeViewColumn("Sync", toggle_rend, active=1)
            self.treeview.append_column(col_enable)

            col_local = Gtk.TreeViewColumn("Local Folder", Gtk.CellRendererText(), text=2)
            col_local.set_expand(True)
            self.treeview.append_column(col_local)

            col_remote = Gtk.TreeViewColumn("Proton Drive Target", Gtk.CellRendererText(), text=3)
            self.treeview.append_column(col_remote)

            col_mode = Gtk.TreeViewColumn("Mode", Gtk.CellRendererText(), text=4)
            self.treeview.append_column(col_mode)

            col_status = Gtk.TreeViewColumn("Status", Gtk.CellRendererText(), text=5)
            self.treeview.append_column(col_status)

            col_sync = Gtk.TreeViewColumn("Last Synced", Gtk.CellRendererText(), text=6)
            self.treeview.append_column(col_sync)

            scroll = Gtk.ScrolledWindow()
            scroll.set_min_content_height(180)
            scroll.add(self.treeview)
            folders_box.pack_start(scroll, True, True, 0)

            # Folder toolbar
            tb_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            btn_add = Gtk.Button(label="+ Add Folder...")
            btn_add.connect("clicked", self.on_add_folder)
            btn_del = Gtk.Button(label="- Remove Selected")
            btn_del.connect("clicked", self.on_remove_folder)
            btn_sync_sel = Gtk.Button(label="🔄 Sync Selected Now")
            btn_sync_sel.connect("clicked", self.on_sync_selected)
            btn_open_sel = Gtk.Button(label="📁 Open Local in Nemo")
            btn_open_sel.connect("clicked", self.on_open_selected)

            tb_box.pack_start(btn_add, False, False, 0)
            tb_box.pack_start(btn_del, False, False, 0)
            tb_box.pack_start(btn_sync_sel, False, False, 0)
            tb_box.pack_start(btn_open_sel, False, False, 0)
            folders_box.pack_start(tb_box, False, False, 0)

            main_box.pack_start(folders_frame, True, True, 0)

            # General Options
            opts_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
            opts_box.pack_start(Gtk.Label(label="Background Sync Interval (minutes):"), False, False, 0)
            self.interval_spin = Gtk.SpinButton.new_with_range(1, 120, 1)
            self.interval_spin.set_value(config_mgr.data.get("auto_sync_interval_minutes", 10))
            self.interval_spin.connect("value-changed", self.on_interval_changed)
            opts_box.pack_start(self.interval_spin, False, False, 0)

            self.chk_notifications = Gtk.CheckButton(label="Show sync popups")
            self.chk_notifications.set_active(config_mgr.data.get("notify_on_sync", False))
            self.chk_notifications.connect("toggled", self.on_notifications_toggled)
            opts_box.pack_start(self.chk_notifications, False, False, 0)

            btn_sync_all = Gtk.Button(label="🔄 Sync All Folders")
            btn_sync_all.connect("clicked", self.on_sync_all)
            opts_box.pack_end(btn_sync_all, False, False, 0)

            main_box.pack_start(opts_box, False, False, 0)

            self.refresh_account_ui()
            self.refresh_mount_status()
            self.refresh_folder_list()
            self.set_role("protondrive-settings")
            icon_file = get_icon_path("protondrive")
            if os.path.exists(icon_file):
                self.set_icon_from_file(icon_file)
            self.show_all()

            if self.standalone:
                self.connect("destroy", Gtk.main_quit)
            else:
                self.connect("delete-event", lambda w, e: self.hide_on_delete())

        def refresh_account_ui(self, force=False):
            def worker():
                info = AccountManager.get_account_info(remote, force=force)
                GLib.idle_add(self._apply_account_info, info)
            threading.Thread(target=worker, daemon=True).start()

        def _apply_account_info(self, info: dict):
            if info.get("logged_in"):
                name = info.get("name") or "Proton User"
                email = info.get("email") or ""
                self.acc_user_lbl.set_markup(f"<b><span size='large'>{name}</span></b> ({email})")

                usage = info.get("usage_str", "0 B")
                limit = info.get("limit_str", "Unlimited")
                pct = info.get("percent_str", "0%")
                self.acc_quota_lbl.set_markup(f"<span color='#555555'>Storage Quota:</span> <b>{usage}</b> of <b>{limit}</b> used ({pct})")

                frac = float(info.get("percent_float", 0.0))
                self.acc_progress.set_fraction(frac)
                self.acc_progress.show()

                self.btn_switch_acc.show()
                self.btn_logout_acc.show()
                self.btn_remove_acc.show()
                self.btn_login_acc.hide()
            else:
                self.acc_user_lbl.set_markup("<b><span size='large'>Not Signed In</span></b>")
                err_text = info.get("error") or "No Proton Drive account is currently linked."
                self.acc_quota_lbl.set_markup(f"<span color='#d9534f'>{err_text}</span>")
                self.acc_progress.set_fraction(0.0)
                self.acc_progress.hide()

                self.btn_switch_acc.hide()
                self.btn_logout_acc.hide()
                self.btn_remove_acc.hide()
                self.btn_login_acc.show()

            self.avatar_img.set_from_file(get_icon_path("protondrive"))

        def on_switch_account_clicked(self, _btn):
            proc = AccountManager.connect_account(remote)
            def wait_proc():
                proc.wait()
                AccountManager.get_account_info(remote, force=True)
                GLib.idle_add(self.refresh_account_ui, True)
                GLib.idle_add(self.refresh_mount_status)
                if self.tray_ref:
                    GLib.idle_add(self.tray_ref.build_menu)
                send_notification("Proton Drive", "Account connected / re-authenticated.")
            threading.Thread(target=wait_proc, daemon=True).start()

        def on_logout_account_clicked(self, _btn):
            info = AccountManager.get_account_info(remote)
            name = info.get("name", "Proton Drive Account")
            email = info.get("email", "")

            dlg = Gtk.MessageDialog(
                transient_for=self,
                flags=0,
                message_type=Gtk.MessageType.QUESTION,
                buttons=Gtk.ButtonsType.OK_CANCEL,
                text=f"Sign Out of {name}?",
            )
            dlg.format_secondary_text(
                f"Account: {email}\n\n"
                "This will unmount Proton Drive and disconnect your login credentials.\n"
                "Your files on Proton Drive will remain safe."
            )
            res = dlg.run()
            dlg.destroy()
            if res == Gtk.ResponseType.OK:
                ok, msg = AccountManager.disconnect_account(remote, mount_point)
                self.refresh_account_ui(force=True)
                self.refresh_mount_status()
                if self.tray_ref:
                    self.tray_ref.build_menu()
                send_notification("Proton Drive", msg if ok else f"Sign out failed: {msg}")

        def on_remove_account_clicked(self, _btn):
            info = AccountManager.get_account_info(remote)
            email = info.get("email", "")
            dlg = Gtk.MessageDialog(
                transient_for=self,
                flags=0,
                message_type=Gtk.MessageType.WARNING,
                buttons=Gtk.ButtonsType.OK_CANCEL,
                text="Remove Proton Drive Account Configuration?",
            )
            dlg.format_secondary_text(
                f"Account: {email}\n\n"
                "This will unmount Proton Drive and completely remove the remote configuration.\n"
                "You will need to sign in again to use Proton Drive."
            )
            res = dlg.run()
            dlg.destroy()
            if res == Gtk.ResponseType.OK:
                ok, msg = AccountManager.remove_account(remote, mount_point)
                self.refresh_account_ui(force=True)
                self.refresh_mount_status()
                if self.tray_ref:
                    self.tray_ref.build_menu()
                send_notification("Proton Drive", msg if ok else f"Removal failed: {msg}")

        def refresh_mount_status(self):
            mounted = RcloneOps.is_mounted(mount_point)
            if mounted:
                self.mount_status_lbl.set_markup(f"<b>Status:</b> <span color='#6D4AFF'>Mounted</span> at <tt>{mount_point}</tt>")
                self.btn_toggle_mount.set_label("Unmount")
                self.btn_open_mount.set_sensitive(True)
            else:
                self.mount_status_lbl.set_markup(f"<b>Status:</b> <span color='#727272'>Unmounted</span> (<tt>{mount_point}</tt>)")
                self.btn_toggle_mount.set_label("Mount")
                self.btn_open_mount.set_sensitive(False)

        def refresh_folder_list(self):
            self.liststore.clear()
            for f in config_mgr.get_folders():
                self.liststore.append([
                    f["id"],
                    f.get("enabled", True),
                    f["local_path"],
                    f["remote_path"],
                    f.get("mode", "bisync"),
                    f.get("status", "idle"),
                    f.get("last_sync", "Never"),
                ])

        def on_toggle_mount(self, _btn):
            if RcloneOps.is_mounted(mount_point):
                ok, err = RcloneOps.unmount_drive(mount_point)
            else:
                ok, err = RcloneOps.mount_drive(remote, mount_point)
            if not ok:
                send_notification("Proton Drive Mount", f"Error: {err}", urgency="critical")
            self.refresh_mount_status()

        def on_enabled_toggled(self, _rend, path):
            tree_iter = self.liststore.get_iter(path)
            f_id = self.liststore.get_value(tree_iter, 0)
            cur = self.liststore.get_value(tree_iter, 1)
            new_val = not cur
            self.liststore.set_value(tree_iter, 1, new_val)
            for f in config_mgr.data["folders"]:
                if f["id"] == f_id:
                    f["enabled"] = new_val
                    config_mgr.save()
                    break

        def on_add_folder(self, _btn):
            dialog = AddFolderDialog(self)
            res = dialog.run()
            if res == Gtk.ResponseType.OK:
                local_path, remote_path, mode = dialog.get_details()
                if local_path and remote_path:
                    entry = config_mgr.add_folder(local_path, remote_path, mode)
                    self.refresh_folder_list()
                    if self.tray_ref:
                        self.tray_ref.sync_folder_thread(entry, resync=True)
            dialog.destroy()

        def on_remove_folder(self, _btn):
            sel = self.treeview.get_selection()
            model, tree_iter = sel.get_selected()
            if tree_iter:
                f_id = model.get_value(tree_iter, 0)
                config_mgr.remove_folder(f_id)
                self.refresh_folder_list()
                if self.tray_ref:
                    self.tray_ref.update_menu()

        def on_sync_selected(self, _btn):
            sel = self.treeview.get_selection()
            model, tree_iter = sel.get_selected()
            if tree_iter:
                f_id = model.get_value(tree_iter, 0)
                for f in config_mgr.get_folders():
                    if f["id"] == f_id:
                        if self.tray_ref:
                            self.tray_ref.sync_folder_thread(f)
                        else:
                            def worker():
                                RcloneOps.sync_folder(f)
                                GLib.idle_add(self.refresh_folder_list)
                            threading.Thread(target=worker, daemon=True).start()
                        break

        def on_sync_all(self, _btn):
            if self.tray_ref:
                self.tray_ref.trigger_sync_all()
            else:
                def worker():
                    for f in config_mgr.get_folders():
                        if f.get("enabled", True):
                            RcloneOps.sync_folder(f)
                    GLib.idle_add(self.refresh_folder_list)
                threading.Thread(target=worker, daemon=True).start()

        def on_open_selected(self, _btn):
            sel = self.treeview.get_selection()
            model, tree_iter = sel.get_selected()
            if tree_iter:
                local_path = model.get_value(tree_iter, 2)
                subprocess.Popen(["nemo", local_path])

        def on_interval_changed(self, spin):
            config_mgr.data["auto_sync_interval_minutes"] = int(spin.get_value())
            config_mgr.save()

        def on_notifications_toggled(self, chk):
            config_mgr.data["notify_on_sync"] = bool(chk.get_active())
            config_mgr.save()

    # Handle Settings Standalone mode
    if start_mode == "settings":
        win = SettingsWindow(standalone=True)
        win.show_all()
        Gtk.main()
        return

    # Handle Tray Mode
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3

    class TrayApp:
        def __init__(self):
            icon_path = get_icon_path("protondrive")
            icon_dir = os.path.dirname(icon_path) if os.path.isabs(icon_path) else ""
            if icon_dir:
                self.indicator = AyatanaAppIndicator3.Indicator.new_with_path(
                    "protondrive-sync",
                    icon_path,
                    AyatanaAppIndicator3.IndicatorCategory.APPLICATION_STATUS,
                    icon_dir,
                )
            else:
                self.indicator = AyatanaAppIndicator3.Indicator.new(
                    "protondrive-sync",
                    icon_path,
                    AyatanaAppIndicator3.IndicatorCategory.APPLICATION_STATUS,
                )
            self.indicator.set_status(AyatanaAppIndicator3.IndicatorStatus.ACTIVE)
            self.indicator.set_title("Proton Drive")

            self.settings_window = None
            self.syncing_folders = set()
            self.menu = Gtk.Menu()
            self.build_menu()
            self.indicator.set_menu(self.menu)

            # Auto-mount drive on startup if account exists and not already mounted
            if not RcloneOps.is_mounted(mount_point):
                acc = AccountManager.get_account_info(remote)
                if acc.get("logged_in"):
                    threading.Thread(target=lambda: RcloneOps.mount_drive(remote, mount_point), daemon=True).start()

            self.timer_source = None
            self.setup_timer()
            GLib.timeout_add_seconds(2, self.check_config_changes)

        def check_config_changes(self):
            if config_mgr.has_changed_on_disk():
                config_mgr.reload_if_needed()
                self.setup_timer()
                self.build_menu()
                if self.settings_window and self.settings_window.get_visible():
                    self.settings_window.refresh_folder_list()
            return True

        def set_tray_icon(self, state: str):
            icon_path = get_icon_path(state)
            icon_dir = os.path.dirname(icon_path) if os.path.isabs(icon_path) else ""
            if icon_dir:
                self.indicator.set_icon_theme_path(icon_dir)
            self.indicator.set_icon_full(icon_path, f"Proton Drive - {state}")

        def setup_timer(self):
            if self.timer_source:
                GLib.source_remove(self.timer_source)
            interval_mins = max(1, config_mgr.data.get("auto_sync_interval_minutes", 10))
            self.timer_source = GLib.timeout_add_seconds(interval_mins * 60, self.on_periodic_sync)

        def on_periodic_sync(self):
            if not config_mgr.data.get("paused", False):
                self.trigger_sync_all()
            return True

        def build_menu(self):
            for child in self.menu.get_children():
                self.menu.remove(child)

            # --- Account Section ---
            acc = AccountManager.get_account_info(remote)
            if acc.get("logged_in"):
                name = acc.get("name") or "Proton User"
                email = acc.get("email") or ""
                usage = acc.get("usage_str", "0 B")
                limit = acc.get("limit_str", "Unlimited")
                pct = acc.get("percent_str", "0%")

                acc_header = Gtk.MenuItem(label=f"👤 {name} ({email})")
                acc_header.set_sensitive(False)
                self.menu.append(acc_header)

                quota_item = Gtk.MenuItem(label=f"📊 Storage: {usage} / {limit} ({pct})")
                quota_item.set_sensitive(False)
                self.menu.append(quota_item)

                acc_menu_item = Gtk.MenuItem(label="⚙ Account Settings")
                acc_sub = Gtk.Menu()

                item_switch = Gtk.MenuItem(label="🔄 Switch / Reconnect Account…")
                item_switch.connect("activate", self.on_switch_account)
                acc_sub.append(item_switch)

                item_logout = Gtk.MenuItem(label="🚪 Sign Out / Disconnect")
                item_logout.connect("activate", self.on_logout_account)
                acc_sub.append(item_logout)

                item_remove = Gtk.MenuItem(label="🗑 Remove Account…")
                item_remove.connect("activate", self.on_remove_account)
                acc_sub.append(item_remove)

                acc_menu_item.set_submenu(acc_sub)
                self.menu.append(acc_menu_item)
            else:
                acc_header = Gtk.MenuItem(label="👤 Not Signed In")
                acc_header.set_sensitive(False)
                self.menu.append(acc_header)

                item_login = Gtk.MenuItem(label="🔑 Sign In / Setup Account…")
                item_login.connect("activate", self.on_switch_account)
                self.menu.append(item_login)

            self.menu.append(Gtk.SeparatorMenuItem())

            # --- Cloud Mount Status & Actions ---
            is_mounted = RcloneOps.is_mounted(mount_point)
            if is_mounted:
                item_open_drive = Gtk.MenuItem(label="☁ Open Proton Drive (Cloud)")
                item_open_drive.connect("activate", lambda _: subprocess.Popen(["nemo", mount_point]))
                self.menu.append(item_open_drive)

                item_mount = Gtk.MenuItem(label="⏏ Unmount Proton Drive")
                item_mount.connect("activate", self.on_toggle_mount_tray)
                self.menu.append(item_mount)
            else:
                item_mount = Gtk.MenuItem(label="☁ Mount Proton Drive")
                item_mount.connect("activate", self.on_toggle_mount_tray)
                self.menu.append(item_mount)

            self.menu.append(Gtk.SeparatorMenuItem())

            # --- Sync Status & Actions ---
            status_text = "✔ All folders synchronized"
            if self.syncing_folders:
                status_text = f"⏳ Syncing ({len(self.syncing_folders)} in progress)..."
            elif config_mgr.data.get("paused", False):
                status_text = "⏸ Auto-sync paused"

            self.status_item = Gtk.MenuItem(label=status_text)
            self.status_item.set_sensitive(False)
            self.menu.append(self.status_item)

            item_sync = Gtk.MenuItem(label="🔄 Sync All Now")
            item_sync.connect("activate", lambda _: self.trigger_sync_all())
            self.menu.append(item_sync)

            folders = [f for f in config_mgr.get_folders() if f.get("enabled", True)]
            folders_menu_item = Gtk.MenuItem(label=f"📂 Synced Folders ({len(folders)})")
            sub_menu = Gtk.Menu()
            if folders:
                for f in folders:
                    folder_name = Path(f["local_path"]).name
                    f_item = Gtk.MenuItem(label=f"{folder_name} ({f.get('status', 'idle')})")
                    f_item.connect("activate", lambda _, path=f["local_path"]: subprocess.Popen(["nemo", path]))
                    sub_menu.append(f_item)
            else:
                none_item = Gtk.MenuItem(label="(No folders configured)")
                none_item.set_sensitive(False)
                sub_menu.append(none_item)
            folders_menu_item.set_submenu(sub_menu)
            self.menu.append(folders_menu_item)

            self.menu.append(Gtk.SeparatorMenuItem())

            paused = config_mgr.data.get("paused", False)
            pause_label = "▶ Resume Auto-Sync" if paused else "⏸ Pause Auto-Sync"
            item_pause = Gtk.MenuItem(label=pause_label)
            item_pause.connect("activate", self.toggle_pause)
            self.menu.append(item_pause)

            item_settings = Gtk.MenuItem(label="⚙ Settings & Manage Folders…")
            item_settings.connect("activate", self.open_settings)
            self.menu.append(item_settings)

            self.menu.append(Gtk.SeparatorMenuItem())

            item_quit = Gtk.MenuItem(label="Quit Proton Drive Tray")
            item_quit.connect("activate", self.on_quit)
            self.menu.append(item_quit)

            self.menu.show_all()

        def on_toggle_mount_tray(self, _item):
            if RcloneOps.is_mounted(mount_point):
                ok, err = RcloneOps.unmount_drive(mount_point)
            else:
                ok, err = RcloneOps.mount_drive(remote, mount_point)
            if not ok:
                send_notification("Proton Drive Mount", f"Error: {err}", urgency="critical")
            self.build_menu()
            if self.settings_window and self.settings_window.get_visible():
                self.settings_window.refresh_mount_status()

        def on_switch_account(self, _item):
            proc = AccountManager.connect_account(remote)
            def wait_proc():
                proc.wait()
                AccountManager.get_account_info(remote, force=True)
                GLib.idle_add(self.build_menu)
                if self.settings_window and self.settings_window.get_visible():
                    GLib.idle_add(self.settings_window.refresh_account_ui, True)
                    GLib.idle_add(self.settings_window.refresh_mount_status)
                send_notification("Proton Drive", "Account connected / re-authenticated.")
            threading.Thread(target=wait_proc, daemon=True).start()

        def on_logout_account(self, _item):
            if not self.settings_window:
                self.settings_window = SettingsWindow(tray_ref=self)
            self.settings_window.on_logout_account_clicked(None)

        def on_remove_account(self, _item):
            if not self.settings_window:
                self.settings_window = SettingsWindow(tray_ref=self)
            self.settings_window.on_remove_account_clicked(None)

        def on_quit(self, _item=None):
            try:
                subprocess.run(["systemctl", "--user", "stop", "protondrive-tray.service"], check=False, timeout=5)
            except Exception:
                pass
            Gtk.main_quit()
            os._exit(0)

        def update_menu(self):
            GLib.idle_add(self.build_menu)

        def toggle_pause(self, _item):
            paused = not config_mgr.data.get("paused", False)
            config_mgr.data["paused"] = paused
            config_mgr.save()
            self.set_tray_icon("protondrive-paused" if paused else "protondrive")
            self.build_menu()

        def open_settings(self, _item=None):
            if not self.settings_window:
                self.settings_window = SettingsWindow(tray_ref=self)
            self.settings_window.refresh_account_ui()
            self.settings_window.refresh_mount_status()
            self.settings_window.refresh_folder_list()
            self.settings_window.show_all()
            self.settings_window.present()

        def sync_folder_thread(self, folder: dict, resync: bool = False):
            f_id = folder["id"]
            if f_id in self.syncing_folders:
                return
            self.syncing_folders.add(f_id)
            if resync:
                folder["resync_needed"] = True

            config_mgr.update_folder_status(f_id, "syncing")
            GLib.idle_add(self.set_tray_icon, "protondrive-syncing")
            self.update_menu()
            if config_mgr.data.get("notify_on_sync", False):
                send_notification("Proton Drive Sync", f"Syncing {Path(folder['local_path']).name}…")

            def worker():
                success, msg = RcloneOps.sync_folder(folder)
                now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                self.syncing_folders.discard(f_id)

                if "already in progress" in msg:
                    config_mgr.update_folder_status(f_id, "syncing")
                    GLib.idle_add(self._on_sync_finished)
                    return

                if success:
                    config_mgr.update_folder_status(f_id, "idle", last_sync=now_str, error="", resync_needed=False)
                    if config_mgr.data.get("notify_on_sync", False):
                        send_notification("Proton Drive Sync", f"✔ Completed: {Path(folder['local_path']).name}")
                else:
                    config_mgr.update_folder_status(f_id, "error", last_sync=now_str, error=msg, resync_needed=(folder.get("mode") == "bisync"))
                    send_notification("Proton Drive Sync", f"⚠ Error in {Path(folder['local_path']).name}: {msg}", urgency="critical")

                GLib.idle_add(self._on_sync_finished)

            threading.Thread(target=worker, daemon=True).start()

        def _on_sync_finished(self):
            if not self.syncing_folders:
                any_error = any(f.get("status") == "error" for f in config_mgr.get_folders())
                paused = config_mgr.data.get("paused", False)
                if any_error:
                    self.set_tray_icon("protondrive-error")
                elif paused:
                    self.set_tray_icon("protondrive-paused")
                else:
                    self.set_tray_icon("protondrive")
            self.update_menu()
            if self.settings_window and self.settings_window.get_visible():
                self.settings_window.refresh_folder_list()

        def trigger_sync_all(self):
            folders = [f for f in config_mgr.get_folders() if f.get("enabled", True)]
            if not folders:
                return
            for f in folders:
                self.sync_folder_thread(f)

    app = TrayApp()
    Gtk.main()


def main():
    parser = argparse.ArgumentParser(description="Proton Drive Sync & Tray Tool")
    parser.add_argument("command", nargs="?", default="tray",
                        choices=["tray", "settings", "add", "remove", "is-synced", "not-synced", "sync-all", "mount", "unmount", "status"],
                        help="Action to perform")
    parser.add_argument("target", nargs="?", default=None, help="Target folder")

    args = parser.parse_args()
    config_mgr = ConfigManager()
    remote = config_mgr.data.get("remote", "protondrive")
    mount_point = config_mgr.data.get("mount_point", str(DEFAULT_MOUNT_POINT))

    clean_target = args.target.strip("\"'") if args.target else None

    if args.command == "is-synced":
        if not clean_target:
            sys.exit(1)
        target = str(Path(clean_target).resolve())
        is_synced = any(str(Path(f["local_path"]).resolve()) == target for f in config_mgr.get_folders())
        sys.exit(0 if is_synced else 1)

    elif args.command == "not-synced":
        if not clean_target:
            sys.exit(1)
        target = Path(clean_target).resolve()
        mount = Path(mount_point).resolve()
        try:
            target.relative_to(mount)
            sys.exit(1)
        except ValueError:
            pass
        is_synced = any(str(Path(f["local_path"]).resolve()) == str(target) for f in config_mgr.get_folders())
        sys.exit(1 if is_synced else 0)

    elif args.command == "mount":
        ok, msg = RcloneOps.mount_drive(remote, mount_point)
        print(f"[{'OK' if ok else 'ERROR'}] {msg}")
        sys.exit(0 if ok else 1)

    elif args.command == "unmount":
        ok, msg = RcloneOps.unmount_drive(mount_point)
        print(f"[{'OK' if ok else 'ERROR'}] {msg}")
        sys.exit(0 if ok else 1)

    elif args.command == "status":
        mounted = RcloneOps.is_mounted(mount_point)
        folders = config_mgr.get_folders()
        acc = AccountManager.get_account_info(remote)
        print(f"Proton Drive Mount ({mount_point}): {'MOUNTED' if mounted else 'UNMOUNTED'}")
        if acc.get("logged_in"):
            print(f"Account: {acc.get('name')} ({acc.get('email')}) - Quota: {acc.get('usage_str')} / {acc.get('limit_str')} ({acc.get('percent_str')})")
        else:
            print("Account: Not logged in / Not configured")
        print(f"Auto-Sync Interval: {config_mgr.data.get('auto_sync_interval_minutes', 10)} min (Paused: {config_mgr.data.get('paused', False)})")
        print(f"Synced Folders ({len(folders)}):")
        for f in folders:
            print(f"  - [{f.get('status','idle')}] {f['local_path']} <-> {f['remote_path']} (Last: {f.get('last_sync','Never')})")
        sys.exit(0)

    elif args.command == "sync-all":
        folders = [f for f in config_mgr.get_folders() if f.get("enabled", True)]
        all_ok = True
        for f in folders:
            print(f"Syncing {f['local_path']} ...")
            ok, msg = RcloneOps.sync_folder(f)
            print(f" -> {'OK' if ok else 'ERROR'}: {msg}")
            if not ok:
                all_ok = False
        sys.exit(0 if all_ok else 1)

    elif args.command in ("tray", "settings", "add", "remove"):
        run_gui_app(start_mode=args.command, extra_arg=clean_target)


if __name__ == "__main__":
    main()
