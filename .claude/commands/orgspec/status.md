---
name: "orgspec: Status"
description: Report task completion for orgspec changes via the running Emacs
allowed-tools: mcp__emacs__eval
category: Workflow
tags: [orgspec, workflow]
---

Report task-checkbox completion for orgspec changes via the running Emacs (mcp-emacs `eval` tool). Wraps `orgspec-status`.

**Input**: The optional argument after `/orgspec:status` is a change id. With no id, all active changes are reported.

**Steps**

1. Evaluate in Emacs. With an id:
   ```elisp
   (progn (require 'orgspec-commands) (orgspec-status "<id>"))
   ```
   Without an id (all active changes):
   ```elisp
   (progn (require 'orgspec-commands) (orgspec-status))
   ```
   Returns an alist `((ID (DONE . TOTAL)) ...)` counting `[x]`/`[ ]` checkboxes per change.

**Output**

- One line per change: `<id>: <done>/<total> tasks done`.
- Flag any change at `N/N` as ready to `/orgspec:archive`.
- Flag any change with `0` total tasks (empty Tasks section).

**Guardrails**

- Read-only. Do NOT modify any files.
- Archived changes (under `changes/archive/`) are excluded by the verb — don't try to include them.
