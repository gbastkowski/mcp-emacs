## 1. Emacs helper and generated bootstrap

- [x] 1.1 Add `mcp-emacs-get-current-clocked-task` to `elisp/mcp-emacs.el` so it returns the current global Org clock heading text or raw `nil`
- [x] 1.2 Run the build step to regenerate `src/utils/bootstrap-elisp.ts` with the new helper included

## 2. MCP tool wiring

- [x] 2.1 Add `src/tools/get-current-clocked-task.ts` as a thin read-only wrapper around the new Elisp helper
- [x] 2.2 Map raw `nil` to one stable friendly fallback message and otherwise return plain text only
- [x] 2.3 Register the new tool in `src/tools/index.ts`

## 3. Verification and documentation

- [x] 3.1 Add `test/tools/get-current-clocked-task.test.js` covering the active-clock case
- [x] 3.2 Add the no-active-clock test case asserting the exact fallback text and helper call pattern
- [x] 3.3 Update `README.md` to document the new read-only tool in the tools table
