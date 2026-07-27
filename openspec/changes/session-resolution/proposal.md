## Why

The Claude runner keeps a `mcp-emacs-run--sessions` hashtable mapping a
project root to its runner buffer. It is the *only* link between a project
and its session, and it is volatile: reloading `mcp-emacs-run.el`,
restarting Emacs, or any `clrhash` wipes it while the live `*claude:...*`
buffers survive. After that, send commands fail with "No live runner
session for this project" even though the buffer is right there on screen.

The buffer name (`*claude:<project>*`) and the buffer's `default-directory`
already encode everything needed to find the right session, so the
registry is redundant state that only creates a class of stale-lookup
bugs. It also cannot express "there are several sessions, which one?".

## What Changes

- **Support multiple concurrent sessions per project.** Rename runner
  buffers to `*claude:<project>:<n>*` where `<n>` is a per-project counter
  (always numbered, starting at 1).
- **Command model** (BREAKING): drop the plain `mcp-emacs-run` command.
  `mcp-emacs-run-new` always launches a fresh next-numbered session;
  `mcp-emacs-run-switch` picks an existing session and displays it.
- **Remove** the `mcp-emacs-run--sessions` registry entirely
  (`--sessions`, `puthash`, `--live-buffer`, and the `clrhash`/`remhash`
  usages).
- **Resolve the target session live** from the set of live `*claude:*`
  buffers each time keys/text are sent, using the buffer's own
  `default-directory` resolved to a project root as the match key.
- Resolution order (highest priority first), picking with `completing-read`
  whenever a tier still has more than one candidate:
  1. same project as the current buffer, **and visible** in a window
  2. same project, hidden
  3. any project, **visible** (cross-project fallback)
  4. any project, hidden
- Exactly one candidate at the winning tier is used without prompting.
- **BREAKING** (internal): commands that took a project root and looked it
  up in the registry now operate on a resolved buffer instead.

Out of scope: the popup output window; opencode.

## Capabilities

### New Capabilities
- `runner-session-resolution`: Determining which live Claude runner
  session receives sent keys/text, derived from live buffers and window
  visibility rather than a stored registry, with a picker for ambiguity.

### Modified Capabilities
- `runner-send-prompt`: send commands now target a *resolved* session
  (visibility + project aware, with a picker) instead of the current
  project's single registry entry.
- `claude-runner`: multiple sessions per project (numbered buffer names);
  session lifecycle no longer maintains a root→buffer registry; liveness is
  read from the `*claude:*` buffers directly; `mcp-emacs-run` replaced by
  `mcp-emacs-run-new`.

## Impact

- `elisp/mcp-emacs-run.el`: remove the registry defvar and helpers; change
  `--buffer-name` to include a per-project number and add next-number
  allocation; add `mcp-emacs-run--resolve-session` (and a
  candidate-collecting helper); rewrite `--send`, `--launch`, `-start`,
  `-toggle`, `-switch`, `-list`, `-kill`; drop `mcp-emacs-run`, add
  `mcp-emacs-run-new`.
- Keybinding: `SPC E e` (currently `mcp-emacs-run`) rebinds to
  `mcp-emacs-run-new` — lives in the Doom config, tracked separately.
- `test/mcp-emacs-run-test.el`: buffer-name test updated for the number;
  resolution-tier tests; remove registry-specific tests.
- Behavior: sending text works after a reload/restart as long as a
  `*claude:*` buffer is alive; multiple same-project sessions prompt.
