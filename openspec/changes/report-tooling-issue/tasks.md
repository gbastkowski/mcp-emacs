## 1. Filing helper (elisp)

- [ ] 1.1 Add `mcp-emacs-report-tooling-issue` (new helper, e.g. in `mcp-emacs.el` or a small `mcp-emacs-report.el`): takes title, optional description, optional kind; targets `gbastkowski/mcp-emacs`; byte-compiles clean.
- [ ] 1.2 Filing via `gh` CLI: `call-process gh issue create --repo gbastkowski/mcp-emacs --title ... [--body ...]`, capture the printed issue URL, trim, return it.
- [ ] 1.3 Fallback to `gh api`: `POST /repos/gbastkowski/mcp-emacs/issues` when `gh issue create` is unavailable/fails for a non-content reason; parse the returned URL.
- [ ] 1.4 Best-effort `kind` label: apply the label when creating the issue; a missing-label error must NOT fail the filing (issue is created regardless).
- [ ] 1.5 No mechanism available: report failure and return the composed title + body so the caller can file manually.

## 2. MCP tool descriptor

- [ ] 2.1 Add a `report_tooling_issue` entry to `mcp-emacs-server--tools`: `:name`, `:description` (scoped to mcp-emacs itself, not arbitrary repos), `:schema` (title required; description optional; kind optional enum bug/feature/skill/server), `:handler` calling the filing helper.
- [ ] 2.2 Handler validation: reject a missing title and an out-of-set `kind` with a clear message; do not create an issue in those cases.
- [ ] 2.3 Handler success returns the created issue URL as text; failure returns an error result with the manual-fallback text.

## 3. report-issue skill

- [ ] 3.1 Add `skills/report-issue/SKILL.md` (repo skill location): front matter (name, description, when-to-use — tooling issues about mcp-emacs, not the user's own project).
- [ ] 3.2 Workflow: classify (server-tool bug / skill-or-prompt issue / feature request) → draft a lean title + what-happened / expected / reproduction body.
- [ ] 3.3 Filing preference in the skill: prefer the `github` MCP tool if that server is connected; otherwise call `report_tooling_issue` (which itself falls back gh CLI → gh api).
- [ ] 3.4 Confirmation gate: confirm the drafted issue with the user before filing; if the user declines, file nothing.
- [ ] 3.5 Report back the resulting issue URL (or, on total failure, the drafted text for manual filing) and which `kind` it was tagged.

## 4. Tests

- [ ] 4.1 Handler validation: missing title rejected; invalid `kind` rejected with accepted-values message; neither creates an issue (drive the handler headlessly, stubbing the filing helper).
- [ ] 4.2 Fallback chain: with the CLI path stubbed present, filing uses it; with it stubbed absent, filing falls to `gh api`; with all absent, returns the manual-fallback text — assert the order and that the first-available wins.
- [ ] 4.3 Best-effort label: a simulated missing-label error still yields a created-issue result (issue URL returned, not an error).
- [ ] 4.4 CI byte-compiles the new elisp and runs the new suite.

## 5. Docs

- [ ] 5.1 README: document the `report_tooling_issue` tool and the `report-issue` skill (what they file, the fixed target repo, the `kind` labels, the filing fallback chain).
- [ ] 5.2 Note the port origin (GitLab tooling feature) and the single-repo / GitHub adaptation (no `get_origin` router). Link issue #26.

## 6. Verify

- [ ] 6.1 Live end-to-end: from the running Emacs, invoke `report_tooling_issue` with a test title/kind, confirm a real issue is created on `gbastkowski/mcp-emacs` with the label and the URL is returned; then close the test issue.
