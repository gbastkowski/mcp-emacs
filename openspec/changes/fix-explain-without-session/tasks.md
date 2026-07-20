## 1. Fix explain routing

- [x] 1.1 Remove the top-level `unless live-buffer -> user-error` guard in `mcp-emacs-explain-selection-in-current-session`.
- [x] 1.2 Keep routing: session buffer visible → TUI send; otherwise → "Working…" popup + headless query → render.
- [x] 1.3 Update the docstring to reflect that no session is required.

## 2. Verify

- [x] 2.1 Byte-compile cleanly.
- [x] 2.2 Update the routing test: no live session now routes to popup + headless (not user-error). Keep visible → TUI and hidden → popup cases.
- [x] 2.3 Update README explain description to say it works without a session.
