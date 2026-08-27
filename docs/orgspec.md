# orgspec — an org-native spec workflow

orgspec is a thin, dependency-free port of the load-bearing core of
[OpenSpec](https://github.com/Fission-AI/OpenSpec) — a structure parser and a
delta-fold — living natively in Org and Emacs Lisp instead of TypeScript over
Markdown. A change is spec-of-intent first: you describe *what* should change,
implement it, then fold that description into an accumulating source of truth.

See [orgspec-vs-openspec.md](orgspec-vs-openspec.md) for the detailed
comparison, and [issue #5](https://github.com/gbastkowski/mcp-emacs/issues/5)
for the full design.

## Layout

Under the orgspec root (`orgspec/` by default):

- `specs/<area>.org` — the accumulating source of truth. Requirements are
  level-1 headlines, scenarios level-2.
- `changes/<id>/change.org` — one change: human sections (Intent / Scope /
  Approach / Tasks) plus a `* Delta` subtree. Each delta requirement is a
  level-2 headline tagged with its op (`:ADDED:` / `:MODIFIED:` / `:REMOVED:` /
  `:RENAMED:`) and an `:AREA:` property naming its target spec; scenarios are
  level-3.

## The workflow

Exposed both as slash commands and as typed `orgspec_*` MCP tools.

| Command | MCP tool | Does |
|---|---|---|
| `/orgspec:propose` | — | scaffold a change and draft the whole `change.org` from a description |
| `/orgspec:new`     | `orgspec_new` | scaffold an empty change from the template |
| `/orgspec:apply`   | `orgspec_advance` | implement the tasks, tick the checklist, advance each requirement's TODO keyword |
| `/orgspec:status`  | `orgspec_status` | report `[x]`/`[ ]` task completion |
| `/orgspec:parse`   | `orgspec_parse` | read a change's delta as structured data (per-requirement op / area / scenarios) |
| `/orgspec:review`  | `orgspec_review` | ediff the fold against the current specs before writing — see it, don't trust it |
| `/orgspec:validate`| `orgspec_validate` | run the hard-gate validator (the same gate `archive` enforces) |
| `/orgspec:archive` | `orgspec_archive` | fold the delta into `specs/` and `git mv` the change to archive |

`orgspec_agenda` registers the in-flight-requirements agenda custom command.

## The fold

**The fold** is the load-bearing piece. It applies a change's delta in the fixed
order `RENAMED → REMOVED → MODIFIED → ADDED` via Org subtree surgery (not text
splicing), builds every affected spec in memory and validates the whole set
before writing anything (so a late failure leaves `specs/` untouched), guards
against a `MODIFIED` requirement silently dropping a scenario, and on re-level
into `specs/` strips the TODO keyword, op tag, and `:AREA:` while keeping any
`:IMPL:` drawer.

## Why Emacs, not a CLI

Delta requirements carry your *existing* Org TODO keywords, so `apply` moves a
requirement through its lifecycle (active / blocked on a
`[NEEDS CLARIFICATION]` marker / done) and one agenda custom command becomes an
in-flight-requirements dashboard — something a headless tool over flat Markdown
can't do for free.

orgspec deliberately drops what only serves multi-developer, multi-artifact
scale (conflict-free parallel changes, artifact DAGs, bulk operations). If
CI-enforced validation, many conflicting parallel changes, or team-enforced
structure ever become the requirement, OpenSpec proper stays the heavier,
battle-tested fallback.

## Code

`elisp/orgspec.el` (marker table), `-model` (structs), `-parse`
(`org-element` extraction), `-fold` (the delta fold), `-commands` (new / status
/ archive), `-lifecycle` + `-agenda` (the TODO lifecycle and in-flight
dashboard), `-review` (the pre-write ediff), `-validate` (the hard gate), and
`-mcp` (the typed `orgspec_*` tools, registered via the extra-tools hook).
