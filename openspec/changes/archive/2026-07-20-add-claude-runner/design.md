## Context

`mcp-emacs` now provides Claude's editor tools over MCP; the missing piece for
retiring `claude-code-ide.el` is a way to *run* the Claude CLI inside Emacs. The
CLI is a full-screen ANSI TUI, so it needs a real terminal emulator, not a
comint line-mode. eat is chosen (pure Elisp, no C dependency, rewraps on resize,
low flicker) and is already the terminal the user runs.

eat exposes a single launch primitive:
`eat-make NAME PROGRAM &optional STARTFILE &rest SWITCHES` — it creates a buffer
`*NAME*` running PROGRAM (with SWITCHES) in an eat terminal and returns that
buffer. The process inherits `default-directory` as its working directory. This
is the same entry point `claude-code.el` uses.

The runner lives in a new file, `elisp/mcp-emacs-run.el`, separate from the MCP
server so the server stays pure. eat is a soft dependency (`featurep`-guarded,
`declare-function` for `eat-make`), so loading `mcp-emacs` never requires eat.

## Goals / Non-Goals

**Goals:**
- Launch the Claude CLI in an eat buffer, project-aware, with a configurable
  executable and flags.
- One primary session per project, with list/switch/kill.
- Show/hide/toggle a side-window for the runner.
- Continue/resume prior conversations.
- No hard dependency on eat.

**Non-Goals:**
- The IDE WebSocket protocol and push notifications (editor tools come from
  mcp-emacs over MCP).
- Reading or parsing the CLI's output (it is an opaque TUI); the runner only
  launches, places, and manages the terminal.
- Any shared abstraction with the opencode client (deliberately separate — the
  two are architecturally different).

## Decisions

### D1: Launch via `eat-make` with the project root as `default-directory`
Bind `default-directory` to the current project's root (via `project-current` /
`project-root`, falling back to the buffer's directory when not in a project),
then call `eat-make` with the runner buffer name, the configured executable, and
the configured switches plus any mode flag (continue/resume). Reference:
`claude-code.el` uses `eat-make` the same way.

- **Alternative considered:** `make-term`/`ansi-term`. Rejected — eat is the
  chosen backend (proposal), and `eat-make` is its supported entry point.

### D2: One primary session per project, keyed by project root
Maintain a registry (alist or hash) from project root to runner buffer. Buffer
name is `*claude:<project-name>*`. Starting the runner for a project with a live
buffer switches to it instead of duplicating. `list` enumerates live registry
entries; `switch` uses `completing-read` over them; `kill` sends the process a
signal (or kills the buffer) and drops the registry entry.

- **Alternative considered:** claude-code.el's multi-instance-per-directory
  model. Rejected as more than needed now; one primary session per project is
  the common case. Multiple instances can be added later without breaking the
  registry shape.

### D3: Side-window placement via `display-buffer` rules
Show the runner with `display-buffer` using a `side`/`slot` alist entry so it
occupies a side window rather than replacing the user's main window. Toggle
hides the window (without killing the process) when visible and shows it
otherwise. A defcustom controls whether showing the window also selects it
(focus), matching claude-code-ide's focus options.

### D4: Continue/resume are launch-time flags
Continue and resume are separate entry commands that add the CLI's continue or
resume flag to the switches passed to `eat-make`. No session state is tracked by
the runner beyond the live buffer; conversation history is the CLI's concern.

### D5: eat is a soft dependency
`(require 'eat nil t)`, `declare-function eat-make`, and a `featurep 'eat`
guard in each command. Runner commands error with a clear "install eat" message
when eat is absent; loading the file never hard-requires it — consistent with
the plz (opencode client) and projectile (project tools) patterns in this repo.

## Risks / Trade-offs

- **eat API drift** → the runner depends only on `eat-make`'s stable signature;
  declared with `declare-function` so byte-compilation is clean without eat.
- **Opaque TUI** → the runner cannot observe the CLI's output; this is accepted
  (editor integration is via MCP, not by scraping the terminal).
- **Killing a session mid-run** → `kill` terminates the process; document that
  in-flight work is lost, same as quitting the CLI in any terminal.
- **Project detection outside a project** → fall back to the buffer's
  `default-directory` and still launch, rather than refusing.

## Open Questions

- Should the runner set any Claude-CLI environment (e.g. to point at the
  mcp-emacs MCP server) at launch, or rely entirely on the user's `.mcp.json`?
  Plan: rely on the user's existing MCP configuration; revisit if a launch-time
  hint proves necessary.
