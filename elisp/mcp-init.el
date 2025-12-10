;;; mcp-init.el --- Helper functions for MCP Emacs -*- lexical-binding: t; -*-

(require 'subr-x nil t)
(require 'org nil t)
(require 'org-agenda nil t)

(defun mcp-emacs--current-buffer ()
  "Return the buffer associated with the currently selected window."
  (window-buffer (frame-selected-window (selected-frame))))

(defun mcp-emacs-get-buffer-content ()
  (with-current-buffer (mcp-emacs--current-buffer)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun mcp-emacs-get-buffer-filename ()
  (with-current-buffer (mcp-emacs--current-buffer)
    (buffer-file-name)))

(defun mcp-emacs-get-selection ()
  (with-current-buffer (mcp-emacs--current-buffer)
    (when (use-region-p)
      (buffer-substring-no-properties (region-beginning) (region-end)))))

(defun mcp-emacs-open-file (path)
  (find-file path)
  path)

(defun mcp-emacs-get-flycheck-info ()
  (with-current-buffer (mcp-emacs--current-buffer)
    (if (bound-and-true-p flycheck-mode)
        (let ((errors (flycheck-overlay-errors-at (point))))
          (if errors
              (mapconcat
               (lambda (err)
                 (format "%s: %s [%s]"
                         (flycheck-error-level err)
                         (flycheck-error-message err)
                         (flycheck-error-checker err)))
               errors
               "\n")
            "No flycheck messages at point"))
      "Flycheck mode not active")))

(defun mcp-emacs-get-error-context ()
  (let* ((max-chars 2000)
         (known-buffers '("*Backtrace*" "*Compile-Log*" "*compilation*" "*Messages*" "*Warnings*" "*Async-native-compile-log*"))
         (dynamic (let (matches)
                    (dolist (buf (buffer-list) matches)
                      (let ((name (buffer-name buf)))
                        (when (and name
                                   (string-match-p "\\(error\\|warning\\|backtrace\\|compile\\|log\\)" (downcase name)))
                          (push name matches))))))
         (targets (delete-dups (append known-buffers dynamic)))
         (results '()))
    (dolist (name targets)
      (when-let ((buf (get-buffer name)))
        (with-current-buffer buf
          (let* ((raw (buffer-substring-no-properties (point-min) (point-max)))
                 (snippet (if (> (length raw) max-chars)
                              (concat (substring raw 0 max-chars) "\n... [truncated]")
                            raw))
                 (trimmed (string-trim snippet)))
            (push (format "Buffer: %s\n%s"
                          name
                          (if (string-empty-p trimmed)
                              "[Buffer is empty]"
                            trimmed))
                  results)))))
    (if results
        (mapconcat #'identity (nreverse results) "\n\n---\n\n")
      "No error-related buffers were found.")))

(defun mcp-emacs-get-org-tasks ()
  (let ((result '()))
    (org-map-entries
     (lambda ()
       (let* ((heading (org-get-heading t t t t))
              (todo-state (org-get-todo-state))
              (tags (org-get-tags))
              (file (buffer-file-name))
              (priority (org-get-priority (thing-at-point 'line)))
              (scheduled (org-get-scheduled-time (point)))
              (deadline (org-get-deadline-time (point))))
         (when todo-state
           (push (format "* [%s] %s%s%s\n  File: %s%s%s"
                         todo-state
                         (if (> priority 0)
                             (format "[#%c] " (org-priority-to-value priority))
                           "")
                         heading
                         (if tags (format " :%s:" (mapconcat #'identity tags ":")) "")
                         file
                         (if scheduled (format "\n  SCHEDULED: %s" (format-time-string "%Y-%m-%d %a" scheduled)) "")
                         (if deadline (format "\n  DEADLINE: %s" (format-time-string "%Y-%m-%d %a" deadline)) ""))
                 result))))
     t
     'agenda)
    (if result
        (mapconcat #'identity (reverse result) "\n\n")
      "No tasks found")))

(defun mcp-emacs-get-env-vars ()
  (let* ((entries (copy-sequence process-environment))
         (sorted (sort entries #'string-lessp)))
    (if sorted
        (mapconcat #'identity sorted "\n")
      "Environment is empty")))

(provide 'mcp-emacs)

;;; mcp-init.el ends here
