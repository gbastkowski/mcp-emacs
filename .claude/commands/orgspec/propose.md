---
name: "orgspec: Propose"
description: Scaffold a change and draft its full change.org from a description
allowed-tools: mcp__emacs__eval, Read, Edit, Write
category: Workflow
tags: [orgspec, workflow]
---

Start a change end-to-end: scaffold it (`orgspec-new`), then draft the whole `change.org` from the user's description. This is the orgspec equivalent of OpenSpec's `propose` — its four artifacts (propose / tasks / design / spec-delta) collapse into one `change.org`.

**Input**: The argument after `/orgspec:propose` is either a change id (kebab-case) followed by a description, or just a description. If only a description is given, derive a kebab-case id from it (e.g. "notify on account lockout" → `notify-account-lockout`).

**Steps**

1. If no description was given, ask what the change is about. Do NOT proceed without understanding the intent.

2. Scaffold the change in Emacs:
   ```elisp
   (progn (require 'orgspec-commands) (orgspec-new "<id>"))
   ```
   Returns the `change.org` path. If it errors that the change already exists, stop and offer to edit the existing file instead.

3. Draft `change.org` at the returned path (use Read to see the scaffold, then Edit/Write). Fill every section:
   - `* Intent` — why this change exists (the problem / motivation).
   - `* Scope` — what's in and, where useful, an explicit out-of-scope note.
   - `* Approach` — how it will be built, at a high level.
   - `* Tasks` — a `- [ ]` checklist of concrete implementation steps (these drive `/orgspec:status`).
   - `* Delta` — the requirements this change adds/changes. Each requirement is a **level-2** headline tagged with its op and carrying an `:AREA:` property; scenarios are **level-3**:
     ```org
     ** Notify on account lockout                            :ADDED:
     :PROPERTIES:
     :AREA: auth
     :END:
     The system SHALL send a notification email when an account is locked out.
     *** Lockout triggered
     - GIVEN an account just crossed the failed-attempt threshold
     - WHEN the lockout is applied
     - THEN a notification email is sent to the account address
     ```
   Rules:
   - Op tag is one of `:ADDED:` `:MODIFIED:` `:REMOVED:` `:RENAMED:`. For `:RENAMED:` add a `:FROM:` property with the old name.
   - Every `:ADDED:` / `:MODIFIED:` requirement body MUST contain `SHALL` or `MUST`, and MUST have ≥ 1 scenario (else the archive fold / future validator rejects it).
   - Requirement identity is its exact headline text; scenario identity is its headline text. GIVEN/WHEN/THEN is free text.
   - Where a decision is genuinely open, leave a `[NEEDS CLARIFICATION: <question>]` marker — it blocks `/orgspec:archive` until resolved, which is the intended gate.

4. Show the drafted `change.org` and run `/orgspec:parse <id>` to confirm the delta parses into the model cleanly (flags no-scenario reqs and renames missing `:FROM:`).

**Output**

- The change id and `change.org` path.
- A short summary of the drafted delta: per requirement, its op / area / scenario count.
- Any `[NEEDS CLARIFICATION]` markers left open.
- Prompt: "Refine `change.org`, then `/orgspec:apply` the tasks; `/orgspec:archive` when done."

**Guardrails**

- If the id is not kebab-case, ask for a valid one.
- Do NOT fold into `specs/` — that's `/orgspec:archive`. Propose only writes `change.org`.
- Do NOT invent requirements the user didn't ask for; leave a `[NEEDS CLARIFICATION]` marker instead of guessing.
- Keep the RFC-2119 keyword (`SHALL` / `MUST`) in the requirement body, not the headline.
