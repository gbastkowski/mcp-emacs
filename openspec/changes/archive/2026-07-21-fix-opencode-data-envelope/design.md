## Context

`opencode-client--request` returns the raw parsed JSON. opencode 1.18.0 wraps object and list responses in `{"data": …}` (lists add a sibling `cursor`), except flat control responses like `/api/health` → `{"healthy": true}`. Callers read top-level fields, so everything but health mis-parses. Verified live against `opencode serve`.

## Goals / Non-Goals

**Goals:**
- One central unwrap so all callers get the payload they expect, health included.

**Non-Goals:**
- No pagination handling yet (drop `cursor`).
- No per-endpoint schema modelling.

## Decisions

### Decision: conditional unwrap in `--request`
After parsing, if the result is an alist that contains a `data` key, return `(alist-get 'data result)`; else return the result. Health has no `data` key, so it passes through. This keeps every caller unchanged.
- **Alternative:** unwrap per caller — more code, and easy to miss one. Rejected. Central is one line and uniform.
- **Risk:** a real payload with a legitimate top-level `data` field would be unwrapped incorrectly. In the current API the envelope is consistent and control responses are flat, so this does not occur; revisit if a flat response ever legitimately carries `data`.

## Risks / Trade-offs

- [Dropping `cursor` loses pagination] → Not used today; list calls fetch the first page. Note it and add later when needed.

## Open Questions

- None.
