---
name: review-diagnostics
description: Pull live Flycheck/Flymake/LSP diagnostics and build-error buffers from Emacs and fix the underlying code problems in the project. Use when the user says "what are the errors", "fix the warnings", "check diagnostics", "why won't this compile", or wants the AI to act on the squiggles they see in their editor. For a broken Emacs/tooling setup (missing LSP client, bad exec-path) use the diagnose-emacs skill instead.
---

# Review and fix project code diagnostics

The user's Emacs already knows what is wrong with the code — Flycheck/Flymake,
LSP, and the compilation/error buffers hold it. Read that state through the
`emacs` MCP tools rather than re-deriving errors yourself. This skill is about
problems in the **project's code**; if the diagnostics are absent or broken
because the tooling itself is misconfigured, switch to the `diagnose-emacs`
skill.

## Gather

- `get_diagnostics` — all diagnostics for the current buffer (Flycheck or
  Flymake, auto-detected).
- `describe_flycheck_info_at_point` — diagnostic(s) at the cursor, when the
  user is pointing at one specific squiggle.
- `get_error_context` — summarizes `*Messages*`, `*Warnings*`, and compilation
  logs, for build/runtime errors not tied to a buffer line.

## Fix them

1. List the diagnostics with file:line and severity; lead with errors, then
   warnings.
2. For each one you intend to fix, open/goto the location (`goto_line`,
   `open_file`) and inspect with `get_buffer_content` / `treesit_info`.
3. Apply the fix via `edit_file_region` or `insert_at_point`
   (Emacs coords: lines 1-based, columns 0-based).
4. Re-run `get_diagnostics` to confirm the diagnostic cleared before moving on.

## Rules

- Report faithfully: if a fix doesn't clear the diagnostic, say so with the
  remaining output — don't claim success.
- Don't save the buffer unless the user asks or a build needs it on disk.
- If diagnostics are empty, stale, or clearly wrong (e.g. no checker running,
  the whole file flagged), the problem is likely the Emacs/tooling setup, not
  the code — hand off to the `diagnose-emacs` skill.
