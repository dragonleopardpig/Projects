# Antigravity in Emacs

The assistant uses `agent-shell` and your existing Antigravity login. Tool
permissions are automatic, matching the desktop agent. It reads and edits the
running Emacs buffer, including unsaved changes, with ordinary Emacs undo.

| Key | Action |
| --- | --- |
| `C-c e a` | Ask Antigravity about the current buffer/table/equation |
| `C-c e i` | Describe a LaTeX symbol and have it inserted at your cursor |
| `C-c e l` | Diagnose, repair and preview the current or selected equation |
| `C-c e s` | Sum an Org column immediately with a native formula |
| `C-c e e` | Open or return to the Antigravity conversation |

For an Org total, put the cursor inside the table, press `C-c e a`, and ask
“Sum the Cost column and put its total below.” The agent uses Emacs's native
table operations to add/reuse a Total row, preserve other formulas, store a
`#+TBLFM` such as `@>$2=vsum(@2$2..@-1$2)`, and recalculate. Changing data and
recalculating the table updates the total. `C-c e s` does this without an AI
request. The first horizontal separator denotes the header boundary.

While typing an equation, use `C-c e i` and describe, for example, “a lowercase
Greek alpha” or “the symbol for a subset, allowing equality.” The agent inserts
the LaTeX at the captured cursor. For a broken equation use `C-c e l`. Selecting
a fragment explicitly is useful for unfinished or multiline math that Org has
not yet recognized. Diagnostics compile an isolated document with `amsmath` and
`amssymb`; document-specific custom macros/packages may need their definitions
included before that diagnostic can reproduce the document's environment.

The chat opens in the bottom half of the frame, with your document above it,
and reuses that split on subsequent requests. It uses the current Emacs theme.
Requests carry a source-buffer
context ID, so focusing the agent window does not redirect edits there. Edit
tools check the buffer's modification tick and original text, and re-read before
retrying if you type concurrently. The assistant leaves saving the document to
you. Use normal Emacs undo to reverse an edit.

`ai-agent.el` provides the buffer tools; `emacs-agent-mcp.py` connects them to the
agent over MCP using Emacs's private local server socket. No extra API key or
separate model service is needed. `agent-shell`, `acp` and `shell-maker` are
installed through the existing Emacs package setup.

Restart Emacs to load the integration, or evaluate
`(load "~/Projects/emacs/ai-agent.el")` in an already-running instance. No system
reboot is needed. The NixOS desktop status widget also sees activity from newly
started Antigravity sessions in Emacs.

Checks from `~/Projects`:

```sh
emacs -Q --batch -l emacs/ai-agent-tests.el -f ert-run-tests-batch-and-exit
python3 emacs/test-emacs-agent-mcp.py
```
