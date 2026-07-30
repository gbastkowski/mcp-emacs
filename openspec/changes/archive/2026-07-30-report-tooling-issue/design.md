## Context

See proposal.md — Why. This ports a feature that already shipped in the sibling GitLab tooling. The
reference implementation is three parts across two repos:

- `report_tooling_issue` (mcp-gitlab) — the filer: a hard-coded repo map + `glab issue create
  --no-editor --yes`, returns the printed issue URL, no labels/template.
- `get_origin` (mcp-jira-confluence) — a router that declares `{repo, url, newIssueUrl, reportFor}`
  per fault domain so a caller can pick the target repo. Files nothing.
- `report-issue` skill (jira-assistant) — orchestrates: classify → get_origin → draft → confirm →
  file (via the gitlab filer) or hand back a prefilled new-issue URL.

mcp-emacs differs in two ways that shape the port: it is a **single GitHub repo**
(`gbastkowski/mcp-emacs`), and its MCP server is **Emacs-resident elisp**, registered as
`(:name :description :schema :handler)` plists in `mcp-emacs-server--tools`
(`elisp/mcp-emacs-server.el`), with schemas built from the `--obj`/`--prop`/`--no-args` helpers.

## Goals / Non-Goals

**Goals:**

- A `report_tooling_issue` MCP tool that files a GitHub issue on the mcp-emacs repo and returns its
  URL, resilient to which GitHub mechanism happens to be available.
- A `report-issue` skill that classifies, drafts, confirms, and files.

**Non-Goals (design-level):**

- No `get_origin`-style router — one repo, nothing to route.
- No issue templates, no multi-repo targeting, no arbitrary-repo issue creation.

## Decisions

### 1. Drop the router; collapse fault domains to a `kind` label

The GitLab feature routed between two repos by fault domain. mcp-emacs is one repo, so routing is
moot. The signal the router carried — "is this a server bug or a skill/prompt bug?" — is preserved as
an optional `kind` label (`bug` / `feature` / `skill` / `server`) on the issue. **Alternative
considered:** port `get_origin` verbatim for 1:1 parity. Rejected — it would be a tool that always
returns one target, i.e. dead weight, until/unless a sibling repo (e.g. a separate opencode-plugin
repo) actually exists.

### 2. GitHub, via a three-step fallback chain

The reference filer shells out to `glab`. mcp-emacs is GitHub, and the environment may expose GitHub
access in more than one way, so the filer tries, in order:

1. **the `github` MCP tool** (`issue_write` / equivalent) if that server is connected,
2. **the `gh` CLI** (`gh issue create --repo gbastkowski/mcp-emacs ...`) — installed and authed here,
3. **`gh api`** directly (`POST /repos/gbastkowski/mcp-emacs/issues`) as the lowest-level fallback.

The elisp tool owns steps 2–3 (it can `call-process gh`); step 1 is naturally the skill's preference
when it is orchestrating, since the skill can see whether the `github` MCP server is present. Either
way the *first available* mechanism wins and the rest are skipped. If none is available, the tool
reports failure and returns the composed title+body so the user can file by hand — the GitHub analog
of the reference's prefilled-`newIssueUrl` fallback. **Alternative considered:** REST via `url.el`
with a token. Rejected — reuses no existing auth; `gh` already holds the credential.

### 3. Label creation is best-effort

Applying a `kind` label must not fail the filing if the label doesn't exist in the repo yet. The
filer applies the label when it can and does not treat a missing-label error as a filing failure —
the issue (the important artifact) is created regardless. Labels can be pre-created in the repo out of
band.

### 4. Skill mirrors the reference's classify → draft → confirm → file → report

Kept intact from `report-issue`, minus the router call: classify (server tool / skill / feature),
draft a lean title + what/expected/repro body, **confirm with the user before filing** (explicit
gate, per the reference and the spec), file via `report_tooling_issue`, report the URL back. The
confirmation gate is a spec requirement ("User declines the draft" → nothing filed), not just skill
prose.

## Risks / Trade-offs

- **Three filing paths to keep working** → more surface than a single `glab` call. Mitigation: they
  are tried in a fixed order and the first available wins; the manual-fallback branch means "no path
  available" degrades to a copy-pasteable draft rather than a hard error.
- **`kind` label may not exist in the repo** → a naive `--label` would fail the whole create.
  Mitigation: best-effort labeling (decision 3) — create the issue first, label if possible.
- **Coupling to `gh` auth** → if `gh` is unauthenticated and no GitHub MCP server is present, filing
  can't proceed. Mitigation: that is exactly the manual-fallback case; the user still gets the drafted
  issue text.

## Open Questions

None that affect the specs, the approach, or the task breakdown. Whether to pre-create the four
`kind` labels in the repo is an out-of-band repo-admin step, not a code decision.
