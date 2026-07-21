## Why

The intended opencode workflow is a long-lived server whose sessions survive Emacs restarts. `opencode-client-serve` currently starts the server with `start-process`, making it a child of Emacs — so it dies when Emacs exits, taking the sessions with it. On macOS the natural way to run an on-demand, Emacs-independent server is a launchd user agent that Emacs starts by kickstarting it, not by spawning a child. That server should also be password-protected, with the password resolved the same way the rest of the setup resolves secrets (via a command such as `pass`).

## What Changes

- Add `opencode-client-launchd-label`: when set, `opencode-client-serve` starts the server by `launchctl kickstart gui/<uid>/<label>` (launchd owns the process, so it outlives Emacs) instead of spawning a child; when unset, it falls back to the current `start-process` behavior.
- Add `opencode-client-password-command`: a shell command whose stdout (trimmed) is used as the server password when `opencode-client-password` is not set directly, so the password can come from `pass` or similar.
- Resolve the password through a single helper used by request headers.

## Capabilities

### New Capabilities

### Modified Capabilities
- `opencode-client`: the connection requirement gains a launchd-kickstart start mode and command-based password resolution.

## Impact

- `elisp/opencode-client.el` — password resolver, `opencode-client-password-command`, `opencode-client-launchd-label`, kickstart path in `opencode-client-serve`.
- Tests: password resolution precedence; kickstart command construction.
- Follow-up (separate, in dotfiles): a home-manager `launchd.agents` entry, loaded but not run at login, that Emacs kickstarts.
