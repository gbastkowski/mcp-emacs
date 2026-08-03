---
name: "orgspec: Archive"
description: Fold a completed change's delta into the specs and move it to archive
allowed-tools: mcp__emacs__eval
category: Workflow
tags: [orgspec, workflow]
---

Fold a completed change's delta into `specs/` and move the change to archive, via the running Emacs (mcp-emacs `eval` tool). Wraps `orgspec-archive`. This is the destructive, load-bearing verb — it rewrites spec files and moves the change directory.

**Input**: The argument after `/orgspec:archive` is the change id to archive. Required.

**Steps**

1. If no id was given, ask which change to archive (offer `/orgspec:status` output to pick from).

2. Confirm the change is complete: run `/orgspec:status <id>` first. If tasks are unfinished (`DONE < TOTAL`), surface that and ask the user to confirm they still want to archive.

3. Archive by evaluating in Emacs:
   ```elisp
   (progn (require 'orgspec-commands) (orgspec-archive "<id>"))
   ```
   Behaviour:
   - Blocks (signals `user-error`) if the change still has a `[NEEDS CLARIFICATION]` marker.
   - Blocks if the change has no delta requirements.
   - Folds every affected area in fixed order `RENAMED → REMOVED → MODIFIED → ADDED`.
   - Validate-all-then-write-all: rebuilds every target spec in memory and writes only if all folds succeed, so a failure leaves `specs/` untouched.
   - Strips TODO keyword / op-tag / `:AREA:` on re-level; keeps the `:IMPL:` drawer.
   - Moves `changes/<id>/` to `changes/archive/<id>/` via `git mv` when in a git repo.
   - Returns the list of spec files written.

4. Show `git diff` of the written `specs/*.org` so the fold is human-verifiable.

**Output**

- The list of spec files written.
- A short summary of the `specs/` diff (added/modified/removed requirements).
- Confirmation the change now lives under `changes/archive/<id>/`.

**Guardrails**

- If the eval errors on a clarification marker, report the message verbatim and stop — the user must resolve the marker in `change.org` first.
- Do NOT retry a failed archive without understanding why it failed; a partial write should not be possible (validate-all-then-write-all), but always show the diff to confirm.
- Do NOT `git commit` — leave the working tree staged/modified for the user to review and commit.
