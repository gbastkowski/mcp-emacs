;;; claude-client-test.el --- Tests for the terminal-free runner -*- lexical-binding: t; -*-

;; Batch tests for `claude-client.el'.  No CLI is spawned: the stream filter
;; is fed captured stream-json lines directly, which is also how the real
;; subprocess reaches it.  The sample lines below are trimmed from actual
;; `claude --print --output-format stream-json' output.

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'cl-lib)
(require 'json)
(require 'claude-client)

(defun claude-test--buffer ()
  "Return a fresh conversation buffer in `claude-client-mode'."
  (let ((buf (generate-new-buffer " *claude-test*")))
    (with-current-buffer buf (claude-client-mode))
    buf))

(defun claude-test--feed (buffer &rest lines)
  "Feed LINES to BUFFER's stream filter as if the CLI had written them."
  (dolist (line lines)
    (claude-client--filter buffer nil line)))

(defun claude-test--kinds (buffer)
  "Return the ordered list of event kinds recorded in BUFFER."
  (with-current-buffer buffer
    (mapcar (lambda (e) (plist-get e :kind)) claude-client--events)))

(defun claude-test--text (buffer)
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun claude-test--dead-process (&optional command)
  "Return a real process that has already exited.
COMMAND defaults to `true', so the exit status is 0; pass `false' for a
non-zero one.  A real process rather than a stub, so `process-live-p'
and `process-exit-status' answer for themselves -- the former is the
branch `claude-client--sentinel' turns on, and the latter is what it
records."
  (let ((proc (start-process "claude-test-dead" nil (or command "true"))))
    (while (process-live-p proc)
      (accept-process-output proc 0.05))
    proc))

;; Captured stream-json lines (one complete JSON object per line).
(defconst claude-test--init
  "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"abc-123\",\"model\":\"claude-opus-5\"}")
(defconst claude-test--text-msg
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"I'll write the file.\"}]}}")
(defconst claude-test--tool-use
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_01\",\"name\":\"mcp__emacs__apply_diff\",\"input\":{\"path\":\"/tmp/x\"}}]}}")
(defconst claude-test--tool-result
  "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\"Status: applied\\nnew\\n\"}]}}")
(defconst claude-test--result
  "{\"type\":\"result\",\"subtype\":\"success\",\"permission_denials\":[]}")

;;;; Command construction
;;
;; These flags are the permission model, not cosmetics: the built-in write
;; tools must be off and the MCP config on, or Claude edits files directly
;; and never reaches the ediff gate.

(describe "claude-client--command"
  (let ((cmd (claude-client--command)))
    (it "runs the CLI in non-interactive print mode"
      (check-that (member "--print" cmd)))
    (it "asks for stream-json on stdout"
      (check-that (equal (cadr (member "--output-format" cmd)) "stream-json")))
    (it "asks for stream-json on stdin"
      (check-that (equal (cadr (member "--input-format" cmd)) "stream-json")))
    (it "confines the CLI to the generated MCP config"
      (check-that (member "--strict-mcp-config" cmd)))
    (it "passes the generated MCP config"
      (check-that (member "--mcp-config" cmd)))
    (it "passes the generated settings file"
      (check-that (member "--settings" cmd)))
    (it "disallows Write so edits cannot bypass the ediff gate"
      (check-that (member "Write" cmd)))
    (it "disallows Edit so edits cannot bypass the ediff gate"
      (check-that (member "Edit" cmd)))
    ;; Edit and MultiEdit both: MultiEdit alone can batch writes past the gate.
    (it "disallows MultiEdit, which alone could batch writes past the gate"
      (check-that (member "MultiEdit" cmd)))))

(describe "claude-client--mcp-config-file"
  (let* ((file (claude-client--mcp-config-file))
         (parsed (with-temp-buffer
                   (insert-file-contents file)
                   (json-parse-string (buffer-string)
                                      :object-type 'alist :array-type 'list))))
    (let* ((servers (alist-get 'mcpServers parsed))
           (emacs (alist-get 'emacs servers)))
      (it "declares the emacs server as an HTTP transport"
        (check (alist-get 'type emacs) "http"))
      (it "points at the mcp-emacs /mcp endpoint"
        (check-that (string-suffix-p "/mcp" (alist-get 'url emacs)))))
    (delete-file file)))

(describe "claude-client--settings-file"
  (let* ((file (claude-client--settings-file))
         (parsed (with-temp-buffer
                   (insert-file-contents file)
                   (json-parse-string (buffer-string)
                                      :object-type 'alist :array-type 'list))))
    ;; apply_diff must be allowlisted: proxied MCP tools are denied by default,
    ;; so without this every edit is refused before the human sees an ediff.
    (let ((allow (alist-get 'allow (alist-get 'permissions parsed))))
      (it "allowlists apply_diff, which is denied by default as a proxied MCP tool"
        (check-that (member "mcp__emacs__apply_diff" allow))))
    (delete-file file)))

;;;; Stream framing
;;
;; stream-json is NDJSON: one object per line.  The filter must tolerate a
;; chunk boundary landing mid-line, since the pipe splits wherever it likes.

(describe "claude-client--filter framing"
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (progn
          (claude-test--feed buf (concat claude-test--init "\n"))
          (it "dispatches a single complete line"
            (check (claude-test--kinds buf) '(started))))
      (kill-buffer buf)))

  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (let* ((whole (concat claude-test--init "\n"))
               (cut (/ (length whole) 2)))
          (claude-test--feed buf (substring whole 0 cut))
          (it "holds a line split across chunks until its newline arrives"
            (check (claude-test--kinds buf) nil))
          (claude-test--feed buf (substring whole cut))
          (it "dispatches the split line once the newline arrives"
            (check (claude-test--kinds buf) '(started))))
      (kill-buffer buf)))

  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (progn
          (claude-test--feed
           buf (concat claude-test--init "\n" claude-test--text-msg "\n"))
          (it "dispatches every object arriving in one chunk"
            (check (claude-test--kinds buf) '(started text))))
      (kill-buffer buf)))

  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (progn
          (claude-test--feed buf "not json at all\n"
                             (concat claude-test--init "\n"))
          (it "skips a garbage line rather than aborting the stream"
            (check (claude-test--kinds buf) '(started))))
      (kill-buffer buf))))

;;;; Event mapping

(describe "system init events"
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (progn
          (claude-test--feed buf (concat claude-test--init "\n"))
          (with-current-buffer buf
            (it "records the session id for later resumes"
              (check claude-client--session-id "abc-123"))
            (let ((e (car claude-client--events)))
              (it "maps init to a started event"
                (check (plist-get e :kind) 'started))
              (it "carries the model the CLI announced"
                (check (plist-get e :model) "claude-opus-5")))))
      (kill-buffer buf))))

(describe "assistant text events"
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (progn
          (claude-test--feed buf (concat claude-test--text-msg "\n"))
          (with-current-buffer buf
            (let ((e (car claude-client--events)))
              (it "maps an assistant text block to a text event"
                (check (plist-get e :kind) 'text))
              (it "carries the model's prose verbatim"
                (check (plist-get e :text) "I'll write the file.")))))
      (kill-buffer buf))))

(describe "assistant tool_use events"
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (progn
          (claude-test--feed buf (concat claude-test--tool-use "\n"))
          (with-current-buffer buf
            (let ((e (car claude-client--events)))
              (it "maps a tool_use block to a tool-use event"
                (check (plist-get e :kind) 'tool-use))
              (it "carries the name of the tool being called"
                (check (plist-get e :name) "mcp__emacs__apply_diff")))))
      (kill-buffer buf))))

;; tool_result content is a plain string in practice; the list form is also
;; accepted, so both shapes must land as text.
(describe "tool_result events"
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (progn
          (claude-test--feed buf (concat claude-test--tool-result "\n"))
          (with-current-buffer buf
            (let ((e (car claude-client--events)))
              (it "maps a tool_result block to a tool-result event"
                (check (plist-get e :kind) 'tool-result))
              (it "carries string content as the event text"
                (check (plist-get e :text) "Status: applied\nnew\n")))))
      (kill-buffer buf)))

  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (progn
          (claude-test--feed
           buf (concat "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":[{\"type\":\"text\",\"text\":\"from list\"}]}]}}" "\n"))
          (with-current-buffer buf
            (it "accepts the list content shape as well as a plain string"
              (check (plist-get (car claude-client--events) :text) "from list"))))
      (kill-buffer buf))))

(describe "result events"
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (progn
          (claude-test--feed buf (concat claude-test--result "\n"))
          (with-current-buffer buf
            (let ((e (car claude-client--events)))
              (it "maps result to a finished event"
                (check (plist-get e :kind) 'finished))
              (it "carries the subtype saying how the turn ended"
                (check (plist-get e :subtype) "success")))))
      (kill-buffer buf))))

(describe "events the runner has no mapping for"
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (progn
          (claude-test--feed buf "{\"type\":\"rate_limit_event\"}\n")
          (it "ignores an unknown top-level type instead of logging a stray event"
            (check (claude-test--kinds buf) nil)))
      (kill-buffer buf)))

  ;; Empty assistant text blocks produce no event (the CLI emits these while
  ;; streaming partial messages).
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (progn
          (claude-test--feed
           buf "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"   \"}]}}\n")
          (it "logs nothing for the blank text blocks the CLI emits while streaming"
            (check (claude-test--kinds buf) nil)))
      (kill-buffer buf))))

;;;; Event ordering and the subscriber hook

(describe "the event log"
  ;; The log is append-only and in arrival order -- this is what issue #39
  ;; subscribes to, so ordering is a contract, not an implementation detail.
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (progn
          (claude-test--feed buf
                             (concat claude-test--init "\n")
                             (concat claude-test--text-msg "\n")
                             (concat claude-test--tool-use "\n")
                             (concat claude-test--tool-result "\n")
                             (concat claude-test--result "\n"))
          (it "keeps events in arrival order, which subscribers rely on"
            (check (claude-test--kinds buf)
                   '(started text tool-use tool-result finished))))
      (kill-buffer buf))))

;; Every event is announced to `claude-client-event-functions' with its
;; buffer -- the seam that lets #39 attach an Org transcript subscriber
;; without touching the renderer.
(describe "claude-client-event-functions"
  (let* ((buf (claude-test--buffer))
         (seen nil)
         (claude-client-event-functions
          (list (lambda (b e) (push (cons b (plist-get e :kind)) seen)))))
    (unwind-protect
        (progn
          (claude-test--feed buf
                             (concat claude-test--init "\n")
                             (concat claude-test--result "\n"))
          (it "is called once per event"
            (check (length seen) 2))
          (it "tells the subscriber which conversation the event came from"
            (check (car (car seen)) buf))
          (it "announces events in the order they arrived"
            (check (mapcar #'cdr (reverse seen)) '(started finished))))
      (kill-buffer buf))))

;;;; The process dying

;; A turn cut short by the process dying must say so in the log.  The
;; render model is the event list, so clearing `--turn-active' alone left
;; the transcript ending on whatever the model was mid-way through --
;; typically a `tool-use' with no result, indistinguishable from a turn
;; still running.  Observed in a real session (issue #62).
(describe "claude-client--sentinel on a turn cut short"
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (progn
          (claude-test--feed buf
                             (concat claude-test--init "\n")
                             (concat claude-test--tool-use "\n"))
          (with-current-buffer buf (setq claude-client--turn-active t))
          (claude-client--sentinel buf (claude-test--dead-process "false")
                                   "exited abnormally with code 1\n")
          (it "appends a died event so the transcript does not end mid-tool-call"
            (check (claude-test--kinds buf) '(started tool-use died)))
          (it "renders a banner saying the turn died"
            (check-that (string-match-p "died mid-turn" (claude-test--text buf))))
          ;; The cause is recorded, not guessed: the sentinel's own account of
          ;; how the process ended, plus a status code to branch on.  Without
          ;; these the banner asserts a death it cannot evidence (issue #62).
          (let ((e (car (last (with-current-buffer buf claude-client--events)))))
            (it "records the sentinel's own account of how the process ended"
              (check (plist-get e :reason) "exited abnormally with code 1"))
            (it "records the exit status so callers can branch on it"
              (check (plist-get e :status) 1)))
          (it "names the cause in the banner rather than asserting a bare death"
            (check-that (string-match-p "died mid-turn: exited abnormally with code 1"
                                        (claude-test--text buf))))
          (with-current-buffer buf
            (it "forgets the dead process"
              (check claude-client--process nil))
            ;; Left set, the buffer could never start another turn.
            (it "clears the in-flight flag so another turn can start"
              (check claude-client--turn-active nil))))
      (kill-buffer buf))))

;; A process exiting between turns is the normal way a conversation ends
;; (`claude --print' lingers on stdin, so this is the human quitting).
;; Nothing was cut short, so nothing is reported.
(describe "claude-client--sentinel on a clean exit"
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (progn
          (claude-test--feed buf
                             (concat claude-test--init "\n")
                             (concat claude-test--result "\n"))
          (claude-client--sentinel buf (claude-test--dead-process) nil)
          (it "reports nothing when the process exits between turns"
            (check (claude-test--kinds buf) '(started finished))))
      (kill-buffer buf))))

;; The sentinel outliving its buffer must not signal -- it fires from a
;; process filter, where an error is swallowed and leaves the log wedged.
(describe "claude-client--sentinel outliving its buffer"
  (let ((buf (claude-test--buffer)))
    (kill-buffer buf)
    (it "returns rather than signalling, since an error here wedges the log"
      (check (progn (claude-client--sentinel buf (claude-test--dead-process) nil)
                    'survived)
             'survived))))

;;;; Rendering

(describe "rendering a whole turn"
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (progn
          (claude-test--feed buf
                             (concat claude-test--init "\n")
                             (concat claude-test--text-msg "\n")
                             (concat claude-test--tool-use "\n")
                             (concat claude-test--result "\n"))
          (let ((text (claude-test--text buf)))
            (it "shows the model's prose"
              (check-that (string-match-p "I'll write the file\\." text)))
            (it "shows the tool that was called"
              (check-that (string-match-p "mcp__emacs__apply_diff" text)))
            (it "shows the model name in the opening banner"
              (check-that (string-match-p "claude-opus-5" text)))))
      (kill-buffer buf))))

;; The buffer is read-only for the human but still writable by the renderer.
(describe "claude-client-mode"
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (it "derives from `special-mode'"
            (check (derived-mode-p 'special-mode) 'special-mode))
          (it "leaves the conversation read-only for the human"
            (check buffer-read-only t)))
      (kill-buffer buf))))

;;;; Prettified rendering
;;
;; Chrome (what the harness did) is faced; prose (what the model said) is
;; fontified as markdown.  Faces go on the `face' property, not
;; `font-lock-face': this buffer runs with `font-lock-mode' off, where
;; `font-lock-face' would be silently ignored.

(defun claude-test--face-at (string index)
  "Return the `face' property of STRING at INDEX."
  (get-text-property index 'face string))

(describe "faces on rendered events"
  (let ((cases '((started . claude-client-banner-face)
                 (finished . claude-client-banner-face)
                 (interrupted . claude-client-banner-face)
                 (prompt . claude-client-prompt-face)
                 (note . claude-client-note-face)
                 (error . claude-client-error-face)
                 ;; `died' is faced as an error rather than a banner: the two
                 ;; deliberate endings are chrome, this one is a failure.
                 (died . claude-client-error-face))))
    (dolist (c cases)
      (let* ((kind (car c))
             (s (claude-client--render-event
                 (list :kind kind :text "x" :model "m" :subtype "success"
                       :session "s")))
             ;; `prompt' opens with a newline that carries no face.
             (i (if (eq kind 'prompt) 1 0)))
        (it (format "faces a %s event on the `face' property" kind)
          (check (claude-test--face-at s i) (cdr c)
                 (format "faces a %s event on the `face' property" kind)))))))

;; The banner reports what the sentinel observed, and no more: with a
;; reason it names the cause, without one it claims only that the turn
;; died.  An empty reason must not render as a dangling colon.
(describe "rendering a died event"
  (let ((s (claude-client--render-event
            '(:kind died :reason "killed by signal 15" :status 15))))
    (it "names the cause when the sentinel supplied a reason"
      (check (substring-no-properties s)
             "── died mid-turn: killed by signal 15 ──")))

  (dolist (event '((:kind died) (:kind died :reason "")))
    (it "claims only that the turn died when there is no reason, without a dangling colon"
      (check (substring-no-properties (claude-client--render-event event))
             "── died mid-turn ──"
             (format "claims only that the turn died for %S, without a dangling colon"
                     event)))))

(describe "rendering a tool-use event"
  (let ((s (claude-client--render-event
            '(:kind tool-use :name "apply_diff" :input ((path . "/tmp/x"))))))
    (it "faces the tool name"
      (check (claude-test--face-at s 2) 'claude-client-tool-face))
    (it "shows the tool's input beside the call"
      (check-that (string-match-p "/tmp/x" (substring-no-properties s))))
    (it "faces the input apart from the name"
      (check (claude-test--face-at s (1- (length s)))
             'claude-client-tool-input-face)))

  ;; A tool's input can be a whole file's contents; only a short summary of
  ;; what was touched belongs beside the call.
  (let ((s (claude-client--render-event
            `(:kind tool-use :name "write"
              :input ((path . ,(concat (make-string 200 ?a) "\nsecond line")))))))
    (it "keeps a multi-line input to a single rendered line"
      (check (length (split-string (substring-no-properties s) "\n")) 1))
    (it "truncates a long input to a short summary"
      (check-that (<= (length (substring-no-properties s)) 100))))

  (let ((s (claude-client--render-event '(:kind tool-use :name "bare"))))
    (it "renders a call with no input as just the tool name"
      (check (substring-no-properties s) "  [tool: bare]"))))

;; A note not yet delivered is marked, and the marker is faced apart from
;; the note itself.
(describe "rendering a pending note"
  (let ((s (claude-client--render-event '(:kind note :text "n" :pending t))))
    (it "faces the not-yet-delivered marker apart from the note itself"
      (check (claude-test--face-at s (1- (length s)))
             'claude-client-pending-face))))

(describe "rendering a tool-result event"
  ;; Earlier this truncated to the first line, hiding the rest of a tool's
  ;; answer.
  (let ((s (claude-client--render-event
            '(:kind tool-result :text "Status: applied\n412 lines\n"))))
    (it "keeps every line rather than truncating to the first"
      (check (substring-no-properties s) "  → Status: applied\n  → 412 lines"))
    (it "faces the result text"
      (check (claude-test--face-at s 2) 'claude-client-tool-result-face)))

  (let ((s (claude-client--render-event '(:kind tool-result :text "   "))))
    (it "renders nothing for a whitespace-only result"
      (check s nil))))

;;;; Bounded tool results (issue #61)

;; A `git diff' or whole-file `Read' used to dump its entire payload and
;; bury the prose.  Bounded now -- but *not* back to one line, which was
;; tried before and reverted (see `tool-result-keeps-lines' above): the
;; floor is a few lines plus a way to reach the rest.
(describe "bounding a long tool result"
  (let* ((long (mapconcat (lambda (i) (format "line %d" i))
                          (number-sequence 1 20) "\n"))
         (event (list :kind 'tool-result :text long))
         (s (substring-no-properties (claude-client--render-event event 0)))
         (lines (split-string s "\n")))
    ;; Six shown plus the elision row.
    (it "shows six lines plus an elision row"
      (check (length lines) 7))
    (it "keeps the head of the result"
      (check (car lines) "  → line 1"))
    (it "stops at the line limit"
      (check (nth 5 lines) "  → line 6"))
    (it "counts the elided remainder and offers a way to reach it"
      (check (nth 6 lines) "  → … 14 more lines (TAB to expand)"))
    ;; The elision is faced as pending, not as result text: it is chrome
    ;; about the result rather than part of the answer.
    (it "faces the elision as chrome rather than as part of the answer"
      (check (claude-test--face-at (claude-client--render-event event 0)
                                   (- (length s) 3))
             'claude-client-pending-face)))

  ;; Singular, because "1 more lines" reads as a bug.
  (let* ((seven (mapconcat #'number-to-string (number-sequence 1 7) "\n"))
         (s (substring-no-properties
             (claude-client--render-event (list :kind 'tool-result :text seven) 0))))
    (it "says \"1 more line\" rather than \"1 more lines\""
      (check-that (string-match-p "… 1 more line (TAB" s))))

  ;; Under the limit nothing is elided, and no affordance is advertised.
  (let ((s (substring-no-properties
            (claude-client--render-event
             '(:kind tool-result :text "one\ntwo\nthree") 0))))
    (it "advertises no expansion affordance for a result under the limit"
      (check (and (string-match-p "more line" s) t) nil))
    (it "leaves a short result intact"
      (check s "  → one\n  → two\n  → three"))))

;; Expansion is keyed by event index, so the *other* result stays bounded.
(describe "claude-client--expanded-results"
  (let* ((long (mapconcat (lambda (i) (format "l%d" i)) (number-sequence 1 20) "\n"))
         (event (list :kind 'tool-result :text long))
         (claude-client--expanded-results '(3)))
    (it "shows every line of the result whose index is expanded"
      (check (length (split-string
                      (substring-no-properties (claude-client--render-event event 3))
                      "\n"))
             20))
    (it "leaves another result bounded, since expansion is keyed by index"
      (check (length (split-string
                      (substring-no-properties (claude-client--render-event event 4))
                      "\n"))
             7))))

;; nil is the documented escape hatch: show everything.
(describe "claude-client-tool-result-lines"
  (let* ((long (mapconcat (lambda (i) (format "l%d" i)) (number-sequence 1 20) "\n"))
         (claude-client-tool-result-lines nil)
         (s (substring-no-properties
             (claude-client--render-event (list :kind 'tool-result :text long) 0))))
    (it "bounds nothing when set to nil"
      (check (length (split-string s "\n")) 20))))

(describe "empty field labels in a tool result"
  ;; `gh issue view' answers with a dozen empty field labels; they are noise.
  (let ((s (substring-no-properties
            (claude-client--render-event
             '(:kind tool-result
               :text "title: Fix it\nlabels:\nassignees:\nmilestone:\nbody: real")
             0))))
    (it "drops the empty labels `gh issue view' pads its answer with"
      (check s "  → title: Fix it\n  → body: real")))

  ;; The pattern must not eat real content that happens to contain a colon.
  (let ((s (substring-no-properties
            (claude-client--render-event
             '(:kind tool-result :text "Status: applied\nlabels: bug\n  (let ((x 1))") 0))))
    (it "keeps real content that happens to contain a colon"
      (check s "  → Status: applied\n  → labels: bug\n  →   (let ((x 1))")))

  ;; A result that is nothing but empty labels earns no row at all.
  (let ((s (claude-client--render-event
            '(:kind tool-result :text "labels:\nassignees:") 0)))
    (it "renders nothing when the result is nothing but empty labels"
      (check s nil))))

;;;; Toggling a result (issue #61)

;; Round-trip through the real command in a real buffer: the rows carry
;; their event index, TAB expands, TAB again collapses, and the prose
;; after the result survives both.
(describe "claude-client-toggle-tool-result"
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (setq claude-client--events
                (list '(:kind tool-use :name "Bash")
                      (list :kind 'tool-result
                            :text (mapconcat (lambda (i) (format "l%d" i))
                                             (number-sequence 1 30) "\n"))
                      '(:kind text :text "prose after")))
          (claude-client--render)
          (let ((collapsed (count-lines (point-min) (point-max))))
            ;; Line 3 is the first result row (banner-less: tool-use, then
            ;; six result rows).
            (goto-char (point-min))
            (forward-line 2)
            (it "finds the event index carried by a rendered result row"
              (check (claude-client--result-at-point) 1))
            (claude-client-toggle-tool-result)
            (it "expands the result under point"
              (check (> (count-lines (point-min) (point-max)) collapsed) t))
            (it "shows the last line of the result once expanded"
              (check-that (string-match-p "→ l30" (buffer-string))))
            (goto-char (point-min))
            (forward-line 2)
            (claude-client-toggle-tool-result)
            (it "collapses the result again on a second toggle"
              (check (count-lines (point-min) (point-max)) collapsed))
            (it "leaves the prose after the result untouched by either toggle"
              (check-that (string-match-p "prose after" (buffer-string))))))
      (kill-buffer buf)))

  ;; Point sits at end of line often enough that looking only at
  ;; `char-after' would make TAB fail there.
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (setq claude-client--events
                (list (list :kind 'tool-result :text "a\nb")))
          (claude-client--render)
          (goto-char (point-min))
          (end-of-line)
          (it "still finds the index with point at end of line"
            (check (claude-client--result-at-point) 0)))
      (kill-buffer buf)))

  ;; Off a result it refuses rather than toggling something arbitrary.
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (setq claude-client--events '((:kind text :text "just prose")))
          (claude-client--render)
          (goto-char (point-min))
          (it "refuses off a result rather than toggling something arbitrary"
            (check (condition-case nil
                       (progn (claude-client-toggle-tool-result) 'no-error)
                     (user-error 'user-error))
                   'user-error)))
      (kill-buffer buf))))

;; Starting a conversation discards the log, so stale indices must not
;; survive to expand unrelated results in the new one.
(describe "claude-client-start and expansion state"
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (setq claude-client--expanded-results '(0 1 2))
          (let ((claude-client-executable "definitely-not-a-real-binary"))
            (ignore-errors (claude-client-start "hi")))
          (it "discards stale expansion indices along with the old log"
            (check claude-client--expanded-results nil)))
      (kill-buffer buf))))

;;;; Mentions (issue #56)

;; A mention must *queue*, not deliver.  Both of add-note's paths are
;; wrong for it: mid-turn a note abandons the turn, and with nothing
;; running add-note drains immediately -- which would send the mention as
;; a turn of its own, the opposite of "without submitting".  Found by
;; running the command, not by reading the code.
(describe "agent-backend-mention on the claude backend"
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (agent-backend-mention (claude-client-backend :buffer buf)
                                 "@elisp/foo.el:12-40")
          (it "queues the mention instead of delivering it"
            (check claude-client--pending-notes '("@elisp/foo.el:12-40")))
          (it "sends nothing, so a mention is not a turn of its own"
            (check (memq 'notes-delivered (claude-test--kinds buf)) nil))
          (it "records the mention in the log"
            (check (claude-test--kinds buf) '(note)))
          ;; `pending' is the truth: the model has not been handed it.
          (it "marks the logged mention pending, since the model has not seen it"
            (check (plist-get (car claude-client--events) :pending) t)))
      (kill-buffer buf)))

  ;; Queued, so the next prompt carries it -- that is what makes a mention
  ;; reach the model at all.
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (agent-backend-mention (claude-client-backend :buffer buf) "@a.el:1")
          (it "rides out on the next prompt, which is how it reaches the model"
            (check (claude-client--prompt-with-notes "what is this?")
                   "what is this?\n\nNotes from the human:\n- @a.el:1")))
      (kill-buffer buf)))

  ;; Mentioning the same lines twice before the model has seen either says
  ;; nothing new, and costs context.
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (let ((backend (claude-client-backend :buffer buf)))
            (agent-backend-mention backend "@a.el:1")
            (agent-backend-mention backend "@a.el:1")
            (agent-backend-mention backend "@b.el:2"))
          (it "coalesces a repeated mention, which says nothing new and costs context"
            (check claude-client--pending-notes '("@a.el:1" "@b.el:2"))))
      (kill-buffer buf)))

  ;; A mention mid-turn must not interrupt: pointing at code is not the
  ;; human changing direction, which is what a note is for.
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (setq claude-client--turn-active t)
          (agent-backend-mention (claude-client-backend :buffer buf) "@a.el:1")
          (it "does not interrupt a running turn, since pointing at code is not a change of direction"
            (check (memq 'interrupted (claude-test--kinds buf)) nil))
          (it "still queues the mention while a turn runs"
            (check claude-client--pending-notes '("@a.el:1"))))
      (kill-buffer buf)))

  ;; Empty or whitespace-only text is not a mention.
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (agent-backend-mention (claude-client-backend :buffer buf) "   ")
          (it "queues nothing for whitespace-only text"
            (check claude-client--pending-notes nil))
          (it "logs nothing for whitespace-only text"
            (check (claude-test--kinds buf) nil)))
      (kill-buffer buf))))

;; TAB is bound in the mode map, and re-registered for evil -- motion
;; state claims it as `evil-jump-forward', so without that it is dead.
(describe "the TAB binding"
  (it "toggles a tool result in the plain-Emacs map"
    (check (lookup-key claude-client-mode-map (kbd "TAB"))
           #'claude-client-toggle-tool-result))
  (it "is re-registered for evil, which would otherwise claim it as a motion"
    (check (cdr (assoc "TAB" claude-client--evil-keys))
           'claude-client-toggle-tool-result)))

;; Prose keeps its exact text either way; only the properties differ.
(describe "rendering prose as markdown"
  (let* ((prose "Use **bold** and `code`.\n")
         (s (claude-client--render-event (list :kind 'text :text prose))))
    (it "keeps the prose text exactly, changing only its properties"
      (check (substring-no-properties s) prose))
    (if (fboundp 'gfm-view-mode)
        (it "fontifies the prose when markdown-mode is available"
          (check (and (text-properties-at 6 s) t) t))
      ;; Without `markdown-mode' the client must still render, plain.
      (it "still renders, plain, without markdown-mode"
        (check (text-properties-at 6 s) nil))))

  (let ((s (claude-client--render-event '(:kind text :text ""))))
    (it "renders empty prose as the empty string rather than nothing"
      (check s ""))))

(describe "claude-client--render-event on an unknown kind"
  (it "renders nothing rather than guessing"
    (check (claude-client--render-event '(:kind :no-such-kind)) nil)))

;;;; Human notes (issue #39, `NoteAdded')
;;
;; A note is the second writer to the log.  It must be recorded immediately
;; -- that is the whole point, the human can add a thought at any time --
;; but in this slice it reaches the model only when the turn ends.
;;
;; Whether a turn is running changes the behaviour, so most of these tests
;; have to fake a live process: with none, a note has nothing to wait for
;; and drains at once.

(defmacro claude-test--with-running-turn (&rest body)
  "Run BODY with this buffer marked as having a turn in flight.
Turn state is tracked from the stream, not the process: `claude --print'
stays alive after `result', so process liveness cannot stand in for it."
  `(let ((claude-client--turn-active t))
     ,@body))

(describe "claude-client-add-note during a turn"
  ;; The note lands in the log as soon as it is written, and waits while a
  ;; turn is running.
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (claude-test--with-running-turn
           (claude-client-add-note "look at the error handling"))
          (it "records the note as soon as it is written"
            (check (claude-test--kinds buf) '(note)))
          (it "logs the note's text verbatim"
            (check (plist-get (car claude-client--events) :text)
                   "look at the error handling"))
          (it "queues the note to wait while a turn is running"
            (check claude-client--pending-notes '("look at the error handling"))))
      (kill-buffer buf))))

;; Turn state must not be inferred from the process.  `claude --print' stays
;; alive after emitting `result' (it waits on stdin), so a live process is
;; not evidence of a turn in flight -- reading it that way left notes queued
;; forever once a run had finished.
(describe "turn state versus process liveness"
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
                    ((symbol-function 'process-send-string) (lambda (&rest _) nil)))
            ;; Process "alive", but the turn ended: the note must still drain.
            (setq claude-client--process 'fake
                  claude-client--turn-active nil)
            (claude-client-add-note "after the turn")
            (it "drains a note against a live process whose turn has ended"
              (check claude-client--pending-notes nil))))
      (kill-buffer buf)))

  ;; The stream is what starts and ends a turn.
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (setq claude-client--turn-active t)
          (claude-test--feed buf (concat claude-test--result "\n"))
          (it "ends the turn when `result' arrives on the stream"
            (check claude-client--turn-active nil)))
      (kill-buffer buf))))

;; With no turn running the note has nothing to wait for, so it is delivered
;; straight away rather than sitting queued for a turn that may never come.
(describe "claude-client-add-note with nothing running"
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (claude-client-add-note "idle note")
          (it "drains at once rather than waiting for a turn that may never come"
            (check claude-client--pending-notes nil))
          (it "logs the delivery alongside the note"
            (check (claude-test--kinds buf) '(note notes-delivered))))
      (kill-buffer buf)))

  ;; Empty and whitespace notes are rejected rather than logged as blanks.
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (it "rejects a whitespace-only note"
            (check (condition-case _ (progn (claude-client-add-note "   ") nil)
                     (user-error t))
                   t))
          (it "logs no blank event for a rejected note"
            (check (claude-test--kinds buf) nil)))
      (kill-buffer buf))))

(describe "the pending-note queue"
  ;; Notes keep their order and all of them are queued.
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (claude-test--with-running-turn
           (claude-client-add-note "first")
           (claude-client-add-note "second"))
          (it "keeps notes in the order they were written"
            (check claude-client--pending-notes '("first" "second"))))
      (kill-buffer buf))))

;; Notes are drained when the turn's `result' arrives -- after the
;; `finished' event, so the log reads in the order things happened.
(describe "draining notes at turn end"
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (claude-test--feed buf (concat claude-test--init "\n"))
          (claude-test--with-running-turn
           (claude-client-add-note "mid-turn thought"))
          (it "holds the note while the turn is still in flight"
            (check claude-client--pending-notes '("mid-turn thought")))
          (claude-test--feed buf (concat claude-test--result "\n"))
          (it "empties the queue when the turn's `result' arrives"
            (check claude-client--pending-notes nil))
          (it "logs the delivery after `finished', so the log reads in order"
            (check (claude-test--kinds buf)
                   '(started note finished notes-delivered)))
          (it "records which notes were delivered"
            (check (plist-get (car (last claude-client--events)) :notes)
                   '("mid-turn thought"))))
      (kill-buffer buf)))

  ;; A turn that ends with no notes produces no delivery event.
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (progn
          (claude-test--feed buf
                             (concat claude-test--init "\n")
                             (concat claude-test--result "\n"))
          (it "logs no delivery event for a turn that ends with no notes"
            (check (claude-test--kinds buf) '(started finished))))
      (kill-buffer buf))))

;; Notes are announced on the subscriber hook like any other event, so the
;; transcript sees the human's writes on the same channel as the runner's.
(describe "notes on the subscriber hook"
  (let* ((buf (claude-test--buffer))
         (seen nil)
         (claude-client-event-functions
          (list (lambda (_b e) (push (plist-get e :kind) seen)))))
    (unwind-protect
        (with-current-buffer buf
          (claude-test--with-running-turn
           (claude-client-add-note "via hook"))
          (it "announces a note on the same channel as the runner's own events"
            (check seen '(note))))
      (kill-buffer buf))))

;; Notes render, and a note added while a turn is running is marked pending.
(describe "rendering a note in the conversation"
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (let ((claude-client-note-interrupts nil))
            (claude-test--with-running-turn
             (claude-client-add-note "rendered note")))
          (it "shows the note in the conversation buffer"
            (check-that (string-match-p "> rendered note" (claude-test--text buf))))
          ;; `pending' means the model has not seen it.  Only true when the
          ;; note waits; an interrupting note is about to be delivered.
          (it "marks a waiting note pending, since the model has not seen it"
            (check (plist-get (car claude-client--events) :pending) t)))
      (kill-buffer buf))))

;; A note outside a conversation buffer is refused rather than silently lost.
(describe "claude-client-add-note outside a conversation"
  (with-temp-buffer
    (it "refuses rather than silently losing the human's words"
      (check (condition-case _ (progn (claude-client-add-note "x") nil)
               (user-error t))
             t))))

;; Starting a run resets the event log, so a note queued beforehand has to be
;; carried into the outgoing prompt or the human's words are silently lost.
;; Stub the subprocess and capture what would be written to its stdin.
(describe "claude-client-start with a note already queued"
  (let ((sent nil))
    (cl-letf (((symbol-function 'make-process) (lambda (&rest _) 'fake-proc))
              ((symbol-function 'process-send-string)
               (lambda (_p s) (setq sent s)))
              ((symbol-function 'pop-to-buffer) #'ignore)
              ;; Keep the real buffer out of the way of an interactive session.
              ((symbol-function 'claude-client--mcp-config-file) (lambda () "/tmp/m.json"))
              ((symbol-function 'claude-client--settings-file) (lambda () "/tmp/s.json"))
              ((symbol-function 'claude-client--system-prompt-file) (lambda () "/tmp/p.txt")))
      (let ((buf (get-buffer-create "*claude-client*")))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (claude-client-mode)
                (setq claude-client--process nil)
                (claude-test--with-running-turn
                 (claude-client-add-note "remember the timeout")))
              (with-current-buffer buf (claude-client-start "do the thing"))
              (let ((text (alist-get
                           'text
                           (aref (alist-get
                                  'content
                                  (alist-get 'message
                                             (json-parse-string
                                              sent :object-type 'alist
                                              :array-type 'array)))
                                 0))))
                (it "carries the queued note into the outgoing prompt, not losing it with the log"
                  (check-that (string-match-p "remember the timeout" text)))
                (it "keeps the human's own prompt alongside the note"
                  (check-that (string-match-p "do the thing" text))))
              (with-current-buffer buf
                (it "empties the queue once the note has gone out"
                  (check claude-client--pending-notes nil))))
          (let ((kill-buffer-query-functions nil)) (kill-buffer buf)))))))

;;;; Multi-turn stdin
;;
;; A follow-up turn reuses the running CLI, so the model keeps its session
;; and context.  Verified against the real CLI: a second turn on the same
;; process returns the same `session_id' and can recall the first turn.

;; `claude-client-send' writes a well-formed user turn and marks the turn
;; active, without respawning.
(describe "claude-client-send"
  (let ((buf (claude-test--buffer))
        (sent nil))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
                    ((symbol-function 'process-send-string)
                     (lambda (_p s) (setq sent s)))
                    ;; A respawn here would be the bug: the point is reuse.
                    ((symbol-function 'make-process)
                     (lambda (&rest _) (error "must not spawn"))))
            (setq claude-client--process 'fake claude-client--turn-active nil)
            (claude-client-send "second turn")
            (let ((msg (json-parse-string sent :object-type 'alist
                                          :array-type 'array)))
              (it "writes a user turn on the running CLI's stdin"
                (check (alist-get 'type msg) "user"))
              (it "carries the prompt text in the turn"
                (check (alist-get 'text
                                  (aref (alist-get 'content
                                                   (alist-get 'message msg)) 0))
                       "second turn")))
            (it "marks the turn in flight"
              (check claude-client--turn-active t))
            (it "logs the prompt"
              (check (plist-get (car (last claude-client--events)) :kind) 'prompt))))
      (kill-buffer buf)))

  ;; Sending while a turn is in flight is refused: the CLI reads one turn at a
  ;; time, so a second write would interleave with the one being answered.
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t)))
            (setq claude-client--process 'fake claude-client--turn-active t)
            (it "refuses mid-turn, since a second write would interleave"
              (check (condition-case _ (progn (claude-client-send "x") nil)
                       (user-error t))
                     t))))
      (kill-buffer buf)))

  ;; With no live process there is nothing to continue.
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (setq claude-client--process nil claude-client--turn-active nil)
          (it "refuses without a live process, since there is nothing to continue"
            (check (condition-case _ (progn (claude-client-send "x") nil)
                     (user-error t))
                   t)))
      (kill-buffer buf))))

;; Notes drained at turn end are delivered to the model as the next turn --
;; this is what makes a note change what the model does, not just the log.
(describe "claude-client-deliver-notes"
  (let ((buf (claude-test--buffer))
        (sent nil))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
                    ((symbol-function 'process-send-string)
                     (lambda (_p s) (setq sent s))))
            (setq claude-client--process 'fake)
            (setq-local claude-client-deliver-notes t)
            (claude-test--with-running-turn
             (claude-client-add-note "reconsider the approach"))
            (setq claude-client--turn-active t)
            (claude-test--feed buf (concat claude-test--result "\n"))
            (it "sends the drained note to the model, not just to the log"
              (check-that (and sent (string-match-p "reconsider the approach" sent))))
            (it "begins a new turn to carry the note"
              (check claude-client--turn-active t))))
      (kill-buffer buf)))

  ;; Delivery is opt-out: with it off the note is still recorded, but nothing
  ;; is sent and no new turn begins.
  (let ((buf (claude-test--buffer))
        (sent nil))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
                    ((symbol-function 'process-send-string)
                     (lambda (_p s) (setq sent s))))
            (setq claude-client--process 'fake)
            (setq-local claude-client-deliver-notes nil)
            (let ((claude-client-note-interrupts nil))
              (claude-test--with-running-turn (claude-client-add-note "quiet note")))
            (setq claude-client--turn-active t)
            (claude-test--feed buf (concat claude-test--result "\n"))
            (it "sends nothing when delivery is switched off"
              (check sent nil))
            (it "begins no new turn when delivery is switched off"
              (check claude-client--turn-active nil))
            (it "still records the note in the log"
              (check-that (memq 'notes-delivered (claude-test--kinds buf))))))
      (kill-buffer buf))))

;; A dead process ends the turn with it; otherwise the buffer would be
;; wedged against ever starting another run.
(describe "claude-client--sentinel on a dead process"
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (setq claude-client--turn-active t)
          (cl-letf (((symbol-function 'process-live-p) (lambda (_p) nil)))
            (claude-client--sentinel buf 'fake "exited"))
          (it "ends the turn with the process, so the buffer is not wedged"
            (check claude-client--turn-active nil))
          (it "forgets the process"
            (check claude-client--process nil)))
      (kill-buffer buf))))

;;;; Resume
;;
;; `--resume' reopens a past session in a NEW process, keeping its id and
;; history.  Verified against the CLI: a resumed session recalls what it was
;; told before the first process exited.  Note `--session-id' is a different
;; flag -- it means "create a new session with this id" and fails if a
;; transcript already exists.

(describe "claude-client--command with a resume id"
  (let ((cmd (claude-client--command "sess-abc")))
    (it "passes --resume"
      (check-that (member "--resume" cmd)))
    (it "passes the session id right after the flag"
      (check (cadr (member "--resume" cmd)) "sess-abc"))
    ;; --session-id would mean "create new with this id" and hard-fail on an
    ;; existing transcript; resuming must not use it.
    (it "does not use --session-id, which would hard-fail on an existing transcript"
      (check (and (member "--session-id" cmd) t) nil)))

  ;; Without an id the flag is absent entirely, so a normal start is unchanged.
  (let ((cmd (claude-client--command)))
    (it "omits --resume entirely without an id, leaving a normal start unchanged"
      (check (and (member "--resume" cmd) t) nil))))

;; Starting with a resume id logs it, so the transcript shows which session
;; was reopened rather than looking like a fresh conversation.
(describe "claude-client-start with a resume id"
  (let ((sent nil))
    (cl-letf (((symbol-function 'make-process) (lambda (&rest _) 'fake-proc))
              ((symbol-function 'process-send-string) (lambda (_p s) (setq sent s)))
              ((symbol-function 'pop-to-buffer) #'ignore)
              ((symbol-function 'claude-client--mcp-config-file) (lambda () "/tmp/m.json"))
              ((symbol-function 'claude-client--settings-file) (lambda () "/tmp/s.json"))
              ((symbol-function 'claude-client--system-prompt-file) (lambda () "/tmp/p.txt")))
      (let ((buf (get-buffer-create "*claude-client*")))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (claude-client-mode)
                (setq claude-client--process nil claude-client--turn-active nil))
              (with-current-buffer buf
                (claude-client-start "carry on" "sess-xyz"))
              (with-current-buffer buf
                (it "logs a resumed event so the transcript is not mistaken for a fresh one"
                  (check (plist-get (car claude-client--events) :kind) 'resumed))
                (it "names the session that was reopened"
                  (check (plist-get (car claude-client--events) :session) "sess-xyz"))
                (it "logs the resume before the prompt"
                  (check (mapcar (lambda (e) (plist-get e :kind)) claude-client--events)
                         '(resumed prompt)))))
          (let ((kill-buffer-query-functions nil)) (kill-buffer buf)))))))

;; A plain start logs no `resumed' event.
(describe "claude-client-start without a resume id"
  (let ((sent nil))
    (cl-letf (((symbol-function 'make-process) (lambda (&rest _) 'fake-proc))
              ((symbol-function 'process-send-string) (lambda (_p s) (setq sent s)))
              ((symbol-function 'pop-to-buffer) #'ignore)
              ((symbol-function 'claude-client--mcp-config-file) (lambda () "/tmp/m.json"))
              ((symbol-function 'claude-client--settings-file) (lambda () "/tmp/s.json"))
              ((symbol-function 'claude-client--system-prompt-file) (lambda () "/tmp/p.txt")))
      (let ((buf (get-buffer-create "*claude-client*")))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (claude-client-mode)
                (setq claude-client--process nil claude-client--turn-active nil))
              (with-current-buffer buf (claude-client-start "fresh"))
              (with-current-buffer buf
                (it "logs no resumed event"
                  (check (memq 'resumed
                               (mapcar (lambda (e) (plist-get e :kind))
                                       claude-client--events))
                         nil))))
          (let ((kill-buffer-query-functions nil)) (kill-buffer buf)))))))

;;;; Window management
;;
;; Placement mirrors the eat runner: an ordinary window in a configurable
;; direction, not a dedicated side window.

(describe "claude-client--display placement"
  (let ((captured nil))
    (cl-letf (((symbol-function 'display-buffer)
               (lambda (_buf &optional action) (setq captured action) nil)))
      (let ((claude-client-window-direction 'right)
            (claude-client-window-width 0.4))
        (claude-client--display (current-buffer))
        (it "places the conversation with `display-buffer-in-direction'"
          (check-that (memq 'display-buffer-in-direction (car captured))))
        (it "honours `claude-client-window-direction'"
          (check (alist-get 'direction captured) 'right))
        (it "sizes a horizontal split by width"
          (check (alist-get 'window-width captured) 0.4)))
      ;; Vertical placement sizes by height instead.
      (let ((claude-client-window-direction 'below)
            (claude-client-window-height 0.3))
        (claude-client--display (current-buffer))
        (it "sizes a vertical split by height instead"
          (check (alist-get 'window-height captured) 0.3)))
      ;; nil hands the decision to display-buffer-alist: no action argument at
      ;; all, rather than an in-direction action.
      (let ((claude-client-window-direction nil))
        (setq captured 'untouched)
        (claude-client--display (current-buffer))
        (it "passes no action at all with a nil direction, leaving it to `display-buffer-alist'"
          (check captured nil))))))

;; Focus is not stolen by default.
(describe "claude-client-focus-on-show"
  (let ((selected nil))
    (cl-letf (((symbol-function 'display-buffer) (lambda (&rest _) 'win))
              ((symbol-function 'select-window) (lambda (w) (setq selected w))))
      (let ((claude-client-focus-on-show nil))
        (claude-client--display (current-buffer))
        (it "does not steal focus by default"
          (check selected nil)))
      (let ((claude-client-focus-on-show t))
        (claude-client--display (current-buffer))
        (it "selects the conversation window when asked to"
          (check selected 'win))))))

;;;; Re-show after an ediff review (#44)
;;
;; `mcp-emacs--ediff-review' restores the window configuration it captured
;; before the review, and does so BEFORE calling its on-resolve callback
;; (mcp-emacs.el: set-window-configuration then on-resolve).  When the review
;; came from this buffer's own tool call that snapshot predates the
;; conversation window, so by the time the tool result arrives the
;; conversation is already off screen.

(describe "claude-client--reshow-after-review"
  (let ((buf (claude-test--buffer))
        (shown nil))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) nil))
                  ((symbol-function 'claude-client--display)
                   (lambda (b) (setq shown b))))
          (let ((claude-client-restore-window-after-review t))
            (claude-client--reshow-after-review
             buf (list :kind 'tool-result :text "Status: applied"))
            (it "brings the conversation back after a tool result"
              (check shown buf))))
      (kill-buffer buf)))

  ;; Only tool results trigger it; ordinary text must not fight the user's
  ;; window layout on every streamed message.
  (let ((buf (claude-test--buffer))
        (shown nil))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) nil))
                  ((symbol-function 'claude-client--display)
                   (lambda (b) (setq shown b))))
          (let ((claude-client-restore-window-after-review t))
            (claude-client--reshow-after-review buf (list :kind 'text :text "hi"))
            (it "leaves the layout alone on ordinary text, not fighting it every message"
              (check shown nil))))
      (kill-buffer buf)))

  ;; A conversation that is already visible is left alone.
  (let ((buf (claude-test--buffer))
        (shown nil))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) 'win))
                  ((symbol-function 'claude-client--display)
                   (lambda (b) (setq shown b))))
          (let ((claude-client-restore-window-after-review t))
            (claude-client--reshow-after-review
             buf (list :kind 'tool-result :text "x"))
            (it "leaves a conversation that is already visible alone"
              (check shown nil))))
      (kill-buffer buf)))

  ;; Opt-out respected.
  (let ((buf (claude-test--buffer))
        (shown nil))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) nil))
                  ((symbol-function 'claude-client--display)
                   (lambda (b) (setq shown b))))
          (let ((claude-client-restore-window-after-review nil))
            (claude-client--reshow-after-review
             buf (list :kind 'tool-result :text "x"))
            (it "does nothing when `claude-client-restore-window-after-review' is off"
              (check shown nil))))
      (kill-buffer buf)))

  ;; The re-show is installed as a subscriber, not wired into the runner: the
  ;; log stays the seam, and this is just one more reader of it.
  (it "is installed as one more subscriber, keeping the log as the seam"
    (check-that (memq #'claude-client--reshow-after-review
                      claude-client-event-functions))))

;;;; Interruption (issue #39)
;;
;; The CLI advertises `interrupt_receipt_v1' and accepts a control request
;; that abandons the turn in flight.  Verified against the real CLI: the turn
;; ends promptly as `error_during_execution' and the session still answers a
;; following turn, so an interrupt costs the in-flight work and nothing else.

;; The wire shape is a control_request, not a user turn.
(describe "claude-client-interrupt"
  (let ((buf (claude-test--buffer))
        (sent nil))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
                    ((symbol-function 'process-send-string)
                     (lambda (_p s) (setq sent s))))
            (setq claude-client--process 'fake claude-client--turn-active t)
            (claude-client-interrupt)
            (let ((msg (json-parse-string sent :object-type 'alist)))
              (it "writes a control_request rather than a user turn"
                (check (alist-get 'type msg) "control_request"))
              (it "asks for the interrupt subtype"
                (check (alist-get 'subtype (alist-get 'request msg)) "interrupt"))
              (it "carries a request id"
                (check (stringp (alist-get 'request_id msg)) t)))
            (it "logs the interruption"
              (check (memq 'interrupted (claude-test--kinds buf)) '(interrupted)))))
      (kill-buffer buf)))

  ;; Interrupting with nothing running is refused rather than sent blindly.
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (setq claude-client--turn-active nil)
          (it "refuses when idle rather than sending the request blindly"
            (check (condition-case _ (progn (claude-client-interrupt) nil)
                     (user-error t))
                   t)))
      (kill-buffer buf))))

;; A note written mid-turn interrupts it, rather than waiting.
(describe "claude-client-note-interrupts"
  (let ((buf (claude-test--buffer))
        (sent nil))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
                    ((symbol-function 'process-send-string)
                     (lambda (_p s) (setq sent s))))
            (setq claude-client--process 'fake)
            (let ((claude-client-note-interrupts t))
              (claude-test--with-running-turn
               (claude-client-add-note "stop, do the other thing")))
            (it "abandons the running turn instead of making the note wait"
              (check-that (and sent (string-match-p "interrupt" sent))))
            (it "logs the interruption"
              (check-that (memq 'interrupted (claude-test--kinds buf))))
            ;; Still queued: it is delivered when `result' arrives for the
            ;; turn being abandoned, not written into a dying turn.
            (it "keeps the note queued until the abandoned turn's `result' arrives"
              (check claude-client--pending-notes '("stop, do the other thing")))))
      (kill-buffer buf)))

  ;; Opting out restores the queueing behaviour: nothing is abandoned.
  (let ((buf (claude-test--buffer))
        (sent nil))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
                    ((symbol-function 'process-send-string)
                     (lambda (_p s) (setq sent s))))
            (setq claude-client--process 'fake)
            (let ((claude-client-note-interrupts nil))
              (claude-test--with-running-turn (claude-client-add-note "later")))
            (it "abandons nothing when switched off"
              (check sent nil))
            (it "falls back to queueing the note"
              (check claude-client--pending-notes '("later")))))
      (kill-buffer buf))))

;; After an interrupt the delivered turn tells the model not to resume, so it
;; re-plans around the note instead of carrying on with abandoned work.
(describe "the turn delivered after an interrupt"
  (let ((buf (claude-test--buffer))
        (sent nil))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
                    ((symbol-function 'process-send-string)
                     (lambda (_p s) (setq sent s))))
            (setq claude-client--process 'fake)
            (let ((claude-client-note-interrupts t)
                  (claude-client-deliver-notes t))
              (claude-test--with-running-turn (claude-client-add-note "change course")))
            (setq sent nil)
            ;; The interrupted turn's result arrives; the note goes out now.
            (setq claude-client--turn-active t)
            (claude-test--feed buf (concat claude-test--result "\n"))
            (it "tells the model its previous turn was interrupted"
              (check-that (and sent (string-match-p "interrupted" sent))))
            (it "tells the model not to resume the abandoned work"
              (check-that (and sent (string-match-p "Do not resume" sent))))
            (it "carries the note it should re-plan around"
              (check-that (and sent (string-match-p "change course" sent))))))
      (kill-buffer buf)))

  ;; A turn that ended on its own is not framed as a re-plan.
  (let ((buf (claude-test--buffer))
        (sent nil))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
                    ((symbol-function 'process-send-string)
                     (lambda (_p s) (setq sent s))))
            (setq claude-client--process 'fake)
            (let ((claude-client-note-interrupts nil)
                  (claude-client-deliver-notes t))
              (claude-test--with-running-turn (claude-client-add-note "fyi")))
            (setq sent nil claude-client--turn-active t)
            (claude-test--feed buf (concat claude-test--result "\n"))
            (it "omits the re-plan framing for a turn that ended on its own"
              (check (and sent (string-match-p "Do not resume" sent)) nil))
            (it "still carries the note"
              (check-that (and sent (string-match-p "fyi" sent))))))
      (kill-buffer buf))))

;;;; Backpressure (issue #39)
;;
;; Several notes in quick succession while the model is slow.  Once a turn is
;; being interrupted it is already ending, so further notes ride out on the
;; same delivery rather than firing more interrupts into a dying turn.

;; Two notes during one turn interrupt it once, and both are delivered.
(describe "several notes during one turn"
  (let ((buf (claude-test--buffer))
        (interrupts 0))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
                    ((symbol-function 'process-send-string)
                     (lambda (_p s)
                       (when (string-match-p "interrupt" s)
                         (setq interrupts (1+ interrupts))))))
            (setq claude-client--process 'fake claude-client--turn-active t)
            (claude-client-add-note "first")
            (claude-client-add-note "second")
            (it "fires one interrupt, not one per note into a dying turn"
              (check interrupts 1))
            (it "queues every note for the same delivery"
              (check claude-client--pending-notes '("first" "second")))
            (it "logs a single interrupted event"
              (check (length (seq-filter
                              (lambda (e) (eq (plist-get e :kind) 'interrupted))
                              claude-client--events))
                     1))))
      (kill-buffer buf)))

  ;; An exact repeat says nothing new, so it is coalesced rather than sent twice.
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
                    ((symbol-function 'process-send-string) (lambda (&rest _) nil)))
            (setq claude-client--process 'fake claude-client--turn-active t)
            (claude-client-add-note "same thing")
            (claude-client-add-note "same thing")
            (it "coalesces an exact repeat rather than sending it twice"
              (check claude-client--pending-notes '("same thing")))
            ;; Still logged twice: the human did write it twice.
            (it "still logs both, since the human did write it twice"
              (check (length (seq-filter (lambda (e) (eq (plist-get e :kind) 'note))
                                         claude-client--events))
                     2))))
      (kill-buffer buf))))

;; Explicitly interrupting a turn that is already being interrupted is
;; refused rather than sending a second control request.
(describe "claude-client-interrupt on an already-interrupted turn"
  (let ((buf (claude-test--buffer))
        (interrupts 0))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
                    ((symbol-function 'process-send-string)
                     (lambda (_p s)
                       (when (string-match-p "interrupt" s)
                         (setq interrupts (1+ interrupts))))))
            (setq claude-client--process 'fake claude-client--turn-active t)
            (claude-client-interrupt)
            (it "refuses a second interrupt"
              (check (condition-case _ (progn (claude-client-interrupt) nil)
                       (user-error t))
                     t))
            (it "sends no second control request"
              (check interrupts 1))))
      (kill-buffer buf))))

;; The queue is bounded: the newest note is the current intent, so the oldest
;; are dropped when the model is too slow to drain them.
(describe "claude-client-max-pending-notes"
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
                    ((symbol-function 'process-send-string) (lambda (&rest _) nil)))
            (setq claude-client--process 'fake claude-client--turn-active t)
            (let ((claude-client-max-pending-notes 3))
              (dolist (n '("n1" "n2" "n3" "n4" "n5"))
                (claude-client-add-note n))
              (it "holds no more notes than the bound"
                (check (length claude-client--pending-notes) 3))
              (it "drops the oldest, keeping the newest as the current intent"
                (check claude-client--pending-notes '("n3" "n4" "n5")))
              ;; A drop is recorded, not silent.
              (it "records each drop rather than losing it silently"
                (check (mapcar (lambda (e) (plist-get e :text))
                               (seq-filter
                                (lambda (e) (eq (plist-get e :kind) 'note-dropped))
                                claude-client--events))
                       '("n1" "n2"))))))
      (kill-buffer buf)))

  ;; nil means keep everything.
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
                    ((symbol-function 'process-send-string) (lambda (&rest _) nil)))
            (setq claude-client--process 'fake claude-client--turn-active t)
            (let ((claude-client-max-pending-notes nil))
              (dolist (n '("a" "b" "c" "d")) (claude-client-add-note n))
              (it "keeps every note when set to nil"
                (check (length claude-client--pending-notes) 4)))))
      (kill-buffer buf))))

;;;; Conversation buffers (issue #56)
;;
;; One buffer per conversation, `*claude-client:<project>:<n>*'.  The bug
;; being pinned: a single hardcoded name meant starting a conversation in
;; one project silently killed another project's CLI.

(describe "claude-client--buffer-name"
  (let ((default-directory "/tmp/proj-a/"))
    (it "names the buffer after the project"
      (check (claude-client--buffer-name "/tmp/proj-a/" 1)
             "*claude-client:proj-a:1*"))
    (it "numbers the conversation within the project"
      (check (claude-client--buffer-name "/tmp/proj-a/" 7)
             "*claude-client:proj-a:7*"))))

;; Numbers are per project and fill the lowest free slot.
(describe "finding and numbering conversation buffers"
  (let* ((a1 (get-buffer-create "*claude-client:proj-a:1*"))
         (a2 (get-buffer-create "*claude-client:proj-a:2*"))
         (b1 (get-buffer-create "*claude-client:proj-b:1*")))
    (unwind-protect
        ;; A buffer's project comes from its own `default-directory', the way
        ;; `claude-client--new-buffer' pins it.
        (progn
          (dolist (cell (list (cons a1 "/tmp/proj-a/")
                              (cons a2 "/tmp/proj-a/")
                              (cons b1 "/tmp/proj-b/")))
            (with-current-buffer (car cell)
              (claude-client-mode)
              (setq default-directory (cdr cell))))
          (it "finds every conversation buffer regardless of project"
            (check (length (claude-client--buffers)) 3))
          (it "scopes conversations to one project by its `default-directory'"
            (check (length (claude-client--project-buffers "/tmp/proj-a/")) 2))
          (it "numbers past the slots already used in that project"
            (check (claude-client--next-number "/tmp/proj-a/") 3))
          ;; A hole left by a killed conversation is refilled, not skipped.
          (let ((kill-buffer-query-functions nil)) (kill-buffer a1))
          (it "refills the hole a killed conversation left, rather than skipping it"
            (check (claude-client--next-number "/tmp/proj-a/") 1)))
      (let ((kill-buffer-query-functions nil))
        (dolist (b (list a1 a2 b1)) (when (buffer-live-p b) (kill-buffer b)))))))

;; `cl-letf' is not used for these: several `symbol-function' places in one
;; form collide during macroexpansion, so the mocks silently overwrite each
;; other.  Save and restore by hand instead.
;; A killed process leaves the session id and the on-disk transcript behind,
;; so `s' can point at `r' (resume this conversation) instead of `g' (start a
;; new one and erase the log).  Regression: the message used to say `g'
;; unconditionally, which threw away the context the human wanted back.
(describe "the message claude-client-send gives on a dead process"
  (let ((buf (generate-new-buffer "*claude-send-dead*")))
    (unwind-protect
        (with-current-buffer buf
          (claude-client-mode)
          (setq claude-client--process nil
                claude-client--turn-active nil)
          ;; `user-error' curls the apostrophe, so match on substance not glyph.
          (let ((msg (lambda ()
                       (condition-case err (claude-client-send "hi")
                         (user-error (error-message-string err))))))
            (setq claude-client--session-id "abc-123")
            (it "points at `r' to resume when a session id survives, not `g' which erases the log"
              (check (and (string-match-p "r." (funcall msg))
                          (string-match-p "resumes" (funcall msg))
                          t)
                     t))
            (setq claude-client--session-id nil)
            (it "does not offer resuming when there is no session to resume"
              (check (and (string-match-p "resumes" (funcall msg)) t) nil))))
      (kill-buffer buf))))

(defmacro claude-test--with-stubs (stubs &rest body)
  "Run BODY with STUBS, an alist of (SYMBOL . FUNCTION), then restore."
  (declare (indent 1))
  `(let ((saved (mapcar (lambda (c)
                          (cons (car c)
                                (and (fboundp (car c))
                                     (symbol-function (car c)))))
                        ,stubs)))
     (unwind-protect
         (progn (dolist (c ,stubs) (fset (car c) (cdr c)))
                ,@body)
       (dolist (c saved)
         (if (cdr c) (fset (car c) (cdr c)) (fmakunbound (car c)))))))

(defun claude-test--start-stubs (root-fn &optional on-delete)
  "Stubs that let `claude-client-start' run without a CLI.
ROOT-FN supplies the project root; ON-DELETE, when given, replaces
`delete-process' so a kill can be detected."
  (append
   (list (cons 'claude-client--project-root root-fn)
         (cons 'make-process (lambda (&rest _) 'fake-proc))
         (cons 'process-send-string (lambda (&rest _) nil))
         (cons 'claude-client--display #'ignore)
         (cons 'claude-client--mcp-config-file (lambda () "/tmp/m.json"))
         (cons 'claude-client--settings-file (lambda () "/tmp/s.json"))
         (cons 'claude-client--system-prompt-file (lambda () "/tmp/p.txt")))
   (when on-delete (list (cons 'delete-process on-delete)))))

;; The regression: starting in project B must not touch project A's process.
(describe "claude-client-start across projects"
  (let ((a nil) (b nil) (root "/tmp/proj-a/"))
    (unwind-protect
        (claude-test--with-stubs
            (cons (cons 'process-live-p (lambda (p) (eq p 'fake-proc)))
                  (claude-test--start-stubs
                   (lambda () root)
                   (lambda (&rest _) (error "a live conversation was killed"))))
          (setq a (claude-client-start "in A"))
          (it "names the new conversation after its project"
            (check (buffer-name a) "*claude-client:proj-a:1*"))
          ;; Switch project and start again: delete-process would signal.
          (setq root "/tmp/proj-b/")
          (it "leaves the other project's CLI running"
            (check (condition-case err
                       (progn (setq b (claude-client-start "in B")) :no-kill)
                     (error (error-message-string err)))
                   :no-kill))
          (it "gives the second project its own buffer"
            (check (buffer-name b) "*claude-client:proj-b:1*"))
          (it "leaves the first conversation's buffer alive"
            (check (buffer-live-p a) t)))
      (let ((kill-buffer-query-functions nil))
        (dolist (x (list a b)) (when (and x (buffer-live-p x)) (kill-buffer x)))))))

;; `g' from inside a conversation restarts in place rather than piling up.
(describe "claude-client-start from inside a conversation"
  (let ((buf nil))
    (unwind-protect
        (claude-test--with-stubs
            (cons (cons 'process-live-p (lambda (_p) nil))
                  (claude-test--start-stubs (lambda () "/tmp/proj-a/")))
          (setq buf (claude-client-start "first"))
          ;; No CLI to emit `result', so clear the in-flight flag by hand --
          ;; otherwise the restart is refused, which is its own correct
          ;; behaviour but not what this test is about.
          (with-current-buffer buf (setq claude-client--turn-active nil))
          (let ((again (with-current-buffer buf (claude-client-start "again"))))
            (it "restarts in the same buffer"
              (check (eq again buf) t))
            (it "adds no buffer, so conversations do not pile up"
              (check (length (claude-client--buffers)) 1))))
      (let ((kill-buffer-query-functions nil))
        (when (and buf (buffer-live-p buf)) (kill-buffer buf))))))

;; Toggle: no conversation starts one, a visible one is hidden, a hidden
;; one is shown.
(describe "claude-client-toggle"
  (let ((buf nil) (started nil) (shown nil) (deleted nil))
    (unwind-protect
        (claude-test--with-stubs
            (list (cons 'claude-client--project-root (lambda () "/tmp/proj-a/"))
                  (cons 'claude-client-start (lambda (&rest _) (interactive) (setq started t)))
                  (cons 'claude-client--display (lambda (b) (setq shown b)))
                  (cons 'delete-window (lambda (&optional w) (setq deleted (or w t)))))
          ;; Nothing yet: toggle starts a conversation.
          (claude-client-toggle)
          (it "starts a conversation when there is none"
            (check started t))
          ;; With one hidden conversation: shown, not started again.
          (setq buf (get-buffer-create "*claude-client:proj-a:1*")
                started nil)
          (with-current-buffer buf
            (claude-client-mode)
            (setq default-directory "/tmp/proj-a/"))
          ;; Nowhere at all (nil for this frame and for all frames).
          (claude-test--with-stubs
              (list (cons 'get-buffer-window (lambda (&rest _) nil)))
            (claude-client-toggle))
          (it "shows a hidden conversation"
            (check shown buf))
          (it "does not start another one when a hidden conversation exists"
            (check started nil))
          ;; Visible on this frame: the window is hidden, not re-shown.
          (setq shown nil)
          (claude-test--with-stubs
              (list (cons 'get-buffer-window (lambda (&rest _) 'fake-window)))
            (claude-client-toggle))
          (it "hides the window of a conversation visible on this frame"
            (check deleted 'fake-window))
          (it "does not re-show a conversation it just hid"
            (check shown nil)))
      (let ((kill-buffer-query-functions nil))
        (when (and buf (buffer-live-p buf)) (kill-buffer buf))))))

;; Frame-awareness: a conversation only on *another* frame is raised, not
;; hidden and not duplicated.
(describe "claude-client-toggle with the conversation on another frame"
  (let ((buf nil) (shown nil) (deleted nil) (focused nil) (selected nil))
    (unwind-protect
        (progn
          (setq buf (get-buffer-create "*claude-client:proj-a:1*"))
          (with-current-buffer buf
            (claude-client-mode)
            (setq default-directory "/tmp/proj-a/"))
          (claude-test--with-stubs
              (list (cons 'claude-client--project-root (lambda () "/tmp/proj-a/"))
                    (cons 'claude-client--display (lambda (b) (setq shown b)))
                    (cons 'delete-window (lambda (&optional w) (setq deleted (or w t))))
                    ;; nil for this frame, a window when asked across frames.
                    (cons 'get-buffer-window
                          (lambda (&optional _buf all-frames)
                            (and all-frames 'other-window)))
                    (cons 'window-frame (lambda (&rest _) 'other-frame))
                    (cons 'select-frame-set-input-focus
                          (lambda (f) (setq focused f)))
                    (cons 'select-window (lambda (w &rest _) (setq selected w))))
            (claude-client-toggle))
          (it "raises the other frame"
            (check focused 'other-frame))
          (it "selects the conversation's window on that frame"
            (check selected 'other-window))
          (it "does not hide it"
            (check deleted nil))
          (it "does not duplicate it into this frame"
            (check shown nil)))
      (let ((kill-buffer-query-functions nil))
        (when (and buf (buffer-live-p buf)) (kill-buffer buf))))))

(describe "claude-client--hide-window"
  ;; A split window is simply deleted.
  (let ((deleted nil) (iconified nil))
    (claude-test--with-stubs
        (list (cons 'delete-window (lambda (&optional w) (setq deleted (or w t))))
              (cons 'iconify-frame (lambda (f) (setq iconified f))))
      (claude-client--hide-window 'a-window))
    (it "deletes a split window"
      (check deleted 'a-window))
    (it "leaves the frame alone when the window could be deleted"
      (check iconified nil)))

  ;; A conversation alone on its own frame would trip `delete-window''s
  ;; sole-window error, so the frame is iconified instead.
  (let ((iconified nil))
    (claude-test--with-stubs
        (list (cons 'delete-window
                    (lambda (&optional _w) (error "Attempt to delete minibuffer or sole ordinary window")))
              (cons 'window-frame (lambda (&rest _) 'lone-frame))
              (cons 'iconify-frame (lambda (f) (setq iconified f))))
      (claude-client--hide-window 'lone-window))
    (it "iconifies the frame when the conversation is its sole window"
      (check iconified 'lone-frame))))

;; Toggle is project-scoped: another project's conversation is not a
;; candidate, so toggling in an empty project starts a new one.
(describe "claude-client-toggle in a project with no conversation"
  (let ((other nil) (started nil))
    (unwind-protect
        (progn
          (setq other (get-buffer-create "*claude-client:proj-b:1*"))
          (with-current-buffer other
            (claude-client-mode)
            (setq default-directory "/tmp/proj-b/"))
          (claude-test--with-stubs
              (list (cons 'claude-client--project-root (lambda () "/tmp/proj-a/"))
                    (cons 'claude-client-start (lambda (&rest _) (interactive) (setq started t)))
                    (cons 'claude-client--display #'ignore))
            (claude-client-toggle))
          (it "starts a new one rather than showing another project's conversation"
            (check started t)))
      (let ((kill-buffer-query-functions nil))
        (when (and other (buffer-live-p other)) (kill-buffer other))))))

;; The single-letter keys.  Evil is not installed in batch, so this only
;; pins the plain-Emacs map and the evil-registration data; the evil path
;; itself needs a live evil (see `claude-client--setup-evil').
(describe "the single-letter keys"
  (let ((buf (claude-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (it "binds `s' to send"
            (check (lookup-key claude-client-mode-map (kbd "s"))
                   'claude-client-send))
          (it "binds `n' to add a note"
            (check (lookup-key claude-client-mode-map (kbd "n"))
                   'claude-client-add-note))
          ;; The evil table must stay in step with the keymap, since the two
          ;; are bound from separate places.
          (it "keeps the evil table in step with the keymap, bound from separate places"
            (check (sort (mapcar (lambda (c)
                                   (format "%s=%s" (car c)
                                           (lookup-key claude-client-mode-map (kbd (car c)))))
                                 claude-client--evil-keys)
                         #'string<)
                   (sort (mapcar (lambda (c) (format "%s=%s" (car c) (cdr c)))
                                 claude-client--evil-keys)
                         #'string<)))
          ;; `k' and `g' are left to evil on purpose: both are motions
          ;; (`evil-previous-line', the `gg' prefix) and both sit in front of a
          ;; destructive command here, so re-registering them made moving the
          ;; cursor up kill the CLI process and `gg' dead.  Pinned as absences
          ;; so re-adding them has to be a deliberate edit to this test.
          (it "leaves `k' to evil, which needs it for `evil-previous-line'"
            (check (and (assoc "k" claude-client--evil-keys) t) nil))
          (it "leaves `g' to evil, which needs it for the `gg' prefix"
            (check (and (assoc "g" claude-client--evil-keys) t) nil))
          ;; ...while the commands stay reachable, evil or not.
          (it "binds `?' to help"
            (check (lookup-key claude-client-mode-map (kbd "?"))
                   'claude-client-help))
          (it "binds C-c C-q to quit"
            (check (lookup-key agent-backend-mode-map (kbd "C-c C-q"))
                   'agent-backend-quit-command))
          ;; The evil-safe C-c vocabulary comes from the parent mode and must
          ;; survive regardless.
          (it "inherits the parent mode's evil-safe C-c C-s"
            (check (lookup-key agent-backend-mode-map (kbd "C-c C-s"))
                   'agent-backend-send-command))
          ;; Guarded so a snipe-less Emacs is a no-op rather than an error.
          (it "makes `claude-client--setup-evil' a no-op without evil, not an error"
            (check (progn (claude-client--setup-evil) :no-error) :no-error)))
      (kill-buffer buf))))

(test-helper-summary)

;;; claude-client-test.el ends here
