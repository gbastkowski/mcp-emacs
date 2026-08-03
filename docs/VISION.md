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
  advanced in place, so intent and implementation stay wired together.

## What this is (and isn't)

This is a **direction, not a destination**. We don't yet know exactly what the
end state looks like, and that's fine — the point is to keep choosing, feature
by feature, the option that:

- shrinks the *type → wait → check → alter → repeat* cycle, and
- pushes the human and the AI toward acting on the **same live state**
  concurrently, with the human still in the driver's seat.

When a design decision is ambiguous, that bias is the tie-breaker.
