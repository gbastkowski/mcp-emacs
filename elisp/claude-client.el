;;; claude-client.el --- Terminal-free Claude Code runner -*- lexical-binding: t; -*-

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
(require 'subr-x)

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

(defvar claude-client-event-functions '(claude-client--reshow-after-review)
  "Abnormal hook run with (BUFFER EVENT) for every parsed event.
Each EVENT is a plist as stored in `claude-client--events'.  This is
the subscriber seam: rendering is one consumer, the Org transcript
\(issue #39) another, and keeping the conversation window visible across
an ediff review a third -- none of which the runner has to know about.")

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
Subscriber for `claude-client-event-functions'.  An `apply_diff' review
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

;;;; Event model

(defun claude-client--push-event (buffer event)
  "Append EVENT to BUFFER's log, notify subscribers, and re-render."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq claude-client--events
            (append claude-client--events (list event)))
      (run-hook-with-args 'claude-client-event-functions buffer event)
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

(defun claude-client--sentinel (buffer proc _change)
  "Report PROC exiting into BUFFER."
  (unless (process-live-p proc)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        ;; The process dying ends any turn with it; leaving the flag set
        ;; would wedge the buffer against ever starting another.
        (setq claude-client--process nil
              claude-client--turn-active nil)))))

;;;; Rendering

(defun claude-client--render-event (event)
  "Return a display string for EVENT, or nil to skip it."
  (pcase (plist-get event :kind)
    ('started (format "── claude %s ──" (or (plist-get event :model) "")))
    ('text (plist-get event :text))
    ('tool-use (format "  [tool: %s]" (plist-get event :name)))
    ('tool-result
     (let ((text (string-trim (or (plist-get event :text) ""))))
       (unless (string-empty-p text)
         (format "  → %s"
                 (car (split-string text "\n"))))))
    ('finished (format "── %s ──" (or (plist-get event :subtype) "done")))
    ('resumed (format "── resumed %s ──" (plist-get event :session)))
    ('interrupted "── interrupted ──")
    ('note-dropped (format "  (dropped unsent note: %s)" (plist-get event :text)))
    ('prompt (format "\n>>> %s" (plist-get event :text)))
    ('note (format "> %s%s"
                   (plist-get event :text)
                   (if (plist-get event :pending) "  (pending)" "")))
    ('notes-delivered
     (format "── %d note%s to carry forward ──"
             (length (plist-get event :notes))
             (if (= 1 (length (plist-get event :notes))) "" "s")))
    (_ nil)))

(defun claude-client--render ()
  "Re-render this buffer's event log."
  (let ((at-end (eobp))
        (inhibit-read-only t))
    (erase-buffer)
    (dolist (event claude-client--events)
      (when-let ((s (claude-client--render-event event)))
        (insert s)
        (unless (string-suffix-p "\n" s) (insert "\n"))))
    (when at-end (goto-char (point-max)))))

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
Starts a fresh conversation, replacing any previous log in this buffer.
Use `claude-client-send' to continue the one already running.

With RESUME-ID, reopen that past session instead of starting a new one,
so the model still has its history; `claude-client-resume' picks one
interactively.  The log itself does not come back -- it lives in this
buffer, not on disk -- so the rendered conversation restarts even though
the model's context does not.

Edits are routed through the mcp-emacs server's `apply_diff', so any
file change opens an ediff for the human to accept or reject."
  (interactive "sPrompt: ")
  (let ((buffer (get-buffer-create "*claude-client*")))
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
            claude-client--interrupted nil)
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

(defun claude-client-quit ()
  "Kill the CLI subprocess for this buffer."
  (interactive)
  (when (process-live-p claude-client--process)
    (delete-process claude-client--process))
  (setq claude-client--process nil
        claude-client--turn-active nil))

;;;; Major mode

(defvar claude-client-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'claude-client-start)
    (define-key map (kbd "k") #'claude-client-quit)
    (define-key map (kbd "n") #'claude-client-add-note)
    (define-key map (kbd "s") #'claude-client-send)
    (define-key map (kbd "r") #'claude-client-resume)
    (define-key map (kbd "i") #'claude-client-interrupt)
    map)
  "Keymap for `claude-client-mode'.")

(define-derived-mode claude-client-mode special-mode "claude"
  "Major mode for the terminal-free Claude conversation buffer."
  (setq-local truncate-lines nil))

(provide 'claude-client)

;;; claude-client.el ends here
