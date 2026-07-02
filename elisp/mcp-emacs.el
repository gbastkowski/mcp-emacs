;;; mcp-emacs.el --- Helper functions for MCP Emacs -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 0.4.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs

;;; Commentary:

;; Helper entry points invoked by the MCP server; load this file and
;; ensure the Emacs server is running before starting the MCP server.

;;; Code:

(require 'subr-x nil t)
(require 'org nil t)
(require 'org-agenda nil t)

(defun mcp-emacs--current-buffer ()
  "Return the buffer associated with the currently selected window."
  (window-buffer (frame-selected-window (selected-frame))))

(defun mcp-emacs-get-buffer-content ()
  "Return the full text of the current buffer without properties."
  (with-current-buffer (mcp-emacs--current-buffer)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun mcp-emacs-get-buffer-filename ()
  "Return the filename associated with the current buffer, or nil."
  (with-current-buffer (mcp-emacs--current-buffer)
    (buffer-file-name)))

(defun mcp-emacs-get-selection ()
  "Return the active region text for the current buffer, or nil."
  (with-current-buffer (mcp-emacs--current-buffer)
    (when (use-region-p)
      (buffer-substring-no-properties (region-beginning) (region-end)))))

(defun mcp-emacs-open-file (path)
  "Open PATH in the current window and return PATH."
  (find-file path)
  path)

(defun mcp-emacs--line-column-position (line column)
  "Return buffer position for 1-based LINE and COLUMN."
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
  "Normalize an imenu position POS to a numeric buffer position."
  (cond
   ((markerp pos) (marker-position pos))
   ((overlayp pos) (overlay-start pos))
   ((numberp pos) pos)
   ((and (consp pos) (numberp (car pos))) (car pos))
   (t nil)))

(defun mcp-emacs--find-imenu-position (target entries)
  "Find TARGET in imenu ENTRIES and return its position."
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
  "Jump to imenu entry NAME and return non-nil when found."
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

(defun mcp-emacs-get-current-clocked-task ()
  "Return the heading of the currently clocked Org task, or nil when no clock is active."
  (when (org-clocking-p)
    (let ((marker (and (boundp 'org-clock-marker) org-clock-marker)))
      (when (and marker (marker-buffer marker))
        (with-current-buffer (marker-buffer marker)
          (save-excursion
           (goto-char marker)
           (org-back-to-heading t)
           (org-get-heading t t t t)))))))

(defun mcp-emacs-get-current-task-at-point ()
  "Return the heading of the Org task at point, or nil when point is not in a task context."
  (with-current-buffer (mcp-emacs--current-buffer)
    (when (derived-mode-p 'org-mode)
      (save-excursion
        (org-back-to-heading t)
        (when (org-get-todo-state)
          (org-get-heading t t t t))))))

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
              (format "Inserted %d chars at point" inserted-length))))))))

(defun mcp-emacs-save-buffer ()
  "Save the current buffer if it is visiting a file."
  (with-current-buffer (mcp-emacs--current-buffer)
    (if (buffer-file-name)
        (progn
          (save-buffer)
          (format "Saved buffer: %s" (buffer-name)))
      "Current buffer is not visiting a file")))

(defun mcp-emacs-close-buffer (save)
  "Close the current buffer, saving when SAVE is non-nil."
  (with-current-buffer (mcp-emacs--current-buffer)
    (let ((name (buffer-name)))
      (cond
       ((and save (not (buffer-file-name)))
        "Current buffer is not visiting a file")
       ((and (buffer-modified-p) (not save))
        "Buffer has unsaved changes")
       (t
        (when save
          (save-buffer))
        (kill-buffer (current-buffer))
        (format "Closed buffer: %s" name))))))

(defun mcp-emacs-switch-buffer (name)
  "Switch to the buffer named NAME."
  (let ((buffer (get-buffer name)))
    (if buffer
        (progn
          (switch-to-buffer buffer)
          (format "Switched to buffer: %s" (buffer-name buffer)))
      "Buffer not found")))

(defun mcp-emacs-get-flycheck-info ()
  "Return flycheck messages at point, or a status message."
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
      (or (let ((msgs (mcp-emacs--flymake-diagnostics-at (point))))
            (when msgs (mapconcat #'identity msgs "\n")))
          "Flycheck mode not active"))))

(defun mcp-emacs--flymake-diagnostics-at (pos)
  "Return flymake diagnostic strings at POS, or nil."
  (when (and (fboundp 'flymake-diagnostics) (bound-and-true-p flymake-mode))
    (mapcar
     (lambda (d)
       (format "%s: %s"
               (flymake-diagnostic-type d)
               (flymake-diagnostic-text d)))
     (flymake-diagnostics pos))))

(defun mcp-emacs-get-diagnostics ()
  "Return all diagnostics for the current buffer via Flycheck or Flymake.
Detects which backend is active; returns a status message when neither is."
  (with-current-buffer (mcp-emacs--current-buffer)
    (cond
     ((bound-and-true-p flycheck-mode)
      (let ((errors (flycheck-current-errors)))
        (if errors
            (mapconcat
             (lambda (err)
               (format "%s:%s: %s: %s [%s]"
                       (or (flycheck-error-line err) "?")
                       (or (flycheck-error-column err) "?")
                       (flycheck-error-level err)
                       (flycheck-error-message err)
                       (flycheck-error-checker err)))
             errors
             "\n")
          "No diagnostics in buffer")))
     ((bound-and-true-p flymake-mode)
      (let ((diags (flymake-diagnostics)))
        (if diags
            (mapconcat
             (lambda (d)
               (format "%s: %s: %s"
                       (line-number-at-pos (flymake-diagnostic-beg d))
                       (flymake-diagnostic-type d)
                       (flymake-diagnostic-text d)))
             diags
             "\n")
          "No diagnostics in buffer")))
     (t "Neither Flycheck nor Flymake is active"))))

(defun mcp-emacs-get-error-context ()
  "Summarize recent error-related buffers."
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
  "Return the full text of buffer NAME."
  (let ((buf (get-buffer name)))
    (if (not buf)
        (format "[Buffer %s not found]" name)
      (with-current-buffer buf
        (let* ((raw (buffer-substring-no-properties (point-min) (point-max)))
               (trimmed (string-trim raw)))
          (if (string-empty-p trimmed)
              "[Buffer is empty]"
            raw))))))

(defun mcp-emacs-get-org-tasks ()
  "Return formatted org-mode tasks from agenda files."
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
  "Return Emacs environment variables as a newline-delimited string."
  (let* ((entries (copy-sequence process-environment))
         (sorted (sort entries #'string-lessp)))
    (if sorted
        (mapconcat #'identity sorted "\n")
      "Environment is empty")))

(defun mcp-emacs--format-list (items)
  "Format ITEMS as a bullet list."
  (if items
      (mapconcat (lambda (item) (format "  - %s" item)) items "\n")
    "  [none]"))

(defun mcp-emacs--check-commands (commands)
  "Return availability strings for COMMANDS."
  (mapcar
   (lambda (cmd)
     (format "%s: %s"
             cmd
             (if (executable-find cmd)
                 "FOUND"
               "MISSING")))
   commands))

(defun mcp-emacs--collect-lsp-workspaces ()
  "Collect LSP workspaces from active lsp-mode buffers."
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
  "Return a human-readable summary for WORKSPACE."
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
  "Return a diagnostic report about the current Emacs session."
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

(defun mcp-emacs--flatten-imenu (entries prefix)
  "Flatten imenu ENTRIES into (name . position) pairs, prefixing nested names with PREFIX."
  (let (result)
    (dolist (entry entries (nreverse result))
      (cond
       ((null entry) nil)
       ((and (stringp (car entry)) (string-prefix-p "*" (car entry))) nil)
       ((and (consp entry) (imenu--subalist-p entry))
        (setq result
              (nconc (nreverse (mcp-emacs--flatten-imenu
                                (cdr entry)
                                (concat prefix (car entry) "/")))
                     result)))
       ((and (consp entry) (stringp (car entry)))
        (let ((pos (mcp-emacs--normalize-position (cdr entry))))
          (when pos
            (push (cons (concat prefix (car entry)) pos) result))))))))

(defun mcp-emacs-imenu-list-symbols ()
  "List the current buffer's symbols (functions, classes, variables) with line numbers."
  (with-current-buffer (mcp-emacs--current-buffer)
    (if (not (require 'imenu nil t))
        "imenu is not available"
      (let* ((index (ignore-errors (imenu--make-index-alist t)))
             (flat (and index (mcp-emacs--flatten-imenu index ""))))
        (if flat
            (mapconcat
             (lambda (pair)
               (format "%d: %s"
                       (line-number-at-pos (cdr pair))
                       (car pair)))
             (sort flat (lambda (a b) (< (cdr a) (cdr b))))
             "\n")
          "No symbols found in buffer")))))

(defun mcp-emacs--xref-format (items)
  "Format xref ITEMS as file:line: summary lines."
  (if (not items)
      "No matches found"
    (mapconcat
     (lambda (item)
       (let* ((summary (substring-no-properties (xref-item-summary item)))
              (loc (xref-item-location item))
              (file (ignore-errors (xref-location-group loc)))
              (line (ignore-errors (xref-location-line loc))))
         (format "%s:%s: %s"
                 (or file "?")
                 (or line "?")
                 summary)))
     items
     "\n")))

(defun mcp-emacs-xref-find-references (identifier)
  "Find references to IDENTIFIER (or the symbol at point) via xref."
  (with-current-buffer (mcp-emacs--current-buffer)
    (unless (require 'xref nil t)
      (error "xref is not available"))
    (let* ((backend (xref-find-backend))
           (id (if (and (stringp identifier) (not (string-empty-p identifier)))
                   identifier
                 (xref-backend-identifier-at-point backend))))
      (unless id
        (error "No identifier given or found at point"))
      (mcp-emacs--xref-format
       (xref-backend-references backend id)))))

(defun mcp-emacs-xref-find-apropos (pattern)
  "Find symbols matching PATTERN across the project via xref apropos."
  (with-current-buffer (mcp-emacs--current-buffer)
    (unless (require 'xref nil t)
      (error "xref is not available"))
    (unless (and (stringp pattern) (not (string-empty-p pattern)))
      (error "A non-empty pattern is required"))
    (mcp-emacs--xref-format
     (xref-backend-apropos (xref-find-backend) pattern))))

(defun mcp-emacs-project-info ()
  "Return an overview of the current project: root, active file, and size."
  (with-current-buffer (mcp-emacs--current-buffer)
    (if (not (require 'project nil t))
        "project.el is not available"
      (let ((proj (project-current)))
        (if (not proj)
            "Not inside a project"
          (let* ((root (project-root proj))
                 (file (buffer-file-name))
                 (files (ignore-errors (project-files proj)))
                 (count (length files)))
            (string-join
             (delq nil
                   (list (format "Project root: %s" root)
                         (when file (format "Active file: %s" file))
                         (format "Tracked files: %d" count)))
             "\n")))))))

(defun mcp-emacs-treesit-info ()
  "Return tree-sitter node info at point: node type, range, and ancestor chain."
  (with-current-buffer (mcp-emacs--current-buffer)
    (cond
     ((not (and (fboundp 'treesit-available-p) (treesit-available-p)))
      "Tree-sitter is not available in this Emacs")
     ((not (treesit-parser-list))
      "No tree-sitter parser active in this buffer")
     (t
      (let ((node (treesit-node-at (point))))
        (if (not node)
            "No tree-sitter node at point"
          (let (chain)
            (let ((n node))
              (while n
                (push (format "%s [%d-%d]"
                              (treesit-node-type n)
                              (treesit-node-start n)
                              (treesit-node-end n))
                      chain)
                (setq n (treesit-node-parent n))))
            (format "Node at point: %s\nAncestors (leaf -> root):\n%s"
                    (treesit-node-type node)
                    (mapconcat (lambda (s) (concat "  " s))
                               (nreverse chain)
                               "\n")))))))))

;;;; Org task session sync
;;
;; A "session task file" is an Org file whose first top-level heading is
;; the task.  Its TODO keyword is the *session status*; its `SESSION'
;; property holds the session id (a plain label).  Child headings of the
;; task are the TODO checklist items.  Progress notes are appended to the
;; task's body; new items are appended as children under the task
;; heading.  The AI mutates only items it can identify (by `ID'/
;; `CUSTOM_ID' property, else heading text) and never reorders, deletes,
;; or rewrites human-authored items.  All edits go through the live
;; buffer; nothing saves to disk unless a tool is defined to save.

(defun mcp-emacs-org-task--buffer-for-path (path)
  "Return the live Org buffer for PATH, opening it if needed.
Signal a `user-error' with a friendly message when PATH is not a
readable file so callers can surface plain text instead of a raw error."
  (unless (and (stringp path) (not (string-empty-p path)))
    (user-error "No task file path was provided"))
  (let ((expanded (expand-file-name path)))
    (or (get-file-buffer expanded)
        (if (file-readable-p expanded)
            (find-file-noselect expanded)
          (user-error "Task file is not readable: %s" path)))))

(defun mcp-emacs-org-task--goto-task ()
  "Move point to the first task heading in the current buffer.
Return non-nil on success, nil when the buffer has no heading."
  (goto-char (point-min))
  (or (org-at-heading-p)
      (outline-next-heading)))

(defun mcp-emacs-org-task--item-id ()
  "Return the ID or CUSTOM_ID property of the heading at point, or nil."
  (or (org-entry-get (point) "ID")
      (org-entry-get (point) "CUSTOM_ID")))

(defun mcp-emacs-org-task--item-headings ()
  "Return the direct child headings of the task as (id . heading) pairs."
  (save-excursion
    (when (mcp-emacs-org-task--goto-task)
      (let ((items '())
            (task-level (org-current-level)))
        (org-map-entries
         (lambda ()
           (when (= (org-current-level) (1+ task-level))
             (push (cons (mcp-emacs-org-task--item-id)
                         (org-get-heading t t t t))
                   items)))
         nil 'tree)
        (nreverse items)))))

(defun mcp-emacs-org-task--find-item (ref)
  "Move point to the child item identified by REF, or return nil.
REF matches an item's ID/CUSTOM_ID property when present, otherwise
its heading text.  Point is left on the matching heading on success."
  (when (and (stringp ref) (not (string-empty-p ref))
             (mcp-emacs-org-task--goto-task))
    (let ((task-level (org-current-level))
          (found nil))
      (save-restriction
        (org-narrow-to-subtree)
        (goto-char (point-min))
        (org-map-entries
         (lambda ()
           (when (and (not found)
                      (= (org-current-level) (1+ task-level))
                      (or (equal ref (mcp-emacs-org-task--item-id))
                          (equal ref (org-get-heading t t t t))))
             (setq found (point))))
         nil 'tree))
      (when found
        (goto-char found)
        t))))

(defun mcp-emacs-org-task-read (path)
  "Return a structured, readable summary of the session task file at PATH.
Reflects live buffer state, including unsaved edits.  Returns friendly
plain text for a missing/invalid path or a file with no task heading."
  (condition-case err
      (with-current-buffer (mcp-emacs-org-task--buffer-for-path path)
        (unless (derived-mode-p 'org-mode)
          (user-error "Not an Org file: %s" path))
        (save-excursion
          (if (not (mcp-emacs-org-task--goto-task))
              "No task heading found in file"
            (let* ((heading (org-get-heading t t t t))
                   (status (or (org-get-todo-state) "(no status)"))
                   (session (or (org-entry-get (point) "SESSION") "(no session id)"))
                   (items (mcp-emacs-org-task--item-headings))
                   (lines
                    (list (format "Task: %s" heading)
                          (format "Session: %s" session)
                          (format "Status: %s" status)
                          "TODO:")))
              (if (null items)
                  (setq lines (append lines (list "  [empty checklist]")))
                (save-excursion
                  (mcp-emacs-org-task--goto-task)
                  (let ((task-level (org-current-level)))
                    (org-map-entries
                     (lambda ()
                       (when (= (org-current-level) (1+ task-level))
                         (setq lines
                               (append lines
                                       (list (format "  - [%s] %s"
                                                     (or (org-get-todo-state) " ")
                                                     (org-get-heading t t t t)))))))
                     nil 'tree))))
              (mapconcat #'identity lines "\n")))))
    (user-error (error-message-string err))))

(defun mcp-emacs-org-task-set-session-status (path status)
  "Set the session STATUS (an Org keyword) of the task file at PATH.
Reject a keyword not in `org-todo-keywords-1', leaving the status
unchanged.  Edits the live buffer only; does not save."
  (condition-case err
      (with-current-buffer (mcp-emacs-org-task--buffer-for-path path)
        (unless (derived-mode-p 'org-mode)
          (user-error "Not an Org file: %s" path))
        (unless (and (stringp status) (not (string-empty-p status)))
          (user-error "No status keyword was provided"))
        (unless (member status org-todo-keywords-1)
          (user-error "Unrecognized status keyword: %s" status))
        (save-excursion
          (if (not (mcp-emacs-org-task--goto-task))
              "No task heading found in file"
            (org-todo status)
            (format "Set session status to %s" status))))
    (user-error (error-message-string err))))

(defun mcp-emacs-org-task-set-item-status (path ref status)
  "Set the Org keyword of the item identified by REF in PATH to STATUS.
No change is made when the item cannot be identified.  Only the matched
item is touched.  Edits the live buffer only; does not save."
  (condition-case err
      (with-current-buffer (mcp-emacs-org-task--buffer-for-path path)
        (unless (derived-mode-p 'org-mode)
          (user-error "Not an Org file: %s" path))
        (unless (and (stringp status) (not (string-empty-p status)))
          (user-error "No status keyword was provided"))
        (unless (member status org-todo-keywords-1)
          (user-error "Unrecognized status keyword: %s" status))
        (save-excursion
          (if (mcp-emacs-org-task--find-item ref)
              (progn
                (org-todo status)
                (format "Set item %S to %s" ref status))
            (format "TODO item not found: %s" ref))))
    (user-error (error-message-string err))))

(defun mcp-emacs-org-task-append-note (path note)
  "Append NOTE to the body of the task in PATH, after existing content.
Existing human content is left untouched.  Edits the live buffer only;
does not save."
  (condition-case err
      (with-current-buffer (mcp-emacs-org-task--buffer-for-path path)
        (unless (derived-mode-p 'org-mode)
          (user-error "Not an Org file: %s" path))
        (unless (and (stringp note) (not (string-empty-p note)))
          (user-error "No note text was provided"))
        (save-excursion
          (if (not (mcp-emacs-org-task--goto-task))
              "No task heading found in file"
            ;; Insert after the task's own body but before the first
            ;; child heading, leaving existing body content in place.
            (let ((task-level (org-current-level))
                  (limit (save-excursion (org-end-of-subtree t t) (point))))
              (org-end-of-meta-data t)
              (if (re-search-forward org-heading-regexp limit t)
                  (goto-char (match-beginning 0))
                (goto-char limit))
              (let ((inhibit-read-only t))
                (unless (bolp) (insert "\n"))
                (insert note "\n")))
            "Appended progress note")))
    (user-error (error-message-string err))))

(defun mcp-emacs-org-task-append-item (path text keyword)
  "Append a new child TODO item TEXT under the task heading in PATH.
KEYWORD, when non-nil, sets the item's Org keyword; it defaults to the
first configured TODO keyword.  Existing items keep their order and
content.  Edits the live buffer only; does not save."
  (condition-case err
      (with-current-buffer (mcp-emacs-org-task--buffer-for-path path)
        (unless (derived-mode-p 'org-mode)
          (user-error "Not an Org file: %s" path))
        (unless (and (stringp text) (not (string-empty-p text)))
          (user-error "No item text was provided"))
        (let ((kw (cond
                   ((and (stringp keyword) (not (string-empty-p keyword)))
                    (unless (member keyword org-todo-keywords-1)
                      (user-error "Unrecognized status keyword: %s" keyword))
                    keyword)
                   (t (car org-todo-keywords-1)))))
          (save-excursion
            (if (not (mcp-emacs-org-task--goto-task))
                "No task heading found in file"
              (let ((task-level (org-current-level))
                    (inhibit-read-only t))
                ;; Move to the end of the task subtree and insert a new
                ;; child heading, leaving existing children in place.
                (org-end-of-subtree t t)
                (unless (bolp) (insert "\n"))
                (insert (make-string (1+ task-level) ?*) " " kw " " text "\n")
                (format "Appended TODO item: %s %s" kw text))))))
    (user-error (error-message-string err))))

(provide 'mcp-emacs)

;;; mcp-emacs.el ends here
