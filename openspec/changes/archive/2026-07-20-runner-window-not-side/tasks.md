## 1. Options

- [x] 1.1 Replace `mcp-emacs-run-window-side` defcustom with `mcp-emacs-run-window-direction` (choice right/left/above/below, default right).
- [x] 1.2 Add `mcp-emacs-run-window-height` defcustom (size hint for above/below); keep `-window-width` for left/right.

## 2. Display

- [x] 2.1 Rewrite `mcp-emacs-run--display` to use `display-buffer-in-direction` with the configured direction and the axis-appropriate size hint; keep focus-on-show.

## 3. Tests & checks

- [x] 3.1 Confirm existing reveal tests still pass (window exists after toggle/switch).
- [x] 3.2 Byte-compile clean.

## 4. Docs

- [x] 4.1 Update README runner section if it mentions the side window.
