;;; agent-backend.el --- Shared core behind the agent chat clients -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.8.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Shared core behind claude-client.el and opencode-client.el (issue #41).

;;; Commentary:

;; An EIEIO base class, `agent-backend', naming what every agent chat
;; backend can do; an abnormal hook, `agent-backend-event-functions',
;; carrying the common event vocabulary both clients publish; and
;; `agent-backend-mode', a major mode with a shared, C-c-prefixed
;; keymap.  Transport, rendering, and window placement stay in the
;; per-client subclasses.
;;
;; A minimal backend implements only `agent-backend-connect',
;; `agent-backend-send', `agent-backend-interrupt',
;; `agent-backend-add-note', `agent-backend-note-policy', and
;; `agent-backend-quit'.  Every optional capability has a default on the
;; base class -- a no-op, nil, or, for `agent-backend-resume', a
;; `user-error' -- so a minimal subclass compiles against the defaults
;; without stubs.

;;; Code:

(require 'eieio)
(require 'cl-lib)

;;;; The base class

(defclass agent-backend ()
  ((note-policy
    :initarg :note-policy
    :initform :steer
    :documentation
    "How a human note written mid-turn reaches the model.
    `:steer' redirects the in-flight turn immediately; `:queue' waits
    for the turn to end on its own.  Backends may add policy values
    beyond this pair (claude-client uses `:interrupt').")
   (session-id
    :initarg :session-id
    :initform nil
    :documentation
    "Identifier of the session this backend is bound to, or nil.")
   (buffer
    :initarg :buffer
    :initform nil
    :documentation
    "The conversation buffer this backend renders into, or nil."))
  "Base class for agent chat backends (issue #41).
Only state every backend shares lives here; per-backend state stays in
the subclasses.")

;;;; The generic interface

;; The required capabilities (connect, quit, send, interrupt, add-note)
;; have no default method: calling one a subclass forgot to implement
;; fails with `cl-no-primary-method', naming the gap.

(cl-defgeneric agent-backend-connect (backend)
  "Connect BACKEND to its agent service, ready to accept prompts.")

(cl-defgeneric agent-backend-quit (backend)
  "Shut BACKEND down, releasing any process or stream it holds.")

(cl-defgeneric agent-backend-send (backend prompt)
  "Send PROMPT to BACKEND as the next turn of the conversation.")

(cl-defgeneric agent-backend-interrupt (backend)
  "Abandon the turn BACKEND is currently working on.")

(cl-defgeneric agent-backend-add-note (backend text)
  "Add TEXT as a human note to BACKEND's conversation.
When the note reaches the model is BACKEND's note policy; see the
`note-policy' slot and `agent-backend-note-policy'.")

(cl-defgeneric agent-backend-note-policy (backend)
  "Return BACKEND's note delivery policy (`:steer' or `:queue').")

(cl-defgeneric agent-backend-reply-permission (backend request-id decision)
  "Reply DECISION to BACKEND's permission request REQUEST-ID.
Optional: backends without a permission gate inherit the no-op
default.")

(cl-defgeneric agent-backend-reply-question (backend request-id answer)
  "Reply ANSWER to BACKEND's question request REQUEST-ID.
Optional: backends without a question gate inherit the no-op
default.")

(cl-defgeneric agent-backend-list-sessions (backend)
  "Return the sessions BACKEND's service knows about, as a list.
Optional: the default returns nil.")

(cl-defgeneric agent-backend-resume (backend session)
  "Reopen the past SESSION in BACKEND.
Optional: the default signals a `user-error' explaining the backend
cannot resume.")

(cl-defgeneric agent-backend-seed-history (backend)
  "Seed BACKEND's conversation model from its stored history.
Optional: the default is a no-op.")

(cl-defgeneric agent-backend-project-root (backend)
  "Return the project root BACKEND works in, or nil.
Optional: the default returns nil.")

(cl-defgeneric agent-backend-render (backend)
  "Re-render BACKEND's conversation buffer.
Optional: the default is a no-op.  Publishing events (see
`agent-backend--publish') is decoupled from rendering; a backend may
render by other means.")

(cl-defgeneric agent-backend-mention (backend text)
  "Offer TEXT to BACKEND's conversation without sending a turn.
A reference to what the human is looking at -- see
`agent-backend-selection-reference' -- handed over for the model to pick
up on its next turn, so the human can keep composing around it (issue
#56).

Deliberately not `agent-backend-send': mentioning is *not* a turn.  The
eat runner could do this by typing into a live TUI input line, which the
API-driven clients have no equivalent of -- they submit a turn or
nothing.  So each backend decides where unsent text goes; the default
routes it through `agent-backend-add-note', which is exactly the
existing \"human said something, deliver it with the next turn\"
channel.")

;;;; Default implementations

(cl-defmethod agent-backend-note-policy ((backend agent-backend))
  "Return BACKEND's note delivery policy."
  (oref backend note-policy))

(cl-defmethod agent-backend-reply-permission
  ((backend agent-backend) request-id decision)
  "No-op default: BACKEND has no permission gate."
  (ignore backend request-id decision)
  nil)

(cl-defmethod agent-backend-reply-question
  ((backend agent-backend) request-id answer)
  "No-op default: BACKEND has no question gate."
  (ignore backend request-id answer)
  nil)

(cl-defmethod agent-backend-list-sessions ((backend agent-backend))
  "Default session list: none."
  (ignore backend)
  nil)

(cl-defmethod agent-backend-resume ((backend agent-backend) session)
  "Default resume: refuse."
  (ignore backend session)
  (user-error "This agent backend cannot resume past sessions"))

(cl-defmethod agent-backend-seed-history ((backend agent-backend))
  "No-op default: BACKEND has no stored history to seed from."
  (ignore backend)
  nil)

(cl-defmethod agent-backend-project-root ((backend agent-backend))
  "Default project root: none known."
  (ignore backend)
  nil)

(cl-defmethod agent-backend-render ((backend agent-backend))
  "No-op default: BACKEND renders by other means, or not at all."
  (ignore backend)
  nil)

(cl-defmethod agent-backend-mention ((backend agent-backend) text)
  "Default mention: hand TEXT to BACKEND as a human note.
Notes already mean \"the human said this; deliver it with the next
turn\", which is what a mention needs -- so every backend gets a working
mention from its `agent-backend-add-note' without implementing anything
new.  A backend with a real editable prompt line should override this to
insert there instead."
  (agent-backend-add-note backend text))

;;;; Events

(defvar agent-backend-event-functions nil
  "Abnormal hook run with (BUFFER EVENT) for every backend event.
EVENT is a plist whose `:kind' is one of:

  `started'            session begun; :session and maybe :model
  `prompt'             a prompt was sent; :text
  `text'               assistant prose; :text
  `tool-use'           a tool call; :name and :input
  `tool-result'        a tool's answer; :text
  `finished'           the turn ended; :subtype
  `interrupted'        the turn was abandoned on purpose
  `note'               a human note; :text and :pending
  `notes-delivered'    queued notes reached the model; :notes
  `note-dropped'       a queued note was dropped; :text
  `resumed'            a past session was reopened; :session
  `permission-request' the backend asks for a decision
  `question-request'   the backend asks a question
  `error'              something failed; :text

Backends may emit kinds beyond this list; subscribers MUST ignore
unknown kinds (guard their own `pcase' with a catch-all), so a
publisher never has to know who is listening.")

(defun agent-backend--publish (buffer event)
  "Publish EVENT for BUFFER to `agent-backend-event-functions'.
Publishing is decoupled from rendering: this only notifies subscribers
and never touches BUFFER's contents or display."
  (run-hook-with-args 'agent-backend-event-functions buffer event))

;;;; Sharing what the human is looking at

;; Declared here rather than where `project' is required: this file must
;; byte-compile standalone, and `project' is only consulted when present.
(declare-function project-root "project" (project))

(defvar-local agent-backend--instance nil
  "The `agent-backend' instance driving this buffer.
The derived client mode sets it with `setq-local' when it creates its
conversation buffer.  Defined before its users below, which scan for it
across buffers to find a conversation to talk to.")

(defun agent-backend--current-project-root ()
  "Return the current project root, or the buffer's directory as a fallback."
  (or (when (and (featurep 'project) (fboundp 'project-current))
        (when-let* ((proj (project-current nil)))
          (expand-file-name (project-root proj))))
      (expand-file-name default-directory)))

(defun agent-backend-selection-reference ()
  "Return a reference to the current selection, for embedding in a prompt.
In a file-visiting buffer, an at-mention of the project-relative path
with the active region's line span (or the line at point with no region)
-- a pointer the agent can read for itself, which beats pasting the text
and stays right if the file moves on.  Otherwise the selected text
verbatim, since there is no path to point at.

Generalised out of `mcp-emacs-run--selection-reference' (issue #56): the
verb belongs to every backend, not to the terminal runner that happened
to implement it first."
  (let* ((beg (if (use-region-p) (region-beginning) (point)))
         (end (if (use-region-p) (region-end) (point)))
         (file (buffer-file-name)))
    (if file
        (let* ((root (agent-backend--current-project-root))
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

(defun agent-backend--conversation-buffers ()
  "Return every live conversation buffer, across all backends.
A `buffer-list' scan for a buffer-local `agent-backend--instance' -- no
registry, and nothing per-backend to keep in step, the same choice
`agent-session-overview--sessions' makes.  Any client that sets the
instance is found for free."
  (seq-filter (lambda (buffer)
                (buffer-local-value 'agent-backend--instance buffer))
              (buffer-list)))

(defun agent-backend--resolve-conversation ()
  "Return the conversation buffer to receive what the human is sharing.
Candidates are ranked in tiers and the first non-empty tier wins:

  1. same project as the current buffer, and visible in a window
  2. same project, hidden
  3. any project, visible
  4. any project, hidden

Visible beats hidden because a conversation on screen is the one being
worked with; same-project beats other projects because that is what the
selection is about.  With several candidates in the winning tier, ask.
Generalised from `mcp-emacs-run--resolve-session' (issue #56), which
ranks the same way over eat buffers only."
  (let ((all (agent-backend--conversation-buffers)))
    (unless all
      (user-error "No live agent conversation; start one with `agent-backend-start'"))
    (let* ((root (agent-backend--current-project-root))
           (visible (lambda (buffer) (get-buffer-window buffer t)))
           (same (seq-filter
                  (lambda (buffer)
                    (equal (expand-file-name
                            (buffer-local-value 'default-directory buffer))
                           root))
                  all))
           (tiers (list (seq-filter visible same)
                        (seq-remove visible same)
                        (seq-filter visible all)
                        (seq-remove visible all)))
           (tier (seq-find #'identity tiers)))
      (if (cdr tier)
          (get-buffer
           (completing-read "Conversation: " (mapcar #'buffer-name tier)
                            nil t))
        (car tier)))))

;;;###autoload
(defun agent-backend-mention-selection ()
  "Share what you are looking at with the current agent conversation.
Sends a reference to the active region (or the line at point) -- see
`agent-backend-selection-reference' -- to the conversation resolved by
`agent-backend--resolve-conversation', without submitting a turn.  Run
this from the code buffer, not the conversation.

Requires a live conversation; it does not start one.  Replaces
`mcp-emacs-run-mention-selection', which only ever worked for the eat
runner (issue #56)."
  (interactive)
  (let ((reference (agent-backend-selection-reference))
        (buffer (agent-backend--resolve-conversation)))
    (with-current-buffer buffer
      (agent-backend-mention agent-backend--instance reference))
    (message "Shared %s with %s" reference (buffer-name buffer))))

;;;; Major mode

(defun agent-backend-send-command (prompt)
  "Send PROMPT to this buffer's backend."
  (interactive "sPrompt: ")
  (unless agent-backend--instance
    (user-error "No agent backend in this buffer"))
  (agent-backend-send agent-backend--instance prompt))

(defun agent-backend-interrupt-command ()
  "Abandon the turn this buffer's backend is working on."
  (interactive)
  (unless agent-backend--instance
    (user-error "No agent backend in this buffer"))
  (agent-backend-interrupt agent-backend--instance))

(defun agent-backend-add-note-command (text)
  "Add TEXT as a human note to this buffer's conversation."
  (interactive "sNote: ")
  (unless agent-backend--instance
    (user-error "No agent backend in this buffer"))
  (agent-backend-add-note agent-backend--instance text))

(defun agent-backend-quit-command ()
  "Shut down this buffer's backend."
  (interactive)
  (unless agent-backend--instance
    (user-error "No agent backend in this buffer"))
  (agent-backend-quit agent-backend--instance))

(defun agent-backend-resume-command (session)
  "Reopen the past SESSION through this buffer's backend."
  (interactive (list (read-string "Session: ")))
  (unless agent-backend--instance
    (user-error "No agent backend in this buffer"))
  (agent-backend-resume agent-backend--instance session))

(defvar agent-backend-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-s") #'agent-backend-send-command)
    (define-key map (kbd "C-c C-i") #'agent-backend-interrupt-command)
    (define-key map (kbd "C-c C-n") #'agent-backend-add-note-command)
    (define-key map (kbd "C-c C-q") #'agent-backend-quit-command)
    (define-key map (kbd "C-c C-r") #'agent-backend-resume-command)
    map)
  "Keymap for `agent-backend-mode'.
The shared, C-c-prefixed vocabulary; per-backend extra keys stay in the
derived mode maps (claude-client-mode-map, opencode-client-mode-map).")

(define-derived-mode agent-backend-mode special-mode "agent"
  "Major mode for a conversation buffer driven by an `agent-backend'.
The backend instance lives in the buffer-local `agent-backend--instance'."
  (setq-local truncate-lines nil))

;; The client functions are loaded on demand; declare them so the
;; shared core still byte-compiles standalone (the clients require
;; this file, so agent-backend cannot require them back at load).
(declare-function opencode-client--health "opencode-client" ())
(declare-function opencode-client-create-session "opencode-client" (&optional title))
(declare-function claude-client-start "claude-client" (prompt &optional resume-id))

;;;; Backend selection

(defcustom agent-backend-preference 'auto
  "Which backend `agent-backend-start' should pick.
`opencode' and `claude' force that backend.  `auto' probes: it starts
opencode when its server is reachable, otherwise Claude.  Set this
per machine when only one backend is usable -- for example `opencode'
on a machine without a Claude subscription, where the CLI is installed
but every request would fail at auth time."
  :type '(choice (const opencode) (const claude) (const auto))
  :group 'agent-backend)

(defun agent-backend-prefer-opencode-p ()
  "Return non-nil when `agent-backend-start' should use opencode.
Honours `agent-backend-preference': explicit `opencode' always, `claude'
never, `auto' when a healthy opencode server answers."
  (pcase agent-backend-preference
    ('opencode t)
    ('claude nil)
    ('auto (and (require 'opencode-client nil t)
                (opencode-client--health)))))

;;;###autoload
(defun agent-backend-start ()
  "Start the preferred backend for this machine.
Dispatch to the opencode or Claude client according to
`agent-backend-preference' -- the per-machine signal, since which CLI
is *usable* cannot be probed reliably (a binary can exist while every
request fails, e.g. no subscription).  Falls back to Claude when
opencode is not reachable under `auto'."
  (interactive)
  (if (agent-backend-prefer-opencode-p)
      (require 'opencode-client nil t)
    (require 'claude-client nil t))
  (if (agent-backend-prefer-opencode-p)
      (opencode-client-create-session)
    (claude-client-start
     (read-string "Prompt: "))))

(provide 'agent-backend)
;;; agent-backend.el ends here
