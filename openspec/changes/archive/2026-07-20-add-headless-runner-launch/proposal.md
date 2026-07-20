## Why

The runner always displays the session in a side window on launch.
There is no way to start a project's Claude CLI session in the background — running and reachable, but without stealing a window or focus — to be revealed later when the user wants it.

## What Changes

- Add a command to start a project's runner session headless: the CLI runs in its eat buffer and is registered as the project's session, but no window is displayed and focus does not move.
- Reuse the existing session model: a later toggle/switch reveals the headless buffer exactly as it reveals any other live session, and starting headless when a live session already exists is a no-op reuse (no duplicate).
- Factor the internal launch so displaying the buffer is optional rather than unconditional.

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `claude-runner`: add a requirement for starting a session without displaying its window (headless start), alongside the existing launch/manage/window requirements.

## Impact

- `elisp/mcp-emacs-run.el`: internal launch helper gains an optional no-display path; new headless start command.
- `test/mcp-emacs-run-test.el`: coverage for headless start (buffer registered, no window) and reveal-after.
- No new package dependency. No breaking change to existing commands.
