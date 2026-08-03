---
name: "orgspec: Validate"
description: Run the hard-gate validator over a change and report problems
allowed-tools: mcp__emacs__eval
category: Workflow
tags: [orgspec, workflow]
---

Run the hard-gate validator over a change's delta and report every structural problem, or "valid". Wraps `orgspec-validate-change` via the mcp-emacs `eval` tool. This is the same gate `/orgspec:archive` enforces — run it early to catch problems before you try to archive.

**Input**: The argument after `/orgspec:validate` is the change id. Required.

**Steps**

1. If no id was given, ask which change to validate (offer `/orgspec:status` output to pick from).

2. Validate by evaluating in Emacs:
   ```elisp
   (progn (require 'orgspec-validate)
          (let ((errors (orgspec-validate-change
                         (orgspec-commands--read-change "<id>"))))
            (if errors (mapconcat #'identity errors "\n") "valid")))
   ```
   The ERROR rules checked:
   - an ADDED/MODIFIED requirement body must contain `SHALL` or `MUST`;
   - an ADDED/MODIFIED requirement must have at least one scenario;
   - no duplicate requirement names within an op, and no duplicate `:FROM:`/`:TO:` across renames;
   - no cross-op conflicts (a name in both MODIFIED and REMOVED, MODIFIED and ADDED, or ADDED and REMOVED; a renamed-to that collides with an ADDED name);
   - at least one delta requirement in the change.

**Output**

- "valid", or the list of problems (one per line).
- For each problem, point at the offending requirement in `change.org` and suggest the fix (add `SHALL`, add a scenario, rename, drop the duplicate op, …).

**Guardrails**

- Read-only. Do NOT modify `change.org` or any spec — just report.
- Report the messages verbatim; they match what `/orgspec:archive` will refuse on.
