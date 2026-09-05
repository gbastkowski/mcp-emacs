;;; opencode-client-sse-test.el --- Tests for the opencode SSE client -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'cl-lib)
(require 'opencode-client)
(defun mk (seq part)
  (json-encode `((type . "sync") (syncEvent . ((type . "message.part.updated.1") (seq . ,seq) (data . ((part . ,part))))))))
(defun new-backend ()
  "Return a fresh opencode backend bound to the current buffer."
  (let ((b (make-instance 'opencode-client-backend :buffer (current-buffer))))
    (setq-local agent-backend--instance b)
    b))
(with-temp-buffer
  (opencode-client-mode)
  (let ((backend (new-backend))
        (buf (current-buffer))
        (f1 (mk 1 '((id . "p1") (messageID . "m") (type . "text") (text . "Hello"))))
        (f2 (mk 2 '((id . "p1") (messageID . "m") (type . "text") (text . "Hello world"))))
        (f3 (mk 3 '((id . "p2") (messageID . "m") (type . "tool") (tool . "read") (state . ((status . "completed"))))))
        (stale (mk 1 '((id . "p1") (type . "text") (text . "STALE")))))
    (describe "opencode-client--stream-filter"
      (let* ((payload (concat "data: " f1 "\n\n")) (m (/ (length payload) 2)))
        (opencode-client--stream-filter buf nil (substring payload 0 m))
        (it "applies nothing until an event's terminating blank line arrives"
          (check (hash-table-count (oref backend parts)) 0))
        (opencode-client--stream-filter buf nil (substring payload m)))
      (it "upserts the part once the split event is complete"
        (check (hash-table-count (oref backend parts)) 1))
      (opencode-client--stream-filter buf nil (concat "data: " f2 "\n\ndata: " f3 "\n\n"))
      (it "handles several events in one chunk, adding the new part"
        (check (hash-table-count (oref backend parts)) 2))
      (it "tracks the highest sequence number seen"
        (check (oref backend seq) 3))
      (it "replaces an existing part's text when its id repeats"
        (check (alist-get 'text (gethash "p1" (oref backend parts))) "Hello world"))
      (opencode-client--stream-filter buf nil (concat "data: " stale "\n\n"))
      (it "ignores an out-of-order event rather than overwriting newer text"
        (check (alist-get 'text (gethash "p1" (oref backend parts))) "Hello world"))
      (it "leaves the sequence number alone for a stale event"
        (check (oref backend seq) 3)))
    (opencode-client--render)
    (princ "=== buffer ===\n") (princ (buffer-string))))

;; Response envelope unwrapping (opencode 1.18.0 wraps most responses in `data').
(describe "opencode-client--unwrap"
  (it "unwraps a `data'-wrapped object"
    (check (opencode-client--unwrap '((data . ((id . "ses_1") (title . "t")))))
           '((id . "ses_1") (title . "t"))))
  (it "unwraps a `data'-wrapped list, dropping the cursor"
    (check (opencode-client--unwrap '((data . (((id . "a")) ((id . "b")))) (cursor . "c")))
           '(((id . "a")) ((id . "b")))))
  (it "passes an unwrapped response through untouched"
    (check (opencode-client--unwrap '((healthy . t)))
           '((healthy . t))))
  (it "returns nil for an empty response"
    (check (opencode-client--unwrap nil) nil)))

;; History seeding: adapt a canned history payload into the render model.
(with-temp-buffer
  (opencode-client-mode)
  (let ((backend (new-backend))
        (history
         (list
          '((id . "m1") (type . "user") (text . "Hi there"))
          '((id . "m2") (type . "assistant")
            (content . (((id . "p1") (type . "text") (text . "Hello"))
                        ((id . "p2") (type . "reasoning") (text . "thinking"))
                        ((id . "p3") (type . "tool") (name . "read")
                         (state . "completed"))))))))
    (oset backend session-id "ses_x")
    (cl-letf (((symbol-function 'opencode-client--request)
               (lambda (&rest _) history)))
      (describe "opencode-client--seed-history"
        (opencode-client--seed-history backend)
        (it "records the messages in the order the history gave them"
          (check (oref backend messages) '("m1" "m2")))
        (it "adapts a user message into a synthetic text part"
          (check (alist-get 'text (gethash "m1:text" (oref backend parts))) "Hi there"))
        (it "maps a history tool part's `name' onto the render model's `tool'"
          (check (alist-get 'tool (gethash "p3" (oref backend parts))) "read"))
        (opencode-client--render)
        (it "renders the seeded history as text, reasoning and tool lines"
          (check (buffer-string)
                 "Hi there\nHello\n  · thinking\n  [tool: read completed]\n"))))))

(with-temp-buffer
  (opencode-client-mode)
  (let ((backend (new-backend)))
    (oset backend session-id "ses_empty")
    (cl-letf (((symbol-function 'opencode-client--request) (lambda (&rest _) nil)))
      (describe "opencode-client--seed-history with an empty history"
        (opencode-client--seed-history backend)
        (opencode-client--render)
        (it "seeds no messages"
          (check (oref backend messages) nil))
        (it "renders an empty buffer"
          (check (buffer-string) ""))))))

;; Password resolution precedence and header emission.
(describe "opencode-client--password"
  (let ((opencode-client-password "direct")
        (opencode-client-password-command "echo should-not-run"))
    (it "prefers a directly configured password over the command"
      (check (opencode-client--password) "direct")))

  (let ((opencode-client-password nil)
        (opencode-client-password-command "printf '  cmdpw\n'"))
    (it "trims whitespace off the password command's output"
      (check (opencode-client--password) "cmdpw")))

  (let ((opencode-client-password nil)
        (opencode-client-password-command "printf ''"))
    (it "returns nil when the password command prints nothing"
      (check (opencode-client--password) nil)))

  (let ((opencode-client-password nil)
        (opencode-client-password-command nil))
    (it "returns nil when neither password nor command is configured"
      (check (opencode-client--password) nil))))

(describe "opencode-client--headers"
  (let ((opencode-client-password "s3cret")
        (opencode-client-password-command nil))
    (it "emits basic auth for the opencode user when a password exists"
      (check (assoc "Authorization" (opencode-client--headers))
             (cons "Authorization"
                   (concat "Basic " (base64-encode-string "opencode:s3cret" t))))))

  (let ((opencode-client-password nil)
        (opencode-client-password-command nil))
    (it "omits the Authorization header when there is no password"
      (check (assoc "Authorization" (opencode-client--headers)) nil))))

;;;; Shared event vocabulary (agent-backend port)

(with-temp-buffer
  (opencode-client-mode)
  (let ((backend (new-backend))
        (seen nil)
        (buf (current-buffer)))
    (add-hook 'agent-backend-event-functions
              (lambda (b ev) (push (cons b (plist-get ev :kind)) seen)))
    (describe "opencode-client--publish-part"
      (opencode-client--publish-part buf '((type . "text") (text . "hi there")))
      (opencode-client--publish-part buf '((type . "tool") (tool . "read") (state . ((status . "completed")))))
      (opencode-client--publish-part buf '((type . "reasoning") (text . "skip me")))
      (it "publishes text as `text' and tool as `tool-use', staying silent on unknown kinds"
        (check (mapcar #'cdr seen) '(tool-use text)))
      (it "publishes the event against the backend's buffer"
        (check (caar seen) buf)))))

(with-temp-buffer
  (opencode-client-mode)
  (let ((backend (new-backend))
        (sent nil)
        (seen nil)
        (agent-backend-event-functions nil))
    (oset backend session-id "ses1")
    (cl-letf (((symbol-function 'opencode-client--request)
               (lambda (&rest args)
                 (setq sent args)
                 nil)))
      (add-hook 'agent-backend-event-functions
                (lambda (_b ev) (push ev seen)))
      (describe "agent-backend-add-note"
        (agent-backend-add-note backend "  steer me  ")
        (it "trims the note text before sending it as the prompt"
          (check (alist-get 'text (cdr (assq 'prompt (caddr sent)))) "steer me"))
        (it "delivers a note as a steering prompt"
          (check (alist-get 'delivery (caddr sent)) "steer"))
        (it "publishes a `note' event on the shared hook"
          (check (plist-get (car seen) :kind) 'note))))))

(with-temp-buffer
  (opencode-client-mode)
  (let ((backend (new-backend)))
    (oset backend session-id "ses9")
    (describe "the opencode backend's shared-surface metadata"
      (it "declares a `:steer' note policy, since notes are steering prompts"
        (check (agent-backend-note-policy backend) :steer))
      (it "has no project root, as the session id drives the HTTP call instead"
        (check (agent-backend-project-root backend) nil)))))

(with-temp-buffer
  (opencode-client-mode)
  (let ((backend (new-backend))
        (sent nil)
        (seen nil)
        (agent-backend-event-functions nil))
    (oset backend session-id "ses2")
    (cl-letf (((symbol-function 'opencode-client--request)
               (lambda (&rest args)
                 (setq sent args)
                 nil)))
      (add-hook 'agent-backend-event-functions
                (lambda (_b ev) (push ev seen)))
      (describe "agent-backend-send"
        (agent-backend-send backend "hello")
        (it "queues a prompt as a normal turn rather than steering"
          (check (alist-get 'delivery (caddr sent)) "queue"))
        (it "publishes a `prompt' event on the shared hook"
          (check (plist-get (car seen) :kind) 'prompt))))))


;;;; Permission and question replies

(with-temp-buffer
  (opencode-client-mode)
  (let ((backend (new-backend))
        (sent nil))
    (oset backend session-id "ses3")
    (cl-letf (((symbol-function 'opencode-client--request)
               (lambda (&rest args) (setq sent args) nil)))
      (describe "agent-backend-reply-permission"
        (agent-backend-reply-permission backend "req-1" "allow")
        (it "posts to the permission reply endpoint for the backend's session"
          (check (cadr sent) "/api/session/ses3/permission/req-1/reply"))
        (it "sends the decision in the body"
          (check (alist-get 'decision (caddr sent)) "allow"))))
    (cl-letf (((symbol-function 'opencode-client--request)
               (lambda (&rest args) (setq sent args) nil)))
      (describe "agent-backend-reply-question"
        (agent-backend-reply-question backend "req-2" "42")
        (it "posts to the question reply endpoint for the backend's session"
          (check (cadr sent) "/api/session/ses3/question/req-2/reply"))
        (it "sends the answer in the body"
          (check (alist-get 'answer (caddr sent)) "42"))))))

;;;; Sessions on the shared surface

(with-temp-buffer
  (opencode-client-mode)
  (let ((backend (new-backend)))
    (cl-letf (((symbol-function 'opencode-client--request)
               (lambda (&rest _)
                 (list (list (cons 'id "a") (cons 'title "Alpha")
                             (cons 'time "2026-01-01"))
                       (list (cons 'id "b"))))))
      (describe "agent-backend-list-sessions"
        (let ((sessions (agent-backend-list-sessions backend)))
          (it "carries the session id through as `:id'"
            (check (plist-get (car sessions) :id) "a"))
          (it "uses the session title as `:label'"
            (check (plist-get (car sessions) :label) "Alpha"))
          (it "carries the session time through as `:time'"
            (check (plist-get (car sessions) :time) "2026-01-01"))
          (it "converts every session in the list"
            (check (plist-get (cadr sessions) :id) "b"))
          (it "falls back to the id as label for an untitled session"
            (check (plist-get (cadr sessions) :label) "b")))))))

(with-temp-buffer
  (opencode-client-mode)
  (let ((backend (new-backend)))
    (oset backend session-id "ses4")
    (describe "agent-backend-resume"
      (let ((err (condition-case e
                     (agent-backend-resume backend "ses4")
                   (user-error (error-message-string e)))))
        (it "signals a user-error naming switch-session, since resume is unsupported"
          (check (and (stringp err)
                      (numberp (string-match-p "switch-session" err)))
                 t))))))

(with-temp-buffer
  (opencode-client-mode)
  (let ((backend (new-backend))
        (sent nil)
        (seen nil)
        (agent-backend-event-functions nil))
    (oset backend session-id "ses5")
    (cl-letf (((symbol-function 'opencode-client--request)
               (lambda (&rest args) (setq sent args) nil)))
      (add-hook 'agent-backend-event-functions
                (lambda (_b ev) (push ev seen)))
      (describe "agent-backend-interrupt"
        (agent-backend-interrupt backend)
        (it "posts to the session's interrupt endpoint"
          (check (cadr sent) "/api/session/ses5/interrupt"))
        (it "publishes an `interrupted' event on the shared hook"
          (check (plist-get (car seen) :kind) 'interrupted))))))

(with-temp-buffer
  (opencode-client-mode)
  (let ((backend (new-backend))
        (killed nil))
    (describe "agent-backend-quit"
      (let ((proc (start-process "fake-sse" nil "sleep" "10")))
        (oset backend stream-process proc)
        (cl-letf (((symbol-function 'delete-process)
                   (lambda (p) (setq killed p))))
          (agent-backend-quit backend))
        (it "stops the stream process of the backend's buffer"
          (check (eq killed proc) t)))
      (it "forgets the stream process afterwards"
        (check (oref backend stream-process) nil)))))

;;;; Per-project parallel servers (multiple ports)

(describe "opencode-client--base-url"
  (let ((b (make-instance 'opencode-client-backend :host "127.0.0.1" :port 5001)))
    (it "follows the instance's own host and port when set"
      (check (opencode-client--base-url b) "http://127.0.0.1:5001"))
    (it "puts the instance's host:port where a URL authority belongs"
      (check (string-match-p "127.0.0.1:5001" (opencode-client--base-url b)) 7)))
  (let ((b (make-instance 'opencode-client-backend)))
    (it "falls back to the configured defaults when the instance has none"
      (check (opencode-client--base-url b)
             (format "http://%s:%d" opencode-client-host opencode-client-port)))))

(describe "opencode-client--free-port"
  (cl-letf (((symbol-function 'make-network-process)
             (lambda (&rest args)
               (let ((port (plist-get args :service)))
                 (when (eq port opencode-client-port)
                   (error "port %d taken" port)))
               (make-symbol "fake-sock")))
            ((symbol-function 'get-process) (lambda (_name) nil))
            ((symbol-function 'delete-process) (lambda (_proc) nil)))
    (let ((opencode-client-port 4096))
      (it "probes upward from the configured port and skips a taken one"
        (check (opencode-client--free-port) 4097)))))

(describe "opencode-client--ensure-server"
  (cl-letf (((symbol-function 'opencode-client-serve)
             (lambda ()
               (let ((b (make-instance 'opencode-client-backend :port 5002)))
                 (setq opencode-client--servers
                       (cons (cons (expand-file-name default-directory) b)
                             opencode-client--servers))
                 b)))
            ((symbol-function 'expand-file-name) (lambda (d) (concat "/proj/" d))))
    (let ((opencode-client--servers nil))
      (let ((b1 (opencode-client--ensure-server)))
        (it "starts a server for a project that has none"
          (check (oref b1 port) 5002))
        (let ((b2 (opencode-client--ensure-server)))
          (it "reuses the running server for the same project"
            (check (eq b1 b2) t)))
        (it "registers the project's server exactly once"
          (check (length opencode-client--servers) 1)))))

  (cl-letf (((symbol-function 'opencode-client-serve)
             (lambda ()
               (let ((b (make-instance 'opencode-client-backend :port 5002)))
                 (setq opencode-client--servers
                       (cons (cons (expand-file-name default-directory) b)
                             opencode-client--servers))
                 b)))
            ((symbol-function 'expand-file-name) (lambda (d) (concat "/proj/" d))))
    (let ((opencode-client--servers nil)
          (default-directory "/proj/one"))
      (let ((b1 (opencode-client--ensure-server)))
        (setq default-directory "/proj/two")
        (let ((b2 (opencode-client--ensure-server)))
          (it "gives a different project its own server, for parallel sessions"
            (check (eq b1 b2) nil))
          (it "keeps one registry entry per project"
            (check (length opencode-client--servers) 2)))))))

(test-helper-summary)

;;; opencode-client-sse-test.el ends here
