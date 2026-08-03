---
name: "orgspec: Apply"
description: Implement a change's tasks in the codebase and tick off the checklist
allowed-tools: mcp__emacs__eval, Read, Edit, Write, Bash
category: Workflow
tags: [orgspec, workflow]
---

Implement a change: write the code that satisfies its delta requirements and tick off the `* Tasks` checklist as each step lands. This is the doing phase between `/orgspec:propose` and `/orgspec:archive`.

**Scope.** This implements tasks, updates the `- [ ]` → `- [x]` boxes, and advances each delta requirement's TODO keyword through its lifecycle (`orgspec-lifecycle`). It still skips the `:IMPL:` code↔spec link writer #5 defers to a later MVP+ pass — add that when the traceability layer lands.

**Input**: The argument after `/orgspec:apply` is the change id. Required.

**Steps**

1. If no id was given, ask which change to apply (offer `/orgspec:status` output to pick from).

2. Read the change and check readiness:
   ```elisp
   (progn (require 'orgspec-commands) (orgspec-commands--read-change "<id>"))
   ```
   And confirm there is no open clarification marker — if `/orgspec:parse` or a scan shows a `[NEEDS CLARIFICATION]`, STOP and ask the user to resolve it first (same gate `/orgspec:archive` enforces). Do not implement around an unresolved question.

3. Read the change file (`orgspec/changes/<id>/change.org`) to get the Intent / Approach and the `* Tasks` checklist.

4. When you start working a requirement, mark it active in Emacs:
   ```elisp
   (progn (require 'orgspec-lifecycle)
          (orgspec-lifecycle-advance "<change.org path>" "<requirement name>" 'active))
   ```
   This sets the requirement's TODO keyword to `orgspec-todo-active` (STRT), so it shows up in the `orgspec` agenda as in-flight. Use the requirement's exact headline text as the name.

5. For each unchecked task, in order:
   - Implement it in the codebase (Read / Edit / Write; run the build or tests via Bash where it makes sense to verify).
   - Only after the task is actually done and verified, tick its box: edit that line's `- [ ]` to `- [x]` in `change.org`.
   - If a task turns out to be blocked or ambiguous, leave it unchecked and note why — do NOT tick a box for work that isn't real. If it is blocked on an open question, mark the requirement blocked and leave a marker:
     ```elisp
     (orgspec-lifecycle-advance "<change.org path>" "<requirement name>" 'blocked)
     ```
     (`orgspec-todo-blocked`, WAIT) and add a `[NEEDS CLARIFICATION: <question>]` to its body.

6. When every task for a requirement is done and verified, mark it done:
   ```elisp
   (orgspec-lifecycle-advance "<change.org path>" "<requirement name>" 'done)
   ```

7. Report progress with `/orgspec:status <id>`.

**Output**

- Which tasks were completed (now `[x]`) and which remain `[ ]` and why.
- A short note on what changed in the codebase (files touched, build/test result).
- If all tasks are done: prompt "All tasks complete — `/orgspec:archive <id>` to fold the delta into `specs/`."

**Guardrails**

- Tick a box ONLY when its task is genuinely implemented and verified. A ticked box is a claim the work is done — never tick ahead of the code.
- Do NOT fold into `specs/` — that's `/orgspec:archive`.
- Do NOT modify the `* Delta` requirements; apply implements them, it doesn't redefine them. If the delta is wrong, that's a `/orgspec:propose` edit, not apply.
- Blocked on a `[NEEDS CLARIFICATION]` marker → stop and ask, don't guess.
