## Context

The repository already exposes Emacs state through small MCP tools backed by Emacs Lisp helper functions.
Current patterns split responsibility between an Emacs-side helper in `elisp/mcp-emacs.el` and a thin TypeScript wrapper in `src/tools/`, with registration centralized in `src/tools/index.ts`.

This change adds a new read-only capability for the Org task at the current point.
It is a cross-cutting but small addition because it touches the public MCP surface, the Emacs Lisp helper layer, the generated bootstrap payload, tests, and README documentation.

There is already a nearby tool, `get_current_clocked_task`, that exposes global Org clock state.
The new capability must stay clearly distinct: it should inspect the current point in the active buffer rather than global clock state.
Adjacent point-scoped Org behavior already exists through `toggle_org_todo`, which operates on the heading at point.

## Goals / Non-Goals

**Goals:**
- Add a new MCP tool that returns the Org task at the current point.
- Follow the existing no-argument getter-tool architecture so the new capability looks and behaves like the rest of the server.
- Return a friendly, stable fallback message when point is not on a valid Org task context.
- Keep the behavior read-only and narrow in scope.
- Cover the new tool with tests and document it in the README tool table.

**Non-Goals:**
- Returning global Org clock state.
- Returning structured metadata such as file path, tags, TODO state object, subtree path, or marker position.
- Mutating Org state, moving point, or changing TODO state.
- Introducing a new resource or broader Org navigation API.

## Decisions

### Decision: expose this as a tool, not a resource

The capability matches existing “current state” tools such as `get_selection`, `get_buffer_filename`, and `get_current_clocked_task`.
The user asks for an on-demand point-scoped query, not a collection or stream of Org data.

Chosen approach:
- Add a new tool in `src/tools/`, likely named `get_current_task_at_point`.
- Register it through `src/tools/index.ts`.

Alternatives considered:
- Add a new resource.
  Rejected because the capability is a single current value tied to point.
- Extend the current-clocked-task tool.
  Rejected because clock state and point state are different lookup scopes and should stay explicit in the MCP surface.

### Decision: resolve task-at-point in Emacs Lisp

The definition of “task at point” depends on Org semantics and the current buffer state.
The repo already keeps Org-specific editor logic in Emacs Lisp and uses TypeScript as a thin wrapper.

Chosen approach:
- Add an Emacs Lisp helper such as `mcp-emacs-get-current-task-at-point` in `elisp/mcp-emacs.el`.
- Use Org primitives around the current point and heading, consistent with `mcp-emacs-toggle-org-todo`, to find the enclosing heading and extract its text.
- Regenerate `src/utils/bootstrap-elisp.ts` through the normal build step so the embedded helper payload stays in sync.

Alternatives considered:
- Derive the task from lower-level point data in TypeScript.
  Rejected because that would move Org-specific behavior out of the existing editor-side layer.

### Decision: keep nil handling in TypeScript, not in Elisp

Existing getter tools establish the pattern that Emacs-side helpers may return raw `nil`, while the TypeScript wrapper maps absence to a friendly message.
This keeps response wording owned by the MCP layer and keeps the helper focused on editor semantics.

Chosen approach:
- Let the helper return the heading text or `nil`.
- In the TypeScript tool, detect `nil` and return a stable user-facing fallback message.

Alternatives considered:
- Return a fallback string directly from Elisp.
  Rejected because it diverges from the repo’s getter-tool pattern.
- Throw an error when point is outside a valid Org task.
  Rejected because the proposal calls for a predictable read-only lookup with a friendly fallback.

### Decision: keep the first version intentionally narrow

The proposal is about retrieving the current task at point, not describing all Org heading context.
Keeping the response to plain text reduces ambiguity and mirrors the shape of the existing clocked-task tool.

Chosen approach:
- Return only the task heading text as plain text.
- Use a single predictable fallback when point is not on a valid Org task context.

Alternatives considered:
- Return TODO state, tags, outline path, or buffer/file metadata.
  Rejected because those broaden the contract beyond the immediate need and would require a richer spec and test matrix.

## Risks / Trade-offs

- [Task-at-point semantics may be ambiguous inside non-heading Org text] → Mitigation: define the behavior in specs around the enclosing heading/subtree and use one stable fallback outside valid task contexts.
- [Point-scoped lookup can be confused with global clock lookup] → Mitigation: keep naming, docs, and specs explicit about “at point” versus “currently clocked in.”
- [Fallback wording becomes part of the user-facing contract] → Mitigation: choose one stable message and use it consistently in implementation, tests, and README.
- [Bootstrap payload can drift from checked-in Elisp] → Mitigation: rely on the existing build step that regenerates `src/utils/bootstrap-elisp.ts` from `elisp/mcp-emacs.el`.

## Migration Plan

1. Add the new Emacs Lisp helper in `elisp/mcp-emacs.el`.
2. Build the project to regenerate `src/utils/bootstrap-elisp.ts`.
3. Add the new TypeScript tool and register it in `src/tools/index.ts`.
4. Add tests covering both task-at-point and no-task-at-point cases.
5. Update the README tool list to document the new capability.

Rollback is straightforward: remove the helper, tool registration, tests, and README entry, then rebuild to regenerate the embedded payload.

## Open Questions

- Should “task at point” include any Org heading, or only headings that are actual TODO tasks?
- What exact fallback text should be standardized on when point is not on a valid Org task context?
