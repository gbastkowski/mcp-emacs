;;; agent-backend.el --- Shared core behind the agent chat clients -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 0.1.0
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
`:steer' redirects the in-flight turn immediately; `:queue' waits for
the turn to end on its own.")
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

;;;; Major mode

(defvar-local agent-backend--instance nil
  "The `agent-backend' instance driving this buffer.
The derived client mode sets it with `setq-local' when it creates its
conversation buffer.")

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

(provide 'agent-backend)
;;; agent-backend.el ends here
