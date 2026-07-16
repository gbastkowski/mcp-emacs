---
name: diagnose-emacs
description: Diagnose the Emacs/tooling setup itself when the editor environment is broken — no checker running, missing or dead LSP client, wrong exec-path, missing executables, or environment/PATH problems. Use when diagnostics are absent or nonsensical, LSP won't start, "command not found" in Emacs, or the user asks why their Emacs tooling isn't working. For fixing actual code problems the checker reports, use the review-diagnostics skill instead.
---

# Diagnose the Emacs / tooling setup

This skill is about the **editor environment**, not the project's code. Reach
for it when the tooling that produces diagnostics is itself broken: no checker
is running, the LSP client won't start or has died, an executable isn't found,
or Emacs's `exec-path`/environment differs from your shell.

## Gather

- `diagnose_emacs` — the primary tool: `exec-path`, active LSP clients, and
  other runtime info about the running Emacs.
- `get_env_vars` — environment variables visible to Emacs. Compare against what
  your shell has; a GUI Emacs often inherits a different `PATH`.
- `get_error_context` — `*Messages*` and `*Warnings*` frequently hold the real
  reason an LSP server or checker failed to start.
- `project_info` — confirm Emacs sees the intended project root and file set.

## Diagnose

1. Confirm the expected checker/LSP client is actually active (`diagnose_emacs`).
   If none is running, that alone explains empty or missing diagnostics.
2. If a client is configured but dead, read `*Messages*`/`*Warnings*`
   (`get_error_context`) for the startup failure.
3. If the failure is "command not found" or a wrong binary, check `exec-path`
   and `PATH` (`diagnose_emacs`, `get_env_vars`) — the executable may be
   present in your shell but not on Emacs's `exec-path`.
4. Use `eval` to inspect or probe further (e.g. `(executable-find "...")`,
   feature/mode state) when the standard tools don't pin it down.

## Rules

- Fix the setup story, not the code — patching source won't help a missing
  server or a bad `exec-path`.
- Report what you found and the concrete remedy (add to `exec-path`, install
  the binary, load the client, fix the env), and say what you could not verify.
- Prefer read-only probing; only `eval` mutating Elisp with clear intent, and
  say what you ran.
- Once the tooling is healthy again, hand back to `review-diagnostics` to work
  through the real code diagnostics.
