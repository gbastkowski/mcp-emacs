## Why

There is a command to hard-kill a runner session (`mcp-emacs-run-kill`,
`SPC E K`) that deletes the process and buffer immediately, but no way to
end a session the way the user normally would — letting the Claude CLI
shut itself down cleanly first. A graceful quit lets the CLI flush and exit
on its own, falling back to a force-kill only if it does not exit in time.

## What Changes

- Add `mcp-emacs-run-quit`: resolve the target runner session (same
  visibility + project tiers as the send commands, prompting on ambiguity),
  send the CLI's quit sequence (Ctrl-C twice, `\003\003`), then after a
  configurable timeout force-kill the process if it is still alive and
  remove the session buffer.
- Add a `mcp-emacs-run-quit-timeout` custom (seconds, default 10) for how
  long to wait for a graceful exit before force-killing.
- Bind the command to a key under the Claude runner leader prefix
  (`SPC E q`) in the Doom config.

The end state matches `mcp-emacs-run-kill` (no process, no buffer); the
difference is the graceful-first step. This change does not alter the
existing hard-kill command.

## Capabilities

### New Capabilities
- `runner-quit-session`: gracefully quit a resolved runner session by
  sending the CLI quit sequence, then force-kill the process and remove the
  buffer if it has not exited within a configurable timeout.

### Modified Capabilities
<!-- none: existing capabilities' requirements are unchanged -->

## Impact

- `elisp/mcp-emacs-run.el`: new `mcp-emacs-run-quit` command, the
  `mcp-emacs-run-quit-timeout` custom, and a small async-quit helper;
  reuses `mcp-emacs-run--resolve-session` and `--send-to-buffer`.
- `test/mcp-emacs-run-test.el`: tests for the quit sequence, the
  force-kill fallback path, and buffer removal.
- Doom config (separate dotfiles repo): a `SPC E q` binding.
- No MCP tool surface change.
