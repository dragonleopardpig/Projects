"""Unit and offscreen Qt tests for rclone-control."""

from __future__ import annotations

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest import mock

from PyQt6.QtWidgets import QApplication

from rclone_control.app import main as app_main
from rclone_control.dialogs import (
    OperationDialog,
    RemoteEditorDialog,
    build_cli_flags_from_preset,
    build_rc_params_from_preset,
)
from rclone_control.main_window import MainWindow
from rclone_control.rc_client import RcloneClient, format_bytes, join_fs_path, split_fs_path
from rclone_control.theme import build_qss


class _MockRCHandler(BaseHTTPRequestHandler):
    calls: list[tuple[str, dict]] = []

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8") if length else "{}"
        payload = json.loads(body or "{}")
        self.__class__.calls.append((self.path, payload))

        if self.path == "/config/listremotes":
            resp = {"remotes": ["gdrive", "scramble_private"]}
        elif self.path == "/config/dump":
            resp = {
                "gdrive": {"type": "drive"},
                "scramble_private": {"type": "crypt", "remote": "scramble_drive:Vault"},
            }
        elif self.path == "/config/providers":
            resp = {
                "providers": [
                    {
                        "Name": "s3",
                        "Description": "Amazon S3 Compliant Storage",
                        "Options": [
                            {"Name": "provider", "Type": "string", "Advanced": False, "Help": "S3 provider"},
                            {"Name": "secret_access_key", "Type": "string", "IsPassword": True, "Advanced": False, "Help": "Secret"},
                            {"Name": "acl", "Type": "string", "Advanced": True, "Help": "Canned ACL"},
                        ],
                    },
                    {"Name": "drive", "Description": "Google Drive", "Options": []},
                ]
            }
        elif self.path == "/operations/list":
            resp = {
                "list": [
                    {"Name": "Docs", "Path": "Docs", "Size": -1, "ModTime": "2026-11-20T10:00:00Z", "IsDir": True},
                    {"Name": "report.txt", "Path": "report.txt", "Size": 2048, "ModTime": "2026-11-20T11:00:00Z", "IsDir": False, "MimeType": "text/plain"},
                ]
            }
        elif self.path == "/operations/about":
            resp = {"used": 1024 * 1024 * 50, "total": 1024 * 1024 * 1024, "free": 1024 * 1024 * 974}
        elif self.path in ("/sync/copy", "/sync/move", "/sync/sync", "/sync/bisync", "/operations/check", "/operations/copyfile", "/operations/movefile"):
            resp = {"jobid": 42}
        elif self.path == "/core/stats":
            resp = {"speed": 0, "bytes": 0, "totalBytes": 0, "transfers": 1, "checks": 0, "errors": 0, "transferring": []}
        elif self.path == "/core/transferred":
            resp = {"transferred": []}
        elif self.path == "/job/status":
            resp = {"finished": True, "success": True, "error": "", "duration": 0.4}
        else:
            resp = {}

        raw = json.dumps(resp).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, _fmt: str, *_args: object) -> None:
        return


class RcloneControlTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
        cls.app = QApplication.instance() or QApplication([])

    def test_path_and_byte_helpers(self) -> None:
        self.assertEqual(format_bytes(0), "0 B")
        self.assertEqual(format_bytes(1536), "1.5 KiB")
        self.assertEqual(split_fs_path("gdrive:Work/Docs"), ("gdrive:", "Work/Docs"))
        self.assertEqual(split_fs_path("/tmp/foo"), ("/", "tmp/foo"))
        self.assertEqual(join_fs_path("gdrive:", "Work/Docs"), "gdrive:Work/Docs")
        self.assertEqual(join_fs_path("/", "tmp/foo"), "/tmp/foo")

    def test_theme_builds_dark_and_light_qss(self) -> None:
        mode_dark, pal_dark, qss_dark = build_qss("dark")
        mode_light, pal_light, qss_light = build_qss("light")
        self.assertEqual(mode_dark, "dark")
        self.assertEqual(mode_light, "light")
        self.assertIn(pal_dark["surface"], qss_dark)
        self.assertIn(pal_light["primary"], qss_light)

    def test_preset_cli_and_rc_mapping(self) -> None:
        preset = {
            "operation": "move",
            "src": "/tmp/a",
            "dst": "gdrive:b",
            "transfers": 6,
            "checkers": 12,
            "excludes": [".git/**", "*.tmp"],
            "includes": [],
            "update_older": True,
            "checksum": True,
            "ignore_existing": False,
            "size_only": False,
            "track_renames": True,
            "delete_empty_src_dirs": True,
            "resync": False,
        }
        flags = build_cli_flags_from_preset(preset)
        self.assertIn("--transfers=6", flags)
        self.assertIn("--update", flags)
        self.assertIn("--delete-empty-src-dirs", flags)
        extra_cfg, extra_params = build_rc_params_from_preset(preset)
        self.assertTrue(extra_cfg["UpdateOlder"])
        self.assertTrue(extra_cfg["CheckSum"])
        self.assertEqual(extra_params["_filter"]["ExcludeRule"], [".git/**", "*.tmp"])
        self.assertTrue(extra_params["deleteEmptySrcDirs"])

    def test_rc_client_real_loopback_list_remotes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            conf = Path(tmp) / "rclone.conf"
            conf.write_text("[demo_local]\ntype = alias\nremote = /tmp\n", encoding="utf-8")
            client = RcloneClient(config_path=conf, auto_start=True)
            try:
                self.assertEqual(client.list_remotes(), ["demo_local"])
                entries = client.list_entries(tmp)
                self.assertIsInstance(entries, list)
            finally:
                client.shutdown()

    def test_mock_rc_endpoints_and_ui_construction(self) -> None:
        _MockRCHandler.calls.clear()
        server = ThreadingHTTPServer(("127.0.0.1", 0), _MockRCHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                sample_file = Path(tmp) / "hello.txt"
                sample_file.write_text("hello", encoding="utf-8")
                conf = Path(tmp) / "rclone.conf"
                conf.write_text("[old_remote]\ntype = alias\nremote = /tmp\n", encoding="utf-8")

                client = RcloneClient(config_path=conf, auto_start=False)
                client._port = server.server_address[1]

                self.assertEqual(client.list_remotes(), ["gdrive", "scramble_private"])
                entries = client.list_entries("gdrive:")
                self.assertEqual([e["name"] for e in entries], ["Docs", "report.txt"])

                jid = client.start_transfer_job("sync", tmp, "gdrive:Backup")
                self.assertEqual(jid, 42)
                self.assertEqual(_MockRCHandler.calls[-1][0], "/sync/sync")

                client.rename_remote("old_remote", "new_remote")
                self.assertIn("[new_remote]", conf.read_text(encoding="utf-8"))

                win = MainWindow(client=client, auto_start_rc=False, left_spec=tmp, right_spec="gdrive:")
                win.left_pane.set_remotes(["gdrive", "scramble_private"])
                win.left_pane._entries = client.list_entries(tmp)
                win.left_pane._apply_filter()
                self.assertEqual(win.left_pane.tree.topLevelItemCount(), 2)
                self.assertEqual(win.tabs.count(), 5)

                op_dlg = OperationDialog(client, "copy", tmp, "gdrive:Dst", parent=win)
                op_dlg.excludes_edit.setText("*.bak")
                collected = op_dlg._collect_preset()
                self.assertEqual(collected["excludes"], ["*.bak"])
                op_dlg.close()

                providers = client.config_providers()
                ed_dlg = RemoteEditorDialog(
                    client, providers, existing_name="mys3", existing_cfg={"type": "s3", "provider": "AWS", "acl": "private"}, parent=win
                )
                params = ed_dlg._collect_params()
                self.assertEqual(params, {})  # Unchanged obscured secret / fields are not overwritten
                ed_dlg.close()
                win.shutdown()
        finally:
            server.shutdown()
            server.server_close()

    def test_app_smoke_test_flag(self) -> None:
        with mock.patch("builtins.print"):
            rc = app_main(["--tab", "mounts", "--smoke-test"])
        self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
