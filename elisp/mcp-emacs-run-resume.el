;;; mcp-emacs-run-resume.el --- Native picker for resuming past Claude sessions  -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.9.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `mcp-emacs-run-resume-select' (issue #19): a native Emacs `completing-read'
;; over the current project's past Claude sessions, launching the chosen one
;; with `--resume <session-id>'.  This replaces relying on the CLI's own
;; in-terminal picker (what `mcp-emacs-run-resume' with a bare `--resume' does)
;; -- pick from Emacs, with readable labels.
;;
;; The session store layout (verified):
;;   ~/.claude/projects/<slug>/<session-id>.jsonl
;; where <slug> is the project root path with `/' and `.' replaced by `-', and
;; <session-id> is the file-name stem (a uuid).
;;
;; The preview label is `<relative-time>  <first real prompt>'.  Extracting the
;; first *genuine* user prompt is the fiddly part: a transcript's literal first
;; `type:user' line is often an injected `<command-message>' / `<local-command-
;; caveat>' block or a tool result, not the human's prompt, so those are skipped
;; and the first real text line wins.  Falls back to the session id.

;;; Code:

(require 'json)
(require 'subr-x)

(defcustom mcp-emacs-run-resume-projects-root
  (expand-file-name "~/.claude/projects")
  "Directory holding per-project Claude session stores."
  :type 'directory :group 'mcp-emacs-run)

(defcustom mcp-emacs-run-resume-head-lines 40
  "How many leading transcript lines to scan for the first real prompt.
Tuned to clear injected caveat/command blocks at the head without
reading whole transcripts."
  :type 'integer :group 'mcp-emacs-run)

;;;; Store location

(defun mcp-emacs-run-resume--slug (root)
  "Return the Claude store slug for project ROOT.
The slug is ROOT's absolute path with `/' and `.' each replaced by `-'."
  (let ((path (directory-file-name (expand-file-name root))))
    (replace-regexp-in-string "[/.]" "-" path)))

(defun mcp-emacs-run-resume--store-dir (root)
  "Return the session store directory for project ROOT."
  (expand-file-name (mcp-emacs-run-resume--slug root)
                    mcp-emacs-run-resume-projects-root))

(defun mcp-emacs-run-resume--session-files (root)
  "Return ROOT's session `.jsonl' files, most-recently-modified first."
  (let ((dir (mcp-emacs-run-resume--store-dir root)))
    (when (file-directory-p dir)
      (sort (directory-files dir t "\\.jsonl\\'")
            (lambda (a b)
              (time-less-p (file-attribute-modification-time (file-attributes b))
                           (file-attribute-modification-time (file-attributes a))))))))

(defun mcp-emacs-run-resume--session-id (file)
  "Return the session id (file-name stem) for transcript FILE."
  (file-name-base file))

;;;; Preview extraction

(defun mcp-emacs-run-resume--content-text (content)
  "Normalise a message CONTENT value to a single string, or nil.
CONTENT is either a string or a vector/list of blocks; for the latter
the first block carrying a `text' field is used."
  (cond
   ((stringp content) content)
   ((and (or (vectorp content) (listp content)) (> (length content) 0))
    (let ((blocks (append content nil)) text)
      (while (and blocks (not text))
        (let ((b (pop blocks)))
          (when (and (listp b) (stringp (alist-get 'text b)))
            (setq text (alist-get 'text b)))))
      text))
   (t nil)))

(defun mcp-emacs-run-resume--noise-p (text)
  "Return non-nil when TEXT is an injected block, not a human prompt.
Skips `<command-*>' / `<local-command-*>' wrappers and caveat blocks."
  (let ((s (string-trim (or text ""))))
    (or (string-empty-p s)
        (string-prefix-p "<command-" s)
        (string-prefix-p "<local-command-" s)
        (string-prefix-p "Caveat:" s))))

(defun mcp-emacs-run-resume--first-prompt (file)
  "Return the first genuine user prompt in transcript FILE, or nil.
Reads only the head window (`mcp-emacs-run-resume-head-lines'): parses
each line, keeps `type:user' entries whose normalised text is not noise,
and returns the first such text trimmed to a single line."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file nil 0)
      (goto-char (point-min))
      (let ((json-object-type 'alist)
            (json-array-type 'vector)
            (n 0) prompt)
        (while (and (not prompt)
                    (< n mcp-emacs-run-resume-head-lines)
                    (not (eobp)))
          (setq n (1+ n))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (unless (string-empty-p (string-trim line))
              (let ((obj (ignore-errors (json-read-from-string line))))
                (when (and obj (equal (alist-get 'type obj) "user"))
                  (let* ((msg (alist-get 'message obj))
                         (text (mcp-emacs-run-resume--content-text
                                (and (listp msg) (alist-get 'content msg)))))
                    (when (and text (not (mcp-emacs-run-resume--noise-p text)))
                      (setq prompt (car (split-string (string-trim text) "\n")))))))))
          (forward-line 1))
        prompt))))

(defun mcp-emacs-run-resume--relative-time (file)
  "Return a short relative-time string for FILE's modification time."
  (let* ((mtime (file-attribute-modification-time (file-attributes file)))
         (secs (float-time (time-subtract (current-time) mtime))))
    (cond
     ((< secs 60) "just now")
     ((< secs 3600) (format "%dm ago" (floor secs 60)))
     ((< secs 86400) (format "%dh ago" (floor secs 3600)))
     (t (format "%dd ago" (floor secs 86400))))))

(defun mcp-emacs-run-resume--label (file)
  "Return the `completing-read' label for session transcript FILE.
`<relative-time>  <first real prompt>', falling back to the session id
when no genuine prompt is found in the head window."
  (let ((id (mcp-emacs-run-resume--session-id file)))
    (format "%-8s  %s"
            (mcp-emacs-run-resume--relative-time file)
            (or (mcp-emacs-run-resume--first-prompt file) id))))

;;;; Command

;;;###autoload
(defun mcp-emacs-run-resume-select ()
  "Pick a past Claude session for the current project and resume it.
`completing-read' over the project's stored sessions (most recent
first), labelled with a relative time and the first real prompt, then
launch the chosen one with `--resume <session-id>'.  Signals a
`user-error' when the store is empty or missing -- it never silently
falls back to the CLI's own picker (use `mcp-emacs-run-resume' for
that)."
  (interactive)
  (require 'mcp-emacs-run)
  (let* ((root (mcp-emacs-run--project-root))
         (files (mcp-emacs-run-resume--session-files root)))
    (unless files
      (user-error "No past Claude sessions for %s"
                  (mcp-emacs-run--project-name root)))
    (let* ((alist (mapcar (lambda (f) (cons (mcp-emacs-run-resume--label f) f))
                          files))
           (pick (completing-read "Resume session: " alist nil t))
           (file (cdr (assoc pick alist))))
      (when file
        (mcp-emacs-run--launch root nil "--resume"
                               (mcp-emacs-run-resume--session-id file))))))

(provide 'mcp-emacs-run-resume)
;;; mcp-emacs-run-resume.el ends here
