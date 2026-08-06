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
