## Context

The repository already exposes Emacs state through small MCP tools and resources backed by Emacs Lisp helper functions.
Current patterns split responsibility between an Emacs-side helper in `elisp/mcp-emacs.el` and a thin TypeScript wrapper in `src/tools/` or `src/resources/`, with registration centralized in `src/tools/index.ts` or `src/resources/index.ts`.

This change adds a new read-only capability for the currently clocked in Org task.
That is a cross-cutting addition because it touches the public MCP surface, the TypeScript wrapper layer, the embedded Emacs Lisp payload, generated bootstrap output, tests, and README documentation.

The current repository patterns also matter for absence handling.
Simple getter tools such as `get_selection` and `get_buffer_filename` let Emacs return raw `nil` and translate that in TypeScript into friendly user-facing fallback text.
Adjacent Org support already exists through `toggle_org_todo` and the `org-tasks://all` resource, but nothing currently exposes global Org clock state.

## Goals / Non-Goals

**Goals:**
- Add a new MCP tool that returns the heading of the Org task currently clocked in.
- Follow the existing tool architecture so the new capability looks and behaves like the rest of the server.
- Return a friendly, stable fallback message when no task is currently clocked in.
- Keep the behavior read-only and narrow in scope.
- Cover the new tool with tests and document it in the README tool table.

**Non-Goals:**
- Returning structured metadata about the clocked task such as file path, tags, or timestamps.
- Modifying Org clock state, starting or stopping clocks, or changing TODO state.
- Introducing a new resource or broader Org status API.
- Redesigning existing tool abstractions or changing how other getter tools handle `nil`.

## Decisions

### Decision: expose this as a tool, not a resource

The capability matches existing “current state” operations such as `get_buffer_content`, `get_buffer_filename`, and `get_selection`.
The user asks for the currently clocked in task as an on-demand query, not as a browsable collection.

Chosen approach:
- Add a new tool in `src/tools/`, likely named `get_current_clocked_task`.
- Register it through `src/tools/index.ts`.

Alternatives considered:
- Add a new resource.
  Rejected because the capability is a single current value, not a dataset like `org-tasks://all`.
- Extend the existing Org tasks resource.
  Rejected because current global clock state is a different concern from listing agenda tasks.

### Decision: keep nil handling in TypeScript, not in the Emacs Lisp helper

Existing getter tools set the precedent that Emacs-side helpers can return raw `nil`, while the TypeScript tool maps absence to a user-facing message.
This keeps the Elisp helper small and keeps response wording owned by the MCP tool layer.

Chosen approach:
- Add a public Emacs Lisp helper such as `mcp-emacs-get-current-clocked-task` that returns either the current heading text or `nil`.
- In the TypeScript tool, detect raw `nil` and return a friendly fallback string such as `No task is currently clocked in`.

Alternatives considered:
- Return the fallback string directly from Elisp.
  Rejected because it diverges from existing getter-tool patterns.
- Surface `nil` directly to the MCP client.
  Rejected because current getter tools return friendly text rather than exposing raw Elisp absence.

### Decision: derive the visible task text from Org clock state on the Emacs side

The current task is an Emacs/Org concern.
The repo already keeps Org-specific knowledge in Emacs Lisp helpers and lets TypeScript act as a thin wrapper.

Chosen approach:
- Implement the lookup in `elisp/mcp-emacs.el`.
- Reuse Org primitives consistent with adjacent helpers, so the helper returns the current heading text for the active clock.
- Regenerate the embedded helper payload through the normal build step so `src/utils/bootstrap-elisp.ts` stays in sync.

Alternatives considered:
- Build the task text in TypeScript from lower-level Emacs data.
  Rejected because this would move Org-specific logic out of the existing Emacs-side integration layer.

### Decision: keep the first version intentionally narrow

The proposal is about finding the currently clocked in task, not building a general clock inspection API.
Keeping the response to plain text reduces implementation and testing surface while matching current tool conventions.

Chosen approach:
- Return only the task heading as text.
- Use a single, predictable fallback message when no clock is active.

Alternatives considered:
- Return additional metadata such as source file, markers, tags, or elapsed time.
  Rejected because those are useful extensions, but they are not required for the initial capability and would broaden the spec and tests.

## Risks / Trade-offs

- [Fallback wording becomes part of the user-facing contract] → Mitigation: choose wording consistent with existing tools and use the same text in tests and documentation.
- [Org clock state may be global rather than tied to the current buffer] → Mitigation: state this explicitly in the spec so the behavior is defined as current Org clock state, not current buffer state.
- [The helper may need Org-specific assumptions] → Mitigation: keep Org-specific logic in the Emacs Lisp helper, where adjacent Org integrations already live.
- [Bootstrap payload can drift from checked-in Elisp] → Mitigation: rely on the existing build step that regenerates `src/utils/bootstrap-elisp.ts` from `elisp/mcp-emacs.el`.
- [Future users may want richer data than plain text] → Mitigation: keep this change minimal now and leave richer clock metadata as a follow-up capability if demand appears.

## Migration Plan

1. Add the new Emacs Lisp helper in `elisp/mcp-emacs.el`.
2. Build the project to regenerate `src/utils/bootstrap-elisp.ts`.
3. Add the new TypeScript tool and register it in `src/tools/index.ts`.
4. Add tests covering both an active clock and the no-clock fallback case.
5. Update the README tool list to document the new capability.

Rollback is straightforward: remove the helper, tool registration, tests, and README entry, then rebuild to regenerate the embedded payload.

## Open Questions

- The main remaining product-level choice is the exact fallback text to standardize on when no clock is active.
- If the implementation uncovers multiple reasonable Org clock representations, the spec should pin down whether the returned text is strictly the heading text or a formatted task label.
