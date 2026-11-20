"""Dialogs for transfer operations, dry-run preview, remote config, mounts, properties, and file preview."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any
from PyQt6.QtCore import Qt, pyqtSignal
from PyQt6.QtGui import QFont
from PyQt6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFileDialog,
    QFormLayout,
    QGroupBox,
    QHBoxLayout,
    QInputDialog,
    QLabel,
    QLineEdit,
    QMessageBox,
    QPlainTextEdit,
    QScrollArea,
    QSpinBox,
    QTabWidget,
    QVBoxLayout,
    QWidget,
)

from .qt_helpers import TaskManager, make_button, show_error
from .rc_client import RcloneClient, format_bytes

POPULAR_BACKENDS = (
    "drive", "webdav", "crypt", "protondrive", "mega", "s3",
    "sftp", "smb", "onedrive", "dropbox", "b2", "local", "alias", "union",
)


def build_cli_flags_from_preset(preset: dict[str, Any]) -> list[str]:
    flags = [
        f"--transfers={int(preset.get('transfers', 4))}",
        f"--checkers={int(preset.get('checkers', 8))}",
    ]
    for pat in preset.get("excludes", []):
        if pat:
            flags.extend(["--exclude", str(pat)])
    for pat in preset.get("includes", []):
        if pat:
            flags.extend(["--include", str(pat)])
    if preset.get("update_older"):
        flags.append("--update")
    if preset.get("checksum"):
        flags.append("--checksum")
    if preset.get("ignore_existing"):
        flags.append("--ignore-existing")
    if preset.get("size_only"):
        flags.append("--size-only")
    if preset.get("track_renames"):
        flags.append("--track-renames")
    if preset.get("operation") == "move" and preset.get("delete_empty_src_dirs"):
        flags.append("--delete-empty-src-dirs")
    if preset.get("operation") == "bisync" and preset.get("resync"):
        flags.append("--resync")
    return flags


def build_rc_params_from_preset(preset: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    extra_config: dict[str, Any] = {
        "Checkers": int(preset.get("checkers", 8)),
        "UpdateOlder": bool(preset.get("update_older", False)),
        "CheckSum": bool(preset.get("checksum", False)),
        "IgnoreExisting": bool(preset.get("ignore_existing", False)),
        "SizeOnly": bool(preset.get("size_only", False)),
        "TrackRenames": bool(preset.get("track_renames", False)),
    }
    extra_params: dict[str, Any] = {}
    excludes = [str(p) for p in preset.get("excludes", []) if p]
    includes = [str(p) for p in preset.get("includes", []) if p]
    if excludes or includes:
        filt: dict[str, Any] = {}
        if excludes:
            filt["ExcludeRule"] = excludes
        if includes:
            filt["IncludeRule"] = includes
        extra_params["_filter"] = filt
    if preset.get("operation") == "move" and preset.get("delete_empty_src_dirs"):
        extra_params["deleteEmptySrcDirs"] = True
    if preset.get("operation") == "bisync" and preset.get("resync"):
        extra_params["resync"] = True
    return extra_config, extra_params


class OperationDialog(QDialog):
    """Configure copy/move/sync/bisync/check with live CLI dry-run diff preview and RC execution."""

    preset_saved = pyqtSignal(dict)
    job_started = pyqtSignal(dict)

    def __init__(
        self,
        client: RcloneClient,
        operation: str = "copy",
        src_spec: str = "",
        dst_spec: str = "",
        preset: dict[str, Any] | None = None,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self.client = client
        self.tasks = TaskManager(self)
        self._did_dry_run = False

        data = dict(preset or {})
        op = data.get("operation", operation)
        src = data.get("src", src_spec)
        dst = data.get("dst", dst_spec)

        self.setWindowTitle("Rclone Transfer & Sync Operation")
        self.resize(780, 660)

        root = QVBoxLayout(self)
        root.setSpacing(10)

        form_box = QGroupBox("Paths & Mode")
        form = QFormLayout(form_box)
        form.setSpacing(8)

        self.op_combo = QComboBox()
        for choice in ("copy", "move", "sync", "bisync", "check", "copyfile", "movefile"):
            self.op_combo.addItem(choice, choice)
        idx = self.op_combo.findData(op)
        if idx >= 0:
            self.op_combo.setCurrentIndex(idx)
        self.op_combo.currentTextChanged.connect(self._update_mode_controls)
        form.addRow("Operation:", self.op_combo)

        src_row = QHBoxLayout()
        self.src_edit = QLineEdit(src)
        self.src_edit.setPlaceholderText("/local/path or remote:sub/path")
        src_row.addWidget(self.src_edit, 1)
        src_row.addWidget(make_button("Browse...", clicked=lambda: self._pick_local(self.src_edit)))
        src_row.addWidget(make_button("Swap <->", clicked=self._swap_paths))
        form.addRow("Source:", src_row)

        dst_row = QHBoxLayout()
        self.dst_edit = QLineEdit(dst)
        self.dst_edit.setPlaceholderText("/local/path or remote:sub/path")
        dst_row.addWidget(self.dst_edit, 1)
        dst_row.addWidget(make_button("Browse...", clicked=lambda: self._pick_local(self.dst_edit)))
        form.addRow("Destination:", dst_row)

        num_row = QHBoxLayout()
        self.transfers_spin = QSpinBox()
        self.transfers_spin.setRange(1, 32)
        self.transfers_spin.setValue(int(data.get("transfers", 4)))
        self.checkers_spin = QSpinBox()
        self.checkers_spin.setRange(1, 32)
        self.checkers_spin.setValue(int(data.get("checkers", 8)))
        num_row.addWidget(QLabel("Transfers:"))
        num_row.addWidget(self.transfers_spin)
        num_row.addSpacing(12)
        num_row.addWidget(QLabel("Checkers:"))
        num_row.addWidget(self.checkers_spin)
        num_row.addStretch(1)
        form.addRow("Parallelism:", num_row)

        self.excludes_edit = QLineEdit(", ".join(data.get("excludes", [])))
        self.excludes_edit.setPlaceholderText("Comma-separated exclude globs, e.g. .git/**, *.tmp")
        form.addRow("Excludes:", self.excludes_edit)

        self.includes_edit = QLineEdit(", ".join(data.get("includes", [])))
        self.includes_edit.setPlaceholderText("Optional comma-separated include globs")
        form.addRow("Includes:", self.includes_edit)

        flags_row1 = QHBoxLayout()
        self.chk_update = QCheckBox("Update (--update)")
        self.chk_update.setChecked(bool(data.get("update_older", False)))
        self.chk_checksum = QCheckBox("Checksum (--checksum)")
        self.chk_checksum.setChecked(bool(data.get("checksum", False)))
        self.chk_ignore_existing = QCheckBox("Ignore Existing")
        self.chk_ignore_existing.setChecked(bool(data.get("ignore_existing", False)))
        for cb in (self.chk_update, self.chk_checksum, self.chk_ignore_existing):
            flags_row1.addWidget(cb)
        flags_row1.addStretch(1)
        form.addRow("Flags:", flags_row1)

        flags_row2 = QHBoxLayout()
        self.chk_size_only = QCheckBox("Size Only")
        self.chk_size_only.setChecked(bool(data.get("size_only", False)))
        self.chk_track_renames = QCheckBox("Track Renames")
        self.chk_track_renames.setChecked(bool(data.get("track_renames", False)))
        self.chk_del_empty = QCheckBox("Delete Empty Src Dirs (move)")
        self.chk_del_empty.setChecked(bool(data.get("delete_empty_src_dirs", True)))
        self.chk_resync = QCheckBox("Bisync --resync")
        self.chk_resync.setChecked(bool(data.get("resync", False)))
        for cb in (self.chk_size_only, self.chk_track_renames, self.chk_del_empty, self.chk_resync):
            flags_row2.addWidget(cb)
        flags_row2.addStretch(1)
        form.addRow("Advanced:", flags_row2)

        root.addWidget(form_box)

        # Dry-Run Preview section
        preview_box = QGroupBox("Dry-Run Diff / Check Output")
        pv_layout = QVBoxLayout(preview_box)
        pv_bar = QHBoxLayout()
        self.dry_run_btn = make_button("Run Dry-Run Preview", clicked=self._run_dry_preview)
        self.pv_status_lbl = QLabel("Preview simulates exact changes without modifying destination.")
        pv_bar.addWidget(self.dry_run_btn)
        pv_bar.addWidget(self.pv_status_lbl, 1)
        pv_layout.addLayout(pv_bar)

        self.preview_text = QPlainTextEdit()
        self.preview_text.setReadOnly(True)
        self.preview_text.setFont(QFont("JetBrainsMono Nerd Font", 11))
        self.preview_text.setMinimumHeight(180)
        pv_layout.addWidget(self.preview_text, 1)
        root.addWidget(preview_box, 1)

        btn_row = QHBoxLayout()
        btn_row.addWidget(make_button("Save as Preset...", clicked=self._save_preset))
        btn_row.addStretch(1)
        btn_row.addWidget(make_button("Cancel", clicked=self.reject))
        self.exec_btn = make_button("Execute Operation", object_name="PrimaryButton", clicked=self._execute)
        btn_row.addWidget(self.exec_btn)
        root.addLayout(btn_row)

        self._update_mode_controls(self.op_combo.currentText())

    def _update_mode_controls(self, op: str) -> None:
        self.chk_del_empty.setEnabled(op == "move")
        self.chk_resync.setEnabled(op == "bisync")
        self.dry_run_btn.setEnabled(op not in ("copyfile", "movefile"))

    def _pick_local(self, target: QLineEdit) -> None:
        start = target.text().strip()
        if not start.startswith("/") or not os.path.exists(start):
            start = str(Path.home())
        chosen = QFileDialog.getExistingDirectory(self, "Select Local Folder", start)
        if chosen:
            target.setText(chosen)

    def _swap_paths(self) -> None:
        a, b = self.src_edit.text(), self.dst_edit.text()
        self.src_edit.setText(b)
        self.dst_edit.setText(a)

    def _collect_preset(self) -> dict[str, Any]:
        def _split_csv(text: str) -> list[str]:
            return [part.strip() for part in text.split(",") if part.strip()]

        return {
            "operation": self.op_combo.currentData(),
            "src": self.src_edit.text().strip(),
            "dst": self.dst_edit.text().strip(),
            "transfers": self.transfers_spin.value(),
            "checkers": self.checkers_spin.value(),
            "excludes": _split_csv(self.excludes_edit.text()),
            "includes": _split_csv(self.includes_edit.text()),
            "update_older": self.chk_update.isChecked(),
            "checksum": self.chk_checksum.isChecked(),
            "ignore_existing": self.chk_ignore_existing.isChecked(),
            "size_only": self.chk_size_only.isChecked(),
            "track_renames": self.chk_track_renames.isChecked(),
            "delete_empty_src_dirs": self.chk_del_empty.isChecked(),
            "resync": self.chk_resync.isChecked(),
        }

    def _validate(self, preset: dict[str, Any]) -> bool:
        if not preset["src"] or not preset["dst"]:
            QMessageBox.warning(self, "Missing Paths", "Both Source and Destination paths are required.")
            return False
        if preset["src"] == preset["dst"]:
            QMessageBox.warning(self, "Invalid Paths", "Source and Destination must differ.")
            return False
        return True

    def _run_dry_preview(self) -> None:
        preset = self._collect_preset()
        if not self._validate(preset):
            return
        self.dry_run_btn.setEnabled(False)
        self.pv_status_lbl.setText(f"Running rclone {preset['operation']} --dry-run ...")
        self.preview_text.setPlainText("")
        flags = build_cli_flags_from_preset(preset)

        def _work() -> tuple[int, str]:
            return self.client.dry_run_preview(preset["operation"], preset["src"], preset["dst"], extra_flags=flags)

        def _done(result: tuple[int, str]) -> None:
            rc, out = result
            self._did_dry_run = True
            self.dry_run_btn.setEnabled(True)
            self.pv_status_lbl.setText(f"Dry-run exited with code {rc}")
            self.preview_text.setPlainText(out or "(No differences or files to transfer)")

        def _err(msg: str) -> None:
            self.dry_run_btn.setEnabled(True)
            self.pv_status_lbl.setText("Dry-run failed")
            self.preview_text.setPlainText(msg)

        self.tasks.run(_work, on_success=_done, on_error=_err)

    def _save_preset(self) -> None:
        preset = self._collect_preset()
        if not self._validate(preset):
            return
        default_name = f"{preset['operation']}: {preset['src']} -> {preset['dst']}"
        name, ok = QInputDialog.getText(self, "Save Job Preset", "Preset Name:", text=default_name)
        if ok and name.strip():
            preset["name"] = name.strip()
            self.preset_saved.emit(preset)
            QMessageBox.information(self, "Saved", f"Preset '{preset['name']}' saved.")

    def _execute(self) -> None:
        preset = self._collect_preset()
        if not self._validate(preset):
            return
        op = preset["operation"]
        if op in ("sync", "move", "bisync") and not self._did_dry_run:
            reply = QMessageBox.question(
                self,
                f"Confirm {op}",
                f"Execute {op.upper()} from:\n  {preset['src']}\nto:\n  {preset['dst']}\n\n"
                "(Tip: you can cancel and click 'Run Dry-Run Preview' first to inspect changes.)",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                QMessageBox.StandardButton.No,
            )
            if reply != QMessageBox.StandardButton.Yes:
                return

        self.exec_btn.setEnabled(False)
        extra_config, extra_params = build_rc_params_from_preset(preset)

        def _start() -> int:
            return self.client.start_transfer_job(
                op,
                preset["src"],
                preset["dst"],
                dry_run=False,
                transfers=int(preset["transfers"]),
                extra_config=extra_config,
                extra_params=extra_params,
            )

        def _done(jobid: int) -> None:
            self.job_started.emit({
                "jobid": jobid,
                "operation": op,
                "src": preset["src"],
                "dst": preset["dst"],
                "dry_run": False,
            })
            self.accept()

        def _err(msg: str) -> None:
            self.exec_btn.setEnabled(True)
            show_error(self, "Start Job Failed", msg)

        self.tasks.run(_start, on_success=_done, on_error=_err)


class RemoteEditorDialog(QDialog):
    """Create or edit an rclone remote using config/providers schema."""

    def __init__(
        self,
        client: RcloneClient,
        providers: list[dict[str, Any]],
        existing_name: str | None = None,
        existing_cfg: dict[str, Any] | None = None,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self.client = client
        self.tasks = TaskManager(self)
        self.existing_name = existing_name
        self.existing_cfg = dict(existing_cfg or {})
        self.providers_by_name = {str(p.get("Name", "")): p for p in providers if p.get("Name")}
        self._field_widgets: dict[str, dict[str, Any]] = {}

        is_edit = existing_name is not None
        self.setWindowTitle(f"Edit Remote '{existing_name}'" if is_edit else "Create New Rclone Remote")
        self.resize(720, 620)

        root = QVBoxLayout(self)
        root.setSpacing(10)

        top_form = QFormLayout()
        self.name_edit = QLineEdit(existing_name or "")
        self.name_edit.setEnabled(not is_edit)
        self.name_edit.setPlaceholderText("e.g. my_s3 or work_drive")
        top_form.addRow("Remote Name:", self.name_edit)

        self.provider_combo = QComboBox()
        ordered = list(POPULAR_BACKENDS) + sorted(set(self.providers_by_name) - set(POPULAR_BACKENDS))
        for pname in ordered:
            p = self.providers_by_name.get(pname)
            if p:
                desc = str(p.get("Description", pname))
                self.provider_combo.addItem(f"{pname} — {desc}", pname)
        if is_edit:
            rtype = str(self.existing_cfg.get("type", ""))
            idx = self.provider_combo.findData(rtype)
            if idx >= 0:
                self.provider_combo.setCurrentIndex(idx)
            self.provider_combo.setEnabled(False)
        self.provider_combo.currentIndexChanged.connect(self._rebuild_option_fields)
        top_form.addRow("Backend Provider:", self.provider_combo)
        root.addLayout(top_form)

        self.tabs = QTabWidget()
        self.basic_container, self.basic_form = self._make_scroll_form()
        self.adv_container, self.adv_form = self._make_scroll_form()
        self.tabs.addTab(self.basic_container, "Basic Options")
        self.tabs.addTab(self.adv_container, "Advanced Options")

        raw_tab = QWidget()
        raw_layout = QVBoxLayout(raw_tab)
        raw_layout.addWidget(QLabel("Extra parameters (one key=value per line; overrides form fields):"))
        self.raw_edit = QPlainTextEdit()
        self.raw_edit.setPlaceholderText("e.g.\npacer_min_sleep = 10ms")
        raw_layout.addWidget(self.raw_edit, 1)
        self.obscure_chk = QCheckBox("Automatically obscure passwords via rclone RC when saving")
        self.obscure_chk.setChecked(True)
        raw_layout.addWidget(self.obscure_chk)
        self.tabs.addTab(raw_tab, "Raw / Security")
        root.addWidget(self.tabs, 1)

        btn_row = QHBoxLayout()
        btn_row.addWidget(make_button("Terminal Wizard (OAuth / 2FA)...", clicked=self._launch_wizard))
        btn_row.addStretch(1)
        btn_row.addWidget(make_button("Cancel", clicked=self.reject))
        self.save_btn = make_button("Save Remote", object_name="PrimaryButton", clicked=self._save_remote)
        btn_row.addWidget(self.save_btn)
        root.addLayout(btn_row)

        self._rebuild_option_fields()

    @staticmethod
    def _make_scroll_form() -> tuple[QScrollArea, QFormLayout]:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        inner = QWidget()
        form = QFormLayout(inner)
        form.setSpacing(8)
        scroll.setWidget(inner)
        return scroll, form

    @staticmethod
    def _clear_form(form: QFormLayout) -> None:
        while form.rowCount() > 0:
            form.removeRow(0)

    def _rebuild_option_fields(self) -> None:
        self._field_widgets.clear()
        self._clear_form(self.basic_form)
        self._clear_form(self.adv_form)
        ptype = str(self.provider_combo.currentData() or "")
        provider = self.providers_by_name.get(ptype, {})
        seen_names: set[str] = set()

        for opt in provider.get("Options", []):
            name = str(opt.get("Name", ""))
            if not name or name in seen_names:
                continue
            seen_names.add(name)
            help_text = str(opt.get("Help", "")).splitlines()[0] if opt.get("Help") else ""
            is_adv = bool(opt.get("Advanced", False))
            is_pwd = bool(opt.get("IsPassword", False))
            opt_type = str(opt.get("Type", "string"))
            default_val = opt.get("DefaultStr") or opt.get("Default") or ""
            existing_val = self.existing_cfg.get(name)

            target_form = self.adv_form if is_adv else self.basic_form

            if opt_type == "bool":
                widget = QCheckBox(help_text[:80] if help_text else name)
                checked = (
                    str(existing_val).lower() == "true"
                    if existing_val is not None
                    else str(default_val).lower() == "true"
                )
                widget.setChecked(checked)
                widget.setToolTip(str(opt.get("Help", "")))
                target_form.addRow(f"{name}:", widget)
                self._field_widgets[name] = {
                    "kind": "bool", "widget": widget, "initial": checked, "is_pwd": False,
                }
            else:
                line = QLineEdit()
                line.setToolTip(str(opt.get("Help", "")))
                if is_pwd:
                    line.setEchoMode(QLineEdit.EchoMode.Password)
                    if existing_val:
                        line.setPlaceholderText("<unchanged obscured secret — leave blank to keep>")
                    else:
                        line.setPlaceholderText(help_text or "Enter secret...")
                    holder = QWidget()
                    hl = QHBoxLayout(holder)
                    hl.setContentsMargins(0, 0, 0, 0)
                    hl.addWidget(line, 1)
                    show_btn = QCheckBox("Show")
                    show_btn.toggled.connect(
                        lambda on, le=line: le.setEchoMode(QLineEdit.EchoMode.Normal if on else QLineEdit.EchoMode.Password)
                    )
                    hl.addWidget(show_btn)
                    target_form.addRow(f"{name}:", holder)
                    self._field_widgets[name] = {
                        "kind": "text", "widget": line, "initial": "", "is_pwd": True,
                    }
                else:
                    init_str = str(existing_val) if existing_val is not None else ""
                    line.setText(init_str)
                    placeholder = help_text or (f"Default: {default_val}" if default_val else "")
                    line.setPlaceholderText(placeholder[:90])
                    examples = opt.get("Examples") or []
                    if examples and not init_str:
                        ex_vals = [str(e.get("Value", "")) for e in examples if e.get("Value")]
                        if ex_vals:
                            line.setPlaceholderText(f"Examples: {', '.join(ex_vals[:3])}")
                    target_form.addRow(f"{name}:", line)
                    self._field_widgets[name] = {
                        "kind": "text", "widget": line, "initial": init_str, "is_pwd": False,
                    }

    def _collect_params(self) -> dict[str, Any]:
        params: dict[str, Any] = {}
        is_edit = self.existing_name is not None
        for name, meta in self._field_widgets.items():
            kind = meta["kind"]
            widget = meta["widget"]
            if kind == "bool":
                val = bool(widget.isChecked())
                if is_edit and val == meta["initial"]:
                    continue
                if val or name in self.existing_cfg:
                    params[name] = "true" if val else "false"
            else:
                text = widget.text().strip()
                if meta["is_pwd"]:
                    if text:
                        params[name] = text
                else:
                    if is_edit and text == meta["initial"]:
                        continue
                    if text or (is_edit and name in self.existing_cfg):
                        params[name] = text

        for line in self.raw_edit.toPlainText().splitlines():
            clean = line.strip()
            if not clean or clean.startswith("#") or "=" not in clean:
                continue
            k, v = clean.split("=", 1)
            params[k.strip()] = v.strip()
        return params

    def _save_remote(self) -> None:
        name = self.name_edit.text().strip()
        if not name or any(ch in name for ch in (":", "/", " ")):
            QMessageBox.warning(self, "Invalid Name", "Remote name must be non-empty without ':', '/' or spaces.")
            return
        rtype = str(self.provider_combo.currentData() or "")
        params = self._collect_params()
        obscure = self.obscure_chk.isChecked()
        self.save_btn.setEnabled(False)

        def _work() -> None:
            if self.existing_name:
                self.client.config_update(self.existing_name, params, obscure=obscure)
            else:
                self.client.config_create(name, rtype, params, obscure=obscure)

        def _done(_: Any) -> None:
            self.accept()

        def _err(msg: str) -> None:
            self.save_btn.setEnabled(True)
            show_error(self, "Save Remote Failed", msg)

        self.tasks.run(_work, on_success=_done, on_error=_err)

    def _launch_wizard(self) -> None:
        name = self.name_edit.text().strip()
        try:
            if self.existing_name:
                self.client.launch_interactive_config(["config", "reconnect", f"{self.existing_name}:"])
            elif name:
                self.client.launch_interactive_config(["config"])
            else:
                self.client.launch_interactive_config(["config"])
            QMessageBox.information(
                self,
                "Terminal Opened",
                "Interactive rclone configuration opened in a terminal window. Refresh Remotes when finished.",
            )
        except Exception as exc:  # noqa: BLE001
            show_error(self, "Terminal Launch Failed", exc)


class MountDialog(QDialog):
    """Configure and spawn a detached rclone FUSE mount."""

    def __init__(
        self,
        client: RcloneClient,
        remotes: list[str],
        initial_source: str = "",
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self.client = client
        self.tasks = TaskManager(self)
        self.setWindowTitle("New Detached Rclone FUSE Mount")
        self.resize(560, 320)

        layout = QVBoxLayout(self)
        form = QFormLayout()
        form.setSpacing(8)

        self.src_combo = QComboBox()
        self.src_combo.setEditable(True)
        for r in remotes:
            self.src_combo.addItem(f"{r}:")
        if initial_source:
            self.src_combo.setEditText(initial_source)
        form.addRow("Remote / Subpath:", self.src_combo)

        mp_row = QHBoxLayout()
        default_mp = str(Path.home() / "Mounts" / (initial_source.rstrip(":").split(":")[0] or "remote"))
        self.mp_edit = QLineEdit(default_mp)
        mp_row.addWidget(self.mp_edit, 1)
        mp_row.addWidget(make_button("Browse...", clicked=self._pick_mp))
        form.addRow("Mountpoint:", mp_row)

        self.cache_combo = QComboBox()
        for m in ("full", "writes", "minimal", "off"):
            self.cache_combo.addItem(m)
        form.addRow("VFS Cache Mode:", self.cache_combo)

        self.cache_size_edit = QLineEdit("10G")
        form.addRow("VFS Cache Max Size:", self.cache_size_edit)

        self.dir_cache_edit = QLineEdit("1m")
        form.addRow("Dir Cache Time:", self.dir_cache_edit)

        self.ro_chk = QCheckBox("Read-only (--read-only)")
        form.addRow("Permissions:", self.ro_chk)

        self.extra_edit = QLineEdit()
        self.extra_edit.setPlaceholderText("Optional extra flags, e.g. --allow-other")
        form.addRow("Extra Flags:", self.extra_edit)

        layout.addLayout(form)

        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        buttons.button(QDialogButtonBox.StandardButton.Ok).setText("Mount")
        buttons.button(QDialogButtonBox.StandardButton.Ok).setObjectName("PrimaryButton")
        buttons.accepted.connect(self._mount_now)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _pick_mp(self) -> None:
        chosen = QFileDialog.getExistingDirectory(self, "Choose Mount Directory", str(Path.home()))
        if chosen:
            self.mp_edit.setText(chosen)

    def _mount_now(self) -> None:
        src = self.src_combo.currentText().strip()
        mp = self.mp_edit.text().strip()
        if not src or not mp:
            QMessageBox.warning(self, "Missing Input", "Remote spec and Mountpoint are required.")
            return
        extra = [tok for tok in self.extra_edit.text().split() if tok]
        try:
            self.client.start_detached_mount(
                src,
                mp,
                vfs_cache_mode=self.cache_combo.currentText(),
                read_only=self.ro_chk.isChecked(),
                cache_max_size=self.cache_size_edit.text().strip() or "10G",
                dir_cache_time=self.dir_cache_edit.text().strip() or "1m",
                extra_args=extra,
            )
            self.accept()
        except Exception as exc:  # noqa: BLE001
            show_error(self, "Mount Failed", exc)


class PropertiesDialog(QDialog):
    """Inspect stat metadata, folder size, file checksums, and crypt filename decoding."""

    def __init__(
        self,
        client: RcloneClient,
        spec: str,
        is_dir: bool,
        remote_name: str = "",
        remotes: list[str] | None = None,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self.client = client
        self.tasks = TaskManager(self)
        self.spec = spec
        self.is_dir = is_dir

        self.setWindowTitle(f"Properties — {spec}")
        self.resize(620, 480)

        layout = QVBoxLayout(self)
        self.info_view = QPlainTextEdit()
        self.info_view.setReadOnly(True)
        self.info_view.setFont(QFont("JetBrainsMono Nerd Font", 11))
        self.info_view.setPlainText(f"Inspecting {spec} ...")
        layout.addWidget(self.info_view, 1)

        if not is_dir:
            hash_row = QHBoxLayout()
            for algo in ("md5", "sha1", "sha256"):
                hash_row.addWidget(make_button(f"Compute {algo.upper()}", clicked=lambda _=False, a=algo: self._compute_hash(a)))
            hash_row.addStretch(1)
            layout.addLayout(hash_row)

        crypt_box = QGroupBox("Crypt Decode Tool")
        cl = QHBoxLayout(crypt_box)
        self.crypt_remote = QComboBox()
        for r in remotes or ([remote_name] if remote_name else []):
            self.crypt_remote.addItem(r)
        if remote_name:
            self.crypt_remote.setCurrentText(remote_name)
        self.crypt_input = QLineEdit()
        self.crypt_input.setPlaceholderText("Encrypted filename/segment...")
        cl.addWidget(self.crypt_remote)
        cl.addWidget(self.crypt_input, 1)
        cl.addWidget(make_button("Decode", clicked=self._decode_crypt))
        layout.addWidget(crypt_box)

        close_row = QHBoxLayout()
        close_row.addStretch(1)
        close_row.addWidget(make_button("Close", object_name="PrimaryButton", clicked=self.accept))
        layout.addLayout(close_row)

        self._load_info()

    def _load_info(self) -> None:
        def _work() -> str:
            lines = [f"Path: {self.spec}", f"Kind: {'Directory' if self.is_dir else 'File'}"]
            try:
                st = self.client.stat_item(self.spec)
                item = st.get("item") or {}
                for key in ("Name", "Path", "Size", "ModTime", "MimeType", "ID", "Tier"):
                    if key in item and item[key] is not None:
                        val = item[key]
                        if key == "Size" and isinstance(val, int) and val >= 0:
                            val = f"{val} B ({format_bytes(val)})"
                        lines.append(f"{key}: {val}")
            except Exception as exc:  # noqa: BLE001
                lines.append(f"stat error: {exc}")

            if self.is_dir:
                try:
                    sz = self.client.dir_size(self.spec)
                    lines.append(f"Total Objects: {sz.get('count', '—')}")
                    lines.append(f"Total Bytes: {sz.get('bytes', '—')} ({format_bytes(sz.get('bytes'))})")
                except Exception as exc:  # noqa: BLE001
                    lines.append(f"size error: {exc}")
            return "\n".join(lines)

        self.tasks.run(_work, on_success=self.info_view.setPlainText, on_error=self.info_view.setPlainText)

    def _compute_hash(self, algo: str) -> None:
        self.info_view.appendPlainText(f"\nComputing {algo.upper()}...")

        def _work() -> str:
            res = self.client.hashsum_file(self.spec, hash_type=algo)
            return f"{res.get('hashType', algo)}: {res.get('hash', '(unsupported or empty)')}"

        self.tasks.run(
            _work,
            on_success=lambda line: self.info_view.appendPlainText(line),
            on_error=lambda msg: self.info_view.appendPlainText(f"Hash error: {msg}"),
        )

    def _decode_crypt(self) -> None:
        rname = self.crypt_remote.currentText().strip()
        sample = self.crypt_input.text().strip()
        if not rname or not sample:
            return
        self.tasks.run(
            lambda: self.client.cryptdecode(rname, [sample]),
            on_success=lambda out: self.info_view.appendPlainText(f"\ncryptdecode ({rname}):\n{out.strip()}"),
            on_error=lambda err: self.info_view.appendPlainText(f"\ncryptdecode error: {err}"),
        )


class PreviewDialog(QDialog):
    """Read-only head preview for remote or local text files."""

    def __init__(self, client: RcloneClient, title: str, spec: str, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.client = client
        self.tasks = TaskManager(self)
        self.spec = spec
        self.setWindowTitle(f"Preview — {title}")
        self.resize(740, 520)

        layout = QVBoxLayout(self)
        layout.addWidget(QLabel(f"{spec} (first 128 KiB):"))
        self.text = QPlainTextEdit()
        self.text.setReadOnly(True)
        self.text.setFont(QFont("JetBrainsMono Nerd Font", 11))
        self.text.setPlainText("Loading preview...")
        layout.addWidget(self.text, 1)

        row = QHBoxLayout()
        row.addStretch(1)
        row.addWidget(make_button("Close", object_name="PrimaryButton", clicked=self.accept))
        layout.addLayout(row)

        def _fetch() -> str:
            if spec.startswith("/"):
                raw = Path(spec).read_bytes()[:131072]
                if b"\x00" in raw:
                    return "[Binary file — preview suppressed]"
                return raw.decode("utf-8", errors="replace")
            return self.client.cat_preview(spec, max_bytes=131072)

        self.tasks.run(_fetch, on_success=self.text.setPlainText, on_error=lambda e: self.text.setPlainText(f"Preview failed: {e}"))
