## 1. Load history on open

- [x] 1.1 Add `opencode-client--seed-history (id)`: GET `/api/session/{id}/message`, iterate the returned messages, and for each append its id to `--messages` and populate `--parts` / `--message-parts`.
- [x] 1.2 User message → synthesize a text part (`id` = `<mid>:text`, `type` = "text", `text` from the message).
- [x] 1.3 Assistant message → map each `content` item to a part; normalize the tool item by copying `name` → `tool` and coercing `state` to its status string.
- [x] 1.4 In `opencode-client--open-buffer`, call `--seed-history` and `--render` before `--start-stream`.

## 2. Verify

- [x] 2.1 Byte-compile cleanly.
- [x] 2.2 Batch test: seed the model from a canned history payload (one user text message, one assistant message with text + reasoning + tool) and assert `--render` produces the expected transcript, including the tool line with its name.
- [x] 2.3 Batch test: empty history seeds nothing and renders empty.
