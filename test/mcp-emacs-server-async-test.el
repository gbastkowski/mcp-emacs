;;; mcp-emacs-server-async-test.el --- Tests for deferred tools/call -*- lexical-binding: t; -*-

;; Batch tests for the async (deferred) tools/call path.  A tool marked with
;; `:async-handler' must not answer from the process filter: the HTTP handler
;; holds the connection open and the response is written later, from the
;; tool's callback.  These tests drive the dispatch layer directly -- no live
;; web-server, no live ediff.

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
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

(describe "mcp-emacs-server--find-tool"
  ;; apply_diff is the human-answered review, so it must carry an async handler
  ;; while keeping its synchronous one as a direct-dispatch fallback.
  (let ((tool (mcp-emacs-server--find-tool "apply_diff")))
    (it "gives the human-answered apply_diff an async handler"
      (check-that (functionp (plist-get tool :async-handler))))
    (it "keeps apply_diff's synchronous handler as a direct-dispatch fallback"
      (check-that (functionp (plist-get tool :handler)))))

  ;; Ordinary tools must stay synchronous: deferring them would hold a
  ;; connection open for a reply that is already available.
  (let ((tool (mcp-emacs-server--find-tool "project_info")))
    (it "leaves an ordinary tool without an async handler"
      (check (plist-get tool :async-handler) nil))))

;;;; Deferral

(describe "mcp-emacs-server--tools-call-async with an async tool"
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
      (it "reports that the call was started"
        (check started t))
      (it "does not answer synchronously"
        (check sent nil))
      ;; Resolving the tool writes the response, carrying the original id.
      (funcall mcp-srv-test--done "Status: applied\nnew\n")
      (it "writes exactly one response once the tool resolves"
        (check (length sent) 1))
      (it "carries the original request id into the deferred response"
        (check (mcp-srv--id (car sent)) 42))
      (it "passes the tool's text through to the deferred response"
        (check (mcp-srv--text (car sent)) "Status: applied\nnew\n")))))

(describe "mcp-emacs-server--tools-call-async with a synchronous tool"
  ;; A synchronous tool must report "not handled" so the caller falls through
  ;; to the normal dispatch path instead of hanging.
  (let ((sent nil))
    (let ((started (mcp-emacs-server--tools-call-async
                    (list (cons 'name "project_info") (cons 'arguments nil))
                    7
                    (lambda (response) (push response sent)))))
      (it "reports not handled so the caller falls through to normal dispatch"
        (check started nil))
      (it "writes no response of its own"
        (check sent nil)))))

(describe "mcp-emacs-server--tools-call-async with an unknown tool"
  ;; An unknown tool is likewise not deferred: it must reach normal dispatch,
  ;; which turns it into a JSON-RPC error rather than an open connection.
  (let ((sent nil))
    (let ((started (mcp-emacs-server--tools-call-async
                    (list (cons 'name "no_such_tool") (cons 'arguments nil))
                    8
                    (lambda (response) (push response sent)))))
      (it "does not defer, so the call reaches normal dispatch and errors there"
        (check started nil))
      (it "leaves the connection unanswered rather than holding it open"
        (check sent nil)))))

(describe "the deferred response object"
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
      (it "is tagged as JSON-RPC 2.0 even though it skips `--dispatch'"
        (check (cdr (assoc "jsonrpc" response)) "2.0"))
      (it "wraps the tool's text as its content payload"
        (check (mcp-srv--text response) "Status: rejected"))
      (it "round-trips through `json-encode' without error"
        (check-that (stringp encoded))))))

(describe "async handler arguments"
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
    (it "reaches the handler with string arguments unchanged"
      (check (alist-get 'path seen) "/tmp/x"))
    (it "reaches the handler with numeric arguments unchanged"
      (check (alist-get 'timeout seen) 30))))

;;;; Body decoding (UTF-8)
;; web-server reads the socket with :coding no-conversion, so the body slot
;; holds raw UTF-8 bytes; parse-body must decode them so non-ASCII survives
;; as proper characters instead of raw bytes that prompt for a coding
;; system when written into a buffer.

(require (quote eieio))
(defclass mcp-srv-test--request () ((body :initarg :body)))

(describe "mcp-emacs-server--parse-body"
  ;; A UTF-8 em dash (U+2014) inside the raw body decodes to one character.
  (let* ((raw-em-dash (string #x3FFFE2 #x3FFF80 #x3FFF94))
         (request (make-instance
                   (quote mcp-srv-test--request)
                   :body (format "{%c%s%c:%c%s%c}" 34 "text" 34 34 raw-em-dash 34)))
         (parsed (mcp-emacs-server--parse-body request))
         (text (alist-get (quote text) parsed)))
    (it "decodes raw UTF-8 bytes back into the em dash they encode"
      (check-that (string= text (string #x2014))))
    (it "yields one character for the em dash rather than three bytes"
      (check (length text) 1)))

  ;; Pure-ASCII bodies are unaffected.
  (let* ((request (make-instance
                   (quote mcp-srv-test--request)
                   :body (format "{%c%s%c:%c%s%c}" 34 "method" 34 34 "ping" 34)))
         (parsed (mcp-emacs-server--parse-body request)))
    (it "leaves a pure-ASCII body unchanged"
      (check (alist-get (quote method) parsed) "ping"))))

(test-helper-summary)

;;; mcp-emacs-server-async-test.el ends here
