## 1. Store location

- [ ] 1.1 Add `mcp-emacs-run-projects-directory` defcustom (default `~/.claude/projects`).
- [ ] 1.2 Add `mcp-emacs-run--session-slug (root)`: absolute root path with `/` and `.` replaced by `-`.
- [ ] 1.3 Add `mcp-emacs-run--session-store-dir (root)`: slug under the projects directory.

## 2. Enumerate + preview

- [ ] 2.1 Add `mcp-emacs-run--session-files (root)`: `*.jsonl` in the store dir with mtimes, sorted most-recent first; empty when the dir is missing.
- [ ] 2.2 Add `mcp-emacs-run-session-preview-bytes` defcustom (head-window size) and `mcp-emacs-run--session-preview (file)`: read only the head, scan lines, JSON-parse, return the first genuine user prompt.
- [ ] 2.3 Normalise `message.content` (string, or first text block of an array); skip empty, `<local-command-*>`, `<command-*>`, and non-textual content; collapse whitespace and truncate.
- [ ] 2.4 Fall back to the session id when no genuine prompt is found in the head window.

## 3. Command

- [ ] 3.1 Add `mcp-emacs-run-resume-select`: build labelled candidates (`<relative-time>  <preview>`) from `--session-files`, `completing-read`, map back to session id, launch `(mcp-emacs-run--launch root nil "--resume" id)`; autoload cookie.
- [ ] 3.2 `user-error` "No past sessions for this project" when there are none; launch nothing.

## 4. Tests

- [ ] 4.1 Slug builder: a path with `/` (and, if applicable, `.`) maps to the expected dir name.
- [ ] 4.2 Preview extractor: first-line genuine prompt -> that prompt.
- [ ] 4.3 Preview extractor: leading `<local-command-caveat>` / `<command-name>` lines skipped, later real prompt used.
- [ ] 4.4 Preview extractor: array-shaped `message.content` -> first text block.
- [ ] 4.5 Preview extractor: no genuine prompt in head window -> session id fallback.
- [ ] 4.6 Enumeration ordering: files returned most-recent first (construct temp files with differing mtimes).
- [ ] 4.7 Empty/missing store -> `--session-files` returns nil (and the command would `user-error`).

## 5. Docs & checks

- [ ] 5.1 README runner section: document `mcp-emacs-run-resume-select` alongside `-resume`.
- [ ] 5.2 Byte-compile clean; all tests pass.
- [ ] 5.3 Verify live in the running Emacs: picker lists this project's sessions with sensible labels and resumes the chosen one.
