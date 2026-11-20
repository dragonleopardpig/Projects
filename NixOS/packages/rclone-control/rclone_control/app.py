"""CLI entrypoint for rclone-control."""

from __future__ import annotations

import argparse
from pathlib import Path
import signal
import sys
from PyQt6.QtWidgets import QApplication

from .main_window import MainWindow
from .rc_client import RcloneClient


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="rclone-control", description="Full-control OLO-Neon GUI for rclone")
    parser.add_argument("--config", type=Path, help="Override path to rclone.conf")
    parser.add_argument("--left", help="Initial spec for left explorer pane")
    parser.add_argument("--right", help="Initial spec for right explorer pane")
    parser.add_argument("--smoke-test", action="store_true", help="Initialize MainWindow, print diagnostics, and exit cleanly")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    signal.signal(signal.SIGINT, signal.SIG_DFL)

    app = QApplication.instance() or QApplication([sys.argv[0]])
    app.setApplicationName("rclone-control")
    app.setDesktopFileName("rclone-control")

    client = RcloneClient(config_path=args.config, auto_start=not args.smoke_test)
    window = MainWindow(
        client=client,
        auto_start_rc=not args.smoke_test,
        left_spec=args.left,
        right_spec=args.right,
    )
    app.aboutToQuit.connect(window.shutdown)

    if args.smoke_test:
        print(f"platform={app.platformName()} tabs={window.tabs.count()} title={window.windowTitle()}")
        window.shutdown()
        return 0

    window.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
