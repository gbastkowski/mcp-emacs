---
title: "OpenSpec vs orgspec — Feature Comparison"
geometry: landscape, a4paper, margin=1.6cm
fontsize: 10pt
mainfont: "Palatino"
colorlinks: true
linkcolor: "black!60!blue"
---

orgspec (issue #5) is an org-native, dependency-free Emacs Lisp port of OpenSpec's load-bearing core.
Complete: MVP (#29), slash commands (#30), agenda lifecycle + typed MCP tools (#31), native session picker, fold review (#37), and the hard-gate validator (#38). Issue #5 and every split follow-up are closed.

## Substrate

| | OpenSpec | orgspec |
|---|---|---|
| Language | TypeScript (~33k lines) | Emacs Lisp (~1k lines) |
| Runtime dep | npm / Node | none (`org-element`) |
| Format | Markdown | org-native |
| Delta marker | `## ADDED` headers | org tags `:ADDED:` / … + `:AREA:` |
| Artifacts/change | 4 files | 1 `change.org` |
| Execution | headless CLI | running Emacs + mcp-emacs |

## Workflow — shipped

| Verb | orgspec | Notes |
|---|---|---|
| propose | `/orgspec:propose` | scaffold + draft the whole `change.org` |
| new | `/orgspec:new` | mkdir + template |
| apply | `/orgspec:apply` | implement tasks, tick boxes, advance TODO lifecycle |
| status | `/orgspec:status` | `[x]`/`[ ]` counts |
| parse | `/orgspec:parse` | delta as structured data |
| validate | `/orgspec:validate` | hard-gate ERROR rules; the gate `archive`/`review` enforce |
| review | `/orgspec:review` | ediff the fold against current specs before writing — see it, don't trust it |
| archive | `/orgspec:archive` | fold delta into `specs/` (RENAMED->REMOVED->MODIFIED->ADDED) + `git mv` |

All are also typed `orgspec_*` MCP tools (eight, registered via a server extra-tools hook), not just the raw `eval` shortcut.

## Fold engine (the load-bearing port)

Fixed order RENAMED->REMOVED->MODIFIED->ADDED · subtree surgery, not text splice · validate-all-then-write-all (a late failure leaves `specs/` untouched) · MODIFIED scenario drop-guard · re-level strips TODO + op-tag + `:AREA:`, keeps `:IMPL:`.

## Org leverage — the "why Emacs, not a CLI" payoff

| Feature | Status |
|---|---|
| Agenda TODO lifecycle (in-flight dashboard from the user's own keywords) | **shipped** |
| ediff fold review (see the fold before it writes) | **shipped** (#37) |
| Req<->code `:IMPL:` writer | won't-do — rot risk vs thin solo payoff; fold still preserves a hand-written drawer |

## Dropped

- **Won't-do:** the `:IMPL:` req<->code traceability writer (rot risk vs thin solo-scale payoff; the fold still preserves a hand-written drawer).
- **Out of scope for solo work:** `explore`, `continue`, `ff` (subsumed by propose), `update`, `sync` (folded into archive), `bulk-archive`, `onboard`.

Nothing is open: the validator (`orgspec-validate.el`) and the ediff fold review both shipped.

**Fallback:** if CI-enforced validation, many conflicting parallel changes, or team-enforced structure ever become the requirement, revert to OpenSpec proper.
