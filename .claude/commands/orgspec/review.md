---
name: "orgspec: Review"
description: Ediff a change's fold against the current specs before writing (writes nothing)
allowed-tools: mcp__emacs__eval
category: Workflow
tags: [orgspec, workflow]
---

Show what `/orgspec:archive` *would* write, as an ediff, before committing to it — "see the fold", not "trust the fold". Wraps `orgspec-review-fold` via the mcp-emacs `eval` tool. Review-only: nothing is written and nothing is moved.

**Input**: The argument after `/orgspec:review` is the change id. Required.

**Steps**

1. If no id was given, ask which change to review (offer `/orgspec:status` output to pick from).

2. Review by evaluating in Emacs:
   ```elisp
   (progn (require 'orgspec-review) (orgspec-review-fold "<id>"))
   ```
   For each affected area this ediffs the on-disk `specs/<area>.org` against the folded result the archive would produce. It builds the same in-memory result `archive` uses (validate-all), so the same blocks apply — an unresolved `[NEEDS CLARIFICATION]` marker or a change with no delta requirements is a `user-error`. The window layout is captured before ediff opens and restored when you quit each review. Returns the list of area spec files reviewed.

**Output**

- The list of area spec files being reviewed.
- Reminder that this wrote nothing: run `/orgspec:archive <id>` to actually apply the fold.

**Guardrails**

- Read-only. Do NOT write specs or move the change — that is `/orgspec:archive`.
- Each area opens its own ediff; the user resolves (quits) each in Emacs. Report the file list, don't try to drive the ediff from here.
- If the eval errors on a clarification marker or an empty delta, report it verbatim and stop.
