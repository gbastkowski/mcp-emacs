;;; agent-session-overview.el --- One live view of every AI session -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.7.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Each backend in this repository answers only for itself, and only
;; when asked: `claude-client-list' and `mcp-emacs-run-list' each print
;; their own sessions into the echo area, which is stale the moment it
;; is printed.  This buffer shows all of them at once and keeps itself
;; current, so "is that turn still running?" is answered by looking
;; rather than by switching buffers to check.
;;
;; Enumeration is a `buffer-list' scan against each backend's own
;; buffer-name regexp -- there is no session registry, and this
;; deliberately does not add one (see the change's Approach).  The
;; claude-client and eat-runner names are parallel
;; (`*claude-client:<project>:<n>*' and `*claude:<project>:<n>*',
;; project in group 1); opencode is not (`*opencode:<title>*', no
;; project), so its project comes from the buffer's `default-directory'.
;;
;; State is reported only as precisely as each backend can observe:
;;
;; - claude-client publishes turn events and keeps `claude-client--turn-active'
;;   plus a process handle, so its rows distinguish working / idle / finished.
;; - The eat runner is a TUI with no turn events at all, and opencode
;;   keeps no per-buffer turn state and never publishes `finished' (its
;;   `step-finish' signal is discarded upstream).  Both report liveness
;;   only.  Inferring working/idle from terminal output activity would
;;   misreport a long model think as idle and a spinner as work, so it is
;;   not done.
;;
;; Live updates come from `agent-backend-event-functions'.  The
;; subscriber guards its own errors: a failure while rendering must not
;; propagate back into the session that published the event, the same
;; rule the remote Org transcript follows.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'tabulated-list)

(declare-function claude-client-interrupt "claude-client" ())
(declare-function claude-client-quit "claude-client" ())
(declare-function mcp-emacs-run-quit "mcp-emacs-run" (&optional buffer))

(defvar claude-client--process)
(defvar claude-client--turn-active)

(defgroup agent-session-overview nil
  "One live view of every AI session."
  :group 'tools
  :prefix "agent-session-overview-")

(defcustom agent-session-overview-buffer-name "*ai-sessions*"
  "Name of the session overview buffer."
  :type 'string
  :group 'agent-session-overview)

(defconst agent-session-overview--backends
  '((claude-client
     :label "claude"
     :mode claude-client-mode
     :regexp "\\`\\*claude-client:\\(.+\\):\\([0-9]+\\)\\*\\'"
     :project-in-name t
     :state agent-session-overview--claude-state)
    (eat
     :label "eat"
     :mode nil
     :regexp "\\`\\*claude:\\(.+\\):\\([0-9]+\\)\\*\\'"
     :project-in-name t
     :state agent-session-overview--process-state)
    (opencode
     :label "opencode"
     :mode opencode-client-mode
     :regexp "\\`\\*opencode:\\(.+\\)\\*\\'"
     :project-in-name nil
     :state agent-session-overview--process-state))
  "How each backend's session buffers are recognised and read.
Each entry is (SYMBOL :label LABEL :mode MODE :regexp RE
:project-in-name FLAG :state FN).

A buffer belongs to a backend if its major mode derives from MODE, or --
when MODE is nil, or the buffer predates it -- if its name matches RE.
Mode is checked first because it is the truth of what a buffer is: a
conversation buffer created before the current naming scheme (plain
`*claude-client*', no project or number) is still a live session and must
not be missed just because its name is old.  The eat runner has no mode
of its own (it is an `eat' terminal), so it is recognised by name only.

RE also supplies the display labels: the session identity is group 1, and
FLAG says whether that group is the project name -- true for the two
runners (`*claude-client:<project>:<n>*' and `*claude:<project>:<n>*'),
false for opencode, which names buffers `*opencode:<title>*' and carries
no project in the name at all.  When a buffer matches by mode but not by
RE, both fall back to the buffer's own name and `default-directory'.

FN is called with the buffer and returns its state symbol.  The regexps
are the backends' own naming schemes, kept here rather than reaching into
their internals so this module has no load-order dependency on them.")

;;;; State

(defun agent-session-overview--process-state (buffer)
  "Return `live' or `dead' for BUFFER, from its process alone.
Used for backends that expose no turn state: the eat runner publishes no
turn events, and opencode publishes no `finished', so neither can be
reported as working or idle without inventing a claim."
  (if (process-live-p (get-buffer-process buffer)) 'live 'dead))

(defun agent-session-overview--claude-state (buffer)
  "Return the turn state of claude-client BUFFER.
`working' while a turn is in flight, `idle' when the process is live and
between turns, `finished' once it has exited -- the same distinction
`claude-client--label' draws for `completing-read'."
  (with-current-buffer buffer
    (cond ((bound-and-true-p claude-client--turn-active) 'working)
          ((process-live-p (bound-and-true-p claude-client--process)) 'idle)
          (t 'finished))))

;;;; Enumeration

(defun agent-session-overview--project (buffer name-project)
  "Return a project name for BUFFER.
NAME-PROJECT is the project parsed out of the buffer name, or nil when
that backend's name does not carry one -- opencode names its buffers by
title, so its project is derived from the buffer's own
`default-directory' instead, as the eat runner already does in
`mcp-emacs-run--buffer-project'."
  (or name-project
      (file-name-nondirectory
       (directory-file-name (buffer-local-value 'default-directory buffer)))))

(defun agent-session-overview--mode-match-p (spec buffer)
  "Return non-nil when BUFFER's major mode is SPEC's backend mode."
  (when-let* ((mode (plist-get spec :mode)))
    (and (fboundp mode)
         (with-current-buffer buffer (derived-mode-p mode)))))

(defun agent-session-overview--session-entry (backend buffer)
  "Return an overview entry plist for BUFFER, or nil if BACKEND does not match.
BACKEND is one entry of `agent-session-overview--backends'.  Matching is
by major mode first and buffer name second, so a session whose buffer
predates the current naming scheme is still listed."
  (let* ((spec (cdr backend))
         (name (buffer-name buffer))
         (by-name (string-match (plist-get spec :regexp) name))
         (identity (and by-name (match-string 1 name)))
         (number (and by-name (> (length (match-data)) 4) (match-string 2 name))))
    (when (or by-name (agent-session-overview--mode-match-p spec buffer))
      (list :buffer buffer
            :backend (car backend)
            :label (plist-get spec :label)
            :project (agent-session-overview--project
                      buffer (and (plist-get spec :project-in-name) identity))
            :session (cond (number (format "%s:%s" identity number))
                           (identity identity)
                           ;; Matched by mode alone: the name carries no
                           ;; parseable identity, so show it as it is.
                           (t name))
            :state (funcall (plist-get spec :state) buffer)))))

(defun agent-session-overview--sessions ()
  "Return entries for every live AI session buffer, across all backends.
A `buffer-list' scan against each backend's naming regexp -- no registry."
  (seq-filter
   #'identity
   (seq-mapcat
    (lambda (buffer)
      (seq-map (lambda (backend)
                 (agent-session-overview--session-entry backend buffer))
               agent-session-overview--backends))
    (buffer-list))))

;;;; Rendering

(defun agent-session-overview--entries ()
  "Return `tabulated-list-entries' for the live sessions."
  (mapcar (lambda (entry)
            (list entry
                  (vector (plist-get entry :label)
                          (plist-get entry :project)
                          (plist-get entry :session)
                          (symbol-name (plist-get entry :state)))))
          (agent-session-overview--sessions)))

(defun agent-session-overview--refresh ()
  "Recompute the overview's rows.
Installed as this buffer's `tabulated-list-revert-hook', so `g' works."
  (setq tabulated-list-entries (agent-session-overview--entries)))

(defun agent-session-overview--render ()
  "Re-render the overview buffer if it exists."
  (when-let* ((buffer (get-buffer agent-session-overview-buffer-name)))
    (with-current-buffer buffer
      (let ((point (point)))
        (agent-session-overview--refresh)
        (tabulated-list-print)
        (goto-char (min point (point-max)))))))

(defun agent-session-overview--on-event (_buffer event)
  "Re-render the overview when EVENT changes what a row would show.
Errors are swallowed on purpose: this runs on
`agent-backend-event-functions', inside the publishing session's own
call stack, so a rendering failure here must not reach that session."
  (when (memq (plist-get event :kind)
              '(started prompt finished interrupted resumed error))
    (condition-case err
        (agent-session-overview--render)
      (error
       (message "agent-session-overview: render failed: %s"
                (error-message-string err))))))

;;;; Actions

(defun agent-session-overview--entry-at-point ()
  "Return the session entry on the current line, or signal."
  (or (tabulated-list-get-id)
      (user-error "No session on this line")))

(defun agent-session-overview--live-buffer-at-point ()
  "Return the live buffer of the session at point, or signal."
  (let ((buffer (plist-get (agent-session-overview--entry-at-point) :buffer)))
    (unless (buffer-live-p buffer)
      (user-error "That session's buffer is gone"))
    buffer))

(defun agent-session-overview-visit ()
  "Display the session on the current line."
  (interactive)
  (pop-to-buffer (agent-session-overview--live-buffer-at-point)))

(defun agent-session-overview-quit-session ()
  "Shut down the session on the current line, without confirming.
Deliberately unconfirmed, including mid-turn: the overview is the place
you go to stop things."
  (interactive)
  (let* ((entry (agent-session-overview--entry-at-point))
         (buffer (agent-session-overview--live-buffer-at-point)))
    (pcase (plist-get entry :backend)
      ('claude-client
       (with-current-buffer buffer (claude-client-quit)))
      ('eat
       (if (fboundp 'mcp-emacs-run-quit)
           (mcp-emacs-run-quit buffer)
         (when-let* ((process (get-buffer-process buffer)))
           (delete-process process))))
      (_
       (if-let* ((process (get-buffer-process buffer)))
           (delete-process process)
         (user-error "Nothing to quit for this session"))))
    (agent-session-overview--render)))

(defun agent-session-overview-interrupt-session ()
  "Interrupt the turn of the session on the current line."
  (interactive)
  (let* ((entry (agent-session-overview--entry-at-point))
         (buffer (agent-session-overview--live-buffer-at-point)))
    (unless (eq (plist-get entry :state) 'working)
      (user-error "No turn is running for this session"))
    (with-current-buffer buffer (claude-client-interrupt))
    (agent-session-overview--render)))

(defvar agent-session-overview-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'agent-session-overview-visit)
    (define-key map (kbd "k") #'agent-session-overview-quit-session)
    (define-key map (kbd "i") #'agent-session-overview-interrupt-session)
    map)
  "Keymap for `agent-session-overview-mode'.
`g' (revert) and `q' (bury) come from `tabulated-list-mode'.")

(define-derived-mode agent-session-overview-mode tabulated-list-mode "ai-sessions"
  "Major mode listing every live AI session across all backends."
  (setq tabulated-list-format
        [("Backend" 10 t)
         ("Project" 22 t)
         ("Session" 16 t)
         ("State" 10 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key '("Backend" . nil))
  (add-hook 'tabulated-list-revert-hook #'agent-session-overview--refresh nil t)
  (tabulated-list-init-header))

;;;###autoload
(defun agent-session-overview ()
  "Show the live AI session overview."
  (interactive)
  (let ((buffer (get-buffer-create agent-session-overview-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-session-overview-mode)
        (agent-session-overview-mode))
      (agent-session-overview--refresh)
      (tabulated-list-print)
      (when (null tabulated-list-entries)
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char (point-max))
            (insert "\n  No live AI sessions.\n")))))
    (pop-to-buffer buffer)))

(add-hook 'agent-backend-event-functions #'agent-session-overview--on-event)

(provide 'agent-session-overview)
;;; agent-session-overview.el ends here
