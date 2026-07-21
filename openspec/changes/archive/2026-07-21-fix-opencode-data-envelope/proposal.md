## Why

Verified against a live `opencode serve` (opencode 1.18.0): the server wraps most JSON responses in a `data` envelope (`{"data": …}`, list responses as `{"data": […], "cursor": …}`). The client reads top-level fields, so session create/list/switch, single-session fetch, message history, and the prompt response all mis-parse — e.g. a created session's `id` is `nil`. Only `/api/health` is flat (`{"healthy": true}`), which is why `connect` still works and masked the breakage.

The endpoints, paths, prompt body (`{prompt:{text}, delivery}` with `delivery` ∈ `steer|queue`) are all correct against 1.18.0 — only the response envelope is unhandled.

## What Changes

- Unwrap the `data` envelope centrally in `opencode-client--request`: when the parsed JSON is an alist carrying a `data` key, return that value; otherwise return the parsed body unchanged (so flat responses like health keep working).
- No change to request bodies, endpoints, or delivery modes — those already match the server.

## Capabilities

### New Capabilities

### Modified Capabilities
- `opencode-client`: responses are unwrapped from the server's `data` envelope before use, so session and message operations parse correctly.

## Impact

- `elisp/opencode-client.el` — unwrap in `opencode-client--request`.
- Tests: add coverage that a `data`-wrapped response is unwrapped and a flat response is passed through.
- No MCP tool surface change. Pagination `cursor` is dropped for now (not currently used).
