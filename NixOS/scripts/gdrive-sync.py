#!/usr/bin/env python3
"""
Google Drive Sync & Tray Manager for NixOS / Hyprland / Nemo
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

CONFIG_DIR = Path.home() / ".config/gdrive-sync"
CONFIG_FILE = CONFIG_DIR / "config.json"
DEFAULT_MOUNT_POINT = Path.home() / "Google Drive"
LOG_FILE = Path.home() / ".local/state/gdrive-sync/sync.log"

# Search paths for custom icons
SCRIPT_DIR = Path(__file__).resolve().parent
ASSET_ICONS = SCRIPT_DIR.parent / "assets/gdrive-icons"
USER_ICONS = Path.home() / ".local/share/icons/hicolor/scalable/apps"


def get_icon_path(name: str) -> str:
    candidates = [
        ASSET_ICONS / f"{name}.svg",
        USER_ICONS / f"{name}.svg",
        ASSET_ICONS / f"{name}.png",
    ]
    for c in candidates:
        if c.exists():
            return str(c)
    # Fallback system icon names
    fallbacks = {
        "gdrive": "folder-google-drive",
        "gdrive-syncing": "emblem-synchronizing",
        "gdrive-paused": "media-playback-pause",
        "gdrive-error": "dialog-warning",
    }
    return fallbacks.get(name, "folder")


def send_notification(title: str, message: str, icon: str = "folder-google-drive", urgency: str = "normal"):
    notify_send = shutil.which("notify-send")
    if notify_send:
        try:
            subprocess.run(
                [notify_send, "-a", "Google Drive", "-i", icon, "-u", urgency, title, message],
                check=False,
            )
        except Exception:
            pass


class ConfigManager:
    def __init__(self):
        self.lock = threading.Lock()
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        self.data = self._load()

    def _load(self) -> dict:
        if CONFIG_FILE.exists():
            try:
                with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    data.setdefault("remote", "gdrive")
                    data.setdefault("mount_point", str(DEFAULT_MOUNT_POINT))
                    data.setdefault("auto_sync_interval_minutes", 10)
                    data.setdefault("paused", False)
                    data.setdefault("folders", [])
                    return data
            except Exception as e:
                print(f"[gdrive-sync] Error reading {CONFIG_FILE}: {e}", file=sys.stderr)
        return {
            "remote": "gdrive",
            "mount_point": str(DEFAULT_MOUNT_POINT),
            "auto_sync_interval_minutes": 10,
            "paused": False,
            "folders": [],
        }

    def save(self):
        with self.lock:
            temp_file = CONFIG_FILE.with_suffix(".tmp")
            with open(temp_file, "w", encoding="utf-8") as f:
                json.dump(self.data, f, indent=2, ensure_ascii=False)
            temp_file.replace(CONFIG_FILE)

    def get_folders(self) -> list:
        with self.lock:
            return list(self.data.get("folders", []))

    def add_folder(self, local_path: str, remote_path: str, mode: str = "bisync", enabled: bool = True) -> dict:
        local_path = str(Path(local_path).resolve())
        with self.lock:
            for f in self.data["folders"]:
                if f["local_path"] == local_path:
                    f["remote_path"] = remote_path
                    f["mode"] = mode
                    f["enabled"] = enabled
                    self.save()
                    return f

            folder_entry = {
                "id": f"folder-{int(time.time()*1000)}",
                "local_path": local_path,
                "remote_path": remote_path,
                "mode": mode,
                "enabled": enabled,
                "status": "idle",
                "last_sync": "Never",
                "last_error": "",
                "resync_needed": True,
            }
            self.data["folders"].append(folder_entry)
            self.save()
            return folder_entry

    def remove_folder(self, folder_id: str):
        with self.lock:
            self.data["folders"] = [f for f in self.data["folders"] if f.get("id") != folder_id and f.get("local_path") != folder_id]
            self.save()

    def update_folder_status(self, folder_id: str, status: str, last_sync: str = None, error: str = "", resync_needed: bool = None):
        with self.lock:
            for f in self.data["folders"]:
                if f.get("id") == folder_id or f.get("local_path") == folder_id:
                    f["status"] = status
                    if last_sync:
                        f["last_sync"] = last_sync
                    f["last_error"] = error
                    if resync_needed is not None:
                        f["resync_needed"] = resync_needed
                    break
            self.save()


class RcloneOps:
    @staticmethod
    def rclone_bin() -> str:
        for candidate in ["rclone", "/etc/profiles/per-user/thinky/bin/rclone", "/run/current-system/sw/bin/rclone"]:
            p = shutil.which(candidate)
            if p:
                return p
        return "rclone"

    @staticmethod
    def fusermount_bin() -> str:
        for candidate in ["/run/wrappers/bin/fusermount3", "fusermount3", "/run/wrappers/bin/fusermount", "fusermount"]:
            p = shutil.which(candidate)
            if p:
                return p
        return "fusermount3"

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
            res = subprocess.run(["systemctl", "--user", "start", "gdrive-mount"], capture_output=True, text=True, timeout=15)
            if res.returncode == 0:
                cls.ensure_gtk_bookmark(mount_point, "Google Drive")
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
                cls.ensure_gtk_bookmark(mount_point, "Google Drive")
                return True, "Mounted successfully"
            return False, res.stderr or "Mount failed"
        except Exception as e:
            return False, str(e)

    @classmethod
    def unmount_drive(cls, mount_point: str) -> tuple[bool, str]:
        if not cls.is_mounted(mount_point):
            return True, "Not mounted"

        try:
            res = subprocess.run(["systemctl", "--user", "stop", "gdrive-mount"], capture_output=True, text=True, timeout=10)
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

    @classmethod
    def sync_folder(cls, folder: dict) -> tuple[bool, str]:
        rclone = cls.rclone_bin()
        local_path = folder["local_path"]
        remote_path = folder["remote_path"]
        mode = folder.get("mode", "bisync")
        resync = folder.get("resync_needed", False)

        if not Path(local_path).exists():
            return False, f"Local path '{local_path}' does not exist"

        if mode == "bisync":
            cmd = [rclone, "bisync", local_path, remote_path, "--verbose"]
            if resync:
                cmd.append("--resync")
        elif mode == "sync_up":
            cmd = [rclone, "sync", local_path, remote_path, "--verbose"]
        elif mode == "sync_down":
            cmd = [rclone, "sync", remote_path, local_path, "--verbose"]
        else:
            return False, f"Unknown sync mode: {mode}"

        try:
            log_line = f"[{datetime.datetime.now().isoformat()}] RUN: {' '.join(cmd)}\n"
            with open(LOG_FILE, "a", encoding="utf-8") as log:
                log.write(log_line)

            res = subprocess.run(cmd, capture_output=True, text=True, timeout=600)

            with open(LOG_FILE, "a", encoding="utf-8") as log:
                log.write(f"EXIT: {res.returncode}\n{res.stdout}\n{res.stderr}\n")

            if res.returncode == 0:
                return True, "Sync completed successfully"

            if "--resync" in res.stderr:
                return False, "Bisync requires resync baseline (--resync)"
            return False, res.stderr.strip().splitlines()[-1] if res.stderr else "Sync exited with error"
        except subprocess.TimeoutExpired:
            return False, "Sync timed out"
        except Exception as e:
            return False, str(e)


# ----------------------------------------------------------------------
# GTK3 GUI COMPONENTS
# ----------------------------------------------------------------------

def run_gui_app(start_mode: str = "tray", extra_arg: str = None):
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk, Gdk, GLib

    GLib.set_prgname("gdrive-settings")
    GLib.set_application_name("Google Drive Sync")

    config_mgr = ConfigManager()
    mount_point = config_mgr.data.get("mount_point", str(DEFAULT_MOUNT_POINT))
    remote = config_mgr.data.get("remote", "gdrive")

    class AddFolderDialog(Gtk.Dialog):
        def __init__(self, parent, prefilled_path: str = None):
            super().__init__(
                title="Sync folder with Google Drive",
                transient_for=parent,
                flags=0,
            )
            self.add_buttons(
                Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
                "Add & Sync Now", Gtk.ResponseType.OK,
            )
            self.set_default_size(520, 260)
            self.set_border_width(12)

            content = self.get_content_area()
            grid = Gtk.Grid(column_spacing=12, row_spacing=12)
            content.add(grid)

            # Local Path Chooser
            grid.attach(Gtk.Label(label="Local Folder:", xalign=0), 0, 0, 1, 1)
            self.file_chooser = Gtk.FileChooserButton(
                title="Select folder to sync",
                action=Gtk.FileChooserAction.SELECT_FOLDER,
            )
            self.file_chooser.set_hexpand(True)
            if prefilled_path and Path(prefilled_path).is_dir():
                self.file_chooser.set_current_folder(str(Path(prefilled_path).resolve()))
            grid.attach(self.file_chooser, 1, 0, 1, 1)

            # Remote Destination
            grid.attach(Gtk.Label(label="Google Drive Target:", xalign=0), 0, 1, 1, 1)
            self.remote_entry = Gtk.Entry()
            self.remote_entry.set_placeholder_text(f"{remote}:FolderName")
            grid.attach(self.remote_entry, 1, 1, 1, 1)

            # Sync Mode
            grid.attach(Gtk.Label(label="Sync Mode:", xalign=0), 0, 2, 1, 1)
            self.mode_combo = Gtk.ComboBoxText()
            self.mode_combo.append("bisync", "Two-Way Sync (Bidirectional bisync) [Recommended]")
            self.mode_combo.append("sync_up", "Upload to Drive Only (Backup / Mirror)")
            self.mode_combo.append("sync_down", "Download from Drive Only")
            self.mode_combo.set_active(0)
            grid.attach(self.mode_combo, 1, 2, 1, 1)

            def on_folder_set(_btn):
                folder = self.file_chooser.get_filename()
                if folder and not self.remote_entry.get_text():
                    name = Path(folder).name
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
                send_notification("Google Drive Sync", f"Initializing baseline sync for {Path(local_path).name}…")
                # Run sync in thread and notify
                def sync_worker():
                    ok, msg = RcloneOps.sync_folder(entry)
                    now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                    if ok:
                        config_mgr.update_folder_status(entry["id"], "idle", last_sync=now_str, error="", resync_needed=False)
                        send_notification("Google Drive Sync", f"✔ Successfully synced {Path(local_path).name} to Google Drive!")
                    else:
                        config_mgr.update_folder_status(entry["id"], "error", last_sync=now_str, error=msg)
                        send_notification("Google Drive Sync", f"⚠ Error syncing {Path(local_path).name}: {msg}", urgency="critical")
                    GLib.idle_add(Gtk.main_quit)

                threading.Thread(target=sync_worker, daemon=True).start()
                Gtk.main()
                return
        else:
            dialog.destroy()
        return

    class SettingsWindow(Gtk.Window):
        def __init__(self, tray_ref=None, standalone=False):
            super().__init__(title="Google Drive Sync Settings")
            self.tray_ref = tray_ref
            self.standalone = standalone
            self.set_default_size(780, 500)
            self.set_position(Gtk.WindowPosition.CENTER)
            self.set_border_width(12)

            main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
            self.add(main_box)

            # Mount status bar
            mount_frame = Gtk.Frame(label="Google Drive Cloud Mount (Nemo Drag-and-Drop)")
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

            col_remote = Gtk.TreeViewColumn("Google Drive Target", Gtk.CellRendererText(), text=3)
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

            btn_sync_all = Gtk.Button(label="🔄 Sync All Folders")
            btn_sync_all.connect("clicked", self.on_sync_all)
            opts_box.pack_end(btn_sync_all, False, False, 0)

            main_box.pack_start(opts_box, False, False, 0)

            self.refresh_mount_status()
            self.refresh_folder_list()
            self.set_role("gdrive-settings")
            icon_file = get_icon_path("gdrive")
            if os.path.exists(icon_file):
                self.set_icon_from_file(icon_file)
            self.show_all()

            if self.standalone:
                self.connect("destroy", Gtk.main_quit)
            else:
                self.connect("delete-event", lambda w, e: self.hide_on_delete())

        def refresh_mount_status(self):
            mounted = RcloneOps.is_mounted(mount_point)
            if mounted:
                self.mount_status_lbl.set_markup(f"<b>Status:</b> <span color='#0F9D58'>Mounted</span> at <tt>{mount_point}</tt>")
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
                send_notification("Google Drive Mount", f"Error: {err}", urgency="critical")
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
            self.indicator = AyatanaAppIndicator3.Indicator.new(
                "google-drive-sync",
                get_icon_path("gdrive"),
                AyatanaAppIndicator3.IndicatorCategory.APPLICATION_STATUS,
            )
            self.indicator.set_status(AyatanaAppIndicator3.IndicatorStatus.ACTIVE)
            self.indicator.set_title("Google Drive")

            self.settings_window = None
            self.syncing_folders = set()
            self.menu = Gtk.Menu()
            self.build_menu()
            self.indicator.set_menu(self.menu)

            # Auto-mount drive on startup if not already mounted
            if not RcloneOps.is_mounted(mount_point):
                threading.Thread(target=lambda: RcloneOps.mount_drive(remote, mount_point), daemon=True).start()

            self.timer_source = None
            self.setup_timer()

        def set_tray_icon(self, state: str):
            self.indicator.set_icon_full(get_icon_path(state), f"Google Drive - {state}")

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

            status_text = "✔ All folders synchronized"
            if self.syncing_folders:
                status_text = f"⏳ Syncing ({len(self.syncing_folders)} in progress)..."
            elif config_mgr.data.get("paused", False):
                status_text = "⏸ Auto-sync paused"

            self.status_item = Gtk.MenuItem(label=status_text)
            self.status_item.set_sensitive(False)
            self.menu.append(self.status_item)
            self.menu.append(Gtk.SeparatorMenuItem())

            item_open_drive = Gtk.MenuItem(label="☁ Open Google Drive (Cloud)")
            item_open_drive.connect("activate", lambda _: subprocess.Popen(["nemo", mount_point]))
            self.menu.append(item_open_drive)

            item_sync = Gtk.MenuItem(label="🔄 Sync All Now")
            item_sync.connect("activate", lambda _: self.trigger_sync_all())
            self.menu.append(item_sync)

            folders = [f for f in config_mgr.get_folders() if f.get("enabled", True)]
            folders_menu_item = Gtk.MenuItem(label="📂 Synced Folders")
            sub_menu = Gtk.Menu()
            if folders:
                for f in folders:
                    name = Path(f["local_path"]).name
                    f_item = Gtk.MenuItem(label=f"{name} ({f.get('status', 'idle')})")
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

            item_quit = Gtk.MenuItem(label="Quit Google Drive Tray")
            item_quit.connect("activate", lambda _: Gtk.main_quit())
            self.menu.append(item_quit)

            self.menu.show_all()

        def update_menu(self):
            GLib.idle_add(self.build_menu)

        def toggle_pause(self, _item):
            paused = not config_mgr.data.get("paused", False)
            config_mgr.data["paused"] = paused
            config_mgr.save()
            self.set_tray_icon("gdrive-paused" if paused else "gdrive")
            self.build_menu()

        def open_settings(self, _item=None):
            if not self.settings_window:
                self.settings_window = SettingsWindow(tray_ref=self)
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
            GLib.idle_add(self.set_tray_icon, "gdrive-syncing")
            self.update_menu()
            send_notification("Google Drive Sync", f"Syncing {Path(folder['local_path']).name}…")

            def worker():
                success, msg = RcloneOps.sync_folder(folder)
                now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                self.syncing_folders.discard(f_id)

                if success:
                    config_mgr.update_folder_status(f_id, "idle", last_sync=now_str, error="", resync_needed=False)
                    send_notification("Google Drive Sync", f"✔ Completed: {Path(folder['local_path']).name}")
                else:
                    config_mgr.update_folder_status(f_id, "error", last_sync=now_str, error=msg)
                    send_notification("Google Drive Sync", f"⚠ Error in {Path(folder['local_path']).name}: {msg}", urgency="critical")

                GLib.idle_add(self._on_sync_finished)

            threading.Thread(target=worker, daemon=True).start()

        def _on_sync_finished(self):
            if not self.syncing_folders:
                any_error = any(f.get("status") == "error" for f in config_mgr.get_folders())
                paused = config_mgr.data.get("paused", False)
                if any_error:
                    self.set_tray_icon("gdrive-error")
                elif paused:
                    self.set_tray_icon("gdrive-paused")
                else:
                    self.set_tray_icon("gdrive")
            self.build_menu()
            if self.settings_window and self.settings_window.get_visible():
                self.settings_window.refresh_folder_list()

        def trigger_sync_all(self):
            folders = [f for f in config_mgr.get_folders() if f.get("enabled", True)]
            for f in folders:
                self.sync_folder_thread(f)

    app = TrayApp()
    Gtk.main()


# ----------------------------------------------------------------------
# CLI ENTRYPOINT
# ----------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Google Drive Sync & Tray Tool")
    parser.add_argument("command", nargs="?", default="tray",
                        choices=["tray", "settings", "add", "sync-all", "mount", "unmount", "status"],
                        help="Action to perform")
    parser.add_argument("target", nargs="?", default=None, help="Target folder for 'add'")

    args = parser.parse_args()
    config_mgr = ConfigManager()
    remote = config_mgr.data.get("remote", "gdrive")
    mount_point = config_mgr.data.get("mount_point", str(DEFAULT_MOUNT_POINT))

    if args.command == "mount":
        ok, msg = RcloneOps.mount_drive(remote, mount_point)
        print(f"[{'OK' if ok else 'ERROR'}] {msg}")
        sys.exit(0 if ok else 1)

    elif args.command == "unmount":
        ok, msg = RcloneOps.unmount_drive(mount_point)
        print(f"[{'OK' if ok else 'ERROR'}] {msg}")
        sys.exit(0 if ok else 1)

    elif args.command == "status":
        mounted = RcloneOps.is_mounted(mount_point)
        print(f"Mount Point: {mount_point} (Mounted: {mounted})")
        print(f"Configured Folders ({len(config_mgr.get_folders())}):")
        for f in config_mgr.get_folders():
            print(f" - [{f.get('status','idle')}] {f['local_path']} <-> {f['remote_path']} (Last sync: {f.get('last_sync','Never')})")
        sys.exit(0)

    elif args.command == "sync-all":
        folders = [f for f in config_mgr.get_folders() if f.get("enabled", True)]
        for f in folders:
            print(f"Syncing {f['local_path']} ...")
            ok, msg = RcloneOps.sync_folder(f)
            print(f" -> {'OK' if ok else 'ERROR'}: {msg}")
        sys.exit(0)

    elif args.command in ("tray", "settings", "add"):
        run_gui_app(start_mode=args.command, extra_arg=args.target)


if __name__ == "__main__":
    main()
