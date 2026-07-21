## Context

`opencode-client--headers` reads `opencode-client-password` directly. `opencode-client-serve` spawns the server with `start-process` (child of Emacs → dies with Emacs). Auth on this box is file-based (`~/.local/share/opencode/auth.json`), so the server needs no provider keys in its environment; only the HTTP basic-auth password matters here. Secrets in the user's setup are resolved via `pass`.

## Goals / Non-Goals

**Goals:**
- Password can be resolved from a command (e.g. `pass show …`).
- `serve` can start a launchd-owned server that outlives Emacs.

**Non-Goals:**
- No launchd agent definition here (that lives in dotfiles/home-manager).
- No change to session/stream logic.
- No caching of the resolved password (resolve per request; simple and correct).

## Decisions

### Decision: single password resolver
Add `opencode-client--password`: return `opencode-client-password` when non-nil; else, when `opencode-client-password-command` is set, run it via the shell and return the trimmed stdout; else nil. `--headers` calls this. Resolving per request is fine — requests are user-paced, `pass` is fast, and it avoids a stale cached secret.

### Decision: kickstart when a label is set
`opencode-client-serve`: if `opencode-client-launchd-label` is non-nil, run `launchctl kickstart gui/<uid>/<label>` (uid from `(user-uid)`), then health-poll as today. Kickstart starts (or restarts) the agent under launchd, not as an Emacs child. If the label is nil, keep the existing `start-process` fallback so non-launchd users are unaffected.
- **Alternative:** always launchd — rejected; keep the child-spawn fallback for portability.
- Note: `launchctl kickstart` requires the agent to be loaded (home-manager loads it at login). If it is not loaded, kickstart fails; the health-poll then reports the server did not come up, which is an acceptable clear error.

## Risks / Trade-offs

- [Password command failure] → if the command errors or returns empty, treat as no password (no auth header); the request then fails against a password-protected server with the existing clear error. Acceptable; surfaced to the user.
- [Label set but agent not loaded] → kickstart errors; health-poll times out with the existing message. Documented.

## Open Questions

- Exact launchd label string is a dotfiles concern; the Emacs side takes it as configuration, so it is not hardcoded here.
