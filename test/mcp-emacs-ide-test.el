;;; mcp-emacs-ide-test.el --- Tests for mcp-emacs-ide -*- lexical-binding: t; -*-

;; Batch tests for the Claude Code IDE integration surface.  These avoid a
;; live WebSocket and a live Claude Code: message dispatch is driven
;; directly and the client socket is stubbed so sent JSON is captured.

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'json)
(require 'cl-lib)
(require 'mcp-emacs)
;; websocket may be unavailable in batch; stub the two symbols the module
;; calls at runtime so loading and dispatch work without the package.
(unless (require 'websocket nil t)
  (defun websocket-send-text (_ws _text) nil)
  (defun websocket-server (&rest _) nil)
  (defun websocket-server-close (&rest _) nil)
  (defun websocket-frame-text (_frame) ""))
(require 'mcp-emacs-ide)

(defvar mcp-ide-test--sent nil
  "List of JSON strings the stubbed client \"sent\", newest last.")

;; Capture everything the module sends by stubbing the send helper.
(defun mcp-ide-test--capture (_client obj)
  (push (json-encode obj) mcp-ide-test--sent))
(advice-add 'mcp-emacs-ide--send :override #'mcp-ide-test--capture)

(defun mcp-ide-test--last ()
  "Return the most recently sent message parsed as an alist."
  (json-parse-string (car mcp-ide-test--sent) :object-type 'alist))

(defun mcp-ide-test--session ()
  "Return a fresh session with a non-nil (stub) client."
  (setq mcp-ide-test--sent nil)
  (mcp-emacs-ide--make-session
   :server nil :client 'stub-client :port 12345
   :project-dir "/tmp/proj/" :lockfile nil))

(defun mcp-ide-test--dispatch (session text)
  (mcp-emacs-ide--handle-message session 'stub-client text))

(describe "initialize"
  (let ((s (mcp-ide-test--session)))
    (mcp-ide-test--dispatch
     s "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{}}")
    (let* ((msg (mcp-ide-test--last))
           (result (alist-get 'result msg)))
      (it "answers under the request id"
        (check (alist-get 'id msg) 0))
      (it "echoes the verified protocol version"
        (check (alist-get 'protocolVersion result)
               mcp-emacs-ide-protocol-version)))))

(describe "tools/list"
  (let ((s (mcp-ide-test--session)))
    (mcp-ide-test--dispatch
     s "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}")
    (let* ((result (alist-get 'result (mcp-ide-test--last)))
           (tools (alist-get 'tools result))
           (names (sort (mapcar (lambda (t) (alist-get 'name t))
                                (append tools nil))
                        #'string<)))
      (it "advertises all four tools"
        (check names '("closeAllDiffTabs" "close_tab"
                       "getDiagnostics" "openDiff"))))))

(describe "getDiagnostics"
  (let ((s (mcp-ide-test--session)))
    (mcp-ide-test--dispatch
     s (concat "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\","
               "\"params\":{\"name\":\"getDiagnostics\",\"arguments\":{}}}"))
    (it "is answered, since Claude blocks otherwise"
      (check (alist-get 'id (mcp-ide-test--last)) 3))))

(describe "closeAllDiffTabs"
  (let ((s (mcp-ide-test--session)))
    (mcp-ide-test--dispatch
     s (concat "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\","
               "\"params\":{\"name\":\"closeAllDiffTabs\",\"arguments\":{}}}"))
    (let* ((result (alist-get 'result (mcp-ide-test--last)))
           (content (alist-get 'content result))
           (text (alist-get 'text (aref content 0))))
      (it "reports zero closed tabs when none are open"
        (check text "CLOSED_0_DIFF_TABS")))))

(describe "mcp-emacs-ide--complete-open-diff on accept"
  (let ((s (mcp-ide-test--session)))
    ;; Simulate an in-flight openDiff by registering a deferred id.
    (puthash "tab-A" 4 (mcp-emacs-ide-session-deferred s))
    (setq mcp-ide-test--sent nil)
    (mcp-emacs-ide--complete-open-diff s "tab-A" "FILE_SAVED" "new content\n")
    (let* ((result (alist-get 'result (mcp-ide-test--last)))
           (content (alist-get 'content result)))
      (it "answers the deferred openDiff request id"
        (check (alist-get 'id (mcp-ide-test--last)) 4))
      (it "reports FILE_SAVED as the status"
        (check (alist-get 'text (aref content 0)) "FILE_SAVED"))
      (it "returns the saved content alongside the status"
        (check (alist-get 'text (aref content 1)) "new content\n"))
      (it "consumes the deferred entry"
        (check (gethash "tab-A" (mcp-emacs-ide-session-deferred s)) nil)))))

(describe "mcp-emacs-ide--complete-open-diff on reject"
  (let ((s (mcp-ide-test--session)))
    (puthash "tab-B" 5 (mcp-emacs-ide-session-deferred s))
    (setq mcp-ide-test--sent nil)
    (mcp-emacs-ide--complete-open-diff s "tab-B" "DIFF_REJECTED" "tab-B")
    (let* ((result (alist-get 'result (mcp-ide-test--last)))
           (content (alist-get 'content result)))
      (it "reports DIFF_REJECTED as the status"
        (check (alist-get 'text (aref content 0)) "DIFF_REJECTED"))
      (it "returns the rejected tab name alongside the status"
        (check (alist-get 'text (aref content 1)) "tab-B")))))

(describe "mcp-emacs-ide--complete-open-diff with nothing pending"
  (let ((s (mcp-ide-test--session)))
    (setq mcp-ide-test--sent nil)
    (mcp-emacs-ide--complete-open-diff s "missing" "FILE_SAVED" "x")
    (it "sends nothing rather than answering an unknown request"
      (check mcp-ide-test--sent nil))))

(describe "mcp-emacs-ide--write-lockfile"
  (let* ((mcp-emacs-ide-lockfile-directory
          (expand-file-name "mcp-ide-test-lock/" temporary-file-directory))
         (path (mcp-emacs-ide--write-lockfile 45678 "/tmp/proj/")))
    (it "creates the lockfile"
      (check (file-exists-p path) t))
    (let ((data (json-parse-string
                 (with-temp-buffer (insert-file-contents path) (buffer-string))
                 :object-type 'alist)))
      (it "identifies the IDE as Emacs"
        (check (alist-get 'ideName data) "Emacs"))
      (it "announces the ws transport"
        (check (alist-get 'transport data) "ws"))
      (it "records this Emacs process id"
        (check (alist-get 'pid data) (emacs-pid))))
    (mcp-emacs-ide--remove-lockfile path)
    (it "is removed again by `mcp-emacs-ide--remove-lockfile'"
      (check (file-exists-p path) nil))))

(describe "mcp-emacs-ide--cleanup-diff"
  (let ((s (mcp-ide-test--session))
        (buffer-b (generate-new-buffer " *ide-test-b*")))
    (puthash "tab-C"
             (list :buffer-a nil :buffer-b buffer-b :control nil :result (list nil))
             (mcp-emacs-ide-session-diffs s))
    (puthash "tab-C" 9 (mcp-emacs-ide-session-deferred s))
    (mcp-emacs-ide--cleanup-diff s "tab-C")
    (it "forgets the tracked diff"
      (check (gethash "tab-C" (mcp-emacs-ide-session-diffs s)) nil))
    (it "forgets the diff's deferred request"
      (check (gethash "tab-C" (mcp-emacs-ide-session-deferred s)) nil))
    (it "kills the diff's buffer"
      (check (buffer-live-p buffer-b) nil))))

(advice-remove 'mcp-emacs-ide--send #'mcp-ide-test--capture)

(test-helper-summary)

;;; mcp-emacs-ide-test.el ends here
