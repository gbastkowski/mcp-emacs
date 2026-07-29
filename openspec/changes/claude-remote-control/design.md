## Context

See proposal.md — Why. The native-edit diff-review change (#20) already stands up an interactive
Claude Code session launched from Emacs (`mcp-emacs-run.el`), connected over WebSocket to the IDE
surface (`mcp-emacs-ide.el`), with an ediff gate on every native edit. The relevant existing seams:

- `mcp-emacs-run-send-prompt` delivers text to the current project's runner session (eat buffer).
- `mcp-emacs-run--resolve-session` resolves the target session for the current project, prompting
  when there is more than one candidate.
- `mcp-emacs-ide--call-tool` is the single dispatch point for every `tools/call` the session makes
  (`openDiff`, `getDiagnostics`, `closeAllDiffTabs`).
- `mcp-emacs-ide--complete-open-diff` is where an `openDiff` review resolves to FILE_SAVED
  (accepted) or DIFF_REJECTED (rejected).
- The IDE `ide_connected` notification and the WebSocket close callback bracket a session's life.

The constraint that shapes everything: **the IDE WebSocket socket carries structured tool calls but
not assistant prose.** Prose is rendered by Claude directly to its eat terminal. So a transcript
built from IDE-surface events can be faithful about *tool activity* but cannot show prose without a
second event source.

## Goals / Non-Goals

**Goals:**

- Drive the interactive session from minibuffer / region / buffer input, reusing the runner's
  existing send + session-resolution paths.
- Render tool activity + run metadata into a per-session Org buffer, driven only by events the IDE
  surface already receives.
- Keep the tap strictly passive — it must never change whether or how a tool call is answered.
- Ship behind an opt-in defcustom, matching the IDE surface's opt-in posture.

**Non-Goals (design-level):**

- No new transport, no second Claude process, no headless `-p` path.
- No terminal-scraping to recover prose.
- No change to the IDE surface's protocol behavior, tool set, or the ediff gate.

## Decisions

### 1. Reuse the interactive IDE session; do not run headless `-p`

Claude Code 2.1.212 removed `--permission-prompt-tool`, so headless `-p` cannot route per-call
approval back to an Emacs MCP tool. The interactive IDE session already provides the approval gate
(ediff) for free. **Alternative considered:** a headless `-p --output-format=stream-json` child that
yields a full prose+tools event stream. Rejected for v1 — it reintroduces an approval problem the
IDE session has already solved, and would run a second, differently-gated Claude alongside the
interactive one.

### 2. Tap the IDE dispatch point, don't parse the socket separately

The renderer subscribes at `mcp-emacs-ide--call-tool` (tool calls + arguments) and
`mcp-emacs-ide--complete-open-diff` (accept/reject outcome), plus the connect notification and
socket-close callback for metadata. **Alternative considered:** a second WebSocket observer.
Rejected — it would duplicate framing/parsing and risk diverging from what the surface actually
answered. Tapping the dispatch point sees exactly the events the surface acts on.

The tap is implemented as an advice/hook that is a no-op unless the remote-control feature is
enabled, so the IDE surface's behavior is unchanged when the feature is off.

### 3. Transcript source is tool activity only; prose is deferred

Because the socket carries no prose, v1 records tool activity + metadata and leaves prose in the
TUI. This is stated as an explicit spec requirement (`remote-org-transcript` → "Scope limited to
tool activity") so it is a deliberate contract, not an omission. **Alternative considered:** wire the
Claude Agent SDK (`canUseTool` + stream events) to get prose and gating in one structured stream.
Deferred to a follow-up — it is a larger build and changes the runner's launch model.

### 4. One Org buffer per session, keyed by the session

Each session gets one long-lived `*claude: <project>*` Org buffer; events append to it. Keying by
session (not by project) keeps two sessions for different projects cleanly separated, per the spec.
Rendering appends headings and a properties drawer; it never rewrites earlier entries, so a partial
render can't corrupt history.

### 5. Passive rendering — failures never block the session

Rendering runs after the surface has decided how to answer a call. A rendering error is caught and
logged, never propagated into the tool-call answer path, so a transcript bug cannot stall an edit.
This is the design counterpart to the spec's "Recording does not gate execution" requirement.

## Risks / Trade-offs

- **Prose absent from the transcript** → users must still glance at the TUI for Claude's reasoning
  and text answers. Accepted for v1; the follow-up (Agent SDK / stream-json) is the path to full
  transcripts, and the spec makes the limitation explicit rather than surprising.
- **Tap coupling to IDE internals** (`--call-tool`, `--complete-open-diff`) → if those internals are
  refactored, the tap must move with them. Mitigation: both live in the same repo and module family;
  the tap is a single, named integration point, and the transcript is opt-in so a break degrades an
  optional feature rather than the shipped IDE gate.
- **`getDiagnostics` / `closeAllDiffTabs` noise** → these fire before every edit and would clutter
  the transcript. Mitigation: render them collapsed or suppress them; only `openDiff` and
  substantive calls get prominent entries.

## Open Questions

None that affect the specs, the approach, or the task breakdown. The prose-transcript follow-up is
out of scope by decision, not deferred ambiguity.
