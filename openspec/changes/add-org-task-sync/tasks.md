## 1. Org task file model & helpers (mcp-emacs.el)

- [x] 1.1 Define the session task file structure: task heading + session id + session status (Org property/keyword) + TODO checklist convention; document it in a docstring / comment
- [x] 1.2 Add `mcp-emacs-org-task--buffer-for-path` helper: resolve a path to its live buffer, opening via `find-file-noselect` if not already open; fail soft (friendly string) on unreadable path
- [x] 1.3 Add `mcp-emacs-org-task-read` helper: parse the buffer with `org-element`/`org-mode` primitives, return task heading, session id, session status, and TODO items with their Org keyword as structured plain text
- [x] 1.4 Add fallback handling for absent session id/status and empty checklist (defined fallback text, never raw nil)
- [x] 1.5 Add `mcp-emacs-org-task--find-item` helper: locate a TODO item by `:ID:`/custom property when present, else by heading text; return nil (not an error) when not found

## 2. Read tool (org-task-session)

- [x] 2.1 Add `mcp-emacs-org-task-session` tool plist to `mcp-emacs-server--tools` with `:schema` taking the file path (built via `--obj`/`--prop`)
- [x] 2.2 Handler calls `mcp-emacs-org-task-read`; reflects live buffer state including unsaved edits
- [x] 2.3 Handler returns friendly plain text for missing/invalid path

## 3. Mutating helpers (mcp-emacs.el)

- [x] 3.1 Add `mcp-emacs-org-task-set-session-status`: set the session status via Org keyword machinery; reject non-configured keywords with a friendly message, leaving status unchanged; edit buffer only (no save)
- [x] 3.2 Add `mcp-emacs-org-task-set-item-status`: set the Org keyword of an identified item via `org-todo`; no change if item not identifiable; touch only that item
- [x] 3.3 Add `mcp-emacs-org-task-append-note`: append a progress note at the defined insertion point under the task heading without altering existing content
- [x] 3.4 Add `mcp-emacs-org-task-append-item`: append a new TODO item under the task heading; preserve order/content of existing items; never reorder/delete/rewrite human-authored items

## 4. Mutating tools (org-task-update)

- [x] 4.1 Add tool plist for set-session-status (path + status args)
- [x] 4.2 Add tool plist for set-item-status (path + item ref + status args)
- [x] 4.3 Add tool plist for append-note (path + note args)
- [x] 4.4 Add tool plist for append-item (path + item text + optional keyword args)
- [x] 4.5 Ensure all mutating tools operate on the buffer only and do not save unless explicitly defined to

## 5. Testing & docs

- [x] 5.1 Manual test per AGENTS.md: reload via `emacsclient --eval` load-file + server stop/start, then exercise each tool with `curl` against `/mcp`
- [x] 5.2 Verify concurrency: apply an update while the buffer holds unsaved human edits; confirm edits preserved
- [x] 5.3 Verify fail-soft paths: invalid file path, unrecognized status keyword, unidentifiable item — all return friendly text, no raw errors, no edits
- [x] 5.4 Update README.md feature list and AGENTS.md if any new convention is worth noting
