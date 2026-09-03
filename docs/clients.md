# Agent clients and runners

Four ways to run a coding agent from inside Emacs. They share one event
vocabulary and one keymap, so which one is driving is mostly an implementation
detail from the user's side.

| Surface | File | What it is |
|---|---|---|
| Claude client | `elisp/claude-client.el` | Terminal-free Claude Code: headless CLI, rendered into a normal buffer |
| opencode client | `elisp/opencode-client.el` | Native client for [opencode](https://opencode.ai)'s local HTTP API |
| Claude runner | `elisp/mcp-emacs-run.el` | The Claude Code TUI in an `eat` terminal buffer |
| IDE + remote | `elisp/mcp-emacs-ide.el`, `-remote.el` | Diff review for Claude's native edits, plus an Org transcript |

The shared layer under the two conversation clients is
[`elisp/agent-backend.el`](#shared-agent-backend), and
[`agent-session-overview.el`](#session-overview) lists what every backend is
doing in one buffer.

## Session overview

`elisp/agent-session-overview.el` lists every live AI session — across all
backends — in one `*ai-sessions*` buffer, and keeps it current.

Without it, each backend answers only for itself and only when asked:
`claude-client-list` and `mcp-emacs-run-list` print their own sessions into the
echo area, which is stale the moment it appears. With several conversations per
project and several projects open, that stops scaling.

```
M-x agent-session-overview
```

| Column | |
|---|---|
| Backend | `claude`, `eat`, or `opencode` |
| Project | from the buffer name, or its `default-directory` for opencode |
| Session | project:number, or the title for opencode |
| State | see below |

Keys: `RET` visit, `k` quit the session, `i` interrupt its turn, `g` refresh,
`?` help, `q` bury. Quitting is **not** confirmed, including mid-turn — the
overview is where you go to stop things.

The mode line carries the key names so they are always in view, and `?` opens a
fuller help buffer that also explains the state column. Both are generated from
one list of bindings, so a new action cannot be documented in one place and
missing from the other.

Under evil, the single-letter keys are re-registered in normal and motion states
(they would otherwise be shadowed — `?` searches backward, `k` moves up). `g`
and `q` are left alone: `g r` reverts, as elsewhere in evil.

**State is only as precise as the backend allows.** `claude-client` publishes
turn events and tracks a turn flag, so its rows read `working` / `idle` /
`finished`. The eat runner is a TUI with no turn events, and opencode keeps no
per-buffer turn state and never publishes a turn-end event, so both report
`live` / `dead` only. Working/idle is deliberately *not* inferred from terminal
output activity: that would misreport a long model think as idle and a spinner
as work.

Rows update themselves off `agent-backend-event-functions`. The subscriber
swallows its own errors, so a rendering failure cannot propagate back into the
session that published the event.

Enumeration is a `buffer-list` scan against each backend's buffer-name pattern —
there is no session registry, by choice.

## Claude client (terminal-free)

`elisp/claude-client.el` drives Claude Code without a terminal emulator: it
spawns the CLI headless (`--output-format stream-json`), parses the NDJSON
stream, and renders the conversation into an ordinary `special-mode` buffer.
No `eat`, no TUI.

**How edits are gated.** Claude's own mutating tools are disabled with
`--disallowedTools`, and the mcp-emacs server is passed via `--mcp-config`. A
write can therefore only happen by calling `mcp__emacs__apply_diff` — which
opens an ediff you answer. (The CLI's `can_use_tool` control request is *not*
used: it is never emitted in headless mode.)

Conversations are per project, one buffer and one subprocess each, named
`*claude-client:<project>:<n>*`. Several can run at once, in one project or
across several. Turns are multi-turn over a single subprocess, so the session id
and its context carry across turns.

- `M-x claude-client-start` — open a conversation (prompts for the first prompt).
- `M-x claude-client-resume` — reopen a past session. It reads the same on-disk
  session store the terminal runner's picker uses, so a session started in
  either runner continues in the other. Only the model's context comes back —
  the rendered log lives in the buffer, not on disk.
- `M-x claude-client-list` / `-switch` / `-toggle` / `-quit` — manage conversations.

In the conversation buffer: `s` send, `i` interrupt, `n` add note, `r` resume,
`g` start, `k` quit, `TAB` expand the tool result under point.

**Appearance.** The buffer separates what the harness did from what the model
said. Structural chrome — the session banner, prompts, tool calls and their
answers, notes, the turn-end marker — carries its own faces
(`claude-client-banner-face` and friends, all customizable). The model's own
prose is fontified as markdown, which is what it emits: headings, emphasis,
inline code and fenced code blocks all render, the last with native
per-language highlighting.

Fontification happens in an off-screen scratch buffer whose text properties are
copied in, so no markdown mode is ever active in the conversation buffer and
its single-letter keys keep working. `markdown-mode` is a soft dependency:
without it prose renders as plain text and the chrome faces still apply.

Tool results are bounded to `claude-client-tool-result-lines` (default 6),
because a `git diff` or a whole-file `Read` otherwise dumps its entire payload
and buries the prose — which defeats facing the two separately. Tool *input*
has always been bounded the same way, to one 60-column line. The elision says
how many lines it hid, and `TAB` on the result shows it in full (`TAB` again
re-collapses); nothing is discarded, since the full text stays in the event log.
Lines that are a bare field label with no value — the dozen `labels:` /
`assignees:` rows `gh issue view` answers with — are dropped outright. Set the
option to `nil` to show every line.

**Notes.** A note written mid-turn abandons that turn immediately and is
delivered as the next one (`claude-client-note-interrupts`, on by default); with
it off, notes queue instead. `claude-client-max-pending-notes` (default 20)
bounds the queue, dropping oldest first.

Key options: `claude-client-executable`, `-model`, `-mcp-config`,
`-disallowed-tools`, `-allowed-mcp-tools`, `-system-prompt`,
`-window-direction` (default `right`), `-window-width` / `-height`,
`-focus-on-show`, `-restore-window-after-review`,
`-tool-result-lines` (default 6).

## opencode client

`elisp/opencode-client.el` is a native Emacs client for
[opencode](https://opencode.ai)'s local HTTP API. opencode runs headless
(`opencode serve`); the client drives it over HTTP and renders the conversation
incrementally from the server's Server-Sent Events stream into an ordinary Emacs
buffer, instead of embedding the opencode TUI in a terminal. Editor-tool
integration is provided to opencode through the `emacs` MCP server (wired via
`opencode.json`), so the client does not reimplement editor tools.

It requires the [`plz`](https://github.com/alphapapa/plz.el) package, loaded as
an optional dependency — installing `mcp-emacs` does not pull it in, and client
commands report clearly if it is missing.

One opencode server runs **per project**, each on its own free port (probing
upward from `opencode-client-port`, default 4096). `opencode-client-serve`
starts the server for the current `default-directory` and registers it, so
several projects can run opencode sessions in parallel without colliding on a
fixed address — switch projects and each keeps its own session list.

Configure `opencode-client-host`, `-port`, and optional `-password`, then:

- `M-x opencode-client-connect` — verify a running server (or
  `opencode-client-serve` to start one).
- `M-x opencode-client-create-session` / `-switch-session` — manage sessions.
  Opening a session loads and renders its prior history before streaming, so
  reconnecting to a persistent server shows the existing conversation.
- In the chat buffer: `C-c C-c` to send a prompt (prefix arg steers a running
  turn), `C-c C-k` to interrupt. Permission and question requests are answered
  from Emacs.

The password may be resolved from a secret store instead of set directly: leave
`opencode-client-password` nil and set `opencode-client-password-command` to a
shell command (for example `pass show private/opencode/server-password`); its
trimmed output is used for HTTP basic auth.

To keep sessions alive across Emacs restarts, run the server independently of
Emacs. On macOS, define an on-demand launchd user agent for `opencode serve`
(loaded at login but not started) and set `opencode-client-launchd-label` to its
label; `opencode-client-serve` then starts it with `launchctl kickstart` so the
server is owned by launchd and outlives Emacs, rather than as a child process.

## Claude runner (terminal)

`elisp/mcp-emacs-run.el` runs the Claude Code CLI inside Emacs. The CLI is a
full-screen TUI, so it runs in an [`eat`](https://codeberg.org/akib/emacs-eat)
terminal buffer (eat is an optional dependency, loaded only when present). The
runner is project-aware, keeps one primary session per project, and displays its
terminal in an ordinary window placed in a configurable direction
(`mcp-emacs-run-window-direction`, default `right`) rather than a dedicated side
window, so the window stays splittable and closable. Editor-tool integration is
provided to the CLI through the `mcp-emacs` MCP server via your own MCP
configuration (e.g. `.mcp.json`); the runner only launches and places the
terminal.

Configure `mcp-emacs-run-executable` and `-flags`, then:

- `M-x mcp-emacs-run` — start (or switch to) the runner for the current project.
- `M-x mcp-emacs-run-start` — start the runner hidden (no window, no focus);
  reveal it later with `-toggle` or `-switch`.
- `M-x mcp-emacs-run-continue` / `-resume` — pick up a prior conversation
  (`-resume` uses the CLI's own in-terminal picker).
- `M-x mcp-emacs-run-resume-select` — pick a past session from a native Emacs
  `completing-read` (most recent first, labelled with a relative time and the
  first real prompt) and resume it with `--resume <id>`. Reads the store under
  `mcp-emacs-run-resume-projects-root` (default `~/.claude/projects`).
- `M-x mcp-emacs-run-toggle` — show/hide the runner window.
- `M-x mcp-emacs-run-list` / `-switch` / `-kill` — manage sessions.
- `M-x mcp-emacs-run-quit` — gracefully quit a session: sends the CLI quit
  (Ctrl-C twice), then force-kills the process and removes the buffer if it has
  not exited within `mcp-emacs-run-quit-timeout` seconds (default 10). Unlike
  `-kill`, it lets the CLI shut down cleanly first.

Drive a running session from anywhere in Emacs (these require a live session and
never launch one):

- `M-x mcp-emacs-run-send-prompt` — send a prompt to the session and submit it.
- `M-x mcp-emacs-run-send-escape` / `-send-newline` — send an interrupt, or a
  newline without submitting.
- `M-x mcp-emacs-run-send-return` — send a bare carriage return (accept a
  default / submit).
- `M-x mcp-emacs-run-send-1` / `-send-2` / `-send-3` — answer Claude's numbered
  menus.
- `M-x mcp-emacs-run-send-shift-tab` — cycle Claude's mode.
- `M-x mcp-emacs-run-send-up` / `-send-down` — arrow keys for history/menu
  navigation.
- `M-x mcp-emacs-explain-selection-in-current-session` — explain the region (or
  line at point). When the session buffer is visible in a window, the request is
  sent to the running TUI as `explain @file:line` (or the selected text for
  non-file buffers). Otherwise — whether the project has a hidden session or
  none at all — the explanation is fetched with a one-shot headless CLI call
  (`claude -p ... --output-format text`) and rendered in the popup output
  window, so it works without an open session and the answer appears near your
  code.

### Popup output window

Formatted AI output is shown in a popup output window: a dedicated buffer per
kind (e.g. `*mcp-emacs:explain*`) rendered read-only with
[`markdown-mode`](https://github.com/jrblevin/markdown-mode)'s `gfm-view-mode`
and native code-block fontification. `markdown-mode` is an optional dependency,
loaded only when present; the popup commands error with an install hint if it is
missing. The window is an ordinary split placed via
`mcp-emacs-run-popup-direction` (default `below`, size
`mcp-emacs-run-popup-size`) — it does not auto-hide, and you can scroll, select,
and copy from it like any buffer. Re-rendering the same kind reuses its buffer
and window. `mcp-emacs-popup-show` is a reusable primitive other features can
render into.

## IDE integration (native-edit diff review)

`elisp/mcp-emacs-ide.el` makes Emacs act as a Claude Code *IDE* so that Claude
Code's **native** Edit/Write operations are reviewed in an interactive ediff
session before they are written — the same accept/reject flow as `apply_diff`,
but triggered automatically instead of only when the model calls a tool.

This is separate from the HTTP MCP server and is **opt-in and off by default**.
It relies on Claude Code's unofficial, reverse-engineered IDE protocol
(WebSocket, verified against Claude Code 2.1.212), so it can break across Claude
Code releases.

How it works: Emacs runs a WebSocket server and launches Claude Code with
`CLAUDE_CODE_SSE_PORT` and `ENABLE_IDE_INTEGRATION=true` in its environment, so
the CLI connects back and calls Emacs's `openDiff` before each edit. Because the
connection is driven by those launch-time environment variables, **only Claude
Code sessions started by the runner get diff review** — a Claude Code you start
by hand in a plain terminal will not.

To enable:

```elisp
(setq mcp-emacs-ide-enabled t)          ; allow the IDE surface to start
(setq mcp-emacs-run-ide-integration t)  ; make the runner launch Claude against it
```

Requires the [`websocket`](https://github.com/ahyatt/emacs-websocket) package
(loaded lazily; the surface errors with an install hint if it is missing). The
runner starts the IDE server automatically on the next launch and manages its
`~/.claude/ide/<port>.lock` discovery file; you can also drive it directly with
`M-x mcp-emacs-ide-start` / `mcp-emacs-ide-stop`.

On the first launch in a project, Claude Code shows a one-time "do you trust
this folder?" prompt; answer it (press Enter / choose *Yes*) so the CLI proceeds
to connect. Reviewing an edit: `C-c C-c` accepts (Claude Code writes the file),
`C-c C-k` or `q` rejects (the file is left unchanged).

The review captures your window configuration before it opens and restores it
when it ends — however you resolve it — so side windows (Treemacs and the like)
come back and your layout is left unchanged. This applies to both `apply_diff`
and the IDE `openDiff` flow, which share the review. By default the diff uses
ediff's plain full-frame layout; set `mcp-emacs-ediff-window-direction` (to
`right` / `left` / `above` / `below`, mirroring `mcp-emacs-run-window-direction`)
to place it in a predictable spot instead.

If you are migrating from `claude-code-ide.el`, disable it for the workspace
first so only one IDE lockfile is published.

## Remote control (Org transcript)

`mcp-emacs-remote.el` (opt-in) lets you drive the interactive Claude session
from ordinary Emacs input and watch its tool activity as a live Org
transcript — without reading the terminal.

- **Prompt input** — `mcp-emacs-remote-prompt` reads a prompt from the
  minibuffer (seeded from the active region when one is set) and sends it to the
  current project's running session; `mcp-emacs-remote-prompt-buffer` sends the
  whole current buffer. Both auto-submit via `mcp-emacs-run-send-prompt` and
  require a live session (they never launch one). Empty or whitespace-only input
  is not sent.
- **Org transcript** — a per-session `*claude: <project>*` Org buffer records
  the session's tool activity: one heading per tool call with its arguments, the
  accept/reject outcome of each `openDiff`, and a run-metadata drawer.
  `getDiagnostics` / `closeAllDiffTabs` are recorded compactly to keep the
  transcript readable.

Enable with `M-x mcp-emacs-remote-enable` (or set `mcp-emacs-remote-enabled`);
the transcript tap on the IDE surface is a no-op while disabled. Recording is
passive — it never changes whether or how a tool call is approved or executed,
and a rendering error cannot stall an edit.

Tool **approval** is not part of this surface: native Edit/Write flow through the
IDE surface's ediff review (above), which is the per-call gate. This is why the
session runs interactively rather than headless — `claude -p` cannot route
per-call approval to Emacs (the `--permission-prompt-tool` flag was removed in
Claude Code 2.1.212). Because the IDE socket carries structured tool calls but
not assistant prose, the transcript records tool activity only in this version; a
full-prose transcript is a tracked follow-up (see
[#23](https://github.com/gbastkowski/mcp-emacs/issues/23)).

## Shared agent-backend

`elisp/agent-backend.el` is the shared layer behind the two conversation
backends ([#41](https://github.com/gbastkowski/mcp-emacs/issues/41)). Both
`opencode-client.el` and `claude-client.el` subclass its EIEIO base class
`agent-backend`, so the backends are interchangeable from the user's point of
view: the same keybindings, the same event consumers, and the same Org
transcript work regardless of which backend is driving the session.

**The interface.** The base class declares a `cl-defgeneric` lifecycle
interface — `agent-backend-connect`, `-quit`, `-send`, `-interrupt`,
`-add-note`, `-note-policy`, `-reply-permission`, `-reply-question`,
`-list-sessions`, `-resume`, `-seed-history`, `-project-root`, `-render`, and
`-mention`. The optional capabilities (permission/question replies, sessions,
resume, history seeding, project root, render, mention) have no-op,
`user-error` or delegating defaults on the base class, so a minimal backend
implements only connect, quit, send, interrupt, add-note, and note-policy and
compiles without stubs.

**Sharing what you are looking at.** `M-x agent-backend-mention-selection`, run
from a *code* buffer, hands the active region (or the line at point) to
whichever conversation is live — previously an eat-runner-only verb
([#56](https://github.com/gbastkowski/mcp-emacs/issues/56)). What gets sent is
a project-relative pointer, `@elisp/foo.el:12-40`, not the text: the agent can
read the file itself, and a pointer stays right as the code moves on. Buffers
with no file send their text instead, since there is nothing to point at.

The target is resolved in tiers — same project and visible, same project
hidden, any project visible, any project hidden — and you are asked only when
the winning tier is ambiguous. Conversations are found by scanning for a
buffer-local backend instance, so there is no registry and a new client is
found for free.

A mention is deliberately **not** a turn. `agent-backend-mention` defaults to
routing through `agent-backend-add-note`, which already means "the human said
this, deliver it with the next turn". Claude overrides it, because both of its
note paths are wrong here: mid-turn a note abandons the turn in flight, and
with nothing running a note drains *immediately* — which would submit the
mention as a turn of its own. So Claude queues the mention and logs it as
pending, and the next prompt you send carries it along.

**The event vocabulary.** Every conversation event is published as a plist with
a `:kind` symbol on the abnormal hook `agent-backend-event-functions`, run with
(BUFFER EVENT). The shared kinds are `started`, `prompt`, `text`, `tool-use`,
`tool-result`, `finished`, `interrupted`, `note`, `notes-delivered`,
`note-dropped`, `resumed`, `permission-request`, `question-request`, and
`error`. Subscribers must ignore unknown kinds, so a new kind degrades to
silence rather than breaking a reader. This is what lets the remote Org
transcript record both opencode and Claude sessions through one subscriber.

**The mode.** `agent-backend-mode` derives from `special-mode` and binds the
common actions in a shared keymap (`C-c C-s` send, `C-c C-i` interrupt, `C-c
C-n` add-note, `C-c C-q` quit, `C-c C-r` resume); each backend's major mode
derives from it and layers its own keys on top.

**Note policy.** `agent-backend-note-policy` names how a human note written
mid-turn reaches the model. opencode notes ARE steering prompts (`:steer`),
delivered immediately via its HTTP API; Claude keeps its native
interrupt-or-queue machinery (`:interrupt` when `claude-client-note-interrupts`
is on, `:queue` when off).
