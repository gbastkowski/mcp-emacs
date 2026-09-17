;;; agent-propose.el --- Let the human edit proposed text before approving it -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.12.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; An agent drafts text the human is going to stand behind -- a commit
;; message, an MR description, an issue body -- and the permission gate
;; (`agent-permission') can only help once the text is already an argument
;; to a command about to run.  A draft that exists before any command has
;; nothing to be gated on.  This is the surface that asks about the draft
;; itself: an editable buffer holding the proposed text, answered with one
;; key -- accept, which resolves with the buffer's current (possibly
;; edited) text, or reject, which discards it.
;;
;; The shape is `agent-permission''s, for the same reasons, with one
;; difference: a decision is a choice among read-only options and a draft
;; exists to be changed, so this is an editable text buffer rather than a
;; row of single keys.  The split / window / close plumbing and the
;; single-answer registry come over wholesale.
;;
;; Backend-agnostic on purpose.  A pending proposal is a plist and a
;; continuation; who asked and how the answer travels back is the caller's
;; business.  The MCP side reaches this as the ~propose_text~ tool
;; (`mcp-emacs-propose-text-async' / `mcp-emacs-propose-text'), and nothing
;; here mentions that.
;;
;; Two invariants the callers depend on:
;;
;; - Every pending proposal is answered exactly once.  Whoever is waiting
;;   is blocked until then, so an answer that resolved twice would answer
;;   a call that already happened.
;; - Not answering is not approving.  These requests arrive while nobody
;;   may be looking, so the timeout has to fall closed;
;;   `agent-propose-request' takes the deadline and reports it as
;;   `timeout' rather than leaving the caller to invent a default.

;;; Code:

(require 'subr-x)

(defgroup agent-propose nil
  "Editing a proposed draft before it is approved."
  :group 'tools
  :prefix "agent-propose-")

(defcustom agent-propose-window-height 12
  "Lines given to the proposal window when splitting below."
  :type 'integer
  :group 'agent-propose)

(defcustom agent-propose-split-height-threshold 20
  "Window height below which the proposal buffer splits sideways.
Mirrors `agent-prompt-split-height-threshold': below this many lines a
horizontal split leaves both halves useless."
  :type 'integer
  :group 'agent-propose)

(defvar agent-propose--pending nil
  "Alist of (ID . PLIST) for proposals raised and not yet answered.
PLIST holds `:text', `:label', `:resolve' and `:buffer'.  The registry is
the single source of truth for \"is this still open\": a resolved
proposal is removed from it before its continuation runs, so a second
answer finds nothing and does nothing.")

(defvar-local agent-propose--id nil
  "The pending proposal this buffer answers.")

;;;; The registry

(defun agent-propose--take (id)
  "Remove and return the pending proposal for ID, or nil when it is gone.
Removal and lookup are one step on purpose: this is what makes
\"answered exactly once\" hold without a separate flag to keep in sync.
Ids are strings, so this compares with `equal' -- an `assq' here would
never match."
  (when-let* ((entry (assoc id agent-propose--pending)))
    (setq agent-propose--pending
          (assoc-delete-all (car entry) agent-propose--pending))
    (cdr entry)))

(defun agent-propose-pending-ids ()
  "Return the ids of proposals still waiting for an answer."
  (mapcar #'car agent-propose--pending))

(defun agent-propose--resolve (id answer)
  "Answer the pending proposal ID with ANSWER.
ANSWER is the accepted text, or `reject' / `timeout'.  Does nothing when
ID is no longer pending, so a race between the human and the deadline
resolves once.  Returns non-nil when this call was the one that
answered."
  (when-let* ((entry (agent-propose--take id)))
    (let ((buffer (plist-get entry :buffer))
          (resolve (plist-get entry :resolve)))
      (when (buffer-live-p buffer)
        (agent-propose--close buffer))
      ;; From a timer, not inline: the continuation writes to a process and
      ;; may rearrange windows, and doing that while this command is still
      ;; unwinding the window it was called from is how windows get lost.
      (when resolve
        (run-at-time 0 nil resolve answer))
      t)))

;;;; Windows

(defun agent-propose--split (window)
  "Split WINDOW for a proposal buffer and return the new window.
Nil when WINDOW cannot be split, so a cramped frame degrades to
`display-buffer' rather than signalling."
  (condition-case nil
      (if (< (window-body-height window) agent-propose-split-height-threshold)
          (split-window window nil 'right)
        (split-window window (- (max 4 agent-propose-window-height)) 'below))
    (error nil)))

(defun agent-propose--display (buffer window)
  "Show BUFFER in a split of WINDOW, select it, and return the window."
  (let* ((split (and (window-live-p window)
                     (agent-propose--split window)))
         (shown (if split
                    (progn (set-window-buffer split buffer) split)
                  (display-buffer buffer))))
    (when (window-live-p shown)
      (select-window shown))
    shown))

(defun agent-propose--close (buffer)
  "Remove BUFFER's window and kill it.
The window is deleted rather than restored from a saved configuration:
the split came from the conversation window, so removing it hands those
lines straight back."
  (when-let* ((window (get-buffer-window buffer)))
    (when (and (window-live-p window) (not (one-window-p t)))
      (ignore-errors (delete-window window))))
  (when (buffer-live-p buffer)
    (kill-buffer buffer)))

;;;; Commands

(defun agent-propose--answer (answer)
  "Answer this buffer's proposal with ANSWER.
ANSWER is the accepted text, or `reject'."
  (if-let* ((id agent-propose--id))
      (unless (agent-propose--resolve id answer)
        (message "That proposal was already answered"))
    (user-error "No pending proposal in this buffer")))

(defun agent-propose-accept ()
  "Accept this proposal with the buffer's current, possibly edited, text.
The accepted text is whatever the buffer holds when this runs: an
untouched draft resolves exactly as given, an edited one with the
human's edits."
  (interactive)
  (agent-propose--answer
   (buffer-substring-no-properties (point-min) (point-max))))

(defun agent-propose-reject ()
  "Reject this proposal, discarding the draft."
  (interactive)
  (agent-propose--answer 'reject))

;;;; Mode

(defvar agent-propose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'agent-propose-accept)
    (define-key map (kbd "C-c C-k") #'agent-propose-reject)
    map)
  "Keymap for `agent-propose-mode'.
`C-c C-c' accepts with the buffer's current text and `C-c C-k' rejects.
There are no single-letter answers on purpose: this buffer is editable,
so every letter is text to type rather than a command.  The editing keys
are `text-mode''s.")

(define-derived-mode agent-propose-mode text-mode "Propose"
  "Major mode for reviewing a proposed draft the human can edit.
The buffer holds the proposed text in full and is editable like any text
buffer; `C-c C-c' (accept) resolves the proposal with the buffer's
current text and `C-c C-k' (reject) discards it.  Derived from
`text-mode' rather than the read-only `special-mode' the permission
decision uses, because a draft exists to be changed before it is
approved.")

(declare-function evil-define-key* "evil-core")
(declare-function evil-set-initial-state "evil-core")
(declare-function evil-insert-state "evil-states")

(with-eval-after-load 'evil
  ;; The buffer is editable, so the permission gate's single letters are
  ;; text to type here rather than answers.  Normal state keeps the vim
  ;; editor-buffer pair instead, as `agent-prompt' does: `ZZ' accepts with
  ;; the current text, `ZQ' rejects.  And because the buffer exists for
  ;; the human to type into, it opens in insert state.
  (evil-define-key* 'normal agent-propose-mode-map
                    (kbd "ZZ") #'agent-propose-accept
                    (kbd "ZQ") #'agent-propose-reject)
  (evil-set-initial-state 'agent-propose-mode 'insert))

;;;; Entry point

(defun agent-propose--buffer-name (id)
  "Return the proposal buffer name for ID."
  (format "*agent-propose: %s*" (or id "?")))

(defun agent-propose--header (label)
  "Return the header line describing the keys, prefixed by LABEL."
  (substitute-command-keys
   (concat (if label (format "%s   " label) "")
           "\\<agent-propose-mode-map>\\[agent-propose-accept] accept  "
           "\\[agent-propose-reject] reject")))

(defun agent-propose-request (id text &rest options)
  "Raise a proposal of TEXT for the human to edit and approve, given ID.
Show an editable buffer holding TEXT and wait for the human to answer
with `agent-propose-accept' or `agent-propose-reject'.  Accept resolves
the proposal with the buffer's current -- possibly edited -- text; reject
discards it.  Return the review buffer.

OPTIONS is a plist:

  `:resolve'  called once, from a timer, with the final text when the
              proposal is accepted, or with `reject' / `timeout'.
              Required to be useful: without it the answer goes nowhere.
  `:label'    a name for the proposal (e.g. \"MR description\"), shown in
              the header line for context.
  `:timeout'  seconds after which the proposal resolves itself as
              `timeout'.  Nil waits indefinitely, which is only
              appropriate when the caller has its own deadline.
  `:window'   the conversation window to split; defaults to the
              selected one.

Raising a proposal for an ID that is already pending answers nothing and
signals: two callers waiting on one id could not both be told the
answer."
  (when (assoc id agent-propose--pending)
    (error "A proposal for %s is already pending" id))
  (let* ((label (plist-get options :label))
         (buffer (get-buffer-create (agent-propose--buffer-name id)))
         (entry (list :text text
                      :label label
                      :resolve (plist-get options :resolve)
                      :buffer buffer)))
    (push (cons id entry) agent-propose--pending)
    (with-current-buffer buffer
      (agent-propose-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (or text "")))
      (goto-char (point-min))
      (setq agent-propose--id id)
      (setq-local header-line-format (agent-propose--header label)))
    (agent-propose--display buffer (or (plist-get options :window)
                                       (selected-window)))
    (when-let* ((seconds (plist-get options :timeout)))
      (run-at-time
       seconds nil
       (lambda ()
         (agent-propose--resolve id 'timeout))))
    buffer))

(provide 'agent-propose)
;;; agent-propose.el ends here