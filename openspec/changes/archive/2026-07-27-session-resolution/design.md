## Context

`mcp-emacs-run.el` tracks sessions in `mcp-emacs-run--sessions`, a
`root -> buffer` hashtable, populated by `--launch` (`puthash`) and read by
`--live-buffer` (`gethash`). Every send command resolves the current
project root and looks it up. The hashtable is volatile: reload / restart /
`clrhash` empties it while `*claude:<project>*` buffers stay alive, so sends
then fail with "No live runner session" despite a visible buffer.

Investigation confirmed each live runner buffer's `default-directory`
equals its project root (e.g. `*claude:mcp-emacs*` →
`.../gbastkowski/mcp-emacs/`), so the buffer alone carries enough to
re-derive its project. The registry is redundant.

## Goals / Non-Goals

**Goals:**
- Multiple sessions per project via numbered buffer names
  `*claude:<project>:<n>*`.
- Remove the registry; derive sessions from live buffers.
- Resolve one send target by (same-project, visible) priority with a
  picker on ambiguity.
- Keep list / switch / kill / toggle working without the registry.
- Resolve once per send operation (no double prompt on prompt+submit).
- Command model: `mcp-emacs-run-new` (spawn), `mcp-emacs-run-switch`
  (pick); drop plain `mcp-emacs-run`.

**Non-Goals:**
- The popup window; opencode.

## Decisions

### Buffer naming and numbering

`mcp-emacs-run--buffer-name` becomes `(root n)` →
`*claude:<project>:<n>*`. A new helper `mcp-emacs-run--next-number (root)`
scans live session buffers for that project, parses their `<n>`, and
returns the lowest positive integer not in use (so a killed middle slot is
refilled). `--launch` allocates the number, builds the name, spawns.

### Candidate discovery

`mcp-emacs-run--sessions-list` returns live buffers whose name matches
`\\`\\*claude:.+:[0-9]+\\*\\'`. For each, its project root is
`(with-current-buffer buf (mcp-emacs-run--project-root))` — reusing the
existing project resolver against the buffer's `default-directory`.

### Resolution priority

`mcp-emacs-run--resolve-session` builds the candidate list, computes the
current buffer's project root once, and partitions into four tiers:

```
tier 1: same-project AND (get-buffer-window buf 'visible)
tier 2: same-project AND not visible
tier 3: other-project AND visible
tier 4: other-project AND not visible
```

Take the first non-empty tier. If empty overall → `user-error`. If the
tier has one buffer → return it. If more → `completing-read` over
`project-name -> buffer` (disambiguate identical names with the buffer
name) and return the pick.

"Visible" uses `(get-buffer-window buf t)` (any frame). This matches the
user's "visible windows get higher priority; else same logic".

### Resolve-once for multi-keystroke sends

`--send` is split:
- `mcp-emacs-run--send-to-buffer (buf string)` — low level, no resolution.
- `mcp-emacs-run--send (string)` — resolves once, then sends.

Commands emitting several keystrokes (`send-prompt` = text then `\r`)
resolve the buffer once via `--resolve-session` and call
`--send-to-buffer` twice. Single-keystroke commands call `--send`.

### Command rewrites

- `--launch`: allocate `<n>` via `--next-number`, name the buffer, spawn;
  drop the `puthash`; still returns the buffer, still may display it.
- Drop `mcp-emacs-run`; add `mcp-emacs-run-new` = always `--launch` a fresh
  numbered session and display it. `-start` stays "launch without display"
  (also numbered).
- `-list`: iterate `--sessions-list`.
- `-switch`: `completing-read` over `--sessions-list` (this is the picker
  for reaching an existing session), then display the pick.
- `-kill`: candidates = current project's sessions; one → kill it, many →
  picker; no `remhash`.
- `-toggle`: current project's sessions; none → `mcp-emacs-run-new`; one
  visible → delete its window; one hidden → display; many → picker then
  toggle the pick.
- `-continue` / `-resume`: still `--launch` with the extra switch,
  numbered.
- Remove `mcp-emacs-run--sessions` defvar and `mcp-emacs-run--live-buffer`.

## Risks / Trade-offs

- **Two projects, same folder name**: matching is by full resolved root
  path, not the display name, so collisions do not mis-target; they only
  make picker labels ambiguous, which we disambiguate with the buffer name.
- **`project-current` in a non-file buffer**: the eat buffer's
  `default-directory` is the project dir, and `--project-root` already
  falls back to `default-directory`, so resolution works without a visited
  file.
- **Behavioral change**: sends may now target another project's session
  (tier 3/4) via a picker, where before they hard-errored. This is the
  requested behavior (visible cross-project fallback).
- **Perf**: scanning `buffer-list` per send is O(buffers); negligible.

## Open Questions

- None blocking. `completing-read` label format finalized during
  implementation (project name, buffer name on tie).
