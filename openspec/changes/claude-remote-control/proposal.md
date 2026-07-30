## Why

Today, driving the mcp-emacs-launched Claude means typing into the eat terminal buffer
and reading its scrollback.
That works, but it keeps the interaction locked inside the TUI: prompts must be typed at
the terminal, and there is no structured, Org-native record of what Claude did.

The native-edit diff-review change (#20, shipped in v1.1.0/v1.1.1) already turned Emacs into
a Claude Code IDE client with an interactive ediff gate on every native edit.
That gives us the two hard pieces for free — a launched-from-Emacs interactive session and a
per-tool-call approval surface.
The missing piece is a way to *drive* that session from ordinary Emacs input and *see* what
it is doing as Org.
This change adds that, reusing the IDE surface rather than building a second runner.

## What Changes

- Add a new opt-in module `mcp-emacs-remote.el` providing a "remote control" over the
  interactive Claude session.
- **Prompt from Emacs, not the terminal.** A `mcp-emacs-remote-prompt` command reads a prompt
  from the minibuffer (or the active region / current buffer) and sends it to the current
  project's runner session via the existing `mcp-emacs-run-send-prompt`.
- **Live Org transcript.** A dedicated `*claude: <project>*` Org buffer per session records
  tool activity as it happens: one heading per tool call with its arguments, the accept/reject
  outcome of each `openDiff`, and a run-metadata drawer.
- **Tool approval stays the ediff review.** No new approval mechanism — native Edit/Write flow
  through `openDiff` → the ediff gate shipped in #20; the transcript just records the outcome.
- The transcript renders **tool activity only** in this version; assistant prose stays in the
  eat TUI (the IDE WebSocket surface does not carry prose — see design.md).

## Capabilities

### New Capabilities

- `remote-prompt-input`: send a prompt to the current project's interactive Claude session from
  the minibuffer, the active region, or the current buffer, without typing into the terminal.
- `remote-org-transcript`: maintain a per-session Org buffer that records Claude's tool activity
  (tool calls, arguments, `openDiff` accept/reject outcomes) and per-session run metadata, driven
  by events the IDE WebSocket surface already receives.

### Modified Capabilities

<!-- None. The IDE surface (ide-protocol-integration), the runner, and the ediff gate are
     reused as-is; this change adds new modules and event taps without altering their
     specified behaviour. -->

## Impact

- **New file**: `elisp/mcp-emacs-remote.el` (opt-in, behind a defcustom like the IDE surface).
- **Event tap**: hooks into `mcp-emacs-ide--call-tool` and the `openDiff` accept/reject
  completion (`mcp-emacs-ide--complete-open-diff`) in `elisp/mcp-emacs-ide.el` to feed the
  transcript renderer. The tap must not change existing IDE-surface behaviour.
- **Reuses unchanged**: the WebSocket IDE server (`mcp-emacs-ide.el`), the env-injecting runner
  and launch path (`mcp-emacs-run.el`), the shared ediff gate (`mcp-emacs--ediff-review`), and
  prompt delivery (`mcp-emacs-run-send-prompt`).
- **Dependencies**: none beyond what the IDE surface already requires (`websocket.el`, built-in
  `org`, `json`).
- **Out of scope** (follow-ups): assistant prose in the transcript (needs a structured event
  source such as the Agent SDK `canUseTool`/stream events or a `--output-format=stream-json`
  child); headless `-p`; `--resume`/`--session-id`; the opencode backend (deferred).

Full context and prior discussion: issue #23.
