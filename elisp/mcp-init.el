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

(defun mcp-emacs--format-list (items)
  (if items
      (mapconcat (lambda (item) (format "  - %s" item)) items "\n")
    "  [none]"))

(defun mcp-emacs--check-commands (commands)
  (mapcar
   (lambda (cmd)
     (format "%s: %s"
             cmd
             (if (executable-find cmd)
                 "FOUND"
               "MISSING")))
   commands))

(defun mcp-emacs--collect-lsp-workspaces ()
  (when (require 'lsp-mode nil t)
    (let ((seen (make-hash-table :test 'eq))
          (entries '()))
      (dolist (buf (buffer-list))
        (with-current-buffer buf
          (when (and (boundp 'lsp-mode) lsp-mode (fboundp 'lsp-workspaces))
            (dolist (ws (lsp-workspaces))
              (unless (gethash ws seen)
                (puthash ws t seen)
                (push (mcp-emacs--describe-workspace ws) entries))))))
      (nreverse entries))))

(defun mcp-emacs--describe-workspace (workspace)
  (let* ((client (when (fboundp 'lsp--workspace-client)
                   (lsp--workspace-client workspace)))
         (server (when (and client (fboundp 'lsp--client-server-id))
                   (lsp--client-server-id client)))
         (root (when (fboundp 'lsp--workspace-root)
                 (lsp--workspace-root workspace)))
         (status (when (fboundp 'lsp--workspace-status)
                   (lsp--workspace-status workspace))))
    (format "%s (root: %s, status: %s)"
            (or server "unknown")
            (or root "?")
            (or status "unknown"))))

(defun mcp-emacs-diagnose ()
  (let* ((basic (list
                 (format "Emacs version: %s" emacs-version)
                 (format "System type: %s" system-type)
                 (format "System configuration: %s" system-configuration)
                 (when (boundp 'doom-version)
                   (format "Doom version: %s" doom-version))))
         (exec (mapcar (lambda (path) (format "  - %s" path)) exec-path))
         (commands '("semgrep" "deno" "typescript-language-server" "metals"))
         (command-results (mcp-emacs--check-commands commands))
         (workspaces (mcp-emacs--collect-lsp-workspaces))
         (sections (list
                    (concat "Basic Info:\n"
                            (mcp-emacs--format-list (delq nil basic)))
                    (concat "exec-path:\n"
                            (if exec
                                (mapconcat #'identity exec "\n")
                              "  [empty]"))
                    (concat "Command availability:\n"
                            (mcp-emacs--format-list command-results))
                    (concat "LSP workspaces:\n"
                            (if workspaces
                                (mcp-emacs--format-list workspaces)
                              "  [none detected or lsp-mode not active]")))))
    (mapconcat #'identity sections "\n\n")))

(provide 'mcp-emacs)

;;; mcp-init.el ends here
