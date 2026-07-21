## ADDED Requirements

### Requirement: Client unwraps the server response envelope
The opencode server returns most responses wrapped in a `data` envelope (and list responses alongside a `cursor`). The client SHALL unwrap this envelope before use: when a parsed JSON response is a map carrying a `data` key, the client SHALL use the value of `data`; otherwise it SHALL use the parsed response unchanged, so flat responses (such as the health check) continue to work.

#### Scenario: Wrapped object response
- **WHEN** the server returns a wrapped object such as a created session `{"data": {"id": …}}`
- **THEN** the client uses the inner object, so fields like the session id are read correctly

#### Scenario: Wrapped list response
- **WHEN** the server returns a wrapped list such as `{"data": [ … ], "cursor": …}`
- **THEN** the client uses the inner list as the collection

#### Scenario: Flat response
- **WHEN** the server returns a flat object with no `data` key, such as the health check `{"healthy": true}`
- **THEN** the client uses the response unchanged
