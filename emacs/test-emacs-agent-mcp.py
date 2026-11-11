#!/usr/bin/env python3
"""Exercise MCP discovery and error recovery without a model request."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class TransportTests(unittest.TestCase):
    def test_discovery_notifications_and_recoverable_tool_failure(self):
        requests = [
            {"id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}},
            {"method": "notifications/initialized"},
            {"id": 2, "method": "tools/list"},
            {"id": 3, "method": "tools/call", "params": {"name": "emacs_context", "arguments": {}}},
            {"id": 4, "method": "ping"},
        ]
        with tempfile.TemporaryDirectory() as directory:
            completed = subprocess.run(
                [sys.executable, str(Path(__file__).with_name("emacs-agent-mcp.py")),
                 "--socket", str(Path(directory) / "no-emacs-server")],
                input="\n".join(json.dumps({"jsonrpc": "2.0", **item}) for item in requests) + "\n",
                capture_output=True, text=True, check=True, timeout=10,
            )
        responses = [json.loads(line) for line in completed.stdout.splitlines()]
        self.assertEqual([r["id"] for r in responses], [1, 2, 3, 4])
        self.assertEqual(responses[0]["result"]["serverInfo"]["name"], "emacs-buffer")
        names = {t["name"] for t in responses[1]["result"]["tools"]}
        self.assertTrue({"sum_column", "insert", "replace", "check_latex"} <= names)
        self.assertTrue(responses[2]["result"]["isError"])
        self.assertEqual(responses[3]["result"], {})

    def test_malformed_input_does_not_crash_stream(self):
        completed = subprocess.run(
            [sys.executable, str(Path(__file__).with_name("emacs-agent-mcp.py")), "--socket", "/not-used"],
            input='[]\nnot json\n{"id":9,"method":"ping"}\n', capture_output=True,
            text=True, check=True, timeout=5,
        )
        responses = [json.loads(line) for line in completed.stdout.splitlines()]
        self.assertIn("error", responses[0])
        self.assertIn("error", responses[1])
        self.assertEqual(responses[2]["id"], 9)
        self.assertEqual(responses[2]["result"], {})


if __name__ == "__main__":
    unittest.main()
