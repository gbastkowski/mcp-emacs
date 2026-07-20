;;; mcp-emacs-run.el --- Run the Claude Code CLI inside Emacs -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.0.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A terminal runner for the Claude Code CLI, hosted inside Emacs.  The
;; CLI is a full-screen ANSI TUI, so it runs in an eat terminal buffer
;; (eat is a soft dependency, loaded only when present).  The runner is
;; project-aware, keeps one primary session per project, shows its
;; terminal in an ordinary directional window, and supports
;; continue/resume.  Editor-tool integration is provided to the CLI
;; through the mcp-emacs MCP server (via the user's MCP configuration),
;; not by this runner.
;;
;; This file is separate from the MCP server so the server stays pure.

;;; Code:

(require 'project nil t)
(require 'eat nil t)

(declare-function eat-make "eat" (name program &optional startfile &rest switches))
(declare-function eat-term-send-string "eat" (terminal string))
(declare-function project-current "project" (&optional maybe-prompt directory))
(declare-function project-root "project" (project))

(defvar eat-terminal)

;;;; Customization

(defgroup mcp-emacs-run nil
  "Run the Claude Code CLI inside Emacs."
  :group 'tools
  :prefix "mcp-emacs-run-")

(defcustom mcp-emacs-run-executable "claude"
  "Path to the Claude Code CLI executable."
  :type 'string
  :group 'mcp-emacs-run)

(defcustom mcp-emacs-run-flags nil
  "Extra command-line flags passed to the Claude Code CLI."
  :type '(repeat string)
  :group 'mcp-emacs-run)

(defcustom mcp-emacs-run-focus-on-show t
  "When non-nil, showing the runner window also selects it."
  :type 'boolean
  :group 'mcp-emacs-run)

(defcustom mcp-emacs-run-window-direction 'right
  "Direction in which the runner window is placed.
The runner uses an ordinary (non-dedicated) window in this direction, so
it can be split, navigated, and closed like any other window."
  :type '(choice (const right) (const left) (const above) (const below))
  :group 'mcp-emacs-run)

;; TODO specify size in columns/lines
(defcustom mcp-emacs-run-window-width 0.4
  "Width hint for the runner window, as a fraction of the frame.
Used when `mcp-emacs-run-window-direction' is `left' or `right'."
  :type 'number
  :group 'mcp-emacs-run)

(defcustom mcp-emacs-run-window-height 0.4
  "Height hint for the runner window, as a fraction of the frame.
Used when `mcp-emacs-run-window-direction' is `above' or `below'."
  :type 'number
  :group 'mcp-emacs-run)

;;;; State

(defvar mcp-emacs-run--sessions (make-hash-table :test 'equal)
  "Registry mapping a project root to its runner buffer.")

;;;; Helpers

;; TODO isn't this already covered by require further up?
(defun mcp-emacs-run--ensure-eat ()
  "Signal a clear error unless eat is available."
  (unless (featurep 'eat)
    (user-error "mcp-emacs-run requires the `eat' package; please install it")))

;; TODO maybe replace when-let with if-let as when-let looks almost deprecated?
(defun mcp-emacs-run--project-root ()
  "Return the current project root, or the buffer's directory as a fallback."
  (or (when (and (featurep 'project) (fboundp 'project-current))
        (when-let ((proj (project-current nil)))
          (expand-file-name (project-root proj))))
      (expand-file-name default-directory)))

(defun mcp-emacs-run--project-name (root)
  "Return a short name for the project at ROOT."
  (file-name-nondirectory (directory-file-name root)))

(defun mcp-emacs-run--buffer-name (root)
  "Return the runner buffer name for project ROOT."
  (format "*claude:%s*" (mcp-emacs-run--project-name root)))

(defun mcp-emacs-run--live-buffer (root)
  "Return the live runner buffer registered for ROOT, or nil."
  (let ((buf (gethash root mcp-emacs-run--sessions)))
    (if (buffer-live-p buf)
        buf
      (remhash root mcp-emacs-run--sessions)
      nil)))

(defun mcp-emacs-run--display (buffer)
  "Display BUFFER in an ordinary window, honouring the focus preference.
The window is placed in `mcp-emacs-run-window-direction' via
`display-buffer-in-direction', so it stays splittable and closable
rather than a dedicated side window."
  (let* ((horizontal (memq mcp-emacs-run-window-direction '(left right)))
         (size (if horizontal
                   `(window-width . ,mcp-emacs-run-window-width)
                 `(window-height . ,mcp-emacs-run-window-height)))
         (window
          (display-buffer
           buffer
           `((display-buffer-in-direction)
             (direction . ,mcp-emacs-run-window-direction)
             ,size))))
    (when (and window mcp-emacs-run-focus-on-show)
      (select-window window))
    window))

(defun mcp-emacs-run--launch (root no-display &rest extra-switches)
  "Launch the CLI for project ROOT in an eat buffer.
Unless NO-DISPLAY is non-nil, the buffer is shown in the runner window.
EXTRA-SWITCHES are appended to the configured flags (e.g. continue/resume)."
  (mcp-emacs-run--ensure-eat)
  (let* ((default-directory (file-name-as-directory root))
         (name (substring (mcp-emacs-run--buffer-name root) 1 -1)) ; eat-make wraps in *...*
         (switches (append mcp-emacs-run-flags extra-switches))
         (buffer (apply #'eat-make name mcp-emacs-run-executable nil switches)))
    (puthash root buffer mcp-emacs-run--sessions)
    (unless no-display
      (mcp-emacs-run--display buffer))
    buffer))

(defun mcp-emacs-run--send (root string)
  "Send STRING to the live runner terminal for project ROOT.
Signal a `user-error' when ROOT has no live session, or its buffer is
not a live eat terminal."
  (let ((buf (mcp-emacs-run--live-buffer root)))
    (unless buf
      (user-error "No live runner session for this project"))
    (let ((term (buffer-local-value 'eat-terminal buf)))
      (unless term
        (user-error "Runner session for this project is not a live terminal"))
      (eat-term-send-string term string))))

(defun mcp-emacs-run--selection-reference ()
  "Return a reference to the current selection for embedding in a prompt.
In a file-visiting buffer, return an at-mention of the project-relative
path with the active region's line span (or the single line at point
when no region is active).  Otherwise return the selected text verbatim
\(or the current line when no region is active)."
  (let* ((beg (if (use-region-p) (region-beginning) (point)))
         (end (if (use-region-p) (region-end) (point)))
         (file (buffer-file-name)))
    (if file
        (let* ((root (mcp-emacs-run--project-root))
               (rel (file-relative-name file root))
               (start-line (line-number-at-pos beg))
               ;; A region ending at column 0 covers up to the previous line.
               (end-line (line-number-at-pos (if (and (use-region-p) (> end beg)
                                                       (save-excursion
                                                         (goto-char end) (bolp)))
                                                  (1- end)
                                                end))))
          (if (and (use-region-p) (/= start-line end-line))
              (format "@%s:%d-%d" rel start-line end-line)
            (format "@%s:%d" rel start-line)))
      (if (use-region-p)
          (buffer-substring-no-properties beg end)
        (buffer-substring-no-properties (line-beginning-position)
                                        (line-end-position))))))

;;;; Commands

;;;###autoload
(defun mcp-emacs-run (&rest extra-switches)
  "Start (or switch to) the Claude Code runner for the current project.
Reuses a live session for the project instead of launching a duplicate.
EXTRA-SWITCHES, when given, are passed to a fresh launch."
  (interactive)
  (mcp-emacs-run--ensure-eat)
  (let* ((root (mcp-emacs-run--project-root))
         (existing (mcp-emacs-run--live-buffer root)))
    (if (and existing (null extra-switches))
        (progn (mcp-emacs-run--display existing) existing)
      (apply #'mcp-emacs-run--launch root nil extra-switches))))

;;;###autoload
(defun mcp-emacs-run-start ()
  "Start the Claude Code runner for the current project without showing it.
Reuses a live session if one exists; otherwise launches the CLI in a
registered eat buffer without displaying any window or moving focus.
Reveal the session later with `mcp-emacs-run-toggle' or
`mcp-emacs-run-switch'."
  (interactive)
  (mcp-emacs-run--ensure-eat)
  (let* ((root (mcp-emacs-run--project-root))
         (existing (mcp-emacs-run--live-buffer root)))
    (prog1 (or existing (mcp-emacs-run--launch root t))
      (message "Claude runner started (hidden) for %s"
               (mcp-emacs-run--project-name root)))))

;;;###autoload
(defun mcp-emacs-run-continue ()
  "Start the runner continuing the most recent conversation."
  (interactive)
  (apply #'mcp-emacs-run--launch (mcp-emacs-run--project-root) nil '("--continue")))

;;;###autoload
(defun mcp-emacs-run-resume ()
  "Start the runner resuming a prior conversation."
  (interactive)
  (apply #'mcp-emacs-run--launch (mcp-emacs-run--project-root) nil '("--resume")))

;;;###autoload
(defun mcp-emacs-run-list ()
  "Message the live runner sessions."
  (interactive)
  (let (entries)
    (maphash (lambda (root buf)
               (when (buffer-live-p buf)
                 (push (format "  %s  ->  %s" (mcp-emacs-run--project-name root)
                               (buffer-name buf))
                       entries)))
             mcp-emacs-run--sessions)
    (if entries
        (message "Claude runner sessions:\n%s" (string-join (nreverse entries) "\n"))
      (message "No live Claude runner sessions"))))

;;;###autoload
(defun mcp-emacs-run-switch ()
  "Choose a live runner session and display it."
  (interactive)
  (let (choices)
    (maphash (lambda (root buf)
               (when (buffer-live-p buf)
                 (push (cons (mcp-emacs-run--project-name root) buf) choices)))
             mcp-emacs-run--sessions)
    (unless choices (user-error "No live Claude runner sessions"))
    (let* ((pick (completing-read "Runner session: " choices nil t))
           (buf (cdr (assoc pick choices))))
      (mcp-emacs-run--display buf))))

;;;###autoload
(defun mcp-emacs-run-kill ()
  "Kill the runner session for the current project."
  (interactive)
  (let* ((root (mcp-emacs-run--project-root))
         (buf (mcp-emacs-run--live-buffer root)))
    (unless buf (user-error "No live runner session for this project"))
    (when-let ((proc (get-buffer-process buf)))
      (ignore-errors (delete-process proc)))
    (kill-buffer buf)
    (remhash root mcp-emacs-run--sessions)
    (message "Killed Claude runner session for %s"
             (mcp-emacs-run--project-name root))))

;;;###autoload
(defun mcp-emacs-run-toggle ()
  "Toggle the runner window for the current project.
Hides the window when visible (without killing the process); shows it
otherwise, starting the runner if there is no session yet."
  (interactive)
  (let* ((root (mcp-emacs-run--project-root))
         (buf (mcp-emacs-run--live-buffer root)))
    (cond
     ((null buf) (mcp-emacs-run))
     ((get-buffer-window buf)
      (delete-window (get-buffer-window buf)))
     (t (mcp-emacs-run--display buf)))))

;;;###autoload
(defun mcp-emacs-run-send-prompt (text)
  "Send TEXT to the current project's runner session and submit it.
Requires a live session; does not launch a new one."
  (interactive "sPrompt: ")
  (let ((root (mcp-emacs-run--project-root)))
    (mcp-emacs-run--send root text)
    (mcp-emacs-run--send root "\r")))

;;;###autoload
(defun mcp-emacs-run-send-escape ()
  "Send an escape/interrupt to the current project's runner session."
  (interactive)
  (mcp-emacs-run--send (mcp-emacs-run--project-root) "\e"))

;;;###autoload
(defun mcp-emacs-run-send-newline ()
  "Insert a newline in the runner prompt without submitting it."
  (interactive)
  (mcp-emacs-run--send (mcp-emacs-run--project-root) "\n"))

;;;###autoload
(defun mcp-emacs-explain-selection-in-current-session ()
  "Ask the current project's runner session to explain the selection.
Builds a reference for the active region (or point) and submits an
explain request.  Requires a live session; does not launch a new one."
  (interactive)
  (mcp-emacs-run-send-prompt
   (concat "explain " (mcp-emacs-run--selection-reference))))

(provide 'mcp-emacs-run)

;;; mcp-emacs-run.el ends here
