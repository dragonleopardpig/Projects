"""Main window for rclone-control: dual-pane explorer, live transfers, remotes, mounts, saved jobs."""

from __future__ import annotations

import json
import os
from pathlib import Path
import time
from typing import Any
from PyQt6.QtCore import Qt, QTimer
from PyQt6.QtGui import QFont, QIcon
from PyQt6.QtWidgets import (
    QComboBox,
    QFrame,
    QHBoxLayout,
    QHeaderView,
    QInputDialog,
    QLabel,
    QLineEdit,
    QMainWindow,
    QMessageBox,
    QPlainTextEdit,
    QProgressBar,
    QPushButton,
    QSplitter,
    QStatusBar,
    QTabWidget,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from .dialogs import (
    MountDialog,
    OperationDialog,
    PreviewDialog,
    PropertiesDialog,
    RemoteEditorDialog,
    build_rc_params_from_preset,
)
from .explorer_pane import ExplorerPane
from .qt_helpers import TaskManager, make_button, show_error
from .rc_client import RcloneClient, format_bytes, join_fs_path, split_fs_path
from .theme import build_qss


def _jobs_store_path() -> Path:
    cfg_home = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config"))
    return cfg_home / "rclone-control" / "jobs.json"


class MainWindow(QMainWindow):
    """Full-control GUI for rclone remotes, transfers, mounts, and saved presets."""

    def __init__(
        self,
        client: RcloneClient | None = None,
        auto_start_rc: bool = True,
        left_spec: str | None = None,
        right_spec: str | None = None,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self.client = client or RcloneClient(auto_start=auto_start_rc)
        self.tasks = TaskManager(self)
        self._remotes: list[str] = []
        self._config_dump: dict[str, dict[str, Any]] = {}
        self._providers: list[dict[str, Any]] = []
        self._tracked_jobs: dict[int, dict[str, Any]] = {}
        self._saved_jobs: list[dict[str, Any]] = self._load_saved_jobs()
        self._mounts_cache: list[Any] = []
        self._theme_mode, self._palette, qss = build_qss()
        self._poll_active = False

        self.setWindowTitle("Rclone Control")
        self.resize(1380, 860)
        self.setStyleSheet(qss)

        svg_path = Path(__file__).resolve().parent.parent / "assets" / "rclone-control.svg"
        if svg_path.is_file():
            self.setWindowIcon(QIcon(str(svg_path)))

        central = QWidget()
        self.setCentralWidget(central)
        root = QVBoxLayout(central)
        root.setContentsMargins(12, 12, 12, 8)
        root.setSpacing(10)

        root.addWidget(self._build_header())

        self.tabs = QTabWidget()
        root.addWidget(self.tabs, 1)

        self.tabs.addTab(self._build_explorer_tab(left_spec, right_spec), "Dual-Pane Explorer")
        self.tabs.addTab(self._build_transfers_tab(), "Transfers && Jobs")
        self.tabs.addTab(self._build_remotes_tab(), "Remotes")
        self.tabs.addTab(self._build_mounts_tab(), "FUSE Mounts")
        self.tabs.addTab(self._build_saved_jobs_tab(), "Saved Jobs && Console")

        self.setStatusBar(QStatusBar())
        self.statusBar().showMessage(f"Config: {self.client.config_path}")

        self.poll_timer = QTimer(self)
        self.poll_timer.setInterval(1200)
        self.poll_timer.timeout.connect(self._poll_rc_stats)

        if auto_start_rc:
            self.refresh_all()
            self.poll_timer.start()

    # ── Top Header Bar ────────────────────────────────────────────────────────

    def _build_header(self) -> QFrame:
        bar = QFrame()
        bar.setObjectName("CardFrame")
        hl = QHBoxLayout(bar)
        hl.setContentsMargins(12, 8, 12, 8)
        hl.setSpacing(10)

        title = QLabel("RCLONE CONTROL")
        title.setStyleSheet(f"font-size: 16px; font-weight: 800; color: {self._palette['primary']};")
        self._brand_lbl = title
        hl.addWidget(title)

        cfg_lbl = QLabel(f"({self.client.config_path})")
        cfg_lbl.setStyleSheet(f"color: {self._palette['on_surface_variant']}; font-size: 12px;")
        self._cfg_lbl = cfg_lbl
        hl.addWidget(cfg_lbl)

        hl.addStretch(1)

        self.stats_pill = QLabel("Idle · 0 active · 0 B/s")
        hl.addWidget(self.stats_pill)

        hl.addWidget(QLabel("Rate Cap:"))
        self.bw_combo = QComboBox()
        for label, rate in (
            ("Unlimited", "off"),
            ("2 MiB/s", "2M"),
            ("10 MiB/s", "10M"),
            ("25 MiB/s", "25M"),
            ("50 MiB/s", "50M"),
            ("100 MiB/s", "100M"),
        ):
            self.bw_combo.addItem(label, rate)
        self.bw_combo.activated.connect(lambda _: self._apply_bwlimit(str(self.bw_combo.currentData())))
        hl.addWidget(self.bw_combo)

        self.theme_btn = make_button("Toggle Light/Dark", clicked=self._toggle_theme)
        hl.addWidget(self.theme_btn)
        hl.addWidget(make_button("Refresh All", object_name="PrimaryButton", clicked=self.refresh_all))
        return bar

    # ── Tab 1: Dual-Pane Explorer ─────────────────────────────────────────────

    def _build_explorer_tab(self, left_spec: str | None, right_spec: str | None) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(6, 6, 6, 6)
        layout.setSpacing(8)

        action_strip = QHBoxLayout()
        action_strip.setSpacing(6)
        for text, op, l_to_r in (
            ("Copy L -> R...", "copy", True),
            ("Move L -> R...", "move", True),
            ("Sync L -> R...", "sync", True),
            ("Dry-Run / Diff...", "sync", True),
            ("Check L <-> R...", "check", True),
            ("Bisync L <-> R...", "bisync", True),
        ):
            action_strip.addWidget(
                make_button(text, clicked=lambda _=False, o=op, lr=l_to_r: self._open_pane_operation(o, lr))
            )
        action_strip.addStretch(1)
        action_strip.addWidget(make_button("<- Copy R to L...", clicked=lambda: self._open_pane_operation("copy", False)))
        action_strip.addWidget(make_button("Swap Panes", clicked=self._swap_panes))
        layout.addLayout(action_strip)

        splitter = QSplitter(Qt.Orientation.Horizontal)
        default_left = left_spec or str(Path.home() / "Projects" if (Path.home() / "Projects").is_dir() else Path.home())
        default_right = right_spec or str(Path.home())

        self.left_pane = ExplorerPane("Left Pane", self.client, initial_spec=default_left)
        self.right_pane = ExplorerPane("Right Pane", self.client, initial_spec=default_right)
        for pane, other in ((self.left_pane, self.right_pane), (self.right_pane, self.left_pane)):
            pane.transfer_requested.connect(
                lambda op, items, src_p=pane, dst_p=other: self._handle_pane_transfer(op, items, src_p, dst_p)
            )
            pane.preview_requested.connect(lambda title, spec: PreviewDialog(self.client, title, spec, self).exec())
            pane.properties_requested.connect(
                lambda spec, is_dir, rname: PropertiesDialog(
                    self.client, spec, is_dir, remote_name=rname, remotes=self._remotes, parent=self
                ).exec()
            )
            pane.mount_requested.connect(lambda spec: self._open_mount_dialog(spec))

        splitter.addWidget(self.left_pane)
        splitter.addWidget(self.right_pane)
        splitter.setSizes([680, 680])
        layout.addWidget(splitter, 1)
        return page

    # ── Tab 2: Transfers & Jobs ───────────────────────────────────────────────

    def _build_transfers_tab(self) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(8, 8, 8, 8)
        layout.setSpacing(8)

        kpi_bar = QHBoxLayout()
        self.kpi_speed = QLabel("Speed: 0 B/s")
        self.kpi_bytes = QLabel("Transferred: 0 B / 0 B")
        self.kpi_counts = QLabel("Done: 0 · Checks: 0 · Errors: 0")
        for lbl in (self.kpi_speed, self.kpi_bytes, self.kpi_counts):
            lbl.setStyleSheet("font-weight: 700; padding: 4px 10px;")
            kpi_bar.addWidget(lbl)
        kpi_bar.addStretch(1)

        self.custom_bw_edit = QLineEdit()
        self.custom_bw_edit.setPlaceholderText("e.g. 10M or 10M:50M or off")
        self.custom_bw_edit.setMaximumWidth(180)
        kpi_bar.addWidget(self.custom_bw_edit)
        kpi_bar.addWidget(make_button("Apply BwLimit", clicked=lambda: self._apply_bwlimit(self.custom_bw_edit.text().strip() or "off")))
        kpi_bar.addWidget(make_button("+ New Transfer...", object_name="PrimaryButton", clicked=lambda: self._open_pane_operation("copy", True)))
        layout.addLayout(kpi_bar)

        layout.addWidget(QLabel("Active & Tracked Jobs:"))
        self.jobs_table = QTableWidget(0, 6)
        self.jobs_table.setHorizontalHeaderLabels(["Job ID", "Op", "Source -> Destination", "State", "Elapsed", "Action / Error"])
        self.jobs_table.horizontalHeader().setSectionResizeMode(2, QHeaderView.ResizeMode.Stretch)
        self.jobs_table.setAlternatingRowColors(True)
        layout.addWidget(self.jobs_table, 1)

        layout.addWidget(QLabel("Currently Transferring Files:"))
        self.active_files_table = QTableWidget(0, 5)
        self.active_files_table.setHorizontalHeaderLabels(["File", "Progress", "Size", "Speed", "ETA"])
        self.active_files_table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        self.active_files_table.setAlternatingRowColors(True)
        layout.addWidget(self.active_files_table, 1)

        layout.addWidget(QLabel("Recently Completed:"))
        self.completed_table = QTableWidget(0, 4)
        self.completed_table.setHorizontalHeaderLabels(["File", "Size", "Completed", "Error"])
        self.completed_table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        self.completed_table.setAlternatingRowColors(True)
        layout.addWidget(self.completed_table, 1)
        return page

    # ── Tab 3: Remotes ────────────────────────────────────────────────────────

    def _build_remotes_tab(self) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(8, 8, 8, 8)
        layout.setSpacing(8)

        toolbar = QHBoxLayout()
        toolbar.addWidget(make_button("+ New Remote...", object_name="PrimaryButton", clicked=self._create_remote))
        toolbar.addWidget(make_button("Edit Remote...", clicked=self._edit_selected_remote))
        toolbar.addWidget(make_button("Rename...", clicked=self._rename_selected_remote))
        toolbar.addWidget(make_button("Reconnect (Terminal OAuth/2FA)", clicked=self._reconnect_selected_remote))
        toolbar.addWidget(make_button("Open in Left", clicked=lambda: self._open_selected_remote_in(self.left_pane)))
        toolbar.addWidget(make_button("Open in Right", clicked=lambda: self._open_selected_remote_in(self.right_pane)))
        toolbar.addWidget(make_button("Mount Remote...", clicked=self._mount_selected_remote))
        toolbar.addStretch(1)
        toolbar.addWidget(make_button("Refresh", clicked=self.refresh_remotes))
        toolbar.addWidget(make_button("Delete Remote", object_name="DangerButton", clicked=self._delete_selected_remote))
        layout.addLayout(toolbar)

        self.remotes_table = QTableWidget(0, 4)
        self.remotes_table.setHorizontalHeaderLabels(["Remote Name", "Backend Type", "Target / URL / Root", "Quota / Info"])
        self.remotes_table.horizontalHeader().setSectionResizeMode(2, QHeaderView.ResizeMode.Stretch)
        self.remotes_table.horizontalHeader().setSectionResizeMode(3, QHeaderView.ResizeMode.Stretch)
        self.remotes_table.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        self.remotes_table.setAlternatingRowColors(True)
        layout.addWidget(self.remotes_table, 1)
        return page

    # ── Tab 4: Mounts ─────────────────────────────────────────────────────────

    def _build_mounts_tab(self) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(8, 8, 8, 8)
        layout.setSpacing(8)

        toolbar = QHBoxLayout()
        toolbar.addWidget(make_button("+ New Custom Mount...", object_name="PrimaryButton", clicked=lambda: self._open_mount_dialog("")))
        toolbar.addWidget(make_button("Start Unit", clicked=lambda: self._mount_unit_action("start")))
        toolbar.addWidget(make_button("Restart Unit", clicked=lambda: self._mount_unit_action("restart")))
        toolbar.addWidget(make_button("Stop Unit", clicked=lambda: self._mount_unit_action("stop")))
        toolbar.addWidget(make_button("Unmount FUSE", clicked=lambda: self._unmount_selected(lazy=False)))
        toolbar.addWidget(make_button("Lazy Unmount", object_name="DangerButton", clicked=lambda: self._unmount_selected(lazy=True)))
        toolbar.addWidget(make_button("VFS Refresh", clicked=self._vfs_refresh_selected))
        toolbar.addWidget(make_button("Browse Mountpoint", clicked=self._browse_selected_mount))
        toolbar.addStretch(1)
        toolbar.addWidget(make_button("Refresh Mounts", clicked=self.refresh_mounts))
        layout.addLayout(toolbar)

        self.mounts_table = QTableWidget(0, 7)
        self.mounts_table.setHorizontalHeaderLabels([
            "Remote Source", "Mountpoint", "Systemd Unit / PID", "State", "VFS Cache", "Access", "RC Addr",
        ])
        self.mounts_table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        self.mounts_table.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        self.mounts_table.setAlternatingRowColors(True)
        layout.addWidget(self.mounts_table, 1)
        return page

    # ── Tab 5: Saved Jobs & CLI Console ───────────────────────────────────────

    def _build_saved_jobs_tab(self) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(8, 8, 8, 8)
        layout.setSpacing(8)

        bar = QHBoxLayout()
        bar.addWidget(make_button("+ New Preset...", object_name="PrimaryButton", clicked=self._new_saved_job))
        bar.addWidget(make_button("Edit / Dry-Run...", clicked=self._edit_saved_job))
        bar.addWidget(make_button("Run Preset Now", clicked=self._run_saved_job))
        bar.addWidget(make_button("Delete Preset", object_name="DangerButton", clicked=self._delete_saved_job))
        bar.addStretch(1)
        layout.addLayout(bar)

        self.saved_jobs_table = QTableWidget(0, 5)
        self.saved_jobs_table.setHorizontalHeaderLabels(["Preset Name", "Op", "Source", "Destination", "Flags Summary"])
        self.saved_jobs_table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        self.saved_jobs_table.horizontalHeader().setSectionResizeMode(2, QHeaderView.ResizeMode.Stretch)
        self.saved_jobs_table.horizontalHeader().setSectionResizeMode(3, QHeaderView.ResizeMode.Stretch)
        self.saved_jobs_table.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        self.saved_jobs_table.setAlternatingRowColors(True)
        layout.addWidget(self.saved_jobs_table, 1)
        self._render_saved_jobs()

        # Quick Rclone Command Console
        console_row = QHBoxLayout()
        console_row.addWidget(QLabel("Quick CLI:  rclone"))
        self.cli_edit = QLineEdit("listremotes --long")
        self.cli_edit.setPlaceholderText("e.g. version | listremotes --long | tree gdrive: --max-depth 2")
        self.cli_edit.returnPressed.connect(self._run_quick_cli)
        console_row.addWidget(self.cli_edit, 1)
        console_row.addWidget(make_button("Run CLI", object_name="PrimaryButton", clicked=self._run_quick_cli))
        layout.addLayout(console_row)

        self.cli_output = QPlainTextEdit()
        self.cli_output.setReadOnly(True)
        self.cli_output.setFont(QFont("JetBrainsMono Nerd Font", 11))
        layout.addWidget(self.cli_output, 1)
        return page

    # ── Data Refresh & Theme ──────────────────────────────────────────────────

    def _toggle_theme(self) -> None:
        next_mode = "light" if self._theme_mode == "dark" else "dark"
        self._theme_mode, self._palette, qss = build_qss(mode=next_mode)
        self.setStyleSheet(qss)
        self._brand_lbl.setStyleSheet(f"font-size: 16px; font-weight: 800; color: {self._palette['primary']};")
        self._cfg_lbl.setStyleSheet(f"color: {self._palette['on_surface_variant']}; font-size: 12px;")

    def refresh_all(self) -> None:
        self.refresh_remotes()
        self.refresh_mounts()
        self.left_pane.refresh()
        self.right_pane.refresh()

    def refresh_remotes(self) -> None:
        def _fetch() -> tuple[list[str], dict[str, dict[str, Any]], list[dict[str, Any]]]:
            remotes = self.client.list_remotes()
            dump = self.client.config_dump()
            providers = self._providers or self.client.config_providers()
            return remotes, dump, providers

        def _done(payload: tuple[list[str], dict[str, dict[str, Any]], list[dict[str, Any]]]) -> None:
            remotes, dump, providers = payload
            self._remotes = remotes
            self._config_dump = dump
            self._providers = providers
            self.left_pane.set_remotes(remotes)
            self.right_pane.set_remotes(remotes)
            self._render_remotes()

        self.tasks.run(_fetch, on_success=_done, on_error=lambda e: self.statusBar().showMessage(f"Remotes error: {e}"))

    def _render_remotes(self) -> None:
        self.remotes_table.setRowCount(len(self._remotes))
        for row, name in enumerate(self._remotes):
            cfg = self._config_dump.get(name, {})
            rtype = str(cfg.get("type", "unknown"))
            target = str(cfg.get("remote") or cfg.get("url") or cfg.get("host") or cfg.get("endpoint") or "—")
            self.remotes_table.setItem(row, 0, QTableWidgetItem(name))
            self.remotes_table.setItem(row, 1, QTableWidgetItem(rtype))
            self.remotes_table.setItem(row, 2, QTableWidgetItem(target))
            self.remotes_table.setItem(row, 3, QTableWidgetItem("Querying..."))

            def _about(r: int = row, remote_name: str = name) -> tuple[int, str]:
                try:
                    info = self.client.about(f"{remote_name}:")
                    used = format_bytes(info.get("used"))
                    total = format_bytes(info.get("total"))
                    free = format_bytes(info.get("free"))
                    return r, f"Used {used} · Total {total} · Free {free}"
                except Exception:
                    return r, "No quota info"

            def _set_quota(res: tuple[int, str]) -> None:
                r, txt = res
                if r < self.remotes_table.rowCount():
                    self.remotes_table.setItem(r, 3, QTableWidgetItem(txt))

            self.tasks.run(_about, on_success=_set_quota)

    # ── Dual-Pane & Transfer Dispatch ─────────────────────────────────────────

    def _swap_panes(self) -> None:
        a, b = self.left_pane.current_spec, self.right_pane.current_spec
        self.left_pane.navigate(b, record_history=True)
        self.right_pane.navigate(a, record_history=True)

    @staticmethod
    def _join_child(base_spec: str, child_name: str) -> str:
        if base_spec.startswith("/"):
            return str(Path(base_spec) / child_name)
        fs_root, sub = split_fs_path(base_spec)
        return join_fs_path(fs_root, f"{sub}/{child_name}".strip("/") if sub else child_name)

    def _open_pane_operation(self, op: str, left_to_right: bool) -> None:
        src_pane = self.left_pane if left_to_right else self.right_pane
        dst_pane = self.right_pane if left_to_right else self.left_pane
        sel = src_pane.selected_entries()
        if len(sel) == 1:
            entry = sel[0]
            name = str(entry["name"])
            is_dir = bool(entry.get("is_dir", False))
            src = self._join_child(src_pane.current_spec, name)
            dst = self._join_child(dst_pane.current_spec, name)
            if not is_dir and op in ("copy", "move"):
                op = f"{op}file"
        else:
            src = src_pane.current_spec
            dst = dst_pane.current_spec
        self._launch_operation_dialog(op, src, dst)

    def _handle_pane_transfer(
        self,
        op: str,
        items: list[dict[str, Any]],
        src_pane: ExplorerPane,
        dst_pane: ExplorerPane,
    ) -> None:
        if op in ("batch_copy", "batch_move") and items:
            real_op = "copy" if op == "batch_copy" else "move"
            reply = QMessageBox.question(
                self,
                f"Batch {real_op.title()}",
                f"{real_op.title()} {len(items)} selected items to {dst_pane.current_spec}?",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            )
            if reply != QMessageBox.StandardButton.Yes:
                return
            for entry in items:
                item_op = real_op if entry["is_dir"] else f"{real_op}file"
                dst_spec = self._join_child(dst_pane.current_spec, entry["name"])
                self.tasks.run(
                    lambda io=item_op, sp=entry["spec"], dp=dst_spec: (
                        self.client.start_transfer_job(io, sp, dp), io, sp, dp
                    ),
                    on_success=lambda res: self._record_started_job({
                        "jobid": res[0], "operation": res[1], "src": res[2], "dst": res[3], "dry_run": False,
                    }),
                    on_error=lambda err: show_error(self, "Batch Transfer Failed", err),
                )
            self.tabs.setCurrentIndex(1)
            return

        if items:
            first = items[0]
            src = str(first["spec"])
            dst = dst_pane.current_spec if op == "check" else self._join_child(dst_pane.current_spec, str(first["name"]))
        else:
            src = src_pane.current_spec
            dst = dst_pane.current_spec
        self._launch_operation_dialog(op, src, dst)

    def _launch_operation_dialog(self, op: str, src: str, dst: str, preset: dict[str, Any] | None = None) -> None:
        dlg = OperationDialog(self.client, operation=op, src_spec=src, dst_spec=dst, preset=preset, parent=self)
        dlg.preset_saved.connect(self._add_saved_job)
        dlg.job_started.connect(self._on_dialog_job_started)
        dlg.exec()

    def _on_dialog_job_started(self, info: dict[str, Any]) -> None:
        self._record_started_job(info)
        self.tabs.setCurrentIndex(1)

    def _record_started_job(self, info: dict[str, Any]) -> None:
        jid = int(info["jobid"])
        self._tracked_jobs[jid] = {
            "jobid": jid,
            "operation": info.get("operation", "transfer"),
            "src": info.get("src", ""),
            "dst": info.get("dst", ""),
            "finished": False,
            "success": True,
            "error": "",
            "started_at": time.monotonic(),
            "duration": 0.0,
        }
        self._poll_rc_stats()

    # ── Live Transfers & Stats Polling ────────────────────────────────────────

    def _apply_bwlimit(self, rate: str) -> None:
        def _done(res: dict[str, Any]) -> None:
            self.statusBar().showMessage(f"Bandwidth limit applied: {res.get('rate', rate)}", 4000)

        self.tasks.run(
            lambda: self.client.set_bwlimit(rate),
            on_success=_done,
            on_error=lambda e: show_error(self, "BwLimit Error", e),
        )

    def _poll_rc_stats(self) -> None:
        if self._poll_active:
            return
        self._poll_active = True

        active_ids = [jid for jid, meta in self._tracked_jobs.items() if not meta.get("finished")]

        def _fetch() -> dict[str, Any]:
            stats = self.client.core_stats()
            transferred = self.client.core_transferred()
            statuses: dict[int, dict[str, Any]] = {}
            for jid in active_ids:
                try:
                    statuses[jid] = self.client.job_status(jid)
                except Exception:
                    pass
            return {"stats": stats, "transferred": transferred, "statuses": statuses}

        def _done(payload: dict[str, Any]) -> None:
            self._poll_active = False
            stats = payload["stats"]
            statuses = payload["statuses"]
            any_just_finished = False
            for jid, st in statuses.items():
                meta = self._tracked_jobs.get(jid)
                if not meta:
                    continue
                if st.get("finished"):
                    meta["finished"] = True
                    meta["success"] = bool(st.get("success", True))
                    meta["error"] = str(st.get("error", ""))
                    meta["duration"] = float(st.get("duration", 0.0))
                    any_just_finished = True
                else:
                    meta["duration"] = time.monotonic() - float(meta.get("started_at", time.monotonic()))
            self._render_stats(stats, payload["transferred"])
            if any_just_finished:
                self.left_pane.refresh()
                self.right_pane.refresh()

        def _err(_msg: str) -> None:
            self._poll_active = False

        self.tasks.run(_fetch, on_success=_done, on_error=_err)

    def _render_stats(self, stats: dict[str, Any], transferred: list[dict[str, Any]]) -> None:
        speed = float(stats.get("speed") or 0.0)
        done_bytes = int(stats.get("bytes") or 0)
        total_bytes = int(stats.get("totalBytes") or 0)
        transfers = int(stats.get("transfers") or 0)
        checks = int(stats.get("checks") or 0)
        errors = int(stats.get("errors") or 0)
        active_list = list(stats.get("transferring") or [])

        self.stats_pill.setText(f"{len(active_list)} active · {format_bytes(speed)}/s")
        self.kpi_speed.setText(f"Speed: {format_bytes(speed)}/s")
        self.kpi_bytes.setText(f"Transferred: {format_bytes(done_bytes)} / {format_bytes(total_bytes)}")
        self.kpi_counts.setText(f"Done: {transfers} · Checks: {checks} · Errors: {errors}")

        # Jobs table
        jobs = sorted(self._tracked_jobs.values(), key=lambda j: int(j["jobid"]), reverse=True)
        self.jobs_table.setRowCount(len(jobs))
        for row, job in enumerate(jobs):
            jid = int(job["jobid"])
            state = "Running" if not job["finished"] else ("Completed" if job["success"] else "Failed")
            self.jobs_table.setItem(row, 0, QTableWidgetItem(str(jid)))
            self.jobs_table.setItem(row, 1, QTableWidgetItem(str(job["operation"])))
            self.jobs_table.setItem(row, 2, QTableWidgetItem(f"{job['src']} -> {job['dst']}"))
            self.jobs_table.setItem(row, 3, QTableWidgetItem(state))
            self.jobs_table.setItem(row, 4, QTableWidgetItem(f"{float(job.get('duration', 0.0)):.1f}s"))
            if not job["finished"]:
                stop_btn = make_button("Stop", object_name="DangerButton", clicked=lambda _=False, j=jid: self._stop_job(j))
                self.jobs_table.setCellWidget(row, 5, stop_btn)
            else:
                self.jobs_table.removeCellWidget(row, 5)
                self.jobs_table.setItem(row, 5, QTableWidgetItem(job.get("error") or "OK"))

        # Active transferring files
        self.active_files_table.setRowCount(len(active_list))
        for row, tf in enumerate(active_list):
            self.active_files_table.setItem(row, 0, QTableWidgetItem(str(tf.get("name", ""))))
            bar = QProgressBar()
            bar.setRange(0, 100)
            bar.setValue(int(tf.get("percentage") or 0))
            self.active_files_table.setCellWidget(row, 1, bar)
            self.active_files_table.setItem(row, 2, QTableWidgetItem(format_bytes(tf.get("size"))))
            self.active_files_table.setItem(row, 3, QTableWidgetItem(f"{format_bytes(tf.get('speedAvg') or tf.get('speed') or 0)}/s"))
            eta = tf.get("eta")
            self.active_files_table.setItem(row, 4, QTableWidgetItem(f"{eta}s" if eta is not None else "—"))

        # Recently completed (newest first, capped to 25)
        recent = list(reversed(transferred))[:25]
        self.completed_table.setRowCount(len(recent))
        for row, item in enumerate(recent):
            self.completed_table.setItem(row, 0, QTableWidgetItem(str(item.get("name", ""))))
            self.completed_table.setItem(row, 1, QTableWidgetItem(format_bytes(item.get("size"))))
            self.completed_table.setItem(row, 2, QTableWidgetItem(str(item.get("completed_at", ""))[:19].replace("T", " ")))
            self.completed_table.setItem(row, 3, QTableWidgetItem(str(item.get("error", "")) or "OK"))

    def _stop_job(self, jobid: int) -> None:
        self.tasks.run(
            lambda: self.client.job_stop(jobid),
            on_success=lambda _: self._poll_rc_stats(),
            on_error=lambda e: show_error(self, "Stop Job Failed", e),
        )

    # ── Remotes CRUD ──────────────────────────────────────────────────────────

    def _selected_remote(self) -> str | None:
        row = self.remotes_table.currentRow()
        if row < 0:
            return None
        item = self.remotes_table.item(row, 0)
        return item.text() if item else None

    def _create_remote(self) -> None:
        dlg = RemoteEditorDialog(self.client, self._providers, parent=self)
        if dlg.exec():
            self.refresh_remotes()

    def _edit_selected_remote(self) -> None:
        name = self._selected_remote()
        if not name:
            return
        dlg = RemoteEditorDialog(
            self.client, self._providers, existing_name=name, existing_cfg=self._config_dump.get(name, {}), parent=self
        )
        if dlg.exec():
            self.refresh_remotes()

    def _rename_selected_remote(self) -> None:
        old_name = self._selected_remote()
        if not old_name:
            return
        new_name, ok = QInputDialog.getText(self, "Rename Remote", f"New name for '{old_name}':", text=old_name)
        clean = new_name.strip()
        if not ok or not clean or clean == old_name:
            return
        try:
            self.client.rename_remote(old_name, clean)
            self.refresh_remotes()
        except Exception as exc:  # noqa: BLE001
            show_error(self, "Rename Remote Failed", exc)

    def _reconnect_selected_remote(self) -> None:
        name = self._selected_remote()
        if not name:
            return
        try:
            self.client.launch_interactive_config(["config", "reconnect", f"{name}:"])
            QMessageBox.information(
                self, "Terminal Opened", f"Opened interactive reconnect for '{name}:'. Click Refresh once complete."
            )
        except Exception as exc:  # noqa: BLE001
            show_error(self, "Reconnect Failed", exc)

    def _delete_selected_remote(self) -> None:
        name = self._selected_remote()
        if not name:
            return
        reply = QMessageBox.question(
            self,
            "Delete Remote",
            f"Remove remote '{name}' from {self.client.config_path}?\n(Cloud data itself is NOT deleted.)",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if reply != QMessageBox.StandardButton.Yes:
            return
        self.tasks.run(
            lambda: self.client.config_delete(name),
            on_success=lambda _: self.refresh_remotes(),
            on_error=lambda e: show_error(self, "Delete Remote Failed", e),
        )

    def _open_selected_remote_in(self, pane: ExplorerPane) -> None:
        name = self._selected_remote()
        if name:
            pane.navigate(f"{name}:")
            self.tabs.setCurrentIndex(0)

    def _mount_selected_remote(self) -> None:
        name = self._selected_remote()
        self._open_mount_dialog(f"{name}:" if name else "")

    # ── Mounts Control ────────────────────────────────────────────────────────

    def refresh_mounts(self) -> None:
        def _done(mounts: list[Any]) -> None:
            self._mounts_cache = mounts
            self.mounts_table.setRowCount(len(mounts))
            for row, m in enumerate(mounts):
                self.mounts_table.setItem(row, 0, QTableWidgetItem(m.source))
                self.mounts_table.setItem(row, 1, QTableWidgetItem(m.mountpoint))
                unit_or_pid = m.systemd_unit or (f"PID {m.pid}" if m.pid else "—")
                self.mounts_table.setItem(row, 2, QTableWidgetItem(unit_or_pid))
                self.mounts_table.setItem(row, 3, QTableWidgetItem(m.active_state))
                self.mounts_table.setItem(row, 4, QTableWidgetItem(m.vfs_cache_mode))
                self.mounts_table.setItem(row, 5, QTableWidgetItem("RO" if m.read_only else "RW"))
                self.mounts_table.setItem(row, 6, QTableWidgetItem(m.rc_addr or "—"))

        self.tasks.run(self.client.discover_mounts, on_success=_done)

    def _selected_mount(self) -> Any | None:
        row = self.mounts_table.currentRow()
        if 0 <= row < len(self._mounts_cache):
            return self._mounts_cache[row]
        return None

    def _open_mount_dialog(self, initial_source: str) -> None:
        dlg = MountDialog(self.client, self._remotes, initial_source=initial_source, parent=self)
        if dlg.exec():
            QTimer.singleShot(900, self.refresh_mounts)

    def _mount_unit_action(self, action: str) -> None:
        m = self._selected_mount()
        if not m or not m.systemd_unit:
            QMessageBox.information(self, "Mount Unit", "Select a systemd user mount row to start/stop/restart.")
            return
        self.tasks.run(
            lambda: self.client.control_systemd_mount(m.systemd_unit, action),
            on_success=lambda _: QTimer.singleShot(700, self.refresh_mounts),
            on_error=lambda e: show_error(self, f"Systemd {action} Failed", e),
        )

    def _unmount_selected(self, lazy: bool = False) -> None:
        m = self._selected_mount()
        if not m:
            return
        self.tasks.run(
            lambda: self.client.unmount_path(m.mountpoint, lazy=lazy),
            on_success=lambda _: QTimer.singleShot(500, self.refresh_mounts),
            on_error=lambda e: show_error(self, "Unmount Failed", e),
        )

    def _vfs_refresh_selected(self) -> None:
        m = self._selected_mount()
        if not m or not m.rc_addr:
            QMessageBox.information(self, "VFS Refresh", "Selected mount does not expose an rclone --rc-addr endpoint.")
            return
        url = f"http://{m.rc_addr}/vfs/refresh" if not str(m.rc_addr).startswith("http") else f"{m.rc_addr}/vfs/refresh"
        self.tasks.run(
            lambda: self.client.call_url(url, {"recursive": False}, timeout=15.0),
            on_success=lambda _: self.statusBar().showMessage(f"VFS refreshed for {m.mountpoint}", 4000),
            on_error=lambda e: show_error(self, "VFS Refresh Failed", e),
        )

    def _browse_selected_mount(self) -> None:
        m = self._selected_mount()
        if m:
            self.left_pane.navigate(m.mountpoint)
            self.tabs.setCurrentIndex(0)

    # ── Saved Jobs & Quick CLI ────────────────────────────────────────────────

    def _load_saved_jobs(self) -> list[dict[str, Any]]:
        path = _jobs_store_path()
        if not path.is_file():
            return []
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            return list(data) if isinstance(data, list) else []
        except (OSError, ValueError):
            return []

    def _write_saved_jobs(self) -> None:
        path = _jobs_store_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(self._saved_jobs, indent=2) + "\n", encoding="utf-8")

    def _add_saved_job(self, preset: dict[str, Any]) -> None:
        name = str(preset.get("name", ""))
        self._saved_jobs = [j for j in self._saved_jobs if j.get("name") != name]
        self._saved_jobs.append(preset)
        self._write_saved_jobs()
        self._render_saved_jobs()

    def _render_saved_jobs(self) -> None:
        self.saved_jobs_table.setRowCount(len(self._saved_jobs))
        for row, job in enumerate(self._saved_jobs):
            flags = [k for k in ("update_older", "checksum", "ignore_existing", "size_only", "track_renames") if job.get(k)]
            self.saved_jobs_table.setItem(row, 0, QTableWidgetItem(str(job.get("name", ""))))
            self.saved_jobs_table.setItem(row, 1, QTableWidgetItem(str(job.get("operation", ""))))
            self.saved_jobs_table.setItem(row, 2, QTableWidgetItem(str(job.get("src", ""))))
            self.saved_jobs_table.setItem(row, 3, QTableWidgetItem(str(job.get("dst", ""))))
            self.saved_jobs_table.setItem(row, 4, QTableWidgetItem(", ".join(flags) or "default"))

    def _new_saved_job(self) -> None:
        self._launch_operation_dialog("sync", self.left_pane.current_spec, self.right_pane.current_spec)

    def _edit_saved_job(self) -> None:
        row = self.saved_jobs_table.currentRow()
        if 0 <= row < len(self._saved_jobs):
            job = self._saved_jobs[row]
            self._launch_operation_dialog(job.get("operation", "sync"), job.get("src", ""), job.get("dst", ""), preset=job)

    def _run_saved_job(self) -> None:
        row = self.saved_jobs_table.currentRow()
        if not (0 <= row < len(self._saved_jobs)):
            return
        job = self._saved_jobs[row]
        extra_cfg, extra_params = build_rc_params_from_preset(job)
        op = str(job.get("operation", "copy"))
        src = str(job.get("src", ""))
        dst = str(job.get("dst", ""))
        self.tasks.run(
            lambda: self.client.start_transfer_job(
                op, src, dst, transfers=int(job.get("transfers", 4)),
                extra_config=extra_cfg, extra_params=extra_params,
            ),
            on_success=lambda jid: self._on_dialog_job_started({"jobid": jid, "operation": op, "src": src, "dst": dst}),
            on_error=lambda e: show_error(self, "Run Preset Failed", e),
        )

    def _delete_saved_job(self) -> None:
        row = self.saved_jobs_table.currentRow()
        if 0 <= row < len(self._saved_jobs):
            del self._saved_jobs[row]
            self._write_saved_jobs()
            self._render_saved_jobs()

    def _run_quick_cli(self) -> None:
        import shlex

        raw = self.cli_edit.text().strip()
        if not raw:
            return
        try:
            args = shlex.split(raw)
        except ValueError as exc:
            show_error(self, "Invalid Command Syntax", exc)
            return
        self.cli_output.setPlainText(f"$ rclone {raw}\nRunning...\n")

        def _done(res: Any) -> None:
            out = "\n".join(part for part in (res.stdout.strip(), res.stderr.strip()) if part)
            self.cli_output.setPlainText(f"$ rclone {raw}\n[exit {res.returncode}]\n\n{out}")

        self.tasks.run(lambda: self.client.run_cli(args, timeout=120.0), on_success=_done, on_error=self.cli_output.setPlainText)

    # ── Lifecycle ─────────────────────────────────────────────────────────────

    def shutdown(self) -> None:
        self.poll_timer.stop()
        self.tasks.cancel_all()
        self.left_pane.tasks.cancel_all()
        self.right_pane.tasks.cancel_all()
        self.client.shutdown()

    def closeEvent(self, event: Any) -> None:
        self.shutdown()
        super().closeEvent(event)
