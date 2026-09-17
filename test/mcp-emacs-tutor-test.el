;;; mcp-emacs-tutor-test.el --- Tests for the guided tutor -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'mcp-emacs-tutor)
(require 'seq)

(defun mcp-emacs-tutor-test--buffer-count ()
  "Count live buffers whose name mentions the tutor.
Match on the name rather than an exact string so a duplicate opened
under a generated name would still be caught."
  (length (seq-filter (lambda (buffer)
                        (string-match-p "mcp-emacs-tutor"
                                        (buffer-name buffer)))
                      (buffer-list))))

(describe "mcp-emacs-tutor"
  (let ((buffer nil))
    (unwind-protect
        (progn
          (delete-other-windows)
          (mcp-emacs-tutor)
          (setq buffer (get-buffer mcp-emacs-tutor-buffer-name))

          (it "opens a non-empty read-only Org buffer"
            (check (and buffer
                        (> (buffer-size buffer) 0)
                        (with-current-buffer buffer
                          (derived-mode-p 'org-mode))
                        (with-current-buffer buffer buffer-read-only))
                   t))

          (it "shows the buffer in a right side window"
            (let ((window (get-buffer-window buffer)))
              (check (and (window-live-p window)
                          (eq (window-parameter window 'window-side) 'right))
                     t)))

          (it "contains a step about starting the MCP server"
            (check-that
             (with-current-buffer buffer
               (string-match-p "^\\*+ Step 1: Start the MCP server"
                               (buffer-string)))))

          (it "contains a step about a diff-gated edit"
            (check-that
             (with-current-buffer buffer
               (string-match-p "^\\*+ Step 6: See an edit gated by a diff"
                               (buffer-string))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-other-windows))))

(describe "mcp-emacs-tutor repeated"
  (let ((buffer nil)
        (before 0))
    (unwind-protect
        (progn
          (delete-other-windows)
          (mcp-emacs-tutor)
          (setq buffer (get-buffer mcp-emacs-tutor-buffer-name))
          (setq before (mcp-emacs-tutor-test--buffer-count))
          (mcp-emacs-tutor)

          (it "reuses the buffer instead of creating a duplicate"
            (check (mcp-emacs-tutor-test--buffer-count) before))

          (it "still shows the same buffer in its side window"
            (check (eq (window-buffer (get-buffer-window buffer)) buffer)
                   t)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-other-windows))))

(test-helper-summary)

;;; mcp-emacs-tutor-test.el ends here
