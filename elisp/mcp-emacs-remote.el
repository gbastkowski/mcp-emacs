;;; mcp-emacs-remote.el --- Remote-control an interactive Claude from Emacs -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.8.0
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

;; Drive the mcp-emacs-launched interactive Claude session from ordinary
;; Emacs input, and watch its tool activity render as a live Org
;; transcript -- without reading the terminal.
;;
;; Two capabilities:
;;
;; * Prompt input (`mcp-emacs-remote-prompt', `mcp-emacs-remote-prompt-buffer'):
;;   send a prompt to the current project's running Claude session from the
;;   minibuffer, the active region, or the whole current buffer.  Delivery
;;   reuses `mcp-emacs-run-send-prompt', which auto-submits.
;;
;; * Org transcript: a per-session `*claude: <project>*' Org buffer records
;;   the session's tool activity -- one heading per tool call with its
;;   arguments, the accept/reject outcome of each openDiff, and a
;;   run-metadata drawer.  It is fed by advising the IDE surface's tool
;;   dispatch (`mcp-emacs-ide--call-tool') and the openDiff completion
;;   (`mcp-emacs-ide--complete-open-diff'); the advice is a no-op unless the
;;   feature is enabled, so the IDE surface is untouched when it is off.
;;
;; Tool approval is NOT provided here: native edits flow through the IDE
;; surface's ediff review (the openDiff gate).  This module only records.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'mcp-emacs-run)
(require 'mcp-emacs-ide)

;; Declared rather than required: the transcript subscribes to the runner's
;; event hook, but neither module needs the other loaded.  That is the point
;; of publishing events instead of advising -- adding a reader costs nothing
;; on the writer's side.
(defvar agent-backend-event-functions)

;; Defined in mcp-emacs, which is loaded via mcp-emacs-run; declared so this
;; file compiles standalone.  Org-side observations land in the same
;; transcript as the runner's events (issue #39).
(defvar mcp-emacs-org-task-event-functions)

(defgroup mcp-emacs-remote nil
  "Remote-control an interactive Claude session from Emacs."
  :group 'tools)

(defcustom mcp-emacs-remote-enabled nil
  "When non-nil, record Claude tool activity into an Org transcript.
The transcript tap on the IDE surface is a no-op while this is nil, so
the IDE surface behaves exactly as if this module were not loaded."
  :type 'boolean
  :group 'mcp-emacs-remote)

;;;; Prompt input

(defun mcp-emacs-remote--send (text)
  "Send TEXT to the current project's Claude session, or report if empty.
Empty or whitespace-only TEXT is not sent.  Delivery (and submission) is
`mcp-emacs-run-send-prompt', which requires a live session and does not
launch one."
  (if (or (null text) (string-empty-p (string-trim text)))
      (user-error "No prompt provided")
    (mcp-emacs-run-send-prompt text)))

;;;###autoload
(defun mcp-emacs-remote-prompt (&optional initial)
  "Read a prompt from the minibuffer and send it to the Claude session.
When a region is active, seed the minibuffer with the region text so it
can be edited or confirmed before sending (INITIAL overrides the seed).
Empty or whitespace-only input is not sent.  The prompt is auto-submitted
to the current project's running session; no session is launched."
  (interactive
   (list (when (use-region-p)
           (buffer-substring-no-properties (region-beginning) (region-end)))))
  (mcp-emacs-remote--send (read-string "Claude prompt: " initial)))

;;;###autoload
(defun mcp-emacs-remote-prompt-buffer ()
  "Send the entire current buffer as the prompt to the Claude session.
An empty or whitespace-only buffer is not sent.  Auto-submitted to the
current project's running session; no session is launched."
  (interactive)
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (if (string-empty-p (string-trim text))
        (user-error "Nothing to send: the buffer is empty")
      (mcp-emacs-remote--send text))))

;;;; Org transcript

(defun mcp-emacs-remote--project-name ()
  "Return a short name for the current project, for the transcript buffer."
  (let ((root (ignore-errors (mcp-emacs-run--project-root))))
    (if (and root (not (string-empty-p root)))
        (file-name-nondirectory (directory-file-name root))
      "session")))

(defun mcp-emacs-remote--buffer ()
  "Return the Org transcript buffer for the current project, creating it.
The buffer is created lazily on first recordable activity and reused for
the lifetime of the session; distinct projects get distinct buffers."
  (let* ((name (format "*claude: %s*" (mcp-emacs-remote--project-name)))
         (buf (get-buffer name)))
    (or buf
        (with-current-buffer (get-buffer-create name)
          (when (fboundp 'org-mode) (org-mode))
          (current-buffer)))))

(defun mcp-emacs-remote--append (text)
  "Append TEXT to the transcript buffer, at end, read-only-safe."
  (let ((buf (mcp-emacs-remote--buffer)))
    (with-current-buffer buf
      (save-excursion
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert text)))))

(defun mcp-emacs-remote--timestamp ()
  "Return an inactive Org timestamp for now."
  (format-time-string "[%Y-%m-%d %a %H:%M:%S]"))

(defun mcp-emacs-remote--json (value)
  "Encode VALUE as pretty JSON for an Org source block, best-effort."
  (condition-case nil
      (let ((json-encoding-pretty-print t))
        (json-encode value))
    (error (format "%S" value))))

(defconst mcp-emacs-remote--quiet-tools '("getDiagnostics" "closeAllDiffTabs")
  "Tool names whose calls are recorded compactly rather than as full entries.
These fire before every edit and would otherwise dominate the transcript.")

(defun mcp-emacs-remote-record-tool-call (name args)
  "Record a tool call NAME with ARGS into the transcript.
Quiet tools (see `mcp-emacs-remote--quiet-tools') get a compact one-line
note; everything else gets a heading with its arguments.  Errors are
swallowed so recording never affects the tool call itself."
  (ignore-errors
    (if (member name mcp-emacs-remote--quiet-tools)
        (mcp-emacs-remote--append
         (format "  - %s %s" (mcp-emacs-remote--timestamp) name))
      (mcp-emacs-remote--append
       (format "* 🔧 %s  %s\n#+begin_src json\n%s\n#+end_src"
               name (mcp-emacs-remote--timestamp)
               (mcp-emacs-remote--json args))))))

(defun mcp-emacs-remote-record-diff-outcome (tab-name status &rest extra)
  "Record an openDiff outcome: STATUS for TAB-NAME, with EXTRA text.
STATUS is \"FILE_SAVED\" (accepted) or \"DIFF_REJECTED\" (rejected).  The
first EXTRA item is the accepted content (accept) or the tab name
\(reject); the target file is derived from TAB-NAME.  Errors are
swallowed."
  (ignore-errors
    (let ((outcome (cond ((string= status "FILE_SAVED") "accepted")
                         ((string= status "DIFF_REJECTED") "rejected")
                         (t status))))
      (mcp-emacs-remote--append
       (format "  - %s openDiff %s :: %s"
               (mcp-emacs-remote--timestamp) outcome tab-name))
      (ignore extra))))

(defun mcp-emacs-remote-record-session-start ()
  "Record a run-metadata drawer for the current session at its start."
  (ignore-errors
    (let ((root (ignore-errors (mcp-emacs-run--project-root)))
          (port (and mcp-emacs-ide--session
                     (mcp-emacs-ide-session-port mcp-emacs-ide--session))))
      (mcp-emacs-remote--append
       (format "* Session  %s\n:PROPERTIES:\n:STARTED: %s\n:WORKSPACE: %s\n:IDE_PORT: %s\n:END:"
               (mcp-emacs-remote--timestamp)
               (mcp-emacs-remote--timestamp)
               (or root "?")
               (or port "?"))))))

(defun mcp-emacs-remote-record-session-end ()
  "Record that the session ended."
  (ignore-errors
    (mcp-emacs-remote--append
     (format "  - %s session ended" (mcp-emacs-remote--timestamp)))))

;;;; Event taps (advice on the IDE surface)

(defun mcp-emacs-remote--tap-call-tool (_session name args _id)
  "Advice for `mcp-emacs-ide--call-tool': record the call when enabled.
A `:before' advice -- it inspects NAME and ARGS and returns nothing, so
the wrapped dispatch runs unchanged."
  (when mcp-emacs-remote-enabled
    (mcp-emacs-remote-record-tool-call name args)))

(defun mcp-emacs-remote--tap-complete-open-diff (_session tab-name status &rest extra)
  "Advice for `mcp-emacs-ide--complete-open-diff': record the outcome.
A `:before' advice; records TAB-NAME/STATUS/EXTRA when enabled and
returns nothing, so the wrapped completion runs unchanged."
  (when mcp-emacs-remote-enabled
    (apply #'mcp-emacs-remote-record-diff-outcome tab-name status extra)))

(defun mcp-emacs-remote--tap-start (&rest _)
  "Advice for `mcp-emacs-ide-start': record session-start metadata."
  (when mcp-emacs-remote-enabled
    (mcp-emacs-remote-record-session-start)))

(defun mcp-emacs-remote--tap-stop (&rest _)
  "Advice for `mcp-emacs-ide-stop': record session end."
  (when mcp-emacs-remote-enabled
    (mcp-emacs-remote-record-session-end)))

;;;; Runner subscriber (claude-client)

;; The IDE taps above are advice: the transcript only learns what the IDE
;; surface happens to be asked.  `claude-client' instead *publishes* an
;; append-only event log and announces each event on a hook, so this is a
;; plain subscriber -- no advice, and rendering stays one consumer among
;; several.  That is the direction issue #39 wants: one log, many readers.

(defun mcp-emacs-remote--record-runner-event (event)
  "Record a `claude-client' EVENT into the transcript.
EVENT is a plist as published on `agent-backend-event-functions'.
Unknown kinds are ignored rather than guessed at, so a new event kind
degrades to silence instead of a malformed entry."
  (pcase (plist-get event :kind)
    ('started
     (mcp-emacs-remote--append
      (format "* Runner  %s\n:PROPERTIES:\n:SESSION: %s\n:MODEL: %s\n:END:"
              (mcp-emacs-remote--timestamp)
              (or (plist-get event :session) "?")
              (or (plist-get event :model) "?"))))
    ('text
     (mcp-emacs-remote--append
      (format "  - %s assistant :: %s"
              (mcp-emacs-remote--timestamp)
              (car (split-string (or (plist-get event :text) "") "\n")))))
    ('tool-use
     (mcp-emacs-remote-record-tool-call
      (or (plist-get event :name) "?")
      (plist-get event :input)))
    ('tool-result
     (mcp-emacs-remote--append
      (format "  - %s result :: %s"
              (mcp-emacs-remote--timestamp)
              (car (split-string (or (plist-get event :text) "") "\n")))))
    ('finished
     (mcp-emacs-remote--append
      (format "  - %s runner %s"
              (mcp-emacs-remote--timestamp)
              (or (plist-get event :subtype) "done"))))
    ;; The human writing to the log, not the runner.  Recorded on the same
    ;; channel and in the same order as everything else -- that is the point
    ;; of one shared log rather than two side-by-side records.
    ('note
     (mcp-emacs-remote--append
      (format "  - %s human :: %s"
              (mcp-emacs-remote--timestamp)
              (or (plist-get event :text) ""))))
    ('notes-delivered
     (mcp-emacs-remote--append
      (format "  - %s carried %d note(s) forward"
              (mcp-emacs-remote--timestamp)
              (length (plist-get event :notes)))))
    (_ nil)))

;;;; Org-task subscriber (issue #39)

;; The Org file is the aggregate and owns this state; these events only
;; *observe* that it changed.  Recording them here puts the human's Org
;; edits and the runner's activity in one shared record, without the log
;; becoming a second source of truth -- nothing here is ever replayed to
;; reconstruct state.

(defun mcp-emacs-remote--record-org-task-event (event)
  "Record an org-task EVENT into the transcript.
EVENT is a plist as published on `mcp-emacs-org-task-event-functions'.
Unknown kinds are ignored rather than guessed at."
  (let ((file (file-name-nondirectory (or (plist-get event :path) "?"))))
    (pcase (plist-get event :kind)
      ('session-status
       (mcp-emacs-remote--append
        (format "  - %s org session :: %s [%s]"
                (mcp-emacs-remote--timestamp)
                (plist-get event :status) file)))
      ('item-status
       (mcp-emacs-remote--append
        (format "  - %s org item :: %s → %s [%s]"
                (mcp-emacs-remote--timestamp)
                (plist-get event :ref) (plist-get event :status) file)))
      ('item-added
       (mcp-emacs-remote--append
        (format "  - %s org item added :: %s %s [%s]"
                (mcp-emacs-remote--timestamp)
                (plist-get event :status) (plist-get event :text) file)))
      ('note
       (mcp-emacs-remote--append
        (format "  - %s org note :: %s [%s]"
                (mcp-emacs-remote--timestamp)
                (car (split-string (or (plist-get event :text) "") "\n"))
                file)))
      (_ nil))))

(defun mcp-emacs-remote--tap-org-task-event (event)
  "Subscriber for `mcp-emacs-org-task-event-functions'.
Records EVENT when recording is enabled.  Errors are swallowed: an
observer must never break the Org write it is observing."
  (when mcp-emacs-remote-enabled
    (ignore-errors (mcp-emacs-remote--record-org-task-event event))))

(defun mcp-emacs-remote--tap-runner-event (buffer event)
  "Subscriber for `agent-backend-event-functions'.
Records EVENT from conversation BUFFER when recording is enabled.
Errors are swallowed: a transcript problem must never take down the
runner whose events it is observing."
  (ignore buffer)
  (when mcp-emacs-remote-enabled
    (ignore-errors (mcp-emacs-remote--record-runner-event event))))

;;;###autoload
(defun mcp-emacs-remote-enable ()
  "Install the transcript taps on the IDE surface (idempotent).
Also sets `mcp-emacs-remote-enabled'."
  (interactive)
  (setq mcp-emacs-remote-enabled t)
  (advice-add 'mcp-emacs-ide--call-tool :before #'mcp-emacs-remote--tap-call-tool)
  (advice-add 'mcp-emacs-ide--complete-open-diff :before
              #'mcp-emacs-remote--tap-complete-open-diff)
  (advice-add 'mcp-emacs-ide-start :after #'mcp-emacs-remote--tap-start)
  (when (fboundp 'mcp-emacs-ide-stop)
    (advice-add 'mcp-emacs-ide-stop :before #'mcp-emacs-remote--tap-stop))
  (add-hook 'agent-backend-event-functions
            #'mcp-emacs-remote--tap-runner-event)
  (add-hook 'mcp-emacs-org-task-event-functions
            #'mcp-emacs-remote--tap-org-task-event))

;;;###autoload
(defun mcp-emacs-remote-disable ()
  "Remove the transcript taps and clear `mcp-emacs-remote-enabled' (idempotent)."
  (interactive)
  (setq mcp-emacs-remote-enabled nil)
  (advice-remove 'mcp-emacs-ide--call-tool #'mcp-emacs-remote--tap-call-tool)
  (advice-remove 'mcp-emacs-ide--complete-open-diff
                 #'mcp-emacs-remote--tap-complete-open-diff)
  (advice-remove 'mcp-emacs-ide-start #'mcp-emacs-remote--tap-start)
  (when (fboundp 'mcp-emacs-ide-stop)
    (advice-remove 'mcp-emacs-ide-stop #'mcp-emacs-remote--tap-stop))
  (remove-hook 'agent-backend-event-functions
               #'mcp-emacs-remote--tap-runner-event)
  (remove-hook 'mcp-emacs-org-task-event-functions
               #'mcp-emacs-remote--tap-org-task-event))

(provide 'mcp-emacs-remote)
;;; mcp-emacs-remote.el ends here
