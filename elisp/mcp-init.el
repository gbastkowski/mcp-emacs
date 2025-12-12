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

(defun mcp-emacs--line-column-position (line column)
  (let ((line (if (and (integerp line) (> line 0)) line 1))
        (column (if (and (integerp column) (> column 0)) column 1)))
    (save-excursion
      (goto-char (point-min))
      (forward-line (1- line))
      (let* ((line-start (line-beginning-position))
             (line-end (line-end-position))
             (line-length (- line-end line-start))
             (offset (min (max 0 (1- column)) line-length)))
        (+ line-start offset)))))

(defun mcp-emacs--normalize-position (pos)
  (cond
   ((markerp pos) (marker-position pos))
   ((overlayp pos) (overlay-start pos))
   ((numberp pos) pos)
   ((and (consp pos) (numberp (car pos))) (car pos))
   (t nil)))

(defun mcp-emacs--find-imenu-position (target entries)
  (catch 'mcp-emacs--found
    (dolist (entry entries nil)
      (cond
       ((or (null entry)
            (and (stringp (car entry))
                 (string-prefix-p "*" (car entry))))
        nil)
       ((and (consp entry) (imenu--subalist-p entry))
        (let ((child (mcp-emacs--find-imenu-position target (cdr entry))))
          (when child (throw 'mcp-emacs--found child))))
       ((and (consp entry)
             (stringp (car entry))
             (string= target (car entry)))
        (let ((pos (mcp-emacs--normalize-position (cdr entry))))
          (when pos (throw 'mcp-emacs--found pos))))))))

(defun mcp-emacs--goto-function (name)
  (when (and (stringp name)
             (not (string-empty-p name))
             (require 'imenu nil t))
    (let* ((index (imenu--make-index-alist t))
           (pos (mcp-emacs--find-imenu-position name index)))
      (when pos
        (goto-char pos)
        t))))

(defun mcp-emacs-goto-location (line column function-name)
  "Move point to LINE/COLUMN or FUNCTION-NAME in the current buffer."
  (let* ((buffer (mcp-emacs--current-buffer))
         (line (if (and (integerp line) (> line 0)) line nil))
         (column (if (and (integerp column) (> column 0)) column nil))
         (fn (and (stringp function-name)
                  (not (string-empty-p function-name))
                  function-name)))
    (with-current-buffer buffer
      (cond
       (fn
        (unless (mcp-emacs--goto-function fn)
          (error "Function %s not found" fn))
        (when column (move-to-column (1- column) t))
        (recenter)
        (format "Moved to function %s (line %d, column %d)"
                fn
                (line-number-at-pos)
                (1+ (current-column))))
       (line
        (goto-char (point-min))
        (forward-line (1- line))
        (when column (move-to-column (1- column) t))
        (recenter)
        (format "Moved to line %d, column %d" (line-number-at-pos) (1+ (current-column))))
       (t
        (error "Either line or function-name must be provided"))))))

(defun mcp-emacs-toggle-org-todo (state)
  "Toggle the TODO state at the current heading. When STATE is non-nil, set it explicitly."
  (unless (derived-mode-p 'org-mode)
    (error "Not in an org buffer"))
  (save-excursion
    (org-back-to-heading t)
    (let* ((current (org-get-todo-state))
           (next (cond
                  ((and (stringp state) (not (string-empty-p state))) state)
                  ((null state) (or (org-get-todo-state) (car org-todo-keywords-1)))
                  (t nil))))
      (if next
          (progn
            (org-todo next)
            (format "Set TODO state to %s" next))
        (org-todo 'next)
        (format "Advanced TODO state%s"
                (if current (format " (now %s)" (org-get-todo-state)) ""))))))

(defun mcp-emacs-edit-file-region (path start-line start-column end-line end-column replacement save)
  "Replace the text in PATH between START and END with REPLACEMENT.
START-LINE/START-COLUMN and END-LINE/END-COLUMN are 1-based coordinates."
  (unless (and (stringp path) (not (string-empty-p path)))
    (error "Path must be a non-empty string"))
  (let* ((buffer (or (get-file-buffer path) (find-file-noselect path)))
         (s-line (if (and (integerp start-line) (> start-line 0)) start-line 1))
         (s-col (if (and (integerp start-column) (> start-column 0)) start-column 1))
         (e-line (if (and (integerp end-line) (> end-line 0)) end-line 1))
         (e-col (if (and (integerp end-column) (> end-column 0)) end-column 1))
         (text (or replacement "")))
    (with-current-buffer buffer
      (let ((start (mcp-emacs--line-column-position s-line s-col))
            (end (mcp-emacs--line-column-position e-line e-col)))
        (when (> start end)
          (error "Start position %d:%d must be before end position %d:%d" s-line s-col e-line e-col))
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char start)
            (delete-region start end)
            (insert text)))
        (when save (save-buffer))
        (format "Edited %s at %d:%d-%d:%d%s"
                path
                s-line
                s-col
                e-line
                e-col
                (if save " (saved)" ""))))))

(defun mcp-emacs-insert-at-point (text replace-selection)
  "Insert TEXT at point. When REPLACE-SELECTION is non-nil and a region is active, replace it."
  (let ((buffer (mcp-emacs--current-buffer))
        (payload (or text "")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (had-selection (use-region-p))
            (inserted-length (length payload)))
        (if (and replace-selection had-selection)
            (let ((start (region-beginning))
                  (end (region-end)))
              (delete-region start end)
              (goto-char start)
              (insert payload)
              (format "Replaced selection (%d chars) with %d chars"
                      (- end start)
                      inserted-length))
          (progn
            (insert payload)
            (if replace-selection
                (format "No selection active; inserted %d chars at point" inserted-length)
              (format "Inserted %d chars at point" inserted-length)))))))

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

(defun mcp-emacs-get-buffer-text (name)
  (let ((buf (get-buffer name)))
    (if (not buf)
        (format "[Buffer %s not found]" name)
      (with-current-buffer buf
        (let* ((raw (buffer-substring-no-properties (point-min) (point-max)))
               (trimmed (string-trim raw)))
          (if (string-empty-p trimmed)
              "[Buffer is empty]"
            raw)))))

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
