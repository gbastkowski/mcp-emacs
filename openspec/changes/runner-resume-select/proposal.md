## Why

To resume an old conversation today, `mcp-emacs-run-resume` passes a bare `--resume` and the Claude CLI shows its own in-terminal picker.
That works but is a full-screen TUI list with no Emacs affordances.
The CLI stores each conversation as `~/.claude/projects/<slug>/<session-id>.jsonl`, and accepts `--resume <session-id>` to launch a specific one — so Emacs can offer a native `completing-read` over the current project's past sessions with a readable label, matching how the rest of the runner is driven.

## What Changes

- Add `mcp-emacs-run-resume-select`: list the current project's past sessions from the on-disk Claude store, present a `completing-read` (most-recent first, each labelled with a relative timestamp and a short preview of the first real user prompt), and launch the chosen one with `--resume <session-id>`.
- Locate transcripts by slugifying the project root to the `~/.claude/projects/<slug>/` directory (replace `/` and `.` with `-`), reading `*.jsonl` files; the session id is the file name stem.
- Build each label cheaply: use file mtime for ordering and the timestamp, and read only enough of the head of each file to find the first genuine user message, skipping injected `<local-command-*>`/`<command-*>` and tool-result content.
- Keep `mcp-emacs-run-resume` (bare `--resume`, CLI picker) unchanged as the robust fallback.

## Capabilities

### New Capabilities
- `runner-resume-select`: selecting and resuming one of the current project's past Claude sessions from a native Emacs picker built from the on-disk transcript store.

### Modified Capabilities
<!-- none: mcp-emacs-run-resume keeps its current behaviour; this adds a distinct command. -->

## Impact

- `elisp/mcp-emacs-run.el`: new command + helpers to locate the store directory, enumerate sessions, and build preview labels; reuses `mcp-emacs-run--launch` with `--resume <id>`.
- New customization for the Claude projects directory root (default `~/.claude/projects`).
- `test/`: unit-test the slug builder and the preview extractor against sample JSONL lines (including the caveat/tool-result skip cases).
- No transport or MCP-tool change; this is a runner (human-driven) command.
- Depends on the CLI accepting `--resume <session-id>` (confirmed against the installed CLI: `-r, --resume [value]` — "Resume a conversation by session ID").
