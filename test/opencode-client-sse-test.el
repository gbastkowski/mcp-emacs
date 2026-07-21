(add-to-list 'load-path (expand-file-name "elisp"))
(require 'cl-lib)
(require 'opencode-client)
(defun check (label got want)
  (princ (format "%s %s: got=%S want=%S\n" (if (equal got want) "PASS" "FAIL") label got want)))
(defun mk (seq part)
  (json-encode `((type . "sync") (syncEvent . ((type . "message.part.updated.1") (seq . ,seq) (data . ((part . ,part))))))))
(with-temp-buffer
  (opencode-client-mode)
  (setq opencode-client--parts (make-hash-table :test 'equal))
  (setq opencode-client--message-parts (make-hash-table :test 'equal))
  (let ((buf (current-buffer))
        (f1 (mk 1 '((id . "p1") (messageID . "m") (type . "text") (text . "Hello"))))
        (f2 (mk 2 '((id . "p1") (messageID . "m") (type . "text") (text . "Hello world"))))
        (f3 (mk 3 '((id . "p2") (messageID . "m") (type . "tool") (tool . "read") (state . ((status . "completed"))))))
        (stale (mk 1 '((id . "p1") (type . "text") (text . "STALE")))))
    (let* ((payload (concat "data: " f1 "\n\n")) (m (/ (length payload) 2)))
      (opencode-client--stream-filter buf nil (substring payload 0 m))
      (check "partial-no-apply" (hash-table-count opencode-client--parts) 0)
      (opencode-client--stream-filter buf nil (substring payload m)))
    (check "after-f1-parts" (hash-table-count opencode-client--parts) 1)
    (opencode-client--stream-filter buf nil (concat "data: " f2 "\n\ndata: " f3 "\n\n"))
    (check "after-f2f3-parts" (hash-table-count opencode-client--parts) 2)
    (check "seq" opencode-client--seq 3)
    (check "p1-upserted" (alist-get 'text (gethash "p1" opencode-client--parts)) "Hello world")
    (opencode-client--stream-filter buf nil (concat "data: " stale "\n\n"))
    (check "stale-text" (alist-get 'text (gethash "p1" opencode-client--parts)) "Hello world")
    (check "stale-seq" opencode-client--seq 3)
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
  (setq opencode-client--parts (make-hash-table :test 'equal))
  (setq opencode-client--message-parts (make-hash-table :test 'equal))
  (setq opencode-client--messages nil)
  (let ((history
         (list
          '((id . "m1") (type . "user") (text . "Hi there"))
          '((id . "m2") (type . "assistant")
            (content . (((id . "p1") (type . "text") (text . "Hello"))
                        ((id . "p2") (type . "reasoning") (text . "thinking"))
                        ((id . "p3") (type . "tool") (name . "read")
                         (state . "completed"))))))))
    (cl-letf (((symbol-function 'opencode-client--request)
               (lambda (&rest _) history)))
      (opencode-client--seed-history "ses_x")
      (check "seed-messages-order" opencode-client--messages '("m1" "m2"))
      (check "seed-user-text"
             (alist-get 'text (gethash "m1:text" opencode-client--parts)) "Hi there")
      (check "seed-tool-name-mapped"
             (alist-get 'tool (gethash "p3" opencode-client--parts)) "read")
      (opencode-client--render)
      (check "seed-render"
             (buffer-string)
             "Hi there\nHello\n  · thinking\n  [tool: read completed]\n"))))

;; Empty history seeds nothing.
(with-temp-buffer
  (opencode-client-mode)
  (setq opencode-client--parts (make-hash-table :test 'equal))
  (setq opencode-client--message-parts (make-hash-table :test 'equal))
  (setq opencode-client--messages nil)
  (cl-letf (((symbol-function 'opencode-client--request) (lambda (&rest _) nil)))
    (opencode-client--seed-history "ses_empty")
    (opencode-client--render)
    (check "seed-empty-messages" opencode-client--messages nil)
    (check "seed-empty-render" (buffer-string) "")))

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
