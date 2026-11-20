"""Dual-pane file explorer widget backed by RcloneClient."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
from typing import Any
from PyQt6.QtCore import Qt, pyqtSignal
from PyQt6.QtGui import QKeySequence, QShortcut
from PyQt6.QtWidgets import (
    QAbstractItemView,
    QCheckBox,
    QComboBox,
    QFrame,
    QHBoxLayout,
    QHeaderView,
    QInputDialog,
    QLabel,
    QLineEdit,
    QMenu,
    QMessageBox,
    QTreeWidget,
    QTreeWidgetItem,
    QVBoxLayout,
    QWidget,
)

from .qt_helpers import TaskManager, make_button, show_error
from .rc_client import RcloneClient, format_bytes, join_fs_path, split_fs_path

LOCAL_OPTION = "[Local Filesystem]"
ROLE_ENTRY = Qt.ItemDataRole.UserRole + 1
ROLE_SORT_KEY = Qt.ItemDataRole.UserRole + 2


class EntryTreeItem(QTreeWidgetItem):
    """Tree row that sorts directories first and compares numeric sizes accurately."""

    def __lt__(self, other: QTreeWidgetItem) -> bool:
        tree = self.treeWidget()
        col = tree.sortColumn() if tree else 0
        self_entry: dict[str, Any] = self.data(0, ROLE_ENTRY) or {}
        other_entry: dict[str, Any] = other.data(0, ROLE_ENTRY) or {}

        # Keep directories grouped ahead of files in ascending order.
        self_dir = bool(self_entry.get("is_dir", False))
        other_dir = bool(other_entry.get("is_dir", False))
        if self_dir != other_dir:
            order = tree.header().sortIndicatorOrder() if tree else Qt.SortOrder.AscendingOrder
            return self_dir if order == Qt.SortOrder.AscendingOrder else not self_dir

        if col == 1:
            return int(self.data(1, ROLE_SORT_KEY) or -1) < int(other.data(1, ROLE_SORT_KEY) or -1)
        return self.text(col).lower() < other.text(col).lower()


class ExplorerPane(QFrame):
    """Single browser pane capable of inspecting local folders or any rclone remote."""

    transfer_requested = pyqtSignal(str, object)     # op, list[{spec, name, is_dir}]
    preview_requested = pyqtSignal(str, str)        # title, spec
    properties_requested = pyqtSignal(str, bool, str)  # spec, is_dir, remote_name
    mount_requested = pyqtSignal(str)               # remote_spec
    path_changed = pyqtSignal(str)

    def __init__(
        self,
        title: str,
        client: RcloneClient,
        initial_spec: str | None = None,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self.setObjectName("CardFrame")
        self.client = client
        self.tasks = TaskManager(self)
        self._remotes: list[str] = []
        self._entries: list[dict[str, Any]] = []
        self._current_spec = initial_spec or str(Path.home())
        self._history: list[str] = []
        self._load_generation = 0

        layout = QVBoxLayout(self)
        layout.setContentsMargins(10, 10, 10, 10)
        layout.setSpacing(8)

        # Header row: pane badge, source dropdown, quota summary
        top_row = QHBoxLayout()
        top_row.setSpacing(8)
        self.title_lbl = QLabel(title)
        self.title_lbl.setStyleSheet("font-weight: 700;")
        top_row.addWidget(self.title_lbl)

        self.source_combo = QComboBox()
        self.source_combo.setMinimumWidth(160)
        self.source_combo.addItem(LOCAL_OPTION, "/")
        self.source_combo.activated.connect(self._on_source_chosen)
        top_row.addWidget(self.source_combo)

        self.quota_lbl = QLabel("Quota: —")
        self.quota_lbl.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        top_row.addWidget(self.quota_lbl, 1)
        layout.addLayout(top_row)

        # Navigation bar
        nav_row = QHBoxLayout()
        nav_row.setSpacing(6)
        self.back_btn = make_button("Back", tooltip="Go back in history", clicked=self.go_back)
        self.up_btn = make_button("Up", tooltip="Parent directory (Backspace)", clicked=self.go_up)
        self.home_btn = make_button("Home", tooltip="Home folder or remote root", clicked=self.go_home)
        self.refresh_btn = make_button("Refresh", tooltip="Reload listing (F5)", clicked=self.refresh)
        for btn in (self.back_btn, self.up_btn, self.home_btn, self.refresh_btn):
            nav_row.addWidget(btn)

        self.path_edit = QLineEdit(self._current_spec)
        self.path_edit.setPlaceholderText("/path/to/local or remote:sub/path")
        self.path_edit.returnPressed.connect(lambda: self.navigate(self.path_edit.text().strip()))
        nav_row.addWidget(self.path_edit, 1)
        layout.addLayout(nav_row)

        # Filter + Hidden bar
        filter_row = QHBoxLayout()
        filter_row.setSpacing(8)
        self.filter_edit = QLineEdit()
        self.filter_edit.setPlaceholderText("Filter files or folders...")
        self.filter_edit.setClearButtonEnabled(True)
        self.filter_edit.textChanged.connect(self._apply_filter)
        filter_row.addWidget(self.filter_edit, 1)

        self.hidden_chk = QCheckBox("Hidden")
        self.hidden_chk.toggled.connect(lambda _: self.refresh())
        filter_row.addWidget(self.hidden_chk)

        self.new_dir_btn = make_button("+ Folder", clicked=self.create_directory)
        self.rename_btn = make_button("Rename", clicked=self.rename_selected)
        self.delete_btn = make_button("Delete", object_name="DangerButton", clicked=self.delete_selected)
        for btn in (self.new_dir_btn, self.rename_btn, self.delete_btn):
            filter_row.addWidget(btn)
        layout.addLayout(filter_row)

        # File listing tree
        self.tree = QTreeWidget()
        self.tree.setColumnCount(4)
        self.tree.setHeaderLabels(["Name", "Size", "Modified", "Type"])
        self.tree.setRootIsDecorated(False)
        self.tree.setAlternatingRowColors(True)
        self.tree.setSortingEnabled(True)
        self.tree.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)
        self.tree.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.tree.customContextMenuRequested.connect(self._show_context_menu)
        self.tree.itemDoubleClicked.connect(self._on_item_double_clicked)
        self.tree.itemSelectionChanged.connect(self._update_status_footer)

        header = self.tree.header()
        header.setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        header.setSectionResizeMode(1, QHeaderView.ResizeMode.ResizeToContents)
        header.setSectionResizeMode(2, QHeaderView.ResizeMode.ResizeToContents)
        header.setSectionResizeMode(3, QHeaderView.ResizeMode.ResizeToContents)
        self.tree.sortByColumn(0, Qt.SortOrder.AscendingOrder)
        layout.addWidget(self.tree, 1)

        self.status_lbl = QLabel("Ready")
        layout.addWidget(self.status_lbl)

        # Pane-scoped keyboard shortcuts
        self._bind_shortcut("F5", self.refresh)
        self._bind_shortcut("F2", self.rename_selected)
        self._bind_shortcut("F7", self.create_directory)
        self._bind_shortcut("Delete", self.delete_selected)
        self._bind_shortcut("Backspace", self.go_up)
        self._bind_shortcut("Ctrl+L", self.path_edit.setFocus)

    def _bind_shortcut(self, key_seq: str, slot: Any) -> None:
        sc = QShortcut(QKeySequence(key_seq), self)
        sc.setContext(Qt.ShortcutContext.WidgetWithChildrenShortcut)
        sc.activated.connect(slot)

    @property
    def current_spec(self) -> str:
        return self._current_spec

    def current_remote_name(self) -> str:
        if self._current_spec.startswith("/"):
            return ""
        fs_root, _ = split_fs_path(self._current_spec)
        return fs_root.rstrip(":")

    def set_remotes(self, remotes: list[str]) -> None:
        self._remotes = list(remotes)
        current_data = "/" if self._current_spec.startswith("/") else split_fs_path(self._current_spec)[0]
        self.source_combo.blockSignals(True)
        self.source_combo.clear()
        self.source_combo.addItem(LOCAL_OPTION, "/")
        for remote in self._remotes:
            root = f"{remote}:"
            self.source_combo.addItem(root, root)
        idx = self.source_combo.findData(current_data)
        if idx >= 0:
            self.source_combo.setCurrentIndex(idx)
        self.source_combo.blockSignals(False)

    def selected_entries(self) -> list[dict[str, Any]]:
        entries: list[dict[str, Any]] = []
        for item in self.tree.selectedItems():
            entry = item.data(0, ROLE_ENTRY)
            if isinstance(entry, dict):
                entries.append(entry)
        return entries

    def _spec_join(self, child_name: str) -> str:
        if self._current_spec.startswith("/"):
            return str(Path(self._current_spec) / child_name)
        fs_root, sub = split_fs_path(self._current_spec)
        joined_sub = f"{sub}/{child_name}".strip("/") if sub else child_name
        return join_fs_path(fs_root, joined_sub)

    def primary_selected_spec(self) -> str:
        sel = self.selected_entries()
        if sel:
            return self._spec_join(sel[0]["name"])
        return self._current_spec

    def _on_source_chosen(self, index: int) -> None:
        root = self.source_combo.itemData(index)
        if not isinstance(root, str):
            return
        if root == "/":
            self.navigate(str(Path.home()))
        else:
            self.navigate(root)

    def navigate(self, spec: str, record_history: bool = True) -> None:
        target = spec.strip()
        if not target:
            return
        if not target.startswith("/") and ":" not in target:
            target = f"{target}:"
        if target.startswith("~"):
            target = os.path.expanduser(target)
        if target.startswith("/") and target != "/":
            target = os.path.normpath(target)
        elif not target.startswith("/"):
            fs_root, sub = split_fs_path(target)
            target = join_fs_path(fs_root, sub)

        if record_history and self._current_spec != target:
            self._history.append(self._current_spec)
        self._current_spec = target
        self.path_edit.setText(target)
        self._sync_source_combo()
        self.path_changed.emit(target)
        self.refresh()

    def _sync_source_combo(self) -> None:
        key = "/" if self._current_spec.startswith("/") else split_fs_path(self._current_spec)[0]
        self.source_combo.blockSignals(True)
        idx = self.source_combo.findData(key)
        if idx >= 0:
            self.source_combo.setCurrentIndex(idx)
        self.source_combo.blockSignals(False)

    def go_back(self) -> None:
        if self._history:
            prev = self._history.pop()
            self.navigate(prev, record_history=False)

    def go_up(self) -> None:
        if self._current_spec.startswith("/"):
            parent = str(Path(self._current_spec).parent)
            if parent != self._current_spec:
                self.navigate(parent)
            return
        fs_root, sub = split_fs_path(self._current_spec)
        if not sub:
            return
        parent_sub = sub.rsplit("/", 1)[0] if "/" in sub else ""
        self.navigate(join_fs_path(fs_root, parent_sub))

    def go_home(self) -> None:
        if self._current_spec.startswith("/"):
            self.navigate(str(Path.home()))
        else:
            fs_root, _ = split_fs_path(self._current_spec)
            self.navigate(fs_root)

    def refresh(self) -> None:
        self._load_generation += 1
        gen = self._load_generation
        spec = self._current_spec
        show_hidden = self.hidden_chk.isChecked()
        self.status_lbl.setText(f"Loading {spec} ...")
        self.tree.setEnabled(False)

        def _fetch() -> tuple[list[dict[str, Any]], str]:
            entries = self.client.list_entries(spec, show_hidden=show_hidden)
            quota_text = self._read_quota_summary(spec)
            return entries, quota_text

        def _done(payload: tuple[list[dict[str, Any]], str]) -> None:
            if gen != self._load_generation:
                return
            entries, quota_text = payload
            self._entries = entries
            self.quota_lbl.setText(quota_text)
            self.tree.setEnabled(True)
            self._apply_filter()

        def _err(msg: str) -> None:
            if gen != self._load_generation:
                return
            self.tree.setEnabled(True)
            self.status_lbl.setText(f"Error: {msg}")
            self.quota_lbl.setText("Quota: unavailable")

        self.tasks.run(_fetch, on_success=_done, on_error=_err)

    def _read_quota_summary(self, spec: str) -> str:
        if spec.startswith("/"):
            try:
                usage = shutil.disk_usage(spec if os.path.exists(spec) else "/")
                return f"Local Disk: {format_bytes(usage.free)} free / {format_bytes(usage.total)}"
            except OSError:
                return "Local Disk"
        fs_root, _ = split_fs_path(spec)
        try:
            info = self.client.about(fs_root)
            used = info.get("used")
            total = info.get("total")
            free = info.get("free")
            parts = []
            if used is not None:
                parts.append(f"Used {format_bytes(used)}")
            if total is not None:
                parts.append(f"Total {format_bytes(total)}")
            elif free is not None:
                parts.append(f"Free {format_bytes(free)}")
            return " · ".join(parts) if parts else f"Remote: {fs_root}"
        except Exception:
            return f"Remote: {fs_root}"

    def _apply_filter(self) -> None:
        needle = self.filter_edit.text().strip().lower()
        self.tree.setSortingEnabled(False)
        self.tree.clear()
        dirs = 0
        files = 0
        for entry in self._entries:
            name = str(entry.get("name", ""))
            if needle and needle not in name.lower():
                continue
            is_dir = bool(entry.get("is_dir", False))
            if is_dir:
                dirs += 1
            else:
                files += 1
            size = int(entry.get("size", -1))
            mod = str(entry.get("mod_time", ""))[:19].replace("T", " ")
            kind = "Folder" if is_dir else (str(entry.get("mime", "")) or "File")
            prefix = "[DIR] " if is_dir else "      "
            item = EntryTreeItem([
                f"{prefix}{name}",
                "—" if is_dir else format_bytes(size),
                mod or "—",
                kind,
            ])
            item.setData(0, ROLE_ENTRY, entry)
            item.setData(1, ROLE_SORT_KEY, -1 if is_dir else size)
            item.setTextAlignment(1, Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
            self.tree.addTopLevelItem(item)
        self.tree.setSortingEnabled(True)
        self._update_status_footer(dirs=dirs, files=files)

    def _update_status_footer(self, dirs: int | None = None, files: int | None = None) -> None:
        if dirs is None or files is None:
            dirs = sum(1 for e in self._entries if e.get("is_dir"))
            files = len(self._entries) - dirs
        selected = self.selected_entries()
        total_sel_bytes = sum(max(0, int(e.get("size", 0))) for e in selected if not e.get("is_dir"))
        if selected:
            self.status_lbl.setText(
                f"{dirs} folders, {files} files · Selected: {len(selected)} ({format_bytes(total_sel_bytes)})"
            )
        else:
            self.status_lbl.setText(f"{dirs} folders, {files} files")

    def _on_item_double_clicked(self, item: QTreeWidgetItem, _col: int) -> None:
        entry = item.data(0, ROLE_ENTRY)
        if not isinstance(entry, dict):
            return
        target = self._spec_join(entry["name"])
        if entry.get("is_dir"):
            self.navigate(target)
        else:
            self.preview_requested.emit(entry["name"], target)

    def create_directory(self) -> None:
        name, ok = QInputDialog.getText(self, "Create Folder", f"New folder inside {self._current_spec}:")
        clean = name.strip().strip("/")
        if not ok or not clean:
            return
        target = self._spec_join(clean)
        self.tasks.run(
            lambda: self.client.mkdir(target),
            on_success=lambda _: self.refresh(),
            on_error=lambda err: show_error(self, "Create Folder Failed", err),
        )

    def rename_selected(self) -> None:
        sel = self.selected_entries()
        if len(sel) != 1:
            QMessageBox.information(self, "Rename", "Select a single file or folder to rename.")
            return
        entry = sel[0]
        old_name = str(entry["name"])
        new_name, ok = QInputDialog.getText(self, "Rename", "New name:", text=old_name)
        clean = new_name.strip().strip("/")
        if not ok or not clean or clean == old_name:
            return
        src_spec = self._spec_join(old_name)
        dst_spec = self._spec_join(clean)
        is_dir = bool(entry.get("is_dir", False))
        self.status_lbl.setText(f"Renaming {old_name} -> {clean} ...")
        self.tasks.run(
            lambda: self.client.rename_item(src_spec, dst_spec, is_dir=is_dir),
            on_success=lambda _: self.refresh(),
            on_error=lambda err: show_error(self, "Rename Failed", err),
        )

    def delete_selected(self) -> None:
        sel = self.selected_entries()
        if not sel:
            return
        names = ", ".join(e["name"] for e in sel[:5])
        if len(sel) > 5:
            names += f" (+{len(sel) - 5} more)"
        reply = QMessageBox.question(
            self,
            "Confirm Delete",
            f"Permanently delete {len(sel)} item(s) from {self._current_spec}?\n\n{names}",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if reply != QMessageBox.StandardButton.Yes:
            return
        specs = [(self._spec_join(e["name"]), bool(e.get("is_dir", False))) for e in sel]
        self.status_lbl.setText(f"Deleting {len(specs)} item(s)...")
        self.tasks.run(
            lambda: self.client.delete_items(specs),
            on_success=lambda _: self.refresh(),
            on_error=lambda err: show_error(self, "Delete Failed", err),
        )

    def _show_public_link(self, spec: str) -> None:
        def _done(url: str) -> None:
            if not url:
                QMessageBox.information(self, "Public Link", "Backend returned no public link.")
                return
            QInputDialog.getText(self, "Public Share Link", "URL (Ctrl+C to copy):", text=url)

        self.tasks.run(
            lambda: self.client.public_link(spec),
            on_success=_done,
            on_error=lambda err: show_error(self, "Public Link Failed", err),
        )

    def _prune_empty_dirs(self, spec: str) -> None:
        self.status_lbl.setText(f"Removing empty folders under {spec}...")
        self.tasks.run(
            lambda: self.client.rmdirs(spec, leave_root=True),
            on_success=lambda _: self.refresh(),
            on_error=lambda err: show_error(self, "Remove Empty Dirs Failed", err),
        )

    def _open_local(self, path: str) -> None:
        try:
            subprocess.Popen(["xdg-open", path], start_new_session=True)
        except OSError as exc:
            show_error(self, "Open Locally Failed", exc)

    def _show_context_menu(self, pos: Any) -> None:
        sel = self.selected_entries()
        menu = QMenu(self)
        target_entry = sel[0] if sel else None
        target_spec = self._spec_join(target_entry["name"]) if target_entry else self._current_spec
        is_dir = bool(target_entry.get("is_dir", True)) if target_entry else True

        if target_entry and not is_dir:
            menu.addAction("Preview File (rclone cat)", lambda: self.preview_requested.emit(target_entry["name"], target_spec))
        if self._current_spec.startswith("/"):
            menu.addAction("Open Locally (xdg-open)", lambda: self._open_local(target_spec))
        if target_entry:
            selected_payload = [
                {
                    "spec": self._spec_join(str(e["name"])),
                    "name": str(e["name"]),
                    "is_dir": bool(e.get("is_dir", False)),
                }
                for e in sel
            ]
            if len(selected_payload) > 1:
                menu.addAction(
                    f"Copy {len(selected_payload)} Selected -> Other Pane",
                    lambda: self.transfer_requested.emit("batch_copy", selected_payload),
                )
                menu.addAction(
                    f"Move {len(selected_payload)} Selected -> Other Pane",
                    lambda: self.transfer_requested.emit("batch_move", selected_payload),
                )
            else:
                single_op = "copy" if is_dir else "copyfile"
                move_op = "move" if is_dir else "movefile"
                menu.addAction("Copy -> Other Pane...", lambda: self.transfer_requested.emit(single_op, selected_payload))
                menu.addAction("Move -> Other Pane...", lambda: self.transfer_requested.emit(move_op, selected_payload))
                if is_dir:
                    menu.addAction("Sync Folder -> Other Pane...", lambda: self.transfer_requested.emit("sync", selected_payload))
                    menu.addAction("Compare / Check <-> Other Pane...", lambda: self.transfer_requested.emit("check", selected_payload))
            menu.addSeparator()
            menu.addAction("Rename...", self.rename_selected)
            menu.addAction("Delete Selected...", self.delete_selected)
            menu.addAction("Properties & Checksums...", lambda: self.properties_requested.emit(target_spec, is_dir, self.current_remote_name()))
            if not self._current_spec.startswith("/"):
                menu.addAction("Public Share Link...", lambda: self._show_public_link(target_spec))
        menu.addSeparator()
        menu.addAction("New Folder...", self.create_directory)
        if is_dir:
            menu.addAction("Prune Empty Subfolders (rmdirs)", lambda: self._prune_empty_dirs(target_spec))
        if not self._current_spec.startswith("/"):
            menu.addAction("Mount This Remote Here...", lambda: self.mount_requested.emit(self._current_spec))
        menu.addAction("Refresh", self.refresh)

        global_pos = self.tree.viewport().mapToGlobal(pos)
        menu.exec(global_pos)
