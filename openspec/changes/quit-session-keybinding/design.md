## Context

`mcp-emacs-run-kill` (in `elisp/mcp-emacs-run.el`) already ends a session
by `delete-process` + `kill-buffer`, targeting the current project's
sessions with a picker. Sends resolve their target via
`mcp-emacs-run--resolve-session` (visibility + project tiers, picker on
ambiguity) and deliver keystrokes with `mcp-emacs-run--send-to-buffer`.
The runner terminal is an `eat` buffer; its process is
`(get-buffer-process buf)`.

The new quit differs from kill only by attempting a clean CLI shutdown
first: send Ctrl-C twice, then force-kill + remove buffer if the CLI has
not exited within a timeout.

## Goals / Non-Goals

**Goals:**
- `mcp-emacs-run-quit` resolves like sends and sends `\003\003`.
- Non-blocking wait; force-kill the process if still live after
  `mcp-emacs-run-quit-timeout` seconds (default 10).
- Remove the session buffer whether the CLI exited on its own or was
  force-killed; tolerate an already-killed buffer.

**Non-Goals:**
- Changing or removing `mcp-emacs-run-kill`.
- Confirmation prompts (quit is deliberate; resolution already prompts on
  ambiguity).

## Decisions

### Command and resolution

`mcp-emacs-run-quit` calls `mcp-emacs-run--resolve-session` (same as
sends), so it prompts once when the winning tier is ambiguous and errors
when no session exists. This is intentionally broader than
`mcp-emacs-run-kill`'s current-project scope, matching the user's "resolve
like sends".

### Quit sequence

Send two Ctrl-C characters (`"\003\003"`) via `--send-to-buffer` — the
Claude CLI exits on a double interrupt. Kept as a `defconst` so it can be
adjusted without touching logic.

### Non-blocking timeout + buffer removal

```elisp
(defcustom mcp-emacs-run-quit-timeout 10 ...)

(defun mcp-emacs-run-quit ()
  (interactive)
  (let ((buf (mcp-emacs-run--resolve-session)))
    (mcp-emacs-run--send-to-buffer buf mcp-emacs-run--quit-sequence)
    (run-with-timer
     mcp-emacs-run-quit-timeout nil
     (lambda ()
       (when (buffer-live-p buf)
         (when-let ((proc (get-buffer-process buf)))
           (ignore-errors (delete-process proc)))
         (kill-buffer buf))))))
```

The timer captures `buf` in a closure (lexical binding is already on). If
the CLI exits on its own, `eat` may or may not auto-kill the buffer; the
handler kills it if still live, and the `buffer-live-p` guard makes an
already-gone buffer a no-op. If the process is still live it is
force-killed first, then the buffer removed. Nothing blocks Emacs in the
meantime.

## Risks / Trade-offs

- **eat buffer survival on clean exit**: whether `eat` kills the buffer on
  process exit is version-dependent; killing it unconditionally in the
  handler guarantees the "no buffer" end state either way.
- **Timer fires after manual cleanup**: if the user kills the buffer
  before the timer, the `buffer-live-p` guard prevents an error.
- **Broader target than kill**: quit may reach another project's visible
  session (via the cross-project tiers). This is the requested
  "resolve like sends" behavior and is guarded by the picker.

## Open Questions

- None blocking. The 10s default is a `defcustom` and easily tuned.
