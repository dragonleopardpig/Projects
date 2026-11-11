#!/usr/bin/env python3
"""Exercise lifecycle state, concurrent sessions, stale PIDs and passive hooks."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

script = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).with_name("agent-status.py")
spec = importlib.util.spec_from_file_location("agent_status", script)
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)


class AgentStatusTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.environment = patch.dict(os.environ, {
            "NOCTALIA_AGENT_STATUS_DIR": str(self.root / "status"),
            "NOCTALIA_AGENT_PID": str(os.getpid()),
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.payload = {"conversationId": "first", "workspacePaths": ["/work/NixOS"]}

    def emit(self, event, **fields):
        agent.handle_hook(event, {**self.payload, **fields})
        return agent.snapshot()

    def test_lifecycle_and_background_tasks(self):
        self.assertEqual(agent.snapshot()["status"], "idle")
        self.assertEqual(self.emit("SessionStart")["status"], "working")
        self.assertEqual(self.emit("PreToolUse", toolCall={"name": "ask_question"})["status"], "waiting")
        self.assertEqual(self.emit("PostToolUse", toolCall={"name": "ask_question"})["status"], "working")
        self.assertEqual(self.emit("Stop", terminationReason="model_stop", fullyIdle=False)["status"], "working")
        self.assertEqual(self.emit("Stop", terminationReason="model_stop", fullyIdle=True)["status"], "done")
        self.assertEqual(self.emit("PreInvocation")["status"], "working")
        self.assertEqual(self.emit("Stop", terminationReason="error", error="failed")["status"], "error")

    def test_other_session_completion_cannot_hide_work(self):
        self.emit("PreInvocation")
        self.emit("Stop", conversationId="second", fullyIdle=True)
        current = agent.snapshot()
        self.assertEqual(current["status"], "working")
        self.assertEqual(current["counts"]["working"], 1)
        self.emit("PreToolUse", conversationId="third", toolCall={"name": "ask_question"})
        current = agent.snapshot()
        self.assertEqual(current["status"], "waiting")
        self.assertEqual(current["counts"]["working"], 1)
        self.assertEqual(current["counts"]["waiting"], 1)

    def test_pid_reuse_is_treated_as_interrupted(self):
        self.emit("PreInvocation")
        path = agent.record_path("first")
        record = json.loads(path.read_text())
        record["start_time"] = "different process"
        path.write_text(json.dumps(record))
        self.assertEqual(agent.snapshot()["status"], "error")
        record["updated"] -= agent.RETENTION_SECONDS + 1
        path.write_text(json.dumps(record))
        self.assertEqual(agent.snapshot()["status"], "idle")
        self.assertFalse(path.exists())

    def test_closed_waiting_session_is_removed(self):
        self.emit("PreToolUse", toolCall={"name": "ask_question"})
        with patch.object(agent, "process_info", return_value=None):
            self.assertEqual(agent.snapshot()["status"], "idle")

    def test_completion_survives_process_exit_briefly(self):
        self.emit("Stop", fullyIdle=True)
        with patch.object(agent, "process_info", return_value=None):
            self.assertEqual(agent.snapshot()["status"], "done")
            with patch.object(agent.time, "time", return_value=time.time() + agent.RETENTION_SECONDS + 1):
                self.assertEqual(agent.snapshot()["status"], "idle")

    def test_only_metadata_is_saved_and_paths_are_safe(self):
        self.emit("Stop", conversationId="../../outside", lastUserInput="PRIVATE PROMPT",
                  transcriptPath="/private/transcript", toolCall={"args": "PRIVATE ARGS"},
                  error="PRIVATE ERROR")
        path = agent.record_path("../../outside")
        saved = path.read_text()
        self.assertNotIn("PRIVATE", saved)
        self.assertNotIn("transcript", saved)
        self.assertEqual(path.parent, agent.status_root())
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(json.loads(saved)["workspace"], "NixOS")

    def test_hooks_never_block_on_invalid_input_or_storage_failure(self):
        for event, value in (("PreToolUse", "not json"), ("Stop", "[]")):
            result = subprocess.run([sys.executable, str(script), "hook", event], input=value,
                                    capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout), {"decision": "allow"})
        blocker = self.root / "not-a-directory"
        blocker.write_text("blocked")
        result = subprocess.run([sys.executable, str(script), "hook", "PreToolUse"],
                                input=json.dumps(self.payload), capture_output=True, text=True,
                                env={**os.environ, "NOCTALIA_AGENT_STATUS_DIR": str(blocker)}, check=True)
        self.assertEqual(json.loads(result.stdout), {"decision": "allow"})

    def test_malformed_record_does_not_break_status(self):
        self.emit("PreInvocation")
        (agent.status_root() / "bad.json").write_text("not json")
        self.assertEqual(agent.snapshot()["status"], "working")

    def test_launcher_preserves_automatic_permissions(self):
        executable = self.root / ".local/bin/agy"
        executable.parent.mkdir(parents=True)
        executable.write_text(f"#!{sys.executable}\nimport json, os, sys\n"
                              "print(json.dumps({'args': sys.argv[1:], 'pid': os.getpid(), "
                              "'tracked': os.environ['NOCTALIA_AGENT_PID']}))\n")
        executable.chmod(0o700)
        result = subprocess.run([sys.executable, str(script), "run"],
                                env={**os.environ, "HOME": str(self.root)},
                                capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)
        self.assertEqual(data["args"], ["--dangerously-skip-permissions"])
        self.assertEqual(str(data["pid"]), data["tracked"])


if __name__ == "__main__":
    unittest.main()
