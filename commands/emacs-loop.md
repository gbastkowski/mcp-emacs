---
description: Start the cooperative Org-task session loop against a session Org file open in Emacs.
argument-hint: [path-to-session.org]
---

Start the cooperative human/AI Org-task session loop for the session file:
`$1`

If no path was given, use the Org file currently open in Emacs
(`get_buffer_filename`).

Follow the `org-task-loop` skill: read the session with `org_task_session`,
work the first actionable TODO item, report status back into the file via the
`org_task_*` tools, then block on `org_task_wait_for_change` and react to the
human's next edit. The human is the driver — never reorder, delete, rewrite, or
save their content.
