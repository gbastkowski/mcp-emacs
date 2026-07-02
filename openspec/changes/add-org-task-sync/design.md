## Context

`mcp-emacs` is a pure Emacs Lisp MCP server running inside the live Emacs daemon over HTTP.
AI coding harnesses (Claude Code, opencode) connect to it as MCP **clients**.
This change adds a shared, live Org workspace so the human and the AI collaborate on the plan itself instead of the human degrading into a pure reviewer of AI diffs.

Key external constraint discovered during design: **Claude Code exposes no inbound localhost API.** It is stateless from the network side (stdin/stdout + `~/.claude/`), acts only as an MCP *client*, and cannot be driven into an already-running interactive session from outside. Data therefore flows AI → Emacs, never Emacs → AI session.

Direction-of-control summary (verified against Claude Code docs):

| Mechanism                                 | Direction                            | Relevance here                                    |
|-------------------------------------------|--------------------------------------|---------------------------------------------------|
| Built-in HTTP/socket server               | —                                    | None. No opencode-style daemon to poll.           |
| Headless `-p --output-format stream-json` | host → claude (stdio)                | One-shot pipe; cannot inject into a live session. |
| Hooks (PostToolUse/Stop/UserPromptSubmit) | claude → external                    | Observe/veto/inject-context only.                 |
| MCP                                       | claude → external (Claude is client) | The integration path: harness calls our tools.    |

opencode differs — it runs a local HTTP server — but the cross-harness common denominator is our own Emacs MCP server as the shared sink. We design to that denominator.

## Goals / Non-Goals

**Goals:**
- Represent a session as one Org file: a task heading, a TODO checklist, an assigned session id, and a status.
- Expose read tools so the harness can fetch the current task, TODO list, session id, and status as structured, read-friendly text.
- Expose mutate tools so the harness can: set session status, set the status of a known TODO item, and append a progress note — all through the live Emacs buffer.
- Preserve concurrent human edits: the human keeps editing the same Org file in Emacs while the AI updates it.

**Non-Goals:**
- Driving or injecting prompts into a running AI session from Emacs (not possible for Claude Code; out of scope even where possible, e.g. opencode).
- Harness-specific hook scripts / glue. MCP-tool-only integration for this change; hooks can come later as a separate change.
- Multi-file task graphs, dependencies, scheduling, or agenda integration.
- Reordering, deleting, or rewriting human-authored TODO items the AI did not create.

## Decisions

### Write path: MCP tools only, through the live Emacs buffer
The AI writes exclusively by calling new `org-task-update` MCP tools; the tools mutate the Org file via its live Emacs buffer (find-file-noselect / existing buffer), never by writing disk behind Emacs' back.
- **Why**: matches the existing "write through Emacs, not disk" architecture, so buffer state and unsaved human edits interleave safely. Cross-harness (any MCP client). No dependency on LLM-external glue.
- **Alternatives**: direct disk writes (rejected — clobbers live human edits, contradicts architecture); Claude Code hook glue (rejected for this change — harness-specific, deterministic-status niceties deferred to a follow-up change).

### File resolution: path passed per call
Every tool takes the target Org file path (or a session id resolving to a path) as an explicit argument. Server holds no ambient "current task file" state.
- **Why**: stateless, explicit, supports multiple concurrent sessions/files. Aligns with existing narrow-scope tool style in the repo.
- **Alternatives**: single well-known `defcustom` file (rejected — one session at a time); per-project auto-resolution (rejected — discovery ambiguity, hidden magic).

### TODO status model: reuse Org keywords
Item and session status use Org's own TODO keyword machinery (`org-todo-keywords`): standard `TODO`/`DONE` plus additional in-progress / blocked states the user already configures.
- **Why**: native to Org, the human already edits these, no parallel status vocabulary to keep in sync. `org-todo` / `org-element` do the work.
- **Alternatives**: fixed custom status set (rejected — diverges from the user's keyword setup, forces a mapping layer).

### Concurrency & ownership rules
- AI updates only the status of TODO items it can identify (by heading text / id) and appends new items/notes at defined insertion points.
- AI MUST NOT reorder, delete, or rewrite human-authored items.
- Reads reflect current buffer state (including unsaved human edits), not last-saved disk.

### Structured-but-readable read output
Read tools return text that is both human-glanceable and parseable by the harness (task heading, session id, status, enumerated TODO items with their keyword). Follows the repo convention of plain-text tool results.

## Risks / Trade-offs

- **LLM may not call the update tools** → status goes stale silently. Mitigation: keep tools few and obvious; document usage; a later change can add Claude Code hooks for deterministic status pushes.
- **Concurrent write races** (AI mutate lands mid human keystroke) → Mitigation: all mutations go through Emacs on the daemon's single-threaded event loop; scope edits to specific subtrees/items rather than whole-buffer rewrites.
- **Item identification drift** (human renames a heading the AI tracked) → Mitigation: match leniently and fail soft with a friendly status message rather than editing the wrong item; never guess-delete.
- **Unsaved buffer vs disk divergence** → Mitigation: operate on the buffer; leave save decisions to the human / existing `save_buffer` tool unless a tool explicitly saves.
- **opencode/other harnesses** rely on the same MCP sink → acceptable; richer opencode-HTTP integration is a separate, optional future change.

## Migration Plan

Additive only. New helpers in `elisp/mcp-emacs.el`, new tool plists in `mcp-emacs-server--tools`. No changes to existing tools/resources/specs. Rollback = remove the new tools; existing capabilities unaffected.

## Resolved Questions

- **Session id semantics**: the session id is a plain label stored in the file. No tool keys behavior off it; the file path is the sole resolution key. Reads return the label; it is metadata only.
- **Item identity**: match TODO items by `:ID:`/`:CUSTOM_ID:` property when present, otherwise by heading text. Robust to renames where an id exists; still addresses plain human-typed items. No ordinal-position matching.
- **New-item insertion point**: append new TODO items as direct children under the task heading; append progress notes in the task's body/logbook. Everything stays in the natural Org tree, visible to the human in context. No separate "AI added" subtree.
- **Save policy**: never auto-save. All mutating tools edit the live buffer only; persistence is left to the human or the existing `save_buffer` tool.
