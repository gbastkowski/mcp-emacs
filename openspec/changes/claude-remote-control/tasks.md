## 1. Module scaffold & opt-in

- [x] 1.1 Add `elisp/mcp-emacs-remote.el` with header, `provide`, and requires (`mcp-emacs-run`, `mcp-emacs-ide`, `org`, `json`, `cl-lib`); byte-compiles clean.
- [x] 1.2 Add a `mcp-emacs-remote-enabled` defcustom (default off), matching the IDE surface's opt-in posture; the event tap is a no-op when disabled.
- [x] 1.3 Lifecycle: `mcp-emacs-remote-enable` / `mcp-emacs-remote-disable` install and remove the event tap idempotently.

## 2. Prompt input (spec: remote-prompt-input)

- [x] 2.1 `mcp-emacs-remote-prompt`: read a prompt from the minibuffer and submit it (auto-submit, session begins responding); empty or whitespace-only input sends nothing and reports "no prompt provided".
- [x] 2.2 When a region is active, pre-fill the minibuffer with the region text so the user edits/confirms before it is sent (not sent raw).
- [x] 2.3 `mcp-emacs-remote-prompt-buffer`: send the whole current buffer as the prompt and submit it; empty/whitespace-only buffer sends nothing and reports "nothing to send".
- [x] 2.4 Deliver the prompt via `mcp-emacs-run-send-prompt` (auto-submits); resolve the target session with `mcp-emacs-run--resolve-session` (prompts on multiple candidates).
- [x] 2.5 Require a live session: if the project has no running session, report it and do not launch one.

## 3. Org transcript buffer (spec: remote-org-transcript)

- [x] 3.1 Per-session transcript buffer keyed by session, named `*claude: <project>*`, created lazily on first recordable event and reused thereafter; distinct sessions get distinct buffers.
- [x] 3.2 Tap `mcp-emacs-ide--call-tool` (behind the enabled flag) to append an Org heading per tool call: tool name, timestamp, and arguments in a readable `#+begin_src json` block.
- [x] 3.3 Collapse or suppress `getDiagnostics` / `closeAllDiffTabs` entries so per-edit noise doesn't dominate the transcript.
- [x] 3.4 Tap `mcp-emacs-ide--complete-open-diff` to record each diff outcome (accepted → FILE_SAVED, rejected → DIFF_REJECTED) with the target file, under the matching tool entry.
- [x] 3.5 Run metadata drawer: on `ide_connected`, record session start + workspace root as Org properties; on socket close, record session end.

## 4. Passive-safety guarantees (spec: remote-org-transcript "does not gate execution")

- [x] 4.1 Rendering runs after the surface has decided how to answer a call; the tap returns control to the surface unchanged (never blocks or alters the answer).
- [x] 4.2 Wrap all rendering in error handling: a rendering failure is caught and logged, never propagated into the tool-call answer path.

## 5. Tests

- [x] 5.1 Prompt input: empty input sends nothing; region pre-fills; no-session case reports and does not launch; multi-session case resolves via the runner's picker (drive commands headlessly as the existing suites do).
- [x] 5.2 Transcript: one buffer per session; a tool call appends a heading with name/timestamp/args; distinct sessions stay isolated.
- [x] 5.3 Diff outcome: accept records FILE_SAVED + file; reject records DIFF_REJECTED + file, under the right entry.
- [x] 5.4 Passive safety: with the tap installed, `openDiff`/`getDiagnostics`/`closeAllDiffTabs` are still answered normally; a forced rendering error does not stall the tool-call answer.
- [x] 5.5 CI byte-compiles the new module and runs the new suite.

## 6. Docs

- [x] 6.1 README: document the remote-control surface, the opt-in defcustom, the `mcp-emacs-remote-prompt` command, and the tool-activity-only transcript scope (prose stays in the TUI).
- [x] 6.2 Note the interactive-vs-headless rationale and the prose-transcript follow-up (link issue #23).

## 7. Verify

- [x] 7.1 Live end-to-end in the running Emacs: enable the feature, launch an IDE session, prompt via `mcp-emacs-remote-prompt`, drive a native edit, confirm the transcript records the tool call + accept/reject outcome + metadata and that approval still runs through the ediff gate.
