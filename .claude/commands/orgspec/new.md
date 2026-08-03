---
name: "orgspec: New"
description: Scaffold a new orgspec change (changes/<id>/change.org) in the running Emacs
allowed-tools: mcp__emacs__eval
category: Workflow
tags: [orgspec, workflow]
---

Scaffold a new orgspec change via the running Emacs (mcp-emacs `eval` tool). Wraps `orgspec-new`.

**Input**: The argument after `/orgspec:new` is the change id (kebab-case). If none given, ask what the user wants to build and derive a kebab-case id (e.g. "notify on account lockout" → `notify-account-lockout`).

**Steps**

1. If no id was provided, ask what the change is about and derive a kebab-case id. Do NOT proceed without one.

2. Create the change by evaluating in Emacs:
   ```elisp
   (progn (require 'orgspec-commands) (orgspec-new "<id>"))
   ```
   This creates `orgspec/changes/<id>/change.org` from the template (Intent / Scope / Approach / Tasks / `* Delta`) and returns the file path.

**Output**

- The change id and the returned `change.org` path.
- Reminder that the file has an empty `* Delta` subtree ready for requirements (level-2 headlines tagged `:ADDED:`/`:MODIFIED:`/`:REMOVED:`/`:RENAMED:` with an `:AREA:` property; scenarios level-3).
- Prompt: "Describe the change and I'll fill in `change.org`, or run `/orgspec:status` to check progress."

**Guardrails**

- If the id is not kebab-case, ask for a valid one.
- If `orgspec-new` signals that the change already exists, stop and suggest editing the existing `change.org` instead.
- Do NOT write any delta requirements yet — just scaffold.
