---
name: org-task-loop
description: Run a cooperative human/AI Org-task session loop against a live Emacs buffer. Use when the user points at a session Org file (a heading with a SESSION property and a TODO checklist) and wants the AI to work items, report status, and wait for their next direction. Trigger phrases: "run the org loop", "start the task session", "work this session file", "cooperative loop".
---

# Org-task session loop

You drive a shared Org file with the human. The human edits it live in Emacs;
you read and update it through the `emacs` MCP tools. The human stays the
driver — you react to their edits, you never reorder, delete, or rewrite
human-authored items, and you never save the buffer automatically.

## Inputs

The user gives you the path to a session Org file, or the file is already open
in Emacs. Its first heading is the task: the TODO keyword is the session
status, the `SESSION` property is the session id, child headings are the
checklist.

## Loop

1. **Read** the session with `org_task_session` (pass the file path). Note the
   returned **change token** and the checklist with each item's Org keyword.
2. **Pick** the first actionable `TODO` item. If none are actionable, skip to
   step 6.
3. **Set it in progress** if the workflow uses an in-progress keyword, via
   `org_task_set_item_status` (identify the item by its ID/CUSTOM_ID property or
   exact heading text — never by position).
4. **Do the work** the item describes (edit code, run commands, etc.).
5. **Report**: mark the item `DONE` with `org_task_set_item_status`, and add a
   short progress note with `org_task_append_note`. Update overall status with
   `org_task_set_session_status` when the whole task advances.
6. **Wait** for the human with `org_task_wait_for_change`, passing the latest
   change token. It blocks (up to a timeout) until the human edits the file,
   then returns the change plus the fresh session view.
7. **React** to what changed — a new item, an edited item, a status flip — and
   go back to step 2 with the new token.

## Rules

- Every read/write is scoped to the explicit file path; there is no ambient
  "current task file".
- Only touch items you can positively identify. Leave everything else untouched.
- Do not save the buffer; the human owns saving.
- If `org_task_session` reports missing session metadata, tell the user rather
  than guessing.
- On `wait_for_change` timeout with no change, either loop again (keep waiting)
  or stop and report, depending on what the user asked for.

Stop the loop when the user says so, or when the task heading reaches its
terminal status and no actionable items remain.
