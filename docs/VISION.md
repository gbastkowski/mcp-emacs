# Vision

## Where we want to move

The goal of mcp-emacs is to move software development **away from the chatbot
style** and toward a **highly dynamic, AI-driven development environment**.

The chatbot loop is: you type a request, you wait, you read the answer, you
check it against reality, you alter your prompt, and you do it again. The
editor is a bystander — a place you paste results back into. The AI never
actually *inhabits* your workspace; it only ever sees the snapshots you hand it,
and you are the courier between the two.

We want the opposite: the AI and the human working the **same live artifacts at
the same time**, each able to see and act on the real, current state of the
project — buffers, the file being looked at, diagnostics, the running process,
the Org plan — without a round-trip through a chat transcript.

## Why Emacs

Emacs is unusually well suited as the substrate for this experiment because it
is a *live, programmable, introspectable* workspace rather than a text box
bolted onto an editor:

- It exposes real session state — what buffer is open, where the cursor is, what
  the checker is complaining about, what the project root is — and it can be
  driven programmatically while a human is also using it.
- It is one address space. A change the AI makes and a change the human makes
  land in the same place, immediately, without a sync step.
- It is endlessly extensible in the same language it is written in, so a new
  interaction style can be prototyped as a few functions rather than a new app.

That makes Emacs a good laboratory for trying out software-engineering styles
that don't fit the request/response mould.

## The through-line

The features already in this repo are early moves in this direction, not a
finished picture:

- **Org task session sync** — the AI and the human share one Org file as a live
  workspace: the AI reports status into it while the human edits the same file,
  and the AI can *wait* for the human's next edit instead of only seeing changes
  when it happens to re-read.
- **An interactive (not headless) AI runner** — driving the assistant inside the
  live editor session, so it operates on real state rather than a detached copy.
- **orgspec** — a spec that lives in the workspace next to the code, folded and
  advanced in place, so intent and implementation stay wired together. It is
  built out: propose → apply → review → validate → archive, driven by slash
  commands and typed MCP tools, with an agenda view of in-flight requirements.
  It was designed by dogfooding itself — its own feature changes were proposed,
  validated, and archived through the running Emacs. (See
  [`orgspec-vs-openspec.md`](orgspec-vs-openspec.md) for how it compares to the
  OpenSpec workflow it ports.)

## What this is (and isn't)

This is a **direction, not a destination**. We don't yet know exactly what the
end state looks like, and that's fine — the point is to keep choosing, feature
by feature, the option that:

- shrinks the *type → wait → check → alter → repeat* cycle, and
- pushes the human and the AI toward acting on the **same live state**
  concurrently, with the human still in the driver's seat.

When a design decision is ambiguous, that bias is the tie-breaker.

## A sketch: the workflow as an event stream

*(Exploratory design, not a committed plan. It names a direction and a domain
vocabulary so the next few features can be chosen coherently.)*

The chatbot loop is fundamentally **request/response**: a turn is a closed
transaction — you speak, it locks, it answers, it unlocks. "Add a thought at any
time" has no place in that model, because there is no *any time*; there is only
"your turn" and "its turn."

An **event stream** has no turns. There is an append-only log of events, and
both the human and the AI *produce* to it and *react* from it. The log is itself
a live artifact you can look at. That is the same "same live state,
concurrently" idea from the vision above, made temporal.

### Domain model (DDD)

The useful surprise is that the aggregates are not records we would invent —
**they are the live Emacs artifacts we already have**, and the state lives in
them, not in a struct beside them:

| Bounded context | Aggregate (its store) | Identity | Transitions (today) |
|---|---|---|---|
| Session (org-task) | the live Org subtree | `SESSION` property | `org_task_set_session_status` / `set_item_status` / `append_note` / `append_item` |
| Spec (orgspec) | `Change` → `Requirement` → `Scenario` | headline text | `orgspec-lifecycle-advance` (active/blocked/removed/done), `orgspec-archive` (fold) |
| Runner | the `eat` terminal buffer | `*claude:<project>:<n>*` | `run-new` / `continue` / `resume` / `kill` / `quit` |
| Review | the `(list nil)` result cell | ediff tab name | accept / reject / timeout, resolved once in `ediff-quit-hook` |

The **domain events** these already emit (or could, trivially): `NoteAdded`,
`SessionStatusChanged`, `ItemStatusChanged`, `RequirementAdvanced`,
`ChangeProposed`, `FoldArchived`, `RunnerStarted`/`RunnerQuit`,
`DiffOpened`/`DiffResolved`, and the two that come from *either* actor —
`FileChanged` and `ToolInvoked`. Org TODO keywords are already the shared
state-transition **vocabulary** across the Session and Spec contexts.

![Domain map — contexts, aggregates, and the shared event log](event-model.png)

### What already exists, and the gap

We have the pieces, siloed and each reinventing the wait/wake:

- **An event feed already exists.** `mcp-emacs-remote` advises the IDE surface
  and appends tool calls, diff outcomes, and session start/end into a per-project
  Org transcript. It is append-only — but *write-only*: nothing reads it back.
- **A wait/wake primitive already exists.** `org_task_wait_for_change` blocks on
  a monotonic `buffer-chars-modified-tick` token via an `accept-process-output`
  poll — i.e. `on(change)` without freezing Emacs.
- **A one-shot resolve primitive already exists.** The diff review's `(list nil)`
  result cell plus a single-fire `ediff-quit-hook` is a promise/resolve.

The gap is that the feed is **one-directional** and the aggregates each **poll
their own thing**. Turning this into an event system is mostly *unifying what
exists*: make the transcript a first-class log with **subscribers**, and let the
AI be one reactor among several (lint, agenda refresh, and the human's rendered
transcript being others).

![The cooperative loop as an event stream, and the mid-flight note it exists for](event-loop.png)

### The hard questions (the actual content of the design)

1. **Interruption semantics.** A `NoteAdded` arrives while the AI is mid
   tool-call. Finish, abort, or re-plan? Request/response dodges this; an event
   model must answer it. This is *the* design question.
2. **Ordering / consistency.** Two writers on one file makes `FileChanged`
   ordering a merge problem — the same concern deferred for the agent backends.
3. **Backpressure.** Several notes in quick succession while the AI is slow —
   queue, coalesce, or latest-wins?

### Smallest first step

Don't refactor everything onto a bus. Make the `mcp-emacs-remote` transcript a
readable log with one subscriber, and wire the single path that most *is* the
vision — "add a note at any time" — reusing the tick-token wait. If that cleanly
subsumes the hand-rolled org-task loop, the abstraction is right. Then settle the
interruption rule before going wider.
