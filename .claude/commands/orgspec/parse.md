---
name: "orgspec: Parse"
description: Read a change's delta as structured data (the orgspec model) via the running Emacs
allowed-tools: mcp__emacs__eval
category: Workflow
tags: [orgspec, workflow]
---

Read a change's `* Delta` as structured data — the orgspec model, not prose — so you can inspect a change programmatically. Wraps `orgspec-parse-change` via the mcp-emacs `eval` tool (the planned `orgspec_parse_change` tool, driven through `eval` until typed MCP tools land).

**Input**: The argument after `/orgspec:parse` is the change id. Required.

**Steps**

1. If no id was given, ask which change to parse (offer `/orgspec:status` output to pick from).

2. Parse by evaluating in Emacs. This maps the structs to a readable alist so the output is inspectable rather than opaque `#s(...)`:
   ```elisp
   (progn
     (require 'orgspec-commands)
     (let ((c (orgspec-commands--read-change "<id>")))
       (list
        :id (orgspec-change-id c)
        :requirements
        (mapcar
         (lambda (r)
           (list :name (orgspec-requirement-name r)
                 :op (orgspec-requirement-op r)
                 :area (orgspec-requirement-area r)
                 :from (orgspec-requirement-from r)
                 :impl (orgspec-requirement-impl r)
                 :scenarios (mapcar #'orgspec-scenario-name
                                    (orgspec-requirement-scenarios r))))
         (orgspec-change-requirements c)))))
   ```
   Each requirement reports its name (identity), op tag (`added`/`modified`/`removed`/`renamed`), `:AREA:` target spec, `:FROM:` rename source, `:IMPL:` traceability entries, and its scenario headline names.

**Output**

- The change id and a per-requirement breakdown: op, area, scenario count + names, and rename source where present.
- Flag anything the archive fold would reject: a requirement with no scenarios, or a `renamed` op missing `:FROM:`.

**Guardrails**

- Read-only. Do NOT modify any files.
- Requirement/scenario identity is the exact headline text — report names verbatim, do not normalize them.
- Errors (e.g. no change file) surface as `user-error`; report the message verbatim and stop.
