## Context

`mcp-emacs-run--launch` currently does three things unconditionally: create the eat buffer, register it in `mcp-emacs-run--sessions`, and call `mcp-emacs-run--display` to show it in a side window (moving focus per `mcp-emacs-run-focus-on-show`).
Display is baked into the launch path, so there is no way to bring up a session that runs but stays hidden.
The reveal machinery already exists: `mcp-emacs-run-toggle` and `mcp-emacs-run-switch` display any registered live buffer, and both already handle the "buffer exists, no window" case.

## Goals / Non-Goals

**Goals:**
- Start a project's session with the CLI running and registered, but no window shown and no focus change.
- Reuse the existing session-reuse and reveal paths unchanged — a headless session is an ordinary session that simply wasn't displayed yet.

**Non-Goals:**
- No change to the default `mcp-emacs-run` behavior (still displays).
- No new "hide without killing" beyond what `-toggle` already does.
- No headless variants of continue/resume for now (can follow if wanted).

## Decisions

- **Make display optional in the launch helper.** Add an optional `no-display` parameter to `mcp-emacs-run--launch`; when non-nil it skips `mcp-emacs-run--display` but still registers the session and returns the buffer. `extra-switches` stays a trailing rest arg — reorder to `(root no-display &rest extra-switches)` and update the two existing callers to pass `nil` for `no-display`.
- **New command `mcp-emacs-run-start`.** Mirrors `mcp-emacs-run`'s reuse check (reuse a live session without displaying), otherwise launches headless. Autoloaded and interactive like the other commands.
- **Reveal is unchanged.** `-toggle`/`-switch` already display a registered-but-hidden buffer, so a headless session reveals with no new code.

## Risks / Trade-offs

- Reordering `mcp-emacs-run--launch`'s signature touches its two callers; internal helper, so no external contract broken. Covered by updating both callers in the same change.
- A headless session gives no visible feedback on start; mitigate with a `message` naming the project and noting it started hidden.
