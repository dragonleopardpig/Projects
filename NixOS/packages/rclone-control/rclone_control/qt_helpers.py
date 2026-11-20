"""Shared PyQt6 threading and formatting helpers for rclone-control."""

from __future__ import annotations

from typing import Any, Callable
from PyQt6.QtCore import QObject, QThread, Qt, pyqtSignal
from PyQt6.QtWidgets import QMessageBox, QPushButton, QWidget


class _Worker(QThread):
    """Runs a callable off the GUI thread and emits result or error text."""

    succeeded = pyqtSignal(object)
    failed = pyqtSignal(str)

    def __init__(self, fn: Callable[[], Any], parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._fn = fn

    def run(self) -> None:
        try:
            res = self._fn()
        except Exception as exc:  # noqa: BLE001
            self.failed.emit(str(exc))
        else:
            self.succeeded.emit(res)


class TaskManager(QObject):
    """Tracks background QThreads owned by a parent QObject to avoid GC crashes."""

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._threads: set[_Worker] = set()

    def run(
        self,
        fn: Callable[[], Any],
        on_success: Callable[[Any], None] | None = None,
        on_error: Callable[[str], None] | None = None,
    ) -> _Worker:
        worker = _Worker(fn, self)
        self._threads.add(worker)

        def _cleanup() -> None:
            self._threads.discard(worker)
            worker.deleteLater()

        if on_success is not None:
            worker.succeeded.connect(on_success, Qt.ConnectionType.QueuedConnection)
        if on_error is not None:
            worker.failed.connect(on_error, Qt.ConnectionType.QueuedConnection)
        worker.finished.connect(_cleanup, Qt.ConnectionType.QueuedConnection)
        worker.start()
        return worker

    def cancel_all(self) -> None:
        for worker in list(self._threads):
            if worker.isRunning():
                worker.wait(1500)


def make_button(
    text: str,
    *,
    object_name: str | None = None,
    tooltip: str | None = None,
    clicked: Callable[[], Any] | None = None,
    parent: QWidget | None = None,
) -> QPushButton:
    btn = QPushButton(text, parent)
    if object_name:
        btn.setObjectName(object_name)
    if tooltip:
        btn.setToolTip(tooltip)
    if clicked is not None:
        btn.clicked.connect(clicked)
    return btn


def show_error(parent: QWidget | None, title: str, err: Any) -> None:
    QMessageBox.critical(parent, title, str(err))
