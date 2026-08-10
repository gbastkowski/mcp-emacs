(add-to-list 'load-path (expand-file-name "elisp"))
(require 'cl-lib)
(require 'opencode-client)
(defun check (label got want)
  (princ (format "%s %s: got=%S want=%S\n" (if (equal got want) "PASS" "FAIL") label got want)))
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
    (let* ((payload (concat "data: " f1 "\n\n")) (m (/ (length payload) 2)))
      (opencode-client--stream-filter buf nil (substring payload 0 m))
      (check "partial-no-apply" (hash-table-count (oref backend parts)) 0)
      (opencode-client--stream-filter buf nil (substring payload m)))
    (check "after-f1-parts" (hash-table-count (oref backend parts)) 1)
    (opencode-client--stream-filter buf nil (concat "data: " f2 "\n\ndata: " f3 "\n\n"))
    (check "after-f2f3-parts" (hash-table-count (oref backend parts)) 2)
    (check "seq" (oref backend seq) 3)
    (check "p1-upserted" (alist-get 'text (gethash "p1" (oref backend parts))) "Hello world")
    (opencode-client--stream-filter buf nil (concat "data: " stale "\n\n"))
    (check "stale-text" (alist-get 'text (gethash "p1" (oref backend parts))) "Hello world")
    (check "stale-seq" (oref backend seq) 3)
    (opencode-client--render)
    (princ "=== buffer ===\n") (princ (buffer-string))))

;; Response envelope unwrapping (opencode 1.18.0 wraps most responses in `data').
(check "unwrap-object"
       (opencode-client--unwrap '((data . ((id . "ses_1") (title . "t")))))
       '((id . "ses_1") (title . "t")))
(check "unwrap-list"
       (opencode-client--unwrap '((data . (((id . "a")) ((id . "b")))) (cursor . "c")))
       '(((id . "a")) ((id . "b"))))
(check "unwrap-flat-health"
       (opencode-client--unwrap '((healthy . t)))
       '((healthy . t)))
(check "unwrap-nil" (opencode-client--unwrap nil) nil)

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
      (opencode-client--seed-history backend)
      (check "seed-messages-order" (oref backend messages) '("m1" "m2"))
      (check "seed-user-text"
             (alist-get 'text (gethash "m1:text" (oref backend parts))) "Hi there")
      (check "seed-tool-name-mapped"
             (alist-get 'tool (gethash "p3" (oref backend parts))) "read")
      (opencode-client--render)
      (check "seed-render"
             (buffer-string)
             "Hi there\nHello\n  · thinking\n  [tool: read completed]\n"))))

;; Empty history seeds nothing.
(with-temp-buffer
  (opencode-client-mode)
  (let ((backend (new-backend)))
    (oset backend session-id "ses_empty")
    (cl-letf (((symbol-function 'opencode-client--request) (lambda (&rest _) nil)))
      (opencode-client--seed-history backend)
      (opencode-client--render)
      (check "seed-empty-messages" (oref backend messages) nil)
      (check "seed-empty-render" (buffer-string) ""))))

;; Password resolution precedence and header emission.
(let ((opencode-client-password "direct")
      (opencode-client-password-command "echo should-not-run"))
  (check "pw-direct-wins" (opencode-client--password) "direct"))

(let ((opencode-client-password nil)
      (opencode-client-password-command "printf '  cmdpw\n'"))
  (check "pw-from-command-trimmed" (opencode-client--password) "cmdpw"))

(let ((opencode-client-password nil)
      (opencode-client-password-command "printf ''"))
  (check "pw-empty-command-nil" (opencode-client--password) nil))

(let ((opencode-client-password nil)
      (opencode-client-password-command nil))
  (check "pw-none-nil" (opencode-client--password) nil))

(let ((opencode-client-password "s3cret")
      (opencode-client-password-command nil))
  (check "headers-auth-present"
         (assoc "Authorization" (opencode-client--headers))
         (cons "Authorization"
               (concat "Basic " (base64-encode-string "opencode:s3cret" t)))))

(let ((opencode-client-password nil)
      (opencode-client-password-command nil))
  (check "headers-auth-absent"
         (assoc "Authorization" (opencode-client--headers)) nil))

;;;; Shared event vocabulary (agent-backend port)

;; A text part in the SSE stream is published as a `:text' event on the
;; shared hook; a tool part becomes `:tool-use'.  Unknown part types are
;; silent (the vocabulary's "ignore unknown kinds" contract).
(with-temp-buffer
  (opencode-client-mode)
  (let ((backend (new-backend))
        (seen nil)
        (buf (current-buffer)))
    (add-hook 'agent-backend-event-functions
              (lambda (b ev) (push (cons b (plist-get ev :kind)) seen)))
    (opencode-client--publish-part buf '((type . "text") (text . "hi there")))
    (opencode-client--publish-part buf '((type . "tool") (tool . "read") (state . ((status . "completed")))))
    (opencode-client--publish-part buf '((type . "reasoning") (text . "skip me")))
    (check "publish-text-kind" (mapcar #'cdr seen) '(tool-use text))
    (check "publish-text-buffer" (caar seen) buf)))

;; A note is a steering prompt: delivery "steer", and a `:note' event
;; on the shared hook.
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
      (agent-backend-add-note backend "  steer me  ")
      (check "note-trimmed" (alist-get 'text (cdr (assq 'prompt (caddr sent)))) "steer me")
      (check "note-delivery-steer" (alist-get 'delivery (caddr sent)) "steer")
      (check "note-event" (plist-get (car seen) :kind) 'note))))

;; The note-policy of the opencode backend is `:steer' (notes ARE
;; steering prompts), and the session id is what drives the HTTP call.
(with-temp-buffer
  (opencode-client-mode)
  (let ((backend (new-backend)))
    (oset backend session-id "ses9")
    (check "note-policy-steer" (agent-backend-note-policy backend) :steer)
    (check "project-root-nil" (agent-backend-project-root backend) nil)))

;; Sending a prompt posts delivery "queue" (a normal turn, not a note)
;; and publishes a `:prompt' event.
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
      (agent-backend-send backend "hello")
      (check "send-delivery-queue" (alist-get 'delivery (caddr sent)) "queue")
      (check "send-event" (plist-get (car seen) :kind) 'prompt))))


;;;; Permission and question replies

;; The shared reply methods hit the opencode endpoints with the
;; backend's session id.
(with-temp-buffer
  (opencode-client-mode)
  (let ((backend (new-backend))
        (sent nil))
    (oset backend session-id "ses3")
    (cl-letf (((symbol-function 'opencode-client--request)
               (lambda (&rest args) (setq sent args) nil)))
      (agent-backend-reply-permission backend "req-1" "allow")
      (check "permission-path"
             (cadr sent)
             "/api/session/ses3/permission/req-1/reply")
      (check "permission-decision"
             (alist-get 'decision (caddr sent)) "allow"))
    (cl-letf (((symbol-function 'opencode-client--request)
               (lambda (&rest args) (setq sent args) nil)))
      (agent-backend-reply-question backend "req-2" "42")
      (check "question-path"
             (cadr sent)
             "/api/session/ses3/question/req-2/reply")
      (check "question-answer"
             (alist-get 'answer (caddr sent)) "42"))))

;;;; Sessions on the shared surface

;; `agent-backend-list-sessions' returns (:id :label :time) plists.
(with-temp-buffer
  (opencode-client-mode)
  (let ((backend (new-backend)))
    (cl-letf (((symbol-function 'opencode-client--request)
               (lambda (&rest _)
                 (list (list (cons 'id "a") (cons 'title "Alpha")
                             (cons 'time "2026-01-01"))
                       (list (cons 'id "b"))))))
      (let ((sessions (agent-backend-list-sessions backend)))
        (check "sessions-first-id" (plist-get (car sessions) :id) "a")
        (check "sessions-first-label" (plist-get (car sessions) :label) "Alpha")
        (check "sessions-first-time" (plist-get (car sessions) :time) "2026-01-01")
        (check "sessions-second-id" (plist-get (cadr sessions) :id) "b")
        (check "sessions-second-label-fallback" (plist-get (cadr sessions) :label) "b")))))

;; Resume is not natively supported: it signals a user-error that names
;; the alternative (switch-session), rather than silently doing nothing.
(with-temp-buffer
  (opencode-client-mode)
  (let ((backend (new-backend)))
    (oset backend session-id "ses4")
    (let ((err (condition-case e
                   (agent-backend-resume backend "ses4")
                 (user-error (error-message-string e)))))
      (check "resume-errors"
             (and (stringp err)
                  (numberp (string-match-p "switch-session" err)))
             t))))

;; Interrupt posts to the interrupt endpoint and publishes `interrupted'.
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
      (agent-backend-interrupt backend)
      (check "interrupt-path" (cadr sent) "/api/session/ses5/interrupt")
      (check "interrupt-event" (plist-get (car seen) :kind) 'interrupted))))

;; Quit stops the stream process of the backend's buffer, if any.
(with-temp-buffer
  (opencode-client-mode)
  (let ((backend (new-backend))
        (killed nil))
    (let ((proc (start-process "fake-sse" nil "sleep" "10")))
      (oset backend stream-process proc)
      (cl-letf (((symbol-function 'delete-process)
                 (lambda (p) (setq killed p))))
        (agent-backend-quit backend))
      (check "quit-kills-stream" (eq killed proc) t))
    (check "quit-sets-nil" (oref backend stream-process) nil)))
