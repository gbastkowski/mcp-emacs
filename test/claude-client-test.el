;;; claude-client-test.el --- Tests for the terminal-free runner -*- lexical-binding: t; -*-

;; Batch tests for `claude-client.el'.  No CLI is spawned: the stream filter
;; is fed captured stream-json lines directly, which is also how the real
;; subprocess reaches it.  The sample lines below are trimmed from actual
;; `claude --print --output-format stream-json' output.

(add-to-list 'load-path (expand-file-name "elisp"))
(require 'cl-lib)
(require 'json)
(require 'claude-client)

(defun check (l g w) (princ (format "%s %s\n" (if (equal g w) "PASS" "FAIL") l)))

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

(let ((cmd (claude-client--command)))
  (check "cmd-print" (and (member "--print" cmd) t) t)
  (check "cmd-stream-json-out"
         (equal (cadr (member "--output-format" cmd)) "stream-json") t)
  (check "cmd-stream-json-in"
         (equal (cadr (member "--input-format" cmd)) "stream-json") t)
  (check "cmd-strict-mcp" (and (member "--strict-mcp-config" cmd) t) t)
  (check "cmd-has-mcp-config" (and (member "--mcp-config" cmd) t) t)
  (check "cmd-has-settings" (and (member "--settings" cmd) t) t)
  ;; Edit and MultiEdit both: MultiEdit alone can batch writes past the gate.
  (check "cmd-disallows-write" (and (member "Write" cmd) t) t)
  (check "cmd-disallows-edit" (and (member "Edit" cmd) t) t)
  (check "cmd-disallows-multiedit" (and (member "MultiEdit" cmd) t) t))

;; The generated MCP config points at the mcp-emacs HTTP endpoint.
(let* ((file (claude-client--mcp-config-file))
       (parsed (with-temp-buffer
                 (insert-file-contents file)
                 (json-parse-string (buffer-string)
                                    :object-type 'alist :array-type 'list))))
  (let* ((servers (alist-get 'mcpServers parsed))
         (emacs (alist-get 'emacs servers)))
    (check "mcp-config-type" (alist-get 'type emacs) "http")
    (check "mcp-config-url-mcp-path"
           (and (string-suffix-p "/mcp" (alist-get 'url emacs)) t) t))
  (delete-file file))

;; apply_diff must be allowlisted: proxied MCP tools are denied by default,
;; so without this every edit is refused before the human sees an ediff.
(let* ((file (claude-client--settings-file))
       (parsed (with-temp-buffer
                 (insert-file-contents file)
                 (json-parse-string (buffer-string)
                                    :object-type 'alist :array-type 'list))))
  (let ((allow (alist-get 'allow (alist-get 'permissions parsed))))
    (check "settings-allows-apply-diff"
           (and (member "mcp__emacs__apply_diff" allow) t) t))
  (delete-file file))

;;;; Stream framing
;;
;; stream-json is NDJSON: one object per line.  The filter must tolerate a
;; chunk boundary landing mid-line, since the pipe splits wherever it likes.

(let ((buf (claude-test--buffer)))
  (unwind-protect
      (progn
        (claude-test--feed buf (concat claude-test--init "\n"))
        (check "frame-single-line" (claude-test--kinds buf) '(started)))
    (kill-buffer buf)))

;; A line split across two chunks is buffered until its newline arrives.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (let* ((whole (concat claude-test--init "\n"))
             (cut (/ (length whole) 2)))
        (claude-test--feed buf (substring whole 0 cut))
        (check "frame-partial-not-yet" (claude-test--kinds buf) nil)
        (claude-test--feed buf (substring whole cut))
        (check "frame-partial-completed" (claude-test--kinds buf) '(started)))
    (kill-buffer buf)))

;; Several objects arriving in one chunk all get dispatched.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (progn
        (claude-test--feed
         buf (concat claude-test--init "\n" claude-test--text-msg "\n"))
        (check "frame-multiple-in-chunk"
               (claude-test--kinds buf) '(started text)))
    (kill-buffer buf)))

;; Garbage lines are skipped rather than aborting the stream.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (progn
        (claude-test--feed buf "not json at all\n"
                           (concat claude-test--init "\n"))
        (check "frame-skips-garbage" (claude-test--kinds buf) '(started)))
    (kill-buffer buf)))

;;;; Event mapping

(let ((buf (claude-test--buffer)))
  (unwind-protect
      (progn
        (claude-test--feed buf (concat claude-test--init "\n"))
        (with-current-buffer buf
          (check "init-records-session" claude-client--session-id "abc-123")
          (let ((e (car claude-client--events)))
            (check "init-kind" (plist-get e :kind) 'started)
            (check "init-model" (plist-get e :model) "claude-opus-5"))))
    (kill-buffer buf)))

(let ((buf (claude-test--buffer)))
  (unwind-protect
      (progn
        (claude-test--feed buf (concat claude-test--text-msg "\n"))
        (with-current-buffer buf
          (let ((e (car claude-client--events)))
            (check "text-kind" (plist-get e :kind) 'text)
            (check "text-content" (plist-get e :text) "I'll write the file."))))
    (kill-buffer buf)))

(let ((buf (claude-test--buffer)))
  (unwind-protect
      (progn
        (claude-test--feed buf (concat claude-test--tool-use "\n"))
        (with-current-buffer buf
          (let ((e (car claude-client--events)))
            (check "tool-use-kind" (plist-get e :kind) 'tool-use)
            (check "tool-use-name"
                   (plist-get e :name) "mcp__emacs__apply_diff"))))
    (kill-buffer buf)))

;; tool_result content is a plain string in practice; the list form is also
;; accepted, so both shapes must land as text.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (progn
        (claude-test--feed buf (concat claude-test--tool-result "\n"))
        (with-current-buffer buf
          (let ((e (car claude-client--events)))
            (check "tool-result-kind" (plist-get e :kind) 'tool-result)
            (check "tool-result-text"
                   (plist-get e :text) "Status: applied\nnew\n"))))
    (kill-buffer buf)))

(let ((buf (claude-test--buffer)))
  (unwind-protect
      (progn
        (claude-test--feed
         buf (concat "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":[{\"type\":\"text\",\"text\":\"from list\"}]}]}}" "\n"))
        (with-current-buffer buf
          (check "tool-result-list-form"
                 (plist-get (car claude-client--events) :text) "from list")))
    (kill-buffer buf)))

(let ((buf (claude-test--buffer)))
  (unwind-protect
      (progn
        (claude-test--feed buf (concat claude-test--result "\n"))
        (with-current-buffer buf
          (let ((e (car claude-client--events)))
            (check "result-kind" (plist-get e :kind) 'finished)
            (check "result-subtype" (plist-get e :subtype) "success"))))
    (kill-buffer buf)))

;; Unknown top-level types are ignored, not turned into stray events.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (progn
        (claude-test--feed buf "{\"type\":\"rate_limit_event\"}\n")
        (check "ignores-unknown-type" (claude-test--kinds buf) nil))
    (kill-buffer buf)))

;; Empty assistant text blocks produce no event (the CLI emits these while
;; streaming partial messages).
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (progn
        (claude-test--feed
         buf "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"   \"}]}}\n")
        (check "skips-empty-text" (claude-test--kinds buf) nil))
    (kill-buffer buf)))

;;;; Event ordering and the subscriber hook

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
        (check "event-order"
               (claude-test--kinds buf)
               '(started text tool-use tool-result finished)))
    (kill-buffer buf)))

;; Every event is announced to `claude-client-event-functions' with its
;; buffer -- the seam that lets #39 attach an Org transcript subscriber
;; without touching the renderer.
(let* ((buf (claude-test--buffer))
       (seen nil)
       (claude-client-event-functions
        (list (lambda (b e) (push (cons b (plist-get e :kind)) seen)))))
  (unwind-protect
      (progn
        (claude-test--feed buf
                           (concat claude-test--init "\n")
                           (concat claude-test--result "\n"))
        (check "hook-called-per-event" (length seen) 2)
        (check "hook-receives-buffer" (car (car seen)) buf)
        (check "hook-order" (mapcar #'cdr (reverse seen)) '(started finished)))
    (kill-buffer buf)))

;;;; The process dying

;; A turn cut short by the process dying must say so in the log.  The
;; render model is the event list, so clearing `--turn-active' alone left
;; the transcript ending on whatever the model was mid-way through --
;; typically a `tool-use' with no result, indistinguishable from a turn
;; still running.  Observed in a real session (issue #62).
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (progn
        (claude-test--feed buf
                           (concat claude-test--init "\n")
                           (concat claude-test--tool-use "\n"))
        (with-current-buffer buf (setq claude-client--turn-active t))
        (claude-client--sentinel buf (claude-test--dead-process "false")
                                 "exited abnormally with code 1\n")
        (check "death-mid-turn-logged"
               (claude-test--kinds buf) '(started tool-use died))
        (check "death-mid-turn-rendered"
               (and (string-match-p "died mid-turn" (claude-test--text buf)) t) t)
        ;; The cause is recorded, not guessed: the sentinel's own account of
        ;; how the process ended, plus a status code to branch on.  Without
        ;; these the banner asserts a death it cannot evidence (issue #62).
        (let ((e (car (last (with-current-buffer buf claude-client--events)))))
          (check "death-records-reason"
                 (plist-get e :reason) "exited abnormally with code 1")
          (check "death-records-status" (plist-get e :status) 1))
        (check "death-reason-rendered"
               (and (string-match-p "died mid-turn: exited abnormally with code 1"
                                    (claude-test--text buf))
                    t)
               t)
        (with-current-buffer buf
          (check "death-clears-process" claude-client--process nil)
          ;; Left set, the buffer could never start another turn.
          (check "death-clears-turn-flag" claude-client--turn-active nil)))
    (kill-buffer buf)))

;; A process exiting between turns is the normal way a conversation ends
;; (`claude --print' lingers on stdin, so this is the human quitting).
;; Nothing was cut short, so nothing is reported.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (progn
        (claude-test--feed buf
                           (concat claude-test--init "\n")
                           (concat claude-test--result "\n"))
        (claude-client--sentinel buf (claude-test--dead-process) nil)
        (check "clean-exit-silent"
               (claude-test--kinds buf) '(started finished)))
    (kill-buffer buf)))

;; The sentinel outliving its buffer must not signal -- it fires from a
;; process filter, where an error is swallowed and leaves the log wedged.
(let ((buf (claude-test--buffer)))
  (kill-buffer buf)
  (check "death-after-buffer-killed"
         (progn (claude-client--sentinel buf (claude-test--dead-process) nil)
                'survived)
         'survived))

;;;; Rendering

(let ((buf (claude-test--buffer)))
  (unwind-protect
      (progn
        (claude-test--feed buf
                           (concat claude-test--init "\n")
                           (concat claude-test--text-msg "\n")
                           (concat claude-test--tool-use "\n")
                           (concat claude-test--result "\n"))
        (let ((text (claude-test--text buf)))
          (check "render-has-text"
                 (and (string-match-p "I'll write the file\\." text) t) t)
          (check "render-has-tool"
                 (and (string-match-p "mcp__emacs__apply_diff" text) t) t)
          (check "render-has-banner"
                 (and (string-match-p "claude-opus-5" text) t) t)))
    (kill-buffer buf)))

;; The buffer is read-only for the human but still writable by the renderer.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (with-current-buffer buf
        (check "mode-is-special" (derived-mode-p 'special-mode) 'special-mode)
        (check "buffer-read-only" buffer-read-only t))
    (kill-buffer buf)))

;;;; Prettified rendering
;;
;; Chrome (what the harness did) is faced; prose (what the model said) is
;; fontified as markdown.  Faces go on the `face' property, not
;; `font-lock-face': this buffer runs with `font-lock-mode' off, where
;; `font-lock-face' would be silently ignored.

(defun claude-test--face-at (string index)
  "Return the `face' property of STRING at INDEX."
  (get-text-property index 'face string))

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
      (check (format "face-%s" kind) (claude-test--face-at s i) (cdr c)))))

;; The banner reports what the sentinel observed, and no more: with a
;; reason it names the cause, without one it claims only that the turn
;; died.  An empty reason must not render as a dangling colon.
(let ((s (claude-client--render-event
          '(:kind died :reason "killed by signal 15" :status 15))))
  (check "died-names-cause"
         (substring-no-properties s) "── died mid-turn: killed by signal 15 ──"))

(dolist (event '((:kind died) (:kind died :reason "")))
  (check "died-without-reason"
         (substring-no-properties (claude-client--render-event event))
         "── died mid-turn ──"))

(let ((s (claude-client--render-event
          '(:kind tool-use :name "apply_diff" :input ((path . "/tmp/x"))))))
  (check "tool-name-faced" (claude-test--face-at s 2)
         'claude-client-tool-face)
  (check "tool-input-shown"
         (and (string-match-p "/tmp/x" (substring-no-properties s)) t) t)
  (check "tool-input-faced"
         (claude-test--face-at s (1- (length s)))
         'claude-client-tool-input-face))

;; A tool's input can be a whole file's contents; only a short summary of
;; what was touched belongs beside the call.
(let ((s (claude-client--render-event
          `(:kind tool-use :name "write"
            :input ((path . ,(concat (make-string 200 ?a) "\nsecond line")))))))
  (check "tool-input-single-line"
         (length (split-string (substring-no-properties s) "\n")) 1)
  (check "tool-input-truncated"
         (and (<= (length (substring-no-properties s)) 100) t) t))

(let ((s (claude-client--render-event '(:kind tool-use :name "bare"))))
  (check "tool-without-input" (substring-no-properties s) "  [tool: bare]"))

;; A note not yet delivered is marked, and the marker is faced apart from
;; the note itself.
(let ((s (claude-client--render-event '(:kind note :text "n" :pending t))))
  (check "pending-marker-faced"
         (claude-test--face-at s (1- (length s)))
         'claude-client-pending-face))

;; Earlier this truncated to the first line, hiding the rest of a tool's
;; answer.
(let ((s (claude-client--render-event
          '(:kind tool-result :text "Status: applied\n412 lines\n"))))
  (check "tool-result-keeps-lines"
         (substring-no-properties s) "  → Status: applied\n  → 412 lines")
  (check "tool-result-faced" (claude-test--face-at s 2)
         'claude-client-tool-result-face))

(let ((s (claude-client--render-event '(:kind tool-result :text "   "))))
  (check "empty-tool-result-skipped" s nil))

;;;; Bounded tool results (issue #61)

;; A `git diff' or whole-file `Read' used to dump its entire payload and
;; bury the prose.  Bounded now -- but *not* back to one line, which was
;; tried before and reverted (see `tool-result-keeps-lines' above): the
;; floor is a few lines plus a way to reach the rest.
(let* ((long (mapconcat (lambda (i) (format "line %d" i))
                        (number-sequence 1 20) "\n"))
       (event (list :kind 'tool-result :text long))
       (s (substring-no-properties (claude-client--render-event event 0)))
       (lines (split-string s "\n")))
  ;; Six shown plus the elision row.
  (check "bounded-result-line-count" (length lines) 7)
  (check "bounded-result-keeps-head" (car lines) "  → line 1")
  (check "bounded-result-stops-at-limit" (nth 5 lines) "  → line 6")
  (check "bounded-result-counts-remainder"
         (nth 6 lines) "  → … 14 more lines (TAB to expand)")
  ;; The elision is faced as pending, not as result text: it is chrome
  ;; about the result rather than part of the answer.
  (check "elision-faced"
         (claude-test--face-at (claude-client--render-event event 0)
                               (- (length s) 3))
         'claude-client-pending-face))

;; Singular, because "1 more lines" reads as a bug.
(let* ((seven (mapconcat #'number-to-string (number-sequence 1 7) "\n"))
       (s (substring-no-properties
           (claude-client--render-event (list :kind 'tool-result :text seven) 0))))
  (check "bounded-result-singular"
         (and (string-match-p "… 1 more line (TAB" s) t) t))

;; Under the limit nothing is elided, and no affordance is advertised.
(let ((s (substring-no-properties
          (claude-client--render-event
           '(:kind tool-result :text "one\ntwo\nthree") 0))))
  (check "short-result-not-elided" (and (string-match-p "more line" s) t) nil)
  (check "short-result-intact" s "  → one\n  → two\n  → three"))

;; Expansion is keyed by event index, so the *other* result stays bounded.
(let* ((long (mapconcat (lambda (i) (format "l%d" i)) (number-sequence 1 20) "\n"))
       (event (list :kind 'tool-result :text long))
       (claude-client--expanded-results '(3)))
  (check "expanded-index-shows-all"
         (length (split-string
                  (substring-no-properties (claude-client--render-event event 3))
                  "\n"))
         20)
  (check "unexpanded-index-still-bounded"
         (length (split-string
                  (substring-no-properties (claude-client--render-event event 4))
                  "\n"))
         7))

;; nil is the documented escape hatch: show everything.
(let* ((long (mapconcat (lambda (i) (format "l%d" i)) (number-sequence 1 20) "\n"))
       (claude-client-tool-result-lines nil)
       (s (substring-no-properties
           (claude-client--render-event (list :kind 'tool-result :text long) 0))))
  (check "unbounded-custom-shows-all" (length (split-string s "\n")) 20))

;; `gh issue view' answers with a dozen empty field labels; they are noise.
(let ((s (substring-no-properties
          (claude-client--render-event
           '(:kind tool-result
             :text "title: Fix it\nlabels:\nassignees:\nmilestone:\nbody: real")
           0))))
  (check "empty-fields-dropped" s "  → title: Fix it\n  → body: real"))

;; The pattern must not eat real content that happens to contain a colon.
(let ((s (substring-no-properties
          (claude-client--render-event
           '(:kind tool-result :text "Status: applied\nlabels: bug\n  (let ((x 1))") 0))))
  (check "populated-fields-kept"
         s "  → Status: applied\n  → labels: bug\n  →   (let ((x 1))"))

;; A result that is nothing but empty labels earns no row at all.
(let ((s (claude-client--render-event
          '(:kind tool-result :text "labels:\nassignees:") 0)))
  (check "all-empty-fields-skipped" s nil))

;;;; Toggling a result (issue #61)

;; Round-trip through the real command in a real buffer: the rows carry
;; their event index, TAB expands, TAB again collapses, and the prose
;; after the result survives both.
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
          (check "result-rows-carry-index" (claude-client--result-at-point) 1)
          (claude-client-toggle-tool-result)
          (check "toggle-expands"
                 (> (count-lines (point-min) (point-max)) collapsed) t)
          (check "expanded-shows-last-line"
                 (and (string-match-p "→ l30" (buffer-string)) t) t)
          (goto-char (point-min))
          (forward-line 2)
          (claude-client-toggle-tool-result)
          (check "toggle-collapses-again"
                 (count-lines (point-min) (point-max)) collapsed)
          (check "prose-survives-toggling"
                 (and (string-match-p "prose after" (buffer-string)) t) t)))
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
        (check "index-found-at-eol" (claude-client--result-at-point) 0))
    (kill-buffer buf)))

;; Off a result it refuses rather than toggling something arbitrary.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (with-current-buffer buf
        (setq claude-client--events '((:kind text :text "just prose")))
        (claude-client--render)
        (goto-char (point-min))
        (check "toggle-off-result-errors"
               (condition-case nil
                   (progn (claude-client-toggle-tool-result) 'no-error)
                 (user-error 'user-error))
               'user-error))
    (kill-buffer buf)))

;; Starting a conversation discards the log, so stale indices must not
;; survive to expand unrelated results in the new one.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (with-current-buffer buf
        (setq claude-client--expanded-results '(0 1 2))
        (let ((claude-client-executable "definitely-not-a-real-binary"))
          (ignore-errors (claude-client-start "hi")))
        (check "start-clears-expansion" claude-client--expanded-results nil))
    (kill-buffer buf)))

;;;; Mentions (issue #56)

;; A mention must *queue*, not deliver.  Both of add-note's paths are
;; wrong for it: mid-turn a note abandons the turn, and with nothing
;; running add-note drains immediately -- which would send the mention as
;; a turn of its own, the opposite of "without submitting".  Found by
;; running the command, not by reading the code.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (with-current-buffer buf
        (agent-backend-mention (claude-client-backend :buffer buf)
                               "@elisp/foo.el:12-40")
        (check "mention-is-queued"
               claude-client--pending-notes '("@elisp/foo.el:12-40"))
        (check "mention-delivers-nothing"
               (memq 'notes-delivered (claude-test--kinds buf)) nil)
        (check "mention-is-logged" (claude-test--kinds buf) '(note))
        ;; `pending' is the truth: the model has not been handed it.
        (check "mention-logged-as-pending"
               (plist-get (car claude-client--events) :pending) t))
    (kill-buffer buf)))

;; Queued, so the next prompt carries it -- that is what makes a mention
;; reach the model at all.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (with-current-buffer buf
        (agent-backend-mention (claude-client-backend :buffer buf) "@a.el:1")
        (check "mention-rides-next-prompt"
               (claude-client--prompt-with-notes "what is this?")
               "what is this?\n\nNotes from the human:\n- @a.el:1"))
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
        (check "mention-coalesces-repeat"
               claude-client--pending-notes '("@a.el:1" "@b.el:2")))
    (kill-buffer buf)))

;; A mention mid-turn must not interrupt: pointing at code is not the
;; human changing direction, which is what a note is for.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (with-current-buffer buf
        (setq claude-client--turn-active t)
        (agent-backend-mention (claude-client-backend :buffer buf) "@a.el:1")
        (check "mention-mid-turn-does-not-interrupt"
               (memq 'interrupted (claude-test--kinds buf)) nil)
        (check "mention-mid-turn-still-queued"
               claude-client--pending-notes '("@a.el:1")))
    (kill-buffer buf)))

;; Empty or whitespace-only text is not a mention.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (with-current-buffer buf
        (agent-backend-mention (claude-client-backend :buffer buf) "   ")
        (check "empty-mention-ignored" claude-client--pending-notes nil)
        (check "empty-mention-not-logged" (claude-test--kinds buf) nil))
    (kill-buffer buf)))

;; TAB is bound in the mode map, and re-registered for evil -- motion
;; state claims it as `evil-jump-forward', so without that it is dead.
(check "tab-bound"
       (lookup-key claude-client-mode-map (kbd "TAB"))
       #'claude-client-toggle-tool-result)
(check "tab-in-evil-keys"
       (cdr (assoc "TAB" claude-client--evil-keys))
       'claude-client-toggle-tool-result)

;; Prose keeps its exact text either way; only the properties differ.
(let* ((prose "Use **bold** and `code`.\n")
       (s (claude-client--render-event (list :kind 'text :text prose))))
  (check "prose-text-unchanged" (substring-no-properties s) prose)
  (if (fboundp 'gfm-view-mode)
      (check "prose-fontified"
             (and (text-properties-at 6 s) t) t)
    ;; Without `markdown-mode' the client must still render, plain.
    (check "prose-plain-without-markdown" (text-properties-at 6 s) nil)))

(let ((s (claude-client--render-event '(:kind text :text ""))))
  (check "empty-prose-renders" s ""))

(check "unknown-kind-skipped"
       (claude-client--render-event '(:kind :no-such-kind)) nil)

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

;; The note lands in the log as soon as it is written, and waits while a
;; turn is running.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (with-current-buffer buf
        (claude-test--with-running-turn
         (claude-client-add-note "look at the error handling"))
        (check "note-logged-immediately" (claude-test--kinds buf) '(note))
        (check "note-text"
               (plist-get (car claude-client--events) :text)
               "look at the error handling")
        (check "note-queued"
               claude-client--pending-notes '("look at the error handling")))
    (kill-buffer buf)))

;; Turn state must not be inferred from the process.  `claude --print' stays
;; alive after emitting `result' (it waits on stdin), so a live process is
;; not evidence of a turn in flight -- reading it that way left notes queued
;; forever once a run had finished.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (with-current-buffer buf
        (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
                  ((symbol-function 'process-send-string) (lambda (&rest _) nil)))
          ;; Process "alive", but the turn ended: the note must still drain.
          (setq claude-client--process 'fake
                claude-client--turn-active nil)
          (claude-client-add-note "after the turn")
          (check "live-process-is-not-an-active-turn"
                 claude-client--pending-notes nil)))
    (kill-buffer buf)))

;; The stream is what starts and ends a turn.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (with-current-buffer buf
        (setq claude-client--turn-active t)
        (claude-test--feed buf (concat claude-test--result "\n"))
        (check "result-clears-turn-active" claude-client--turn-active nil))
    (kill-buffer buf)))

;; With no turn running the note has nothing to wait for, so it is delivered
;; straight away rather than sitting queued for a turn that may never come.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (with-current-buffer buf
        (claude-client-add-note "idle note")
        (check "idle-note-drains-now" claude-client--pending-notes nil)
        (check "idle-note-delivery-event"
               (claude-test--kinds buf) '(note notes-delivered)))
    (kill-buffer buf)))

;; Empty and whitespace notes are rejected rather than logged as blanks.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (with-current-buffer buf
        (check "empty-note-errors"
               (condition-case _ (progn (claude-client-add-note "   ") nil)
                 (user-error t))
               t)
        (check "empty-note-not-logged" (claude-test--kinds buf) nil))
    (kill-buffer buf)))

;; Notes keep their order and all of them are queued.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (with-current-buffer buf
        (claude-test--with-running-turn
         (claude-client-add-note "first")
         (claude-client-add-note "second"))
        (check "notes-ordered" claude-client--pending-notes '("first" "second")))
    (kill-buffer buf)))

;; Notes are drained when the turn's `result' arrives -- after the
;; `finished' event, so the log reads in the order things happened.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (with-current-buffer buf
        (claude-test--feed buf (concat claude-test--init "\n"))
        (claude-test--with-running-turn
         (claude-client-add-note "mid-turn thought"))
        (check "note-pending-during-turn"
               claude-client--pending-notes '("mid-turn thought"))
        (claude-test--feed buf (concat claude-test--result "\n"))
        (check "notes-drained-at-turn-end" claude-client--pending-notes nil)
        (check "drain-order"
               (claude-test--kinds buf)
               '(started note finished notes-delivered))
        (check "delivered-carries-notes"
               (plist-get (car (last claude-client--events)) :notes)
               '("mid-turn thought")))
    (kill-buffer buf)))

;; A turn that ends with no notes produces no delivery event.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (progn
        (claude-test--feed buf
                           (concat claude-test--init "\n")
                           (concat claude-test--result "\n"))
        (check "no-notes-no-delivery-event"
               (claude-test--kinds buf) '(started finished)))
    (kill-buffer buf)))

;; Notes are announced on the subscriber hook like any other event, so the
;; transcript sees the human's writes on the same channel as the runner's.
(let* ((buf (claude-test--buffer))
       (seen nil)
       (claude-client-event-functions
        (list (lambda (_b e) (push (plist-get e :kind) seen)))))
  (unwind-protect
      (with-current-buffer buf
        (claude-test--with-running-turn
         (claude-client-add-note "via hook"))
        (check "note-reaches-subscribers" seen '(note)))
    (kill-buffer buf)))

;; Notes render, and a note added while a turn is running is marked pending.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (with-current-buffer buf
        (let ((claude-client-note-interrupts nil))
          (claude-test--with-running-turn
           (claude-client-add-note "rendered note")))
        (check "note-rendered"
               (and (string-match-p "> rendered note" (claude-test--text buf)) t) t)
        ;; `pending' means the model has not seen it.  Only true when the
        ;; note waits; an interrupting note is about to be delivered.
        (check "note-pending-marked"
               (plist-get (car claude-client--events) :pending) t))
    (kill-buffer buf)))

;; A note outside a conversation buffer is refused rather than silently lost.
(with-temp-buffer
  (check "note-outside-conversation-errors"
         (condition-case _ (progn (claude-client-add-note "x") nil)
           (user-error t))
         t))

;; Starting a run resets the event log, so a note queued beforehand has to be
;; carried into the outgoing prompt or the human's words are silently lost.
;; Stub the subprocess and capture what would be written to its stdin.
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
              (check "restart-carries-note"
                     (and (string-match-p "remember the timeout" text) t) t)
              (check "restart-keeps-prompt"
                     (and (string-match-p "do the thing" text) t) t))
            (with-current-buffer buf
              (check "restart-clears-queue" claude-client--pending-notes nil)))
        (let ((kill-buffer-query-functions nil)) (kill-buffer buf))))))

;;;; Multi-turn stdin
;;
;; A follow-up turn reuses the running CLI, so the model keeps its session
;; and context.  Verified against the real CLI: a second turn on the same
;; process returns the same `session_id' and can recall the first turn.

;; `claude-client-send' writes a well-formed user turn and marks the turn
;; active, without respawning.
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
            (check "send-type-user" (alist-get 'type msg) "user")
            (check "send-text"
                   (alist-get 'text
                              (aref (alist-get 'content
                                               (alist-get 'message msg)) 0))
                   "second turn"))
          (check "send-marks-turn-active" claude-client--turn-active t)
          (check "send-logs-prompt"
                 (plist-get (car (last claude-client--events)) :kind) 'prompt)))
    (kill-buffer buf)))

;; Sending while a turn is in flight is refused: the CLI reads one turn at a
;; time, so a second write would interleave with the one being answered.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (with-current-buffer buf
        (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t)))
          (setq claude-client--process 'fake claude-client--turn-active t)
          (check "send-refused-mid-turn"
                 (condition-case _ (progn (claude-client-send "x") nil)
                   (user-error t))
                 t)))
    (kill-buffer buf)))

;; With no live process there is nothing to continue.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (with-current-buffer buf
        (setq claude-client--process nil claude-client--turn-active nil)
        (check "send-refused-without-process"
               (condition-case _ (progn (claude-client-send "x") nil)
                 (user-error t))
               t))
    (kill-buffer buf)))

;; Notes drained at turn end are delivered to the model as the next turn --
;; this is what makes a note change what the model does, not just the log.
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
          (check "notes-delivered-to-model"
                 (and sent (string-match-p "reconsider the approach" sent) t) t)
          (check "note-delivery-starts-a-turn" claude-client--turn-active t)))
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
          (check "no-delivery-when-disabled" sent nil)
          (check "no-turn-when-disabled" claude-client--turn-active nil)
          (check "note-still-recorded"
                 (and (memq 'notes-delivered (claude-test--kinds buf)) t) t)))
    (kill-buffer buf)))

;; A dead process ends the turn with it; otherwise the buffer would be
;; wedged against ever starting another run.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (with-current-buffer buf
        (setq claude-client--turn-active t)
        (cl-letf (((symbol-function 'process-live-p) (lambda (_p) nil)))
          (claude-client--sentinel buf 'fake "exited"))
        (check "sentinel-clears-turn" claude-client--turn-active nil)
        (check "sentinel-clears-process" claude-client--process nil))
    (kill-buffer buf)))

;;;; Resume
;;
;; `--resume' reopens a past session in a NEW process, keeping its id and
;; history.  Verified against the CLI: a resumed session recalls what it was
;; told before the first process exited.  Note `--session-id' is a different
;; flag -- it means "create a new session with this id" and fails if a
;; transcript already exists.

(let ((cmd (claude-client--command "sess-abc")))
  (check "resume-flag-present" (and (member "--resume" cmd) t) t)
  (check "resume-id-follows-flag"
         (cadr (member "--resume" cmd)) "sess-abc")
  ;; --session-id would mean "create new with this id" and hard-fail on an
  ;; existing transcript; resuming must not use it.
  (check "resume-does-not-use-session-id"
         (and (member "--session-id" cmd) t) nil))

;; Without an id the flag is absent entirely, so a normal start is unchanged.
(let ((cmd (claude-client--command)))
  (check "no-resume-flag-by-default" (and (member "--resume" cmd) t) nil))

;; Starting with a resume id logs it, so the transcript shows which session
;; was reopened rather than looking like a fresh conversation.
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
              (check "resume-logs-resumed-event"
                     (plist-get (car claude-client--events) :kind) 'resumed)
              (check "resume-event-carries-id"
                     (plist-get (car claude-client--events) :session) "sess-xyz")
              (check "resume-then-prompt"
                     (mapcar (lambda (e) (plist-get e :kind)) claude-client--events)
                     '(resumed prompt))))
        (let ((kill-buffer-query-functions nil)) (kill-buffer buf))))))

;; A plain start logs no `resumed' event.
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
              (check "fresh-start-has-no-resumed"
                     (memq 'resumed
                           (mapcar (lambda (e) (plist-get e :kind))
                                   claude-client--events))
                     nil)))
        (let ((kill-buffer-query-functions nil)) (kill-buffer buf))))))

;;;; Window management
;;
;; Placement mirrors the eat runner: an ordinary window in a configurable
;; direction, not a dedicated side window.

(let ((captured nil))
  (cl-letf (((symbol-function 'display-buffer)
             (lambda (_buf &optional action) (setq captured action) nil)))
    (let ((claude-client-window-direction 'right)
          (claude-client-window-width 0.4))
      (claude-client--display (current-buffer))
      (check "display-uses-in-direction"
             (and (memq 'display-buffer-in-direction (car captured)) t) t)
      (check "display-honours-direction"
             (alist-get 'direction captured) 'right)
      (check "display-sets-width"
             (alist-get 'window-width captured) 0.4))
    ;; Vertical placement sizes by height instead.
    (let ((claude-client-window-direction 'below)
          (claude-client-window-height 0.3))
      (claude-client--display (current-buffer))
      (check "display-vertical-uses-height"
             (alist-get 'window-height captured) 0.3))
    ;; nil hands the decision to display-buffer-alist: no action argument at
    ;; all, rather than an in-direction action.
    (let ((claude-client-window-direction nil))
      (setq captured 'untouched)
      (claude-client--display (current-buffer))
      (check "display-nil-direction-plain" captured nil))))

;; Focus is not stolen by default.
(let ((selected nil))
  (cl-letf (((symbol-function 'display-buffer) (lambda (&rest _) 'win))
            ((symbol-function 'select-window) (lambda (w) (setq selected w))))
    (let ((claude-client-focus-on-show nil))
      (claude-client--display (current-buffer))
      (check "no-focus-by-default" selected nil))
    (let ((claude-client-focus-on-show t))
      (claude-client--display (current-buffer))
      (check "focus-when-requested" selected 'win))))

;;;; Re-show after an ediff review (#44)
;;
;; `mcp-emacs--ediff-review' restores the window configuration it captured
;; before the review, and does so BEFORE calling its on-resolve callback
;; (mcp-emacs.el: set-window-configuration then on-resolve).  When the review
;; came from this buffer's own tool call that snapshot predates the
;; conversation window, so by the time the tool result arrives the
;; conversation is already off screen.

(let ((buf (claude-test--buffer))
      (shown nil))
  (unwind-protect
      (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) nil))
                ((symbol-function 'claude-client--display)
                 (lambda (b) (setq shown b))))
        (let ((claude-client-restore-window-after-review t))
          (claude-client--reshow-after-review
           buf (list :kind 'tool-result :text "Status: applied"))
          (check "reshow-after-tool-result" shown buf)))
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
          (check "no-reshow-on-text" shown nil)))
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
          (check "no-reshow-when-visible" shown nil)))
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
          (check "reshow-opt-out" shown nil)))
    (kill-buffer buf)))

;; The re-show is installed as a subscriber, not wired into the runner: the
;; log stays the seam, and this is just one more reader of it.
(check "reshow-is-a-subscriber"
       (and (memq #'claude-client--reshow-after-review
                  claude-client-event-functions) t)
       t)

;;;; Interruption (issue #39)
;;
;; The CLI advertises `interrupt_receipt_v1' and accepts a control request
;; that abandons the turn in flight.  Verified against the real CLI: the turn
;; ends promptly as `error_during_execution' and the session still answers a
;; following turn, so an interrupt costs the in-flight work and nothing else.

;; The wire shape is a control_request, not a user turn.
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
            (check "interrupt-is-control-request"
                   (alist-get 'type msg) "control_request")
            (check "interrupt-subtype"
                   (alist-get 'subtype (alist-get 'request msg)) "interrupt")
            (check "interrupt-has-request-id"
                   (stringp (alist-get 'request_id msg)) t))
          (check "interrupt-logged"
                 (memq 'interrupted (claude-test--kinds buf)) '(interrupted))))
    (kill-buffer buf)))

;; Interrupting with nothing running is refused rather than sent blindly.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (with-current-buffer buf
        (setq claude-client--turn-active nil)
        (check "interrupt-refused-when-idle"
               (condition-case _ (progn (claude-client-interrupt) nil)
                 (user-error t))
               t))
    (kill-buffer buf)))

;; A note written mid-turn interrupts it, rather than waiting.
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
          (check "note-interrupts-turn"
                 (and sent (string-match-p "interrupt" sent) t) t)
          (check "note-logs-interrupted"
                 (and (memq 'interrupted (claude-test--kinds buf)) t) t)
          ;; Still queued: it is delivered when `result' arrives for the
          ;; turn being abandoned, not written into a dying turn.
          (check "note-still-queued-until-result"
                 claude-client--pending-notes '("stop, do the other thing"))))
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
          (check "no-interrupt-when-opted-out" sent nil)
          (check "opted-out-note-queues"
                 claude-client--pending-notes '("later"))))
    (kill-buffer buf)))

;; After an interrupt the delivered turn tells the model not to resume, so it
;; re-plans around the note instead of carrying on with abandoned work.
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
          (check "replan-mentions-interruption"
                 (and sent (string-match-p "interrupted" sent) t) t)
          (check "replan-says-do-not-resume"
                 (and sent (string-match-p "Do not resume" sent) t) t)
          (check "replan-carries-note"
                 (and sent (string-match-p "change course" sent) t) t)))
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
          (check "uninterrupted-has-no-replan-framing"
                 (and sent (string-match-p "Do not resume" sent)) nil)
          (check "uninterrupted-still-carries-note"
                 (and sent (string-match-p "fyi" sent) t) t)))
    (kill-buffer buf)))

;;;; Backpressure (issue #39)
;;
;; Several notes in quick succession while the model is slow.  Once a turn is
;; being interrupted it is already ending, so further notes ride out on the
;; same delivery rather than firing more interrupts into a dying turn.

;; Two notes during one turn interrupt it once, and both are delivered.
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
          (check "one-interrupt-for-many-notes" interrupts 1)
          (check "later-notes-still-queued"
                 claude-client--pending-notes '("first" "second"))
          (check "one-interrupted-event"
                 (length (seq-filter
                          (lambda (e) (eq (plist-get e :kind) 'interrupted))
                          claude-client--events))
                 1)))
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
          (check "duplicate-note-coalesced"
                 claude-client--pending-notes '("same thing"))
          ;; Still logged twice: the human did write it twice.
          (check "duplicate-still-recorded"
                 (length (seq-filter (lambda (e) (eq (plist-get e :kind) 'note))
                                     claude-client--events))
                 2)))
    (kill-buffer buf)))

;; Explicitly interrupting a turn that is already being interrupted is
;; refused rather than sending a second control request.
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
          (check "second-interrupt-refused"
                 (condition-case _ (progn (claude-client-interrupt) nil)
                   (user-error t))
                 t)
          (check "second-interrupt-not-sent" interrupts 1)))
    (kill-buffer buf)))

;; The queue is bounded: the newest note is the current intent, so the oldest
;; are dropped when the model is too slow to drain them.
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (with-current-buffer buf
        (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
                  ((symbol-function 'process-send-string) (lambda (&rest _) nil)))
          (setq claude-client--process 'fake claude-client--turn-active t)
          (let ((claude-client-max-pending-notes 3))
            (dolist (n '("n1" "n2" "n3" "n4" "n5"))
              (claude-client-add-note n))
            (check "queue-bounded" (length claude-client--pending-notes) 3)
            (check "newest-kept"
                   claude-client--pending-notes '("n3" "n4" "n5"))
            ;; A drop is recorded, not silent.
            (check "drops-logged"
                   (mapcar (lambda (e) (plist-get e :text))
                           (seq-filter
                            (lambda (e) (eq (plist-get e :kind) 'note-dropped))
                            claude-client--events))
                   '("n1" "n2")))))
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
            (check "unbounded-keeps-all"
                   (length claude-client--pending-notes) 4))))
    (kill-buffer buf)))

;;;; Conversation buffers (issue #56)
;;
;; One buffer per conversation, `*claude-client:<project>:<n>*'.  The bug
;; being pinned: a single hardcoded name meant starting a conversation in
;; one project silently killed another project's CLI.

(let ((default-directory "/tmp/proj-a/"))
  (check "buffer-name-uses-project"
         (claude-client--buffer-name "/tmp/proj-a/" 1)
         "*claude-client:proj-a:1*")
  (check "buffer-name-numbers"
         (claude-client--buffer-name "/tmp/proj-a/" 7)
         "*claude-client:proj-a:7*"))

;; Numbers are per project and fill the lowest free slot.
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
        (check "buffers-found" (length (claude-client--buffers)) 3)
        (check "project-scopes-buffers"
               (length (claude-client--project-buffers "/tmp/proj-a/")) 2)
        (check "next-number-skips-used"
               (claude-client--next-number "/tmp/proj-a/") 3)
        ;; A hole left by a killed conversation is refilled, not skipped.
        (let ((kill-buffer-query-functions nil)) (kill-buffer a1))
        (check "next-number-refills-hole"
               (claude-client--next-number "/tmp/proj-a/") 1))
    (let ((kill-buffer-query-functions nil))
      (dolist (b (list a1 a2 b1)) (when (buffer-live-p b) (kill-buffer b))))))

;; `cl-letf' is not used for these: several `symbol-function' places in one
;; form collide during macroexpansion, so the mocks silently overwrite each
;; other.  Save and restore by hand instead.
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
(let ((a nil) (b nil) (root "/tmp/proj-a/"))
  (unwind-protect
      (claude-test--with-stubs
          (cons (cons 'process-live-p (lambda (p) (eq p 'fake-proc)))
                (claude-test--start-stubs
                 (lambda () root)
                 (lambda (&rest _) (error "a live conversation was killed"))))
        (setq a (claude-client-start "in A"))
        (check "start-names-by-project" (buffer-name a) "*claude-client:proj-a:1*")
        ;; Switch project and start again: delete-process would signal.
        (setq root "/tmp/proj-b/")
        (check "cross-project-start-spares-other"
               (condition-case err
                   (progn (setq b (claude-client-start "in B")) :no-kill)
                 (error (error-message-string err)))
               :no-kill)
        (check "second-buffer-is-distinct" (buffer-name b)
               "*claude-client:proj-b:1*")
        (check "first-still-live" (buffer-live-p a) t))
    (let ((kill-buffer-query-functions nil))
      (dolist (x (list a b)) (when (and x (buffer-live-p x)) (kill-buffer x))))))

;; `g' from inside a conversation restarts in place rather than piling up.
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
          (check "restart-in-place-reuses-buffer" (eq again buf) t)
          (check "restart-in-place-adds-no-buffer"
                 (length (claude-client--buffers)) 1)))
    (let ((kill-buffer-query-functions nil))
      (when (and buf (buffer-live-p buf)) (kill-buffer buf)))))

;; Toggle: no conversation starts one, a visible one is hidden, a hidden
;; one is shown.
(let ((buf nil) (started nil) (shown nil) (deleted nil))
  (unwind-protect
      (claude-test--with-stubs
          (list (cons 'claude-client--project-root (lambda () "/tmp/proj-a/"))
                (cons 'claude-client-start (lambda (&rest _) (interactive) (setq started t)))
                (cons 'claude-client--display (lambda (b) (setq shown b)))
                (cons 'delete-window (lambda (&optional w) (setq deleted (or w t)))))
        ;; Nothing yet: toggle starts a conversation.
        (claude-client-toggle)
        (check "toggle-with-none-starts" started t)
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
        (check "toggle-hidden-shows" shown buf)
        (check "toggle-hidden-does-not-start" started nil)
        ;; Visible on this frame: the window is hidden, not re-shown.
        (setq shown nil)
        (claude-test--with-stubs
            (list (cons 'get-buffer-window (lambda (&rest _) 'fake-window)))
          (claude-client-toggle))
        (check "toggle-visible-hides" deleted 'fake-window)
        (check "toggle-visible-does-not-show" shown nil))
    (let ((kill-buffer-query-functions nil))
      (when (and buf (buffer-live-p buf)) (kill-buffer buf)))))

;; Frame-awareness: a conversation only on *another* frame is raised, not
;; hidden and not duplicated.
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
        (check "toggle-other-frame-raises" focused 'other-frame)
        (check "toggle-other-frame-selects-window" selected 'other-window)
        (check "toggle-other-frame-does-not-hide" deleted nil)
        (check "toggle-other-frame-does-not-redisplay" shown nil))
    (let ((kill-buffer-query-functions nil))
      (when (and buf (buffer-live-p buf)) (kill-buffer buf)))))

;; A split window is simply deleted.
(let ((deleted nil) (iconified nil))
  (claude-test--with-stubs
      (list (cons 'delete-window (lambda (&optional w) (setq deleted (or w t))))
            (cons 'iconify-frame (lambda (f) (setq iconified f))))
    (claude-client--hide-window 'a-window))
  (check "hide-window-deletes" deleted 'a-window)
  (check "hide-window-spares-frame" iconified nil))

;; A conversation alone on its own frame would trip `delete-window''s
;; sole-window error, so the frame is iconified instead.
(let ((iconified nil))
  (claude-test--with-stubs
      (list (cons 'delete-window
                  (lambda (&optional _w) (error "Attempt to delete minibuffer or sole ordinary window")))
            (cons 'window-frame (lambda (&rest _) 'lone-frame))
            (cons 'iconify-frame (lambda (f) (setq iconified f))))
    (claude-client--hide-window 'lone-window))
  (check "hide-sole-window-iconifies" iconified 'lone-frame))

;; Toggle is project-scoped: another project's conversation is not a
;; candidate, so toggling in an empty project starts a new one.
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
        (check "toggle-ignores-other-project" started t))
    (let ((kill-buffer-query-functions nil))
      (when (and other (buffer-live-p other)) (kill-buffer other)))))

;; The single-letter keys.  Evil is not installed in batch, so this only
;; pins the plain-Emacs map and the evil-registration data; the evil path
;; itself needs a live evil (see `claude-client--setup-evil').
(let ((buf (claude-test--buffer)))
  (unwind-protect
      (with-current-buffer buf
        (check "letter-s-sends"
               (lookup-key claude-client-mode-map (kbd "s")) 'claude-client-send)
        (check "letter-n-notes"
               (lookup-key claude-client-mode-map (kbd "n")) 'claude-client-add-note)
        ;; The evil table must stay in step with the keymap, since the two
        ;; are bound from separate places.
        (check "evil-table-matches-keymap"
               (sort (mapcar (lambda (c)
                               (format "%s=%s" (car c)
                                       (lookup-key claude-client-mode-map (kbd (car c)))))
                             claude-client--evil-keys)
                     #'string<)
               (sort (mapcar (lambda (c) (format "%s=%s" (car c) (cdr c)))
                             claude-client--evil-keys)
                     #'string<))
        ;; The evil-safe C-c vocabulary comes from the parent mode and must
        ;; survive regardless.
        (check "C-c-C-s-inherited"
               (lookup-key agent-backend-mode-map (kbd "C-c C-s"))
               'agent-backend-send-command)
        ;; Guarded so a snipe-less Emacs is a no-op rather than an error.
        (check "setup-evil-safe-without-evil"
               (progn (claude-client--setup-evil) :no-error) :no-error))
    (kill-buffer buf)))
