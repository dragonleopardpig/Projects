#!/usr/bin/env python3
"""Stdio MCP transport for the running Emacs, using its private server socket."""

import argparse
import base64
import json
import subprocess
import sys


def tool(name, description, properties=None, required=None):
    return {"name": name, "description": description,
            "inputSchema": {"type": "object", "properties": properties or {},
                            "required": required or [], "additionalProperties": False}}


CONTEXT = {"context_id": {"type": "string", "description": "Captured source context ID from the user's request."}}
TICK = {"expected_tick": {"type": "integer", "description": "Latest tick from emacs_context or read_buffer; protects concurrent typing."}}
RANGE = {"start": {"type": "integer"}, "end": {"type": "integer"}}
TEXT = {"text": {"type": "string"}}
TOOLS = [
    tool("emacs_context", "Read the live source buffer, captured cursor, Org table and math fragment. Call before editing.", CONTEXT),
    tool("read_buffer", "Read a range of the live buffer, including unsaved edits, up to 40000 characters.", {**CONTEXT, **RANGE}),
    tool("insert", "Insert text at the captured cursor. Use for a described LaTeX symbol. One undoable edit; does not save.",
         {**CONTEXT, **TICK, **TEXT}, ["context_id", "expected_tick", "text"]),
    tool("replace", "Replace an exact buffer range. Provide its original expected_text and latest tick. Preserves undo.",
         {**CONTEXT, **TICK, **RANGE, **TEXT, "expected_text": {"type": "string"}},
         ["context_id", "expected_tick", "start", "end", "expected_text", "text"]),
    tool("sum_column", "Sum an Org column into a footer using a persistent TBLFM vsum formula, and recalculate it.",
         {**CONTEXT, **TICK, "column": {"type": "integer", "minimum": 1}}, ["context_id", "expected_tick", "column"]),
    tool("check_latex", "Compile the captured math fragment with LaTeX and amsmath/amssymb. Return real compiler diagnostics.", CONTEXT),
    tool("preview_latex", "Refresh the Org math preview after repairing and checking the fragment.", CONTEXT),
]


def call_emacs(arguments, name, values):
    action = "context" if name == "emacs_context" else name
    request = base64.b64encode(json.dumps({**values, "action": action}).encode()).decode()
    expression = f'(my/agent-dispatch "{request}")'
    result = subprocess.run([arguments.emacsclient, "--socket-name", arguments.socket,
                             "--eval", expression], capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "Emacs is unavailable")
    return json.loads(base64.b64decode(json.loads(result.stdout)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--emacsclient", default="emacsclient")
    arguments = parser.parse_args()
    for line in sys.stdin:
        identifier = None
        try:
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("Expected a JSON-RPC object")
            method = request.get("method")
            identifier = request.get("id")
            if identifier is None:
                continue
            if method == "initialize":
                result = {"protocolVersion": request.get("params", {}).get("protocolVersion", "2024-11-05"),
                          "capabilities": {"tools": {}}, "serverInfo": {"name": "emacs-buffer", "version": "1.0.0"}}
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": TOOLS}
            elif method == "tools/call":
                params = request.get("params", {})
                name = params.get("name")
                if name not in {item["name"] for item in TOOLS}:
                    raise ValueError(f"Unknown tool: {name}")
                try:
                    data = call_emacs(arguments, name, params.get("arguments", {}))
                    result = {"content": [{"type": "text", "text": json.dumps(data)}], "isError": bool(data.get("error"))}
                except Exception as error:
                    result = {"content": [{"type": "text", "text": str(error)}], "isError": True}
            else:
                raise ValueError(f"Unsupported method: {method}")
            response = {"jsonrpc": "2.0", "id": identifier, "result": result}
        except Exception as error:
            response = {"jsonrpc": "2.0", "id": identifier,
                        "error": {"code": -32603, "message": str(error)}}
        print(json.dumps(response), flush=True)


if __name__ == "__main__":
    main()
