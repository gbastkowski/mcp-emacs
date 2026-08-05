;;; mcp-emacs-server-async-test.el --- Tests for deferred tools/call -*- lexical-binding: t; -*-

;; Batch tests for the async (deferred) tools/call path.  A tool marked with
;; `:async-handler' must not answer from the process filter: the HTTP handler
;; holds the connection open and the response is written later, from the
;; tool's callback.  These tests drive the dispatch layer directly -- no live
;; web-server, no live ediff.

(add-to-list 'load-path (expand-file-name "elisp"))
(require 'json)
(require 'cl-lib)
(require 'mcp-emacs)
;; `mcp-emacs-server' hard-requires web-server, which is usually absent in
;; batch.  Satisfy the require with a stub feature before loading it; these
;; tests drive dispatch directly and never open a socket.
(unless (require 'web-server nil t)
  (defun ws-response-header (&rest _) nil)
  (defun ws-start (&rest _) nil)
  (defun ws-stop (&rest _) nil)
  (provide 'web-server))
(require 'mcp-emacs-server)

(defun check (l g w) (princ (format "%s %s\n" (if (equal g w) "PASS" "FAIL") l)))

(defun mcp-srv--text (response)
  "Return the text payload of a JSON-RPC RESPONSE object built by the server."
  (let* ((result (cdr (assoc "result" response)))
         (content (cdr (assoc "content" result)))
         (first (aref content 0)))
    (cdr (assoc "text" first))))

(defun mcp-srv--id (response)
  "Return the id of a JSON-RPC RESPONSE object built by the server."
  (cdr (assoc "id" response)))

;;;; Registry

;; apply_diff is the human-answered review, so it must carry an async handler
;; while keeping its synchronous one as a direct-dispatch fallback.
(let ((tool (mcp-emacs-server--find-tool "apply_diff")))
  (check "apply-diff-has-async" (functionp (plist-get tool :async-handler)) t)
  (check "apply-diff-keeps-sync" (functionp (plist-get tool :handler)) t))

;; Ordinary tools must stay synchronous: deferring them would hold a
;; connection open for a reply that is already available.
(let ((tool (mcp-emacs-server--find-tool "project_info")))
  (check "sync-tool-has-no-async" (plist-get tool :async-handler) nil))

;;;; Deferral

;; An async tool returns non-nil (the call was started) and does NOT answer
;; synchronously -- that is the whole point of the path.
(let* ((sent nil)
       (tool (list :name "fake_async"
                   :async-handler (lambda (_args done)
                                    (setq mcp-srv-test--done done))))
       (mcp-emacs-server-extra-tools (list tool)))
  (defvar mcp-srv-test--done nil)
  (setq mcp-srv-test--done nil)
  (let ((started (mcp-emacs-server--tools-call-async
                  (list (cons 'name "fake_async") (cons 'arguments nil))
                  42
                  (lambda (response) (push response sent)))))
    (check "async-call-started" started t)
    (check "async-no-immediate-response" sent nil)
    ;; Resolving the tool writes the response, carrying the original id.
    (funcall mcp-srv-test--done "Status: applied\nnew\n")
    (check "async-response-sent" (length sent) 1)
    (check "async-response-id" (mcp-srv--id (car sent)) 42)
    (check "async-response-text"
           (mcp-srv--text (car sent)) "Status: applied\nnew\n")))

;; A synchronous tool must report "not handled" so the caller falls through
;; to the normal dispatch path instead of hanging.
(let ((sent nil))
  (let ((started (mcp-emacs-server--tools-call-async
                  (list (cons 'name "project_info") (cons 'arguments nil))
                  7
                  (lambda (response) (push response sent)))))
    (check "sync-tool-not-deferred" started nil)
    (check "sync-tool-no-response" sent nil)))

;; An unknown tool is likewise not deferred: it must reach normal dispatch,
;; which turns it into a JSON-RPC error rather than an open connection.
(let ((sent nil))
  (let ((started (mcp-emacs-server--tools-call-async
                  (list (cons 'name "no_such_tool") (cons 'arguments nil))
                  8
                  (lambda (response) (push response sent)))))
    (check "unknown-tool-not-deferred" started nil)
    (check "unknown-tool-no-response" sent nil)))

;; The deferred response is a well-formed JSON-RPC success object, since it
;; is written straight to the socket without going through `--dispatch'.
(let* ((sent nil)
       (tool (list :name "fake_async2"
                   :async-handler (lambda (_args done)
                                    (funcall done "Status: rejected"))))
       (mcp-emacs-server-extra-tools (list tool)))
  (mcp-emacs-server--tools-call-async
   (list (cons 'name "fake_async2") (cons 'arguments nil))
   99
   (lambda (response) (push response sent)))
  (let* ((response (car sent))
         (encoded (json-encode response)))
    (check "deferred-has-jsonrpc" (cdr (assoc "jsonrpc" response)) "2.0")
    (check "deferred-text" (mcp-srv--text response) "Status: rejected")
    ;; Round-trips through json-encode without error.
    (check "deferred-encodes" (stringp encoded) t)))

;; Arguments reach the async handler unchanged.
(let* ((seen nil)
       (tool (list :name "fake_async3"
                   :async-handler (lambda (args done)
                                    (setq seen args)
                                    (funcall done "ok"))))
       (mcp-emacs-server-extra-tools (list tool)))
  (mcp-emacs-server--tools-call-async
   (list (cons 'name "fake_async3")
         (cons 'arguments (list (cons 'path "/tmp/x") (cons 'timeout 30))))
   1 (lambda (_r) nil))
  (check "async-args-passed-path" (alist-get 'path seen) "/tmp/x")
  (check "async-args-passed-timeout" (alist-get 'timeout seen) 30))
