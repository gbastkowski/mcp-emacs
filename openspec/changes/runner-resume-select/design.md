## Context

The Claude CLI persists each conversation as a JSONL transcript at
`~/.claude/projects/<slug>/<session-id>.jsonl`, where `<slug>` is the project's absolute path with `/` and `.` replaced by `-`, and `<session-id>` is the file-name stem (a UUID). The CLI resumes a specific one with `--resume <session-id>`.

`mcp-emacs-run.el` already launches via `mcp-emacs-run--launch root no-display &rest extra-switches`, and `mcp-emacs-run-resume` passes a bare `--resume` (CLI picker). This change adds a native Emacs picker; nothing in the runner reads `~/.claude` today.

Two practical hazards observed in real transcripts:
- Transcripts can be large (10 MB seen). Full parsing per candidate is too slow.
- The first `type":"user"` line is frequently an injected `<local-command-caveat>` / `<command-name>` block or a tool result, not the human's prompt. `message.content` may be a string or an array of content blocks.

## Goals / Non-Goals

**Goals:**
- A `completing-read` over the current project's past sessions, most-recent first, each labelled `<relative-time>  <preview>`.
- Launch the chosen session with `--resume <session-id>` through the existing launch path.
- Cheap: order by file mtime; read only the head of each file for the preview.
- Robust when the store dir is missing or empty (clear message, no error).

**Non-Goals:**
- No change to `mcp-emacs-run-resume` (kept as CLI-picker fallback).
- No cross-project session browsing (scope = current project's slug dir).
- No full transcript rendering or search inside Emacs.
- No live-session interaction (that is `-list` / `-switch`).

## Decisions

### D1: Locate the store by slugifying the project root
`mcp-emacs-run--session-store-dir (root)` = `(expand-file-name (slug root) mcp-emacs-run-projects-directory)`, where `slug` replaces `/` and `.` with `-` in the absolute root path, and `mcp-emacs-run-projects-directory` defaults to `~/.claude/projects`.
*Alternative:* read the `cwd` field inside transcripts to match — rejected, requires opening files just to locate them; the slug is deterministic.

### D2: Enumerate + order by mtime
`directory-files-and-attributes DIR t "\\.jsonl\\'"`, sort by mtime descending. mtime is the cheap, reliable recency signal; avoids reading file bodies for ordering.
*Alternative:* parse the last message's `timestamp` — rejected, needs reading each file; mtime is close enough for a picker.

### D3: Cheap preview extraction
`mcp-emacs-run--session-preview (file)` reads only the first N KB (e.g. `insert-file-contents` with a byte bound), scans line by line, JSON-parses each, and returns the first `type=="user"` message whose textual content is a *genuine* prompt:
- Normalise `message.content`: if a string, use it; if an array, take the first text block's text.
- Skip when the text is empty, or begins with `<local-command-`, `<command-name>`, `<command-message>`, or looks like a tool/system caveat block.
- Truncate to a fixed width for the label; collapse whitespace/newlines.
If none found in the head window, fall back to the session id.
*Alternative:* prefer `type=="summary"` lines — deferred; summaries aren't always near the head, and the first real prompt is a good, cheap label (chosen "First prompt + mtime").

### D4: Label + selection
Candidate label: `<relative-time>  <preview>` (e.g. `2h ago  refactor the runner window`), where relative-time is derived from mtime. `completing-read` maps the label back to the session id; launch `(mcp-emacs-run--launch root nil "--resume" id)`.
Duplicate/blank previews still differ by their time prefix; if labels could collide, disambiguate with a short id suffix.

### D5: Empty / missing store
If the slug dir does not exist or has no `*.jsonl`, `user-error` "No past sessions for this project" — do not launch anything and do not fall back to the CLI picker silently (the user asked for the native list).

## Risks / Trade-offs

- [Slug algorithm drifts from the CLI's] → the algorithm (`/` and `.` → `-`) is verified against the live store for this project; if the CLI changes it, the dir simply won't be found and the user gets the clear empty-store message. Keep the slug rule in one helper.
- [Head-window misses the first real prompt in a transcript with a long preamble] → fall back to session id; the window size is a defcustom so it can be raised. Acceptable: label degrades, resume still works.
- [`message.content` shapes beyond string/array-of-text] → normalise defensively; unknown shapes fall through to the skip/fallback path rather than erroring.
- [Large number of sessions] → `completing-read` handles hundreds fine; previews are read lazily only for the files listed (all of them at build time — bounded by head-window reads, cheap).
- [CLI `--resume <id>` semantics change] → confirmed against installed CLI; if it regresses, `mcp-emacs-run-resume` (bare) remains.

## Open Questions

- Exact head-window size (KB) balancing "finds the real prompt" vs speed — start at a few KB, tune during implementation with real transcripts.
- Whether to show the session id in the label always (for disambiguation) or only on collision — default to time+preview, add id only if needed.
