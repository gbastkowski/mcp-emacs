;;; claude-client.el --- Terminal-free Claude Code runner -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.8.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Drive Claude Code without a terminal emulator: spawn the CLI headless,
;; parse its stream-json output, and render the conversation into an
;; ordinary Emacs buffer.  This is the non-`eat' runner from issue #40,
;; modelled on `opencode-client.el' (stream parse -> event model -> render
;; into a `special-mode' buffer).
;;
;; Two things differ from the opencode backend:
;;
;; - Transport is a subprocess, not HTTP+SSE.  Claude's `--output-format
;;   stream-json' is NDJSON: one complete JSON object per line.  Frame on
;;   newlines, not on SSE's blank-line separator.
;; - Edits are gated at the MCP tool boundary.  Claude's own mutating tools
;;   are disabled with `--disallowedTools' and the mcp-emacs server is
;;   passed via `--mcp-config', so a write can only happen by calling
;;   `mcp__emacs__apply_diff' -- which opens an ediff the human answers.
;;   The CLI's `can_use_tool' stdio control request is NOT used: it is
;;   never emitted in headless mode (verified against 2.1.220), and the
;;   `permission_denials' in the result are a post-hoc audit record rather
;;   than a gate.
;;
;; Conversations are per project, one buffer and one subprocess each, named
;; `*claude-client:<project>:<n>*' (`claude-client-list' and
;; `claude-client-switch' enumerate them).  Several can run at once, in one
;; project or across several.
;;
;; Turns are multi-turn over one subprocess: `claude-client-start' opens a
;; conversation and `claude-client-send' continues it, reusing the same CLI
;; so the session id and its context carry across turns.  That is also what
;; lets a human note actually reach the model -- notes queued during a turn
;; are delivered as the next one (see `claude-client-deliver-notes').
;;
;; A past session can be reopened with `claude-client-resume' (`r'), which
;; reuses the same on-disk session store the eat runner's picker reads, so a
;; session started in either runner can be continued in the other.  Only the
;; model's context comes back -- the rendered log lives in the buffer, not on
;; disk.
;;
;; The conversation window is an ordinary window placed with
;; `display-buffer-in-direction' (`claude-client-window-direction'), matching
;; the eat runner's placement.  It is also re-shown after an ediff review
;; resolves: the review restores a window configuration captured before the
;; conversation existed, which would otherwise hide it exactly when the
;; result arrives (issue #44).

;;; Code:

(require 'json)
(require 'seq)
(require 'subr-x)
(require 'agent-backend)

;; Soft dependency: prose is fontified as markdown when `markdown-mode' is
;; installed, and rendered plain when it is not (see
;; `claude-client--fontify-markdown').  The popup output window takes the
;; same optional dependency.
(require 'markdown-mode nil t)
(declare-function gfm-view-mode "markdown-mode" ())
(defvar markdown-fontify-code-blocks-natively)

;;;; Customization

(defgroup claude-client nil
  "Terminal-free Claude Code runner."
  :group 'tools)

(defcustom claude-client-executable "claude"
  "Claude Code CLI executable."
  :type 'string
  :group 'claude-client)

(defcustom claude-client-model nil
  "Model to pass to the CLI, or nil to use its default."
  :type '(choice (const :tag "CLI default" nil) string)
  :group 'claude-client)

(defcustom claude-client-mcp-config nil
  "Path to an MCP config file exposing the mcp-emacs server to Claude.
When nil, one is written to a temp file pointing at the running
`mcp-emacs-server' -- see `claude-client--mcp-config-file'."
  :type '(choice (const :tag "Generate" nil) file)
  :group 'claude-client)

(defcustom claude-client-disallowed-tools
  '("Write" "Edit" "MultiEdit" "NotebookEdit")
  "Claude built-in tools to disable so edits route through mcp-emacs.
`MultiEdit' must be disabled alongside `Edit': otherwise Claude can
batch file changes through it and bypass the ediff gate entirely."
  :type '(repeat string)
  :group 'claude-client)

(defcustom claude-client-allowed-mcp-tools
  '("mcp__emacs__apply_diff"
    "mcp__emacs__open_file"
    "mcp__emacs__get_buffer_content"
    "mcp__emacs__list_open_editors"
    "mcp__emacs__save_buffer")
  "MCP tools Claude may call without an interactive permission prompt.
Proxied MCP tools are denied by default, so the write path
\(`apply_diff') has to be listed here or every edit is refused before
the human ever sees the ediff."
  :type '(repeat string)
  :group 'claude-client)

(defcustom claude-client-deliver-notes t
  "When non-nil, hand queued notes to the model as a turn of their own.
A note is always recorded immediately.  This controls whether it also
*reaches* the model: with multi-turn stdin the notes drained at the end
of a turn can be sent straight back as the next one, so \"add a thought
at any time\" changes what the model does rather than only what the log
says.  Set to nil to keep notes as a record the human relays by hand.

Delivery timing is `claude-client-note-interrupts'."
  :type 'boolean
  :group 'claude-client)

(defcustom claude-client-note-interrupts t
  "When non-nil, a note written mid-turn abandons that turn immediately.
This is the answer to the interruption question in #39.

With this on, writing a note is how the human redirects the model *now*:
the in-flight turn is interrupted, and the note is re-sent as the next
turn along with the fact that the previous one was cut short, so the
model re-plans rather than resuming.  The partial work of the abandoned
turn is lost -- that is the price of acting immediately, and it is the
whole point of \"add a thought at any time\".

With it off, notes queue and are delivered when the turn ends on its
own; nothing is ever abandoned.  `claude-client-interrupt' is still
available either way for a deliberate stop."
  :type 'boolean
  :group 'claude-client)

(defcustom claude-client-max-pending-notes 20
  "How many undelivered notes to keep before dropping the oldest.
Backpressure for the case where the human keeps writing while the model
is slow or wedged.  Without a bound the queue grows until it is
delivered as one enormous prompt, and the newest thought -- the one most
likely to matter -- competes with everything stale in front of it.

Dropping the oldest is the deliberate choice: the recent note is the
current intent.  A drop is recorded in the log, so the record still
shows that something was said and lost rather than quietly discarding
it.  nil means keep everything."
  :type '(choice (const :tag "Unbounded" nil) integer)
  :group 'claude-client)

(defcustom claude-client-tool-result-lines 6
  "How many lines of a tool result to show before eliding the rest.
A `git diff' or a whole-file `Read' otherwise dumps its entire payload
into the conversation and buries the model's prose, which defeats facing
chrome separately from prose (issue #61).  Tool *input* has always been
bounded to one 60-column line by `claude-client--tool-input-summary';
this is the same bound for the answer.

Six is enough for a status line plus context, or the head of a diff.
The elided lines are not lost: the full text stays in
`claude-client--events', the elision says how many were dropped, and
TAB (`claude-client-toggle-tool-result') on the result shows it in full.
nil means show everything.

This bounds *display* only.  Truncating to a single line was tried
before and reverted -- it hid the answer -- so the floor here is a few
lines with a way to see the rest, not one line."
  :type '(choice (const :tag "Unbounded" nil) integer)
  :group 'claude-client)

(defcustom claude-client-window-direction 'right
  "Direction in which the conversation window is placed.
An ordinary window in this direction, so it can be split, navigated and
closed like any other -- mirroring `mcp-emacs-run-window-direction' so
both runners feel the same.  `nil' uses plain `pop-to-buffer' and lets
`display-buffer-alist' decide."
  :type '(choice (const right) (const left) (const above) (const below)
                 (const :tag "Let display-buffer decide" nil))
  :group 'claude-client)

(defcustom claude-client-window-width 0.4
  "Width of the conversation window, as a fraction of the frame.
Used when `claude-client-window-direction' is `left' or `right'."
  :type 'number
  :group 'claude-client)

(defcustom claude-client-window-height 0.4
  "Height of the conversation window, as a fraction of the frame.
Used when `claude-client-window-direction' is `above' or `below'."
  :type 'number
  :group 'claude-client)

(defcustom claude-client-focus-on-show nil
  "When non-nil, select the conversation window when it is shown.
Off by default: the runner is something to watch while working
elsewhere, so stealing point on every redisplay would be disruptive."
  :type 'boolean
  :group 'claude-client)

(defcustom claude-client-restore-window-after-review t
  "Re-show the conversation window after an ediff review resolves.
The review captures the window configuration before it starts and
restores it on quit (so side windows come back).  When the review was
triggered by a tool call from this buffer, that snapshot predates the
conversation window, so restoring it takes the conversation off screen
exactly when its result arrives.  Re-displaying afterwards keeps it
visible without touching the review's own restore."
  :type 'boolean
  :group 'claude-client)

(defcustom claude-client-system-prompt
  "You are running inside Emacs. You have no Write or Edit tools.
To change a file you must call mcp__emacs__apply_diff with the absolute
path and the complete new file content. The human reviews it in ediff and
accepts or rejects; the tool result tells you which. Never claim a change
was made unless apply_diff returned applied."
  "Extra system prompt telling Claude how to reach the edit path.
Without this the model tends to reach for its (disabled) built-in
tools first and then report that it cannot edit."
  :type 'string
  :group 'claude-client)

;;;; State

(defvar-local claude-client--process nil
  "The Claude CLI subprocess for this conversation buffer.")

(defvar-local claude-client--stdout ""
  "Unparsed tail of the CLI's stdout, awaiting a complete line.")

(defvar-local claude-client--events nil
  "Parsed conversation events, oldest first.
Each is a plist: :kind, plus kind-specific keys.  This is the render
model, and the append-only log issue #39 wants to subscribe to.")

(defvar-local claude-client--expanded-results nil
  "Indices into `claude-client--events' whose tool result is shown in full.
Expansion is display state, not part of the log, so it is kept beside the
events rather than written into them -- issue #39 wants that log to stay
an append-only record of what happened.

Keyed by index because events carry no identity of their own, and the
list is append-only: an index stays valid as long as the log it indexes
does.  Starting a fresh conversation discards the log, so this is
cleared alongside it in `claude-client-start'.")

(defvar-local claude-client--session-id nil
  "Claude session id, from the `system'/`init' event.")

(defvar-local claude-client--pending-notes nil
  "Notes added by the human that the model has not been shown yet.
Oldest first.  A note is logged the moment it is written -- it is part
of the shared record immediately -- but it is only handed to the model
when the current turn ends.  See `claude-client-add-note'.")

(defvar-local claude-client--interrupted nil
  "Non-nil when the turn now ending was abandoned on purpose.
Set when an interrupt is sent, cleared when the next turn starts.  The
model is told its previous turn was cut short, so it re-plans around the
note that caused the interrupt instead of resuming what it was doing.")

(defvar-local claude-client--turn-active nil
  "Non-nil while a turn is in flight, i.e. between spawn and `result'.
Tracked from the stream rather than from the process: `claude --print'
stays alive after emitting `result' (it waits on stdin for a follow-up
turn), so `process-live-p' reports `run' long after the turn is over
and cannot answer \"is the model working right now?\".")

(defvaralias 'claude-client-event-functions 'agent-backend-event-functions)
(make-obsolete-variable 'claude-client-event-functions
                        'agent-backend-event-functions "1.7.0")
;; `claude-client-event-functions' is now an alias of the shared hook
;; `agent-backend-event-functions' (issue #41): every event is published
;; on the shared hook, and subscribers that still name the old hook keep
;; working because the alias resolves to the same variable.

;;;; The backend class

(defclass claude-client-backend (agent-backend)
  ()
  "A Claude conversation backend (an `agent-backend' subclass).
The conversation state stays in the buffer-local variables this file
already uses (`claude-client--events' and friends): the change spec
deliberately keeps the append-only event log backend-internal rather
than forcing one conversation model.  The instance is the dispatch
target for the shared generic methods and is held in the buffer-local
`agent-backend--instance'.")

(defun claude-client--instance ()
  "Return the claude backend instance for the current buffer."
  agent-backend--instance)
;;;; Spawning

(defun claude-client--mcp-config-file ()
  "Return a path to the MCP config exposing mcp-emacs to Claude.
Uses `claude-client-mcp-config' when set, otherwise writes a temp file
pointing at the running server's endpoint."
  (or claude-client-mcp-config
      (let ((file (make-temp-file "claude-client-mcp-" nil ".json"))
            (url (format "http://localhost:%s/mcp"
                         (if (boundp 'mcp-emacs-server-port)
                             (symbol-value 'mcp-emacs-server-port)
                           8765))))
        (with-temp-file file
          (insert (json-encode
                   `((mcpServers . ((emacs . ((type . "http")
                                              (url . ,url)))))))))
        file)))

(defun claude-client--settings-file ()
  "Write and return a settings file allowlisting the mcp-emacs tools."
  (let ((file (make-temp-file "claude-client-settings-" nil ".json")))
    (with-temp-file file
      (insert (json-encode
               `((permissions
                  . ((allow . ,(vconcat claude-client-allowed-mcp-tools))
                     (deny . [])))))))
    file))

(defun claude-client--system-prompt-file ()
  "Write and return a file holding `claude-client-system-prompt'."
  (let ((file (make-temp-file "claude-client-prompt-" nil ".txt")))
    (with-temp-file file (insert claude-client-system-prompt))
    file))

(defun claude-client--command (&optional resume-id)
  "Return the full argument list for the Claude CLI subprocess.
With RESUME-ID, continue that past session instead of starting a new
one: the CLI reopens it with its history, keeping the same session id.
Note `--session-id' is not the same thing -- that means \"create a new
session with this id\" and fails outright if a transcript already
exists."
  (append
   (list claude-client-executable
         "--print"
         "--output-format" "stream-json"
         "--input-format" "stream-json"
         "--verbose"
         "--mcp-config" (claude-client--mcp-config-file)
         "--strict-mcp-config"
         "--settings" (claude-client--settings-file)
         "--append-system-prompt-file" (claude-client--system-prompt-file))
   (when resume-id (list "--resume" resume-id))
   (when claude-client-model (list "--model" claude-client-model))
   (when claude-client-disallowed-tools
     (cons "--disallowedTools" claude-client-disallowed-tools))))

;;;; Conversation buffers

;; One buffer per conversation, named `*claude-client:<project>:<n>*' --
;; the eat runner's `*claude:<project>:<n>*' scheme with this client's own
;; prefix, so the two runners stay distinguishable in the buffer list.  The
;; project comes from each buffer's own `default-directory', so no registry
;; has to be kept in sync (issue #56).

(declare-function project-root "project" (project))

(defconst claude-client--buffer-name-regexp
  "\\`\\*claude-client:\\(.+\\):\\([0-9]+\\)\\*\\'"
  "Regexp matching a conversation buffer name.
Group 1 is the project name, group 2 the per-project number.")

(defun claude-client--project-root ()
  "Return the current project root, or `default-directory' as a fallback.
Delegates to the runner's helper so both runners agree on what a project
is, but falls back when that file is absent."
  (if (require 'mcp-emacs-run nil t)
      (mcp-emacs-run--project-root)
    (or (when (and (featurep 'project) (fboundp 'project-current))
          (when-let* ((proj (project-current nil)))
            (expand-file-name (project-root proj))))
        (expand-file-name default-directory))))

(defun claude-client--buffer-name (root n)
  "Return the conversation buffer name for project ROOT and number N."
  (format "*claude-client:%s:%d*"
          (file-name-nondirectory (directory-file-name root))
          n))

(defun claude-client--buffers ()
  "Return all live conversation buffers."
  (seq-filter (lambda (buf)
                (string-match-p claude-client--buffer-name-regexp
                                (buffer-name buf)))
              (buffer-list)))

(defun claude-client--project-buffers (root)
  "Return the live conversation buffers belonging to project ROOT.
A buffer's project is read straight off its own `default-directory',
which `claude-client--new-buffer' pins to the root it was created for.
Re-running project detection inside the buffer would be wrong: it can
resolve to a different root (or fail over to `default-directory' of a
parent project), which mis-scopes the numbering."
  (let ((root (expand-file-name root)))
    (seq-filter (lambda (buf)
                  (string= (expand-file-name
                            (buffer-local-value 'default-directory buf))
                           root))
                (claude-client--buffers))))

(defun claude-client--next-number (root)
  "Return the lowest positive conversation number free for project ROOT.
Killed middle slots are refilled, so numbers stay compact."
  (let ((used (delq nil
                    (mapcar (lambda (buf)
                              (when (string-match claude-client--buffer-name-regexp
                                                  (buffer-name buf))
                                (string-to-number
                                 (match-string 2 (buffer-name buf)))))
                            (claude-client--project-buffers root))))
        (n 1))
    (while (memq n used) (setq n (1+ n)))
    n))

(defun claude-client--new-buffer ()
  "Create and return a fresh conversation buffer for this project.
`default-directory' is pinned to the project root so the buffer keeps
answering for the right project even when the conversation outlives the
buffer it was started from."
  (let* ((root (claude-client--project-root))
         (buffer (get-buffer-create
                  (claude-client--buffer-name
                   root (claude-client--next-number root)))))
    (with-current-buffer buffer
      (setq default-directory root)
      (unless (derived-mode-p 'claude-client-mode)
        (claude-client-mode)))
    buffer))

;;;; Windows

(defun claude-client--display (buffer)
  "Display BUFFER in the conversation window and return that window.
Placed with `display-buffer-in-direction' so it stays an ordinary,
splittable window rather than a dedicated side window -- the same shape
`mcp-emacs-run--display' gives the eat runner."
  (let* ((window
          (if (null claude-client-window-direction)
              (display-buffer buffer)
            (let ((size (if (memq claude-client-window-direction '(left right))
                            `(window-width . ,claude-client-window-width)
                          `(window-height . ,claude-client-window-height))))
              (display-buffer
               buffer
               `((display-buffer-in-direction)
                 (direction . ,claude-client-window-direction)
                 ,size))))))
    (when (and window claude-client-focus-on-show)
      (select-window window))
    window))

(defun claude-client--reshow-after-review (buffer event)
  "Re-display BUFFER when EVENT reports a finished tool call.
Subscriber for `agent-backend-event-functions'.  An `apply_diff' review
restores the window configuration it captured before it opened, which
predates this conversation window when the review came from this
buffer's own tool call -- so without this the conversation vanishes at
the moment its result lands.  Only re-shows a buffer that was already
displayed, so this never forces a hidden conversation on screen."
  (when (and claude-client-restore-window-after-review
             (eq (plist-get event :kind) 'tool-result)
             (buffer-live-p buffer)
             (not (get-buffer-window buffer t)))
    (claude-client--display buffer)))
;; The re-show is a subscriber on the shared hook now (issue #41).
(add-hook 'agent-backend-event-functions #'claude-client--reshow-after-review)

;;;; Event model

(defun claude-client--push-event (buffer event)
  "Append EVENT to BUFFER's log, notify subscribers, and re-render.
Events are published on `agent-backend-event-functions' -- the shared
hook (issue #41) -- which `claude-client-event-functions' aliases, so
subscribers on either name see every event."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq claude-client--events
            (append claude-client--events (list event)))
      (agent-backend--publish buffer event)
      (claude-client--render))))
(defun claude-client--events-for-message (msg)
  "Return render events for an assistant MSG's content blocks."
  (delq nil
        (mapcar
         (lambda (block)
           (let ((type (alist-get 'type block)))
             (cond
              ((equal type "text")
               (let ((text (string-trim (or (alist-get 'text block) ""))))
                 (unless (string-empty-p text)
                   (list :kind 'text :text text))))
              ((equal type "tool_use")
               (list :kind 'tool-use
                     :name (alist-get 'name block)
                     :input (alist-get 'input block)))
              (t nil))))
         (alist-get 'content msg))))

(defun claude-client--handle-message (buffer msg)
  "Turn one parsed stream-json MSG into events and apply them to BUFFER."
  (let ((type (alist-get 'type msg)))
    (cond
     ((and (equal type "system") (equal (alist-get 'subtype msg) "init"))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq claude-client--session-id (alist-get 'session_id msg))))
      (claude-client--push-event
       buffer (list :kind 'started
                    :session (alist-get 'session_id msg)
                    :model (alist-get 'model msg))))
     ((equal type "assistant")
      (dolist (event (claude-client--events-for-message
                      (alist-get 'message msg)))
        (claude-client--push-event buffer event)))
     ((equal type "user")
      ;; Tool results come back as a synthetic user message.
      (dolist (block (alist-get 'content (alist-get 'message msg)))
        (when (equal (alist-get 'type block) "tool_result")
          (let ((content (alist-get 'content block)))
            (claude-client--push-event
             buffer (list :kind 'tool-result
                          :text (if (stringp content)
                                    content
                                  (mapconcat
                                   (lambda (c) (or (alist-get 'text c) ""))
                                   content "\n"))))))))
     ((equal type "result")
      (claude-client--push-event
       buffer (list :kind 'finished
                    :subtype (alist-get 'subtype msg)
                    :denials (alist-get 'permission_denials msg)))
      ;; Turn over: anything the human wrote while it ran is surfaced now.
      ;; Drained after `finished' so the log reads in the order things
      ;; actually happened.
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (setq claude-client--turn-active nil)))
      (claude-client--drain-notes buffer))
     (t nil))))

;;;; Notes from the human (issue #39, `NoteAdded')

;; The second writer.  Until now the log had one producer (the runner) and
;; readers; a note is the human producing to the same log, which is what the
;; event-stream direction is actually for.
;;
;; Delivery is deliberately conservative in this slice: the note is logged
;; and visible *immediately*, but it is only handed to the model when the
;; current turn ends.  Nothing is aborted mid tool-call.  That is not a
;; claim that queueing is the right interruption rule -- it is the honest
;; behaviour for a one-shot runner that has no way to steer a turn in
;; flight (no multi-turn stdin, no `--resume').  Deciding finish/abort/
;; re-plan is still the open question in #39, and it needs a runner that
;; can act on the answer.

;;;###autoload
(defun claude-client-add-note (text)
  "Add TEXT to this conversation's log as a human note.
The note is recorded at once, so it is part of the shared record the
moment it is written and every subscriber sees it.

What happens next depends on `claude-client-note-interrupts'.  By
default a note written while a turn is running abandons that turn and
is delivered immediately, so the model re-plans around it; otherwise it
waits until the turn ends on its own.  With nothing running it is
delivered straight away either way."
  (interactive "sNote: ")
  (unless (derived-mode-p 'claude-client-mode)
    (user-error "Not in a Claude conversation buffer"))
  (let ((note (string-trim text))
        (running (and claude-client--turn-active t)))
    (when (string-empty-p note)
      (user-error "Empty note"))
    ;; Coalesce an exact repeat: writing the same thing twice while the model
    ;; has seen neither says nothing new, and sending it twice only spends
    ;; context.  Anything genuinely different is kept, in order.
    (unless (member note claude-client--pending-notes)
      (setq claude-client--pending-notes
            (append claude-client--pending-notes (list note))))
    ;; Bound the queue: the newest note is the current intent, so when the
    ;; model is too slow to drain them the oldest go.  Each drop is logged --
    ;; the record should show that something was said and lost.
    (when claude-client-max-pending-notes
      (while (> (length claude-client--pending-notes)
                claude-client-max-pending-notes)
        (let ((dropped (pop claude-client--pending-notes)))
          (claude-client--push-event
           (current-buffer) (list :kind 'note-dropped :text dropped)))))
    (claude-client--push-event
     (current-buffer)
     (list :kind 'note :text note
           ;; `pending' means "the model has not seen this yet".  When the
           ;; note interrupts, it is about to be delivered, so it is not.
           :pending (and running (not claude-client-note-interrupts))))
    (cond
     ;; Redirect now: abandon the turn.  The drain happens when `result'
     ;; arrives for the interrupted turn, which also marks the turn over --
     ;; draining here would race that and deliver into a dying turn.
     ;;
     ;; `claude-client--interrupted' also serves as the backpressure guard:
     ;; a second note arriving before the abandoned turn has finished dying
     ;; must not fire another interrupt.  The turn is already ending and the
     ;; note is already queued, so it rides out on the same delivery.
     ((and running claude-client-note-interrupts
           (not claude-client--interrupted)
           (process-live-p claude-client--process))
      (setq claude-client--interrupted t)
      (claude-client--push-event (current-buffer) (list :kind 'interrupted))
      (claude-client--send-interrupt claude-client--process))
     ;; Nothing running: there is nothing to wait for, and the drain fires on
     ;; `result', so a queued note would otherwise sit until some later turn
     ;; happened to end -- or forever, if none did.
     ((not running)
      (claude-client--drain-notes (current-buffer))))))

(defun claude-client--drain-notes (buffer)
  "Surface BUFFER's pending notes now that its turn has ended.
When `claude-client-deliver-notes' is non-nil and the process is still
alive, the notes are also sent to the model as the next turn -- which is
what makes a note actually reach it rather than only being recorded.
Returns the drained notes, oldest first, and clears the queue."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((notes claude-client--pending-notes))
        (setq claude-client--pending-notes nil)
        (when notes
          (claude-client--push-event
           buffer (list :kind 'notes-delivered :notes notes))
          (when (and claude-client-deliver-notes
                     (not claude-client--turn-active)
                     (process-live-p claude-client--process))
            (setq claude-client--turn-active t)
            (claude-client--send-turn
             claude-client--process
             (concat
              (when claude-client--interrupted
                (concat "Your previous turn was interrupted before it "
                        "finished, on purpose. Do not resume it; re-plan "
                        "around the note below.\n\n"))
              "Notes from the human:\n"
              (mapconcat (lambda (n) (concat "- " n)) notes "\n")))
            (setq claude-client--interrupted nil)))
        notes))))

;;;; Streaming

(defun claude-client--filter (buffer proc chunk)
  "Frame CHUNK from PROC as NDJSON lines and dispatch them to BUFFER."
  (ignore proc)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq claude-client--stdout (concat claude-client--stdout chunk))
      ;; stream-json is one complete object per line; a chunk can split a
      ;; line, so only consume up to the last newline and keep the tail.
      (let (pos)
        (while (setq pos (string-search "\n" claude-client--stdout))
          (let ((line (substring claude-client--stdout 0 pos)))
            (setq claude-client--stdout
                  (substring claude-client--stdout (1+ pos)))
            (unless (string-empty-p (string-trim line))
              (let ((msg (ignore-errors
                           (json-parse-string line
                                              :object-type 'alist
                                              :array-type 'list
                                              :null-object nil
                                              :false-object nil))))
                (when msg
                  (claude-client--handle-message buffer msg))))))))))

(defun claude-client--sentinel (buffer proc change)
  "Report PROC exiting into BUFFER, with CHANGE saying how."
  (unless (process-live-p proc)
    (when (buffer-live-p buffer)
      (let ((mid-turn (with-current-buffer buffer claude-client--turn-active))
            ;; Read from PROC before anything else touches it, and keep both:
            ;; CHANGE is the human-readable cause ("exited abnormally with
            ;; code 1", "killed by signal 15") while the status is what code
            ;; can branch on.  Recording them is what makes the event
            ;; evidence of how the process ended rather than an assertion
            ;; that it did -- see issue #62.
            (reason (string-trim (or change "")))
            ;; Guarded because this runs from Emacs' process machinery,
            ;; which swallows errors: signalling here would skip the state
            ;; clearing below and wedge the buffer against another turn --
            ;; the very thing that clearing exists to prevent.
            (status (and (processp proc) (process-exit-status proc))))
        (with-current-buffer buffer
          ;; The process dying ends any turn with it; leaving the flag set
          ;; would wedge the buffer against ever starting another.
          (setq claude-client--process nil
                claude-client--turn-active nil))
        ;; A turn cut short by the process dying has to say so in the log.
        ;; The render model is the event list, so clearing the flag alone
        ;; leaves the transcript ending on whatever the model was doing --
        ;; typically a `tool-use' with no result, which reads exactly like a
        ;; turn still in flight.  Pushing after the flag is cleared so
        ;; subscribers and the mode line see the settled state.
        (when mid-turn
          (claude-client--push-event
           buffer (list :kind 'died :reason reason :status status)))))))

;;;; Faces
;;
;; The chrome (what the harness did) is faced separately from the model's
;; own prose (what it said), so the two are distinguishable at a glance.
;; Prose is fontified as markdown instead, because that is what the model
;; emits -- see `claude-client--fontify-markdown'.

(defface claude-client-banner-face
  '((t :inherit shadow :weight bold))
  "Face for the session banner and turn-end markers."
  :group 'claude-client)

(defface claude-client-prompt-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for a prompt the human sent."
  :group 'claude-client)

(defface claude-client-tool-face
  '((t :inherit font-lock-function-name-face))
  "Face for a tool call's name."
  :group 'claude-client)

(defface claude-client-tool-input-face
  '((t :inherit shadow))
  "Face for the arguments shown beside a tool call."
  :group 'claude-client)

(defface claude-client-tool-result-face
  '((t :inherit font-lock-comment-face))
  "Face for a tool's answer."
  :group 'claude-client)

(defface claude-client-note-face
  '((t :inherit font-lock-doc-face))
  "Face for a human note."
  :group 'claude-client)

(defface claude-client-pending-face
  '((t :inherit warning))
  "Face for the marker on a note that has not reached the model yet."
  :group 'claude-client)

(defface claude-client-error-face
  '((t :inherit error))
  "Face for a reported failure."
  :group 'claude-client)

;;;; Rendering

(defvar claude-client--fontify-buffer nil
  "Scratch buffer used to fontify markdown, or nil before first use.")

(defun claude-client--fontify-markdown (text)
  "Return TEXT with markdown text properties applied.
Fontification happens in a scratch buffer whose properties are copied
out, so no markdown mode is ever active in the conversation buffer and
its own keymap is untouched.  When `markdown-mode' is absent TEXT is
returned unchanged: prose then reads plain, which is worse than
fontified but better than refusing to render."
  (if (or (string-empty-p text) (not (fboundp 'gfm-view-mode)))
      text
    (unless (buffer-live-p claude-client--fontify-buffer)
      (setq claude-client--fontify-buffer
            (get-buffer-create " *claude-client-fontify*")))
    (with-current-buffer claude-client--fontify-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        ;; Re-entering the mode per call is wasteful but keeps this a pure
        ;; function of TEXT; the buffer is small and off-screen.
        (setq-local markdown-fontify-code-blocks-natively t)
        (delay-mode-hooks (gfm-view-mode))
        (setq-local markdown-fontify-code-blocks-natively t)
        (font-lock-flush)
        (font-lock-ensure)
        (buffer-string)))))

(defun claude-client--faced (text face)
  "Return TEXT propertized with FACE.
Uses the `face' property, not `font-lock-face': the conversation buffer
derives from `special-mode' and runs with `font-lock-mode' off, where
`font-lock-face' has no effect.  This is also the property
`markdown-mode' leaves on the fontified prose, so chrome and prose carry
their faces the same way."
  (propertize text 'face face))

(defconst claude-client--tool-input-keys
  '(path file_path pattern command query url description)
  "Input keys worth showing beside a tool call, in order of preference.
A tool's whole input is often long (a diff, a file's new contents); the
point of the summary is to say *what* was touched, not to reproduce it.")

(defun claude-client--tool-input-summary (event)
  "Return a one-line summary of EVENT's tool input, or nil.
Prefers the first of `claude-client--tool-input-keys' present in the
input, so a call reads as \"[tool: apply_diff] /tmp/x\"."
  (let ((input (plist-get event :input)))
    (when (consp input)
      (when-let* ((key (seq-find (lambda (k) (assq k input))
                                 claude-client--tool-input-keys))
                  (val (alist-get key input)))
        (when (stringp val)
          (let ((line (car (split-string (string-trim val) "\n"))))
            (unless (string-empty-p line)
              (truncate-string-to-width line 60 nil nil "…"))))))))

(defconst claude-client--empty-field-regexp
  "\\`[ \t]*[a-z_][a-z0-9_ -]*:[ \t]*\\'"
  "A line that is a field label with no value, e.g. \"labels:\".
`gh issue view' answers with a dozen of these; they are pure noise in
the conversation.  Deliberately narrow -- lowercase label, nothing after
the colon -- so it cannot eat a real line of prose or code.")

(defun claude-client--tool-result-lines (text)
  "Return TEXT's lines, dropping ones that are an empty field label.
See `claude-client--empty-field-regexp' (issue #61)."
  (seq-remove (lambda (l)
                (string-match-p claude-client--empty-field-regexp l))
              (split-string text "\n")))

(defun claude-client--render-tool-result (event index)
  "Return the display string for tool-result EVENT at INDEX, or nil.
Bounded to `claude-client-tool-result-lines' unless INDEX is in
`claude-client--expanded-results' -- see that custom for why.  The
elision line carries INDEX as a `claude-client-result' text property, so
`claude-client-toggle-tool-result' can tell which result point is on
without re-deriving positions."
  (let ((text (string-trim (or (plist-get event :text) ""))))
    (unless (string-empty-p text)
      (let* ((lines (claude-client--tool-result-lines text))
             (limit claude-client-tool-result-lines)
             (expanded (memq index claude-client--expanded-results))
             (elided (and limit (not expanded)
                          (> (length lines) limit)))
             (shown (if elided (seq-take lines limit) lines))
             (body (claude-client--faced
                    (mapconcat (lambda (l) (concat "  → " l)) shown "\n")
                    'claude-client-tool-result-face)))
        (if (not shown)
            ;; Every line was an empty field label: nothing worth a row.
            nil
          (concat
           body
           (when elided
             (concat
              "\n"
              (claude-client--faced
               (format "  → … %d more line%s (TAB to expand)"
                       (- (length lines) limit)
                       (if (= 1 (- (length lines) limit)) "" "s"))
               'claude-client-pending-face)))))))))

(defun claude-client--render-event (event &optional index)
  "Return a display string for EVENT, or nil to skip it.
Structural chrome carries its own face; the model's prose is fontified
as markdown.  The plain text is kept stable -- callers and tests match
on it -- so this only adds properties.

INDEX is EVENT's position in `claude-client--events', needed only by
tool results to track expansion; it is optional so that callers and
tests can render a lone event."
  (pcase (plist-get event :kind)
    ('started
     (claude-client--faced
      (format "── claude %s ──" (or (plist-get event :model) ""))
      'claude-client-banner-face))
    ('text (claude-client--fontify-markdown (or (plist-get event :text) "")))
    ('tool-use
     (concat "  "
             (claude-client--faced (format "[tool: %s]" (plist-get event :name))
                                   'claude-client-tool-face)
             (when-let* ((input (claude-client--tool-input-summary event)))
               (claude-client--faced (concat " " input)
                                     'claude-client-tool-input-face))))
    ('tool-result (claude-client--render-tool-result event index))
    ('finished
     (claude-client--faced
      (format "── %s ──" (or (plist-get event :subtype) "done"))
      'claude-client-banner-face))
    ('resumed
     (claude-client--faced
      (format "── resumed %s ──" (plist-get event :session))
      'claude-client-banner-face))
    ('interrupted
     (claude-client--faced "── interrupted ──" 'claude-client-banner-face))
    ;; Faced as an error, not a banner: unlike `interrupted' and `finished'
    ;; this end was not anyone's intent.  The reason is the sentinel's own
    ;; account of how the process ended, so the banner reports what was
    ;; observed; with no reason recorded it states only what it knows.
    ('died
     (claude-client--faced
      (let ((reason (plist-get event :reason)))
        (if (and reason (not (string-empty-p reason)))
            (format "── died mid-turn: %s ──" reason)
          "── died mid-turn ──"))
      'claude-client-error-face))
    ('error
     (claude-client--faced (format "  !! %s" (plist-get event :text))
                           'claude-client-error-face))
    ('note-dropped
     (claude-client--faced
      (format "  (dropped unsent note: %s)" (plist-get event :text))
      'claude-client-pending-face))
    ('prompt
     (concat "\n"
             (claude-client--faced (format ">>> %s" (plist-get event :text))
                                   'claude-client-prompt-face)))
    ('note
     (concat (claude-client--faced (format "> %s" (plist-get event :text))
                                   'claude-client-note-face)
             (when (plist-get event :pending)
               (claude-client--faced "  (pending)"
                                     'claude-client-pending-face))))
    ('notes-delivered
     (claude-client--faced
      (format "── %d note%s to carry forward ──"
              (length (plist-get event :notes))
              (if (= 1 (length (plist-get event :notes))) "" "s"))
      'claude-client-banner-face))
    (_ nil)))

(defun claude-client--render ()
  "Re-render this buffer's event log.
Each tool result's rows carry a `claude-client-result' property holding
its event index, so `claude-client-toggle-tool-result' can act on the
result under point."
  (let ((at-end (eobp))
        (inhibit-read-only t)
        (index -1))
    (erase-buffer)
    (dolist (event claude-client--events)
      (setq index (1+ index))
      (when-let* ((s (claude-client--render-event event index)))
        (let ((start (point)))
          (insert s)
          (unless (string-suffix-p "\n" s) (insert "\n"))
          (when (eq (plist-get event :kind) 'tool-result)
            (put-text-property start (point) 'claude-client-result index)))))
    (when at-end (goto-char (point-max)))))

(defun claude-client--result-at-point ()
  "Return the event index of the tool result at point, or nil.
Also looks at the position before point, so the command still works with
point at end of line -- where `char-after' is the newline past the
property."
  (or (get-text-property (point) 'claude-client-result)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) 'claude-client-result))))

;;;###autoload
(defun claude-client-toggle-tool-result ()
  "Show the tool result at point in full, or re-collapse it.
Results are bounded to `claude-client-tool-result-lines' so a large
payload cannot bury the model's prose; this reaches the rest.  The full
text was never discarded -- it is in `claude-client--events' -- so this
only flips display state and re-renders.

Point is restored by line rather than by character offset: expanding
rewrites the whole buffer, so the old position would otherwise land
somewhere unrelated."
  (interactive)
  (let ((index (claude-client--result-at-point)))
    (unless index
      (user-error "No tool result at point"))
    (let ((line (line-number-at-pos)))
      (setq claude-client--expanded-results
            (if (memq index claude-client--expanded-results)
                (delq index claude-client--expanded-results)
              (cons index claude-client--expanded-results)))
      (claude-client--render)
      (goto-char (point-min))
      (forward-line (1- line)))))

;;;; Turns

(defun claude-client--prompt-with-notes (prompt)
  "Return PROMPT with this buffer's pending notes appended, and clear them.
Notes the human wrote before a turn started are carried into that turn's
prompt rather than dropped."
  (let ((carried claude-client--pending-notes))
    (setq claude-client--pending-notes nil)
    (if carried
        (concat prompt "\n\nNotes from the human:\n"
                (mapconcat (lambda (n) (concat "- " n)) carried "\n"))
      prompt)))

(defun claude-client--send-turn (proc text)
  "Write TEXT to PROC as one stream-json user turn."
  (process-send-string
   proc
   (concat (json-encode
            `((type . "user")
              (message . ((role . "user")
                          (content . [((type . "text") (text . ,text))])))))
           "\n")))

(defun claude-client--send-interrupt (proc)
  "Ask PROC to abandon the turn it is working on.
Writes the `interrupt' control request the CLI advertises as
`interrupt_receipt_v1' in its init capabilities.  The turn ends promptly
with `result'/`error_during_execution'; the session itself survives and
accepts further turns, so an interrupt costs the in-flight work and
nothing else."
  (process-send-string
   proc
   (concat (json-encode
            `((type . "control_request")
              (request_id . ,(format "int-%s" (float-time)))
              (request . ((subtype . "interrupt")))))
           "\n")))

;;;###autoload
(defun claude-client-interrupt ()
  "Abandon the turn this conversation is working on.
The partial work is lost; the session is not.  Use `n' to add a note
instead when the point is to redirect rather than to stop."
  (interactive)
  (unless (derived-mode-p 'claude-client-mode)
    (user-error "Not in a Claude conversation buffer"))
  (unless claude-client--turn-active
    (user-error "No turn is running"))
  (unless (process-live-p claude-client--process)
    (user-error "No live Claude process"))
  (when claude-client--interrupted
    (user-error "This turn is already being interrupted"))
  (setq claude-client--interrupted t)
  (claude-client--push-event (current-buffer) (list :kind 'interrupted))
  (claude-client--send-interrupt claude-client--process))

;;;###autoload
(defun claude-client-send (prompt)
  "Send PROMPT as the next turn of this conversation.
Reuses the running CLI process, so the model keeps the session and its
context; `claude-client-start' is only needed for the first turn or
after the process has gone.  Refuses while a turn is in flight -- the
CLI reads one turn at a time, and writing a second would interleave
with the one being answered."
  (interactive "sPrompt: ")
  (unless (derived-mode-p 'claude-client-mode)
    (user-error "Not in a Claude conversation buffer"))
  (cond
   (claude-client--turn-active
    (user-error "A turn is already running; add a note with `n' instead"))
   ((not (process-live-p claude-client--process))
    (user-error "No live Claude process; start one with `g'"))
   (t
    (let ((text (claude-client--prompt-with-notes prompt)))
      (claude-client--push-event (current-buffer)
                                 (list :kind 'prompt :text prompt))
      (setq claude-client--turn-active t
            claude-client--interrupted nil)
      (claude-client--send-turn claude-client--process text)))))

;;;; Entry point

;;;###autoload
(defun claude-client-start (prompt &optional resume-id)
  "Run PROMPT through a headless Claude and render it in a buffer.
From outside a conversation buffer this opens a new one for the current
project, named `*claude-client:<project>:<n>*', so conversations in
different projects (or several in one) coexist.  Called from inside a
conversation buffer -- the `g' binding -- it restarts that conversation
in place, replacing its log.  Use `claude-client-send' to continue the
one already running.

With RESUME-ID, reopen that past session instead of starting a new one,
so the model still has its history; `claude-client-resume' picks one
interactively.  The log itself does not come back -- it lives in this
buffer, not on disk -- so the rendered conversation restarts even though
the model's context does not.

Edits are routed through the mcp-emacs server's `apply_diff', so any
file change opens an ediff for the human to accept or reject."
  (interactive "sPrompt: ")
  (let ((buffer (if (derived-mode-p 'claude-client-mode)
                    ;; Called from a conversation buffer (`g'): restart this
                    ;; one in place rather than piling up a new buffer.
                    (current-buffer)
                  (claude-client--new-buffer))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'claude-client-mode)
        (claude-client-mode))
      ;; One conversation buffer, one subprocess.  Silently restarting would
      ;; orphan the running CLI -- and any ediff it is blocked on, which then
      ;; waits for a human whose answer no longer goes anywhere.
      (when claude-client--turn-active
        (user-error "A Claude run is already active here; `k' to kill it first"))
      ;; A previous conversation's process is replaced, not left behind.
      (when (process-live-p claude-client--process)
        (delete-process claude-client--process))
      (let ((inhibit-read-only t)) (erase-buffer))
      (setq claude-client--events nil
            claude-client--stdout ""
            claude-client--session-id nil
            claude-client--interrupted nil
            ;; Indices into the log that was just discarded would
            ;; otherwise expand unrelated results in the new one.
            claude-client--expanded-results nil)
      (let ((text (claude-client--prompt-with-notes prompt))
            (proc (make-process
                   :name "claude-client"
                   :buffer nil
                   :command (claude-client--command resume-id)
                   :connection-type 'pipe
                   :noquery t
                   :filter (lambda (p c) (claude-client--filter buffer p c))
                   :sentinel (lambda (p c)
                               (claude-client--sentinel buffer p c)))))
        (setq claude-client--process proc
              claude-client--turn-active t)
        (when resume-id
          (claude-client--push-event buffer (list :kind 'resumed
                                                  :session resume-id)))
        (claude-client--push-event buffer (list :kind 'prompt :text prompt))
        (claude-client--send-turn proc text)))
    (claude-client--display buffer)
    buffer))

(declare-function mcp-emacs-run--project-root "mcp-emacs-run" ())
(declare-function mcp-emacs-run-resume--session-files "mcp-emacs-run-resume" (root))
(declare-function mcp-emacs-run-resume--session-id "mcp-emacs-run-resume" (file))
(declare-function mcp-emacs-run-resume--label "mcp-emacs-run-resume" (file))

;;;###autoload
(defun claude-client-resume ()
  "Pick a past Claude session for this project and reopen it here.
Reuses the on-disk session store and the labels the eat runner's picker
already builds -- the store is backend-agnostic, so a session started in
either runner can be resumed in this one."
  (interactive)
  (require 'mcp-emacs-run)
  (require 'mcp-emacs-run-resume)
  (let* ((root (mcp-emacs-run--project-root))
         (files (mcp-emacs-run-resume--session-files root)))
    (unless files
      (user-error "No past Claude sessions for this project"))
    (let* ((alist (mapcar (lambda (f)
                            (cons (mcp-emacs-run-resume--label f) f))
                          files))
           (pick (completing-read "Resume session: " alist nil t))
           (file (cdr (assoc pick alist))))
      (when file
        (claude-client-start
         (read-string "Prompt: ")
         (mcp-emacs-run-resume--session-id file))))))

(defun claude-client--label (buffer)
  "Return a `completing-read' label for conversation BUFFER.
The buffer name already carries project and number, so it only gains a
marker for whether the model is working."
  (format "%s%s"
          (buffer-name buffer)
          (with-current-buffer buffer
            (cond (claude-client--turn-active "  (working)")
                  ((process-live-p claude-client--process) "  (idle)")
                  (t "  (finished)")))))

;;;###autoload
(defun claude-client-list ()
  "Message the live Claude conversations."
  (interactive)
  (if-let* ((bufs (claude-client--buffers)))
      (message "Claude conversations:\n%s"
               (string-join (mapcar (lambda (b)
                                      (format "  %s" (claude-client--label b)))
                                    bufs)
                            "\n"))
    (message "No Claude conversations")))

(defun claude-client--pick (bufs &optional prompt)
  "Return one buffer from BUFS, asking with PROMPT when there is a choice.
Nil when BUFS is empty, so callers can decide what \"nothing yet\" means;
the sole buffer is returned without prompting."
  (cond
   ((null bufs) nil)
   ((= (length bufs) 1) (car bufs))
   (t (let* ((alist (mapcar (lambda (b) (cons (claude-client--label b) b)) bufs))
             (pick (completing-read (or prompt "Conversation: ") alist nil t)))
        (cdr (assoc pick alist))))))

;;;###autoload
(defun claude-client-switch ()
  "Choose a live Claude conversation and display it."
  (interactive)
  (let ((bufs (claude-client--buffers)))
    (unless bufs (user-error "No Claude conversations"))
    (when-let* ((buf (claude-client--pick bufs "Switch to conversation: ")))
      (claude-client--display buf))))

(defun claude-client--hide-window (window)
  "Hide WINDOW, or its whole frame when it is that frame's only window.
`delete-window' signals on a frame's sole window, and a conversation
given its own frame is a reasonable thing to have done, so iconify that
frame instead of refusing to toggle."
  (condition-case nil
      (delete-window window)
    ;; The sole-window case is reported as a plain `error', so it cannot be
    ;; caught by type; trying and falling back beats predicting it.
    (error (iconify-frame (window-frame window)))))

;;;###autoload
(defun claude-client-toggle ()
  "Toggle a conversation window for the current project.
With no conversation, start one.  With several, prompt for which to
toggle.  Mirrors `mcp-emacs-run-toggle', scoped to this project rather
than frame-wide so it does not reach past the project you are working in.

Frame-aware: a conversation shown on this frame is hidden, but one that
is only on another frame is raised rather than hidden -- asking to toggle
something you cannot see means you want to see it, and deleting a window
on a frame you are not looking at is worse than surprising."
  (interactive)
  (let* ((bufs (claude-client--project-buffers (claude-client--project-root)))
         (buf (claude-client--pick bufs "Toggle conversation: ")))
    (cond
     ((null buf) (call-interactively #'claude-client-start))
     ;; This frame: hide it.
     ((get-buffer-window buf) (claude-client--hide-window (get-buffer-window buf)))
     ;; Another frame only: raise that frame and select the window there.
     ((get-buffer-window buf t)
      (let ((window (get-buffer-window buf t)))
        (select-frame-set-input-focus (window-frame window))
        (select-window window)))
     (t (claude-client--display buf)))))

(defun claude-client-quit ()
  "Kill the CLI subprocess for this buffer."
  (interactive)
  (when (process-live-p claude-client--process)
    (delete-process claude-client--process))
  (setq claude-client--process nil
        claude-client--turn-active nil))

;;;; agent-backend methods

(cl-defmethod agent-backend-connect ((_backend claude-client-backend))
  "Verify the Claude executable is present.
Claude has no connect handshake -- a conversation starts on the first
turn -- so this only checks the executable is runnable."
  (unless (executable-find claude-client-executable)
    (user-error "claude: executable %s not found" claude-client-executable))
  t)

(cl-defmethod agent-backend-quit ((backend claude-client-backend))
  "Kill the CLI subprocess for BACKEND's buffer."
  (let ((buffer (oref backend buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (claude-client-quit)))))

(cl-defmethod agent-backend-send ((backend claude-client-backend) prompt)
  "Send PROMPT as the next turn of BACKEND's conversation."
  (let ((buffer (oref backend buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (claude-client-send prompt)))))

(cl-defmethod agent-backend-interrupt ((backend claude-client-backend))
  "Abandon the turn BACKEND's conversation is working on."
  (let ((buffer (oref backend buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (claude-client-interrupt)))))

(cl-defmethod agent-backend-add-note ((backend claude-client-backend) text)
  "Add TEXT as a human note to BACKEND's conversation.
Uses Claude's native note machinery -- the pending-notes queue, the
interrupt-or-queue delivery policy -- unchanged."
  (let ((buffer (oref backend buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (claude-client-add-note text)))))

(cl-defmethod agent-backend-note-policy ((_backend claude-client-backend))
  "Return Claude's note delivery policy.
`:interrupt' when `claude-client-note-interrupts' is on (a note
abandons the turn in flight); `:queue' when off (notes wait for the
turn to end)."
  (if claude-client-note-interrupts :interrupt :queue))

;; Claude never emits permission or question requests: its gate is the
;; ediff review (mcp-emacs-ide), not a stream-json request.  The base
;; no-op defaults for reply-permission / reply-question apply.

(cl-defmethod agent-backend-list-sessions ((_backend claude-client-backend))
  "Return past Claude sessions from the on-disk resume store."
  (require 'mcp-emacs-run)
  (require 'mcp-emacs-run-resume)
  (let* ((root (mcp-emacs-run--project-root))
         (files (mcp-emacs-run-resume--session-files root)))
    (mapcar (lambda (f)
              (list :id (mcp-emacs-run-resume--session-id f)
                    :label (mcp-emacs-run-resume--label f)))
            files)))

(cl-defmethod agent-backend-resume ((backend claude-client-backend) _session)
  "Reopen a past Claude session through BACKEND's native picker."
  (let ((buffer (oref backend buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (claude-client-resume)))))

;; History seeding is a no-op for Claude: the rendered log lives in the
;; buffer, not on disk, so there is nothing to replay (the base default
;; applies).  project-root is likewise nil -- Claude's session store is
;; project-scoped but the backend itself does not report a root.

(cl-defmethod agent-backend-render ((backend claude-client-backend))
  "Re-render BACKEND's conversation buffer."
  (let ((buffer (oref backend buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (claude-client--render)))))

;;;; Major mode

(defvar claude-client-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'claude-client-start)
    (define-key map (kbd "k") #'claude-client-quit)
    (define-key map (kbd "n") #'claude-client-add-note)
    (define-key map (kbd "s") #'claude-client-send)
    (define-key map (kbd "r") #'claude-client-resume)
    (define-key map (kbd "i") #'claude-client-interrupt)
    (define-key map (kbd "TAB") #'claude-client-toggle-tool-result)
    map)
  "Keymap for `claude-client-mode'.
The single-letter keys are only reachable in plain Emacs; under evil they
are shadowed by the normal-state map, so `claude-client--setup-evil'
re-registers them.  The evil-safe `C-c'-prefixed vocabulary lives in
`agent-backend-mode-map' and works either way.")

(defconst claude-client--evil-keys
  '(("g" . claude-client-start)
    ("k" . claude-client-quit)
    ("n" . claude-client-add-note)
    ("s" . claude-client-send)
    ("r" . claude-client-resume)
    ("i" . claude-client-interrupt)
    ;; Not single-letter, but evil's motion state does claim TAB
    ;; (`evil-jump-forward'), so it needs re-registering the same way.
    ("TAB" . claude-client-toggle-tool-result))
  "The single-letter bindings to re-register with evil.
Mirrors `claude-client-mode-map'; kept as data so both paths bind the
same set.")

(declare-function evil-define-key* "evil-core"
                  (state keymap key def &rest bindings))

(defun claude-client--setup-evil ()
  "Bind `claude-client--evil-keys' in evil's normal and motion states.
Evil's state maps take precedence over a major mode's own keymap, so
without this every single-letter binding above is dead in a Doom-style
config -- `s' runs `evil-snipe-s', `k' moves the cursor up.  Evil is not
a dependency of this package (it must work in plain Emacs), so this is
called from an `evil-mode' load hook and is a no-op when evil is absent."
  (when (fboundp 'evil-define-key*)
    (pcase-dolist (`(,key . ,cmd) claude-client--evil-keys)
      (evil-define-key* '(normal motion) claude-client-mode-map
                        (kbd key) cmd))))

(with-eval-after-load 'evil
  (claude-client--setup-evil))

;; evil-snipe binds `s' in a *minor* mode map, which outranks even an
;; evil-registered major-mode map, so `s' would still snipe.  This is the
;; opt-out evil-snipe provides for exactly this case; magit, dired and
;; treemacs are on the same list by default.
(with-eval-after-load 'evil-snipe
  (when (boundp 'evil-snipe-disabled-modes)
    (add-to-list 'evil-snipe-disabled-modes 'claude-client-mode)))

(define-derived-mode claude-client-mode agent-backend-mode "claude"
  "Major mode for the terminal-free Claude conversation buffer.
Derives from `agent-backend-mode' (issue #41), so the shared keymap is
inherited and the buffer-local `agent-backend--instance' holds a fresh
`claude-client-backend' bound to this buffer."
  (setq-local truncate-lines nil)
  (setq-local agent-backend--instance
              (make-instance 'claude-client-backend
                             :buffer (current-buffer))))
(provide 'claude-client)

