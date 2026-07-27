;;; mcp-emacs-ide-test.el --- Tests for mcp-emacs-ide -*- lexical-binding: t; -*-

;; Batch tests for the Claude Code IDE integration surface.  These avoid a
;; live WebSocket and a live Claude Code: message dispatch is driven
;; directly and the client socket is stubbed so sent JSON is captured.

(add-to-list 'load-path (expand-file-name "elisp"))
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

(defun mcp-ide-test--check (label got want)
  (princ (format "%s %s\n" (if (equal got want) "PASS" "FAIL") label)))

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

;;;; initialize echoes the verified protocol version

(let ((s (mcp-ide-test--session)))
  (mcp-ide-test--dispatch
   s "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{}}")
  (let* ((msg (mcp-ide-test--last))
         (result (alist-get 'result msg)))
    (mcp-ide-test--check "initialize-id" (alist-get 'id msg) 0)
    (mcp-ide-test--check "initialize-protocol-version"
                         (alist-get 'protocolVersion result)
                         mcp-emacs-ide-protocol-version)))

;;;; tools/list advertises all four tools

(let ((s (mcp-ide-test--session)))
  (mcp-ide-test--dispatch
   s "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}")
  (let* ((result (alist-get 'result (mcp-ide-test--last)))
         (tools (alist-get 'tools result))
         (names (sort (mapcar (lambda (t) (alist-get 'name t))
                              (append tools nil))
                      #'string<)))
    (mcp-ide-test--check "tools-list-names" names
                         '("closeAllDiffTabs" "close_tab"
                           "getDiagnostics" "openDiff"))))

;;;; getDiagnostics is answered (Claude blocks otherwise)

(let ((s (mcp-ide-test--session)))
  (mcp-ide-test--dispatch
   s (concat "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\","
             "\"params\":{\"name\":\"getDiagnostics\",\"arguments\":{}}}"))
  (mcp-ide-test--check "getDiagnostics-answered"
                       (alist-get 'id (mcp-ide-test--last)) 3))

;;;; closeAllDiffTabs is answered and reports zero when none open

(let ((s (mcp-ide-test--session)))
  (mcp-ide-test--dispatch
   s (concat "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\","
             "\"params\":{\"name\":\"closeAllDiffTabs\",\"arguments\":{}}}"))
  (let* ((result (alist-get 'result (mcp-ide-test--last)))
         (content (alist-get 'content result))
         (text (alist-get 'text (aref content 0))))
    (mcp-ide-test--check "closeAllDiffTabs-empty" text "CLOSED_0_DIFF_TABS")))

;;;; openDiff completion: accept -> FILE_SAVED + content

(let ((s (mcp-ide-test--session)))
  ;; Simulate an in-flight openDiff by registering a deferred id.
  (puthash "tab-A" 4 (mcp-emacs-ide-session-deferred s))
  (setq mcp-ide-test--sent nil)
  (mcp-emacs-ide--complete-open-diff s "tab-A" "FILE_SAVED" "new content\n")
  (let* ((result (alist-get 'result (mcp-ide-test--last)))
         (content (alist-get 'content result)))
    (mcp-ide-test--check "openDiff-accept-id" (alist-get 'id (mcp-ide-test--last)) 4)
    (mcp-ide-test--check "openDiff-accept-status"
                         (alist-get 'text (aref content 0)) "FILE_SAVED")
    (mcp-ide-test--check "openDiff-accept-content"
                         (alist-get 'text (aref content 1)) "new content\n")
    ;; Deferred entry consumed.
    (mcp-ide-test--check "openDiff-accept-deferred-cleared"
                         (gethash "tab-A" (mcp-emacs-ide-session-deferred s)) nil)))

;;;; openDiff completion: reject -> DIFF_REJECTED + tab name

(let ((s (mcp-ide-test--session)))
  (puthash "tab-B" 5 (mcp-emacs-ide-session-deferred s))
  (setq mcp-ide-test--sent nil)
  (mcp-emacs-ide--complete-open-diff s "tab-B" "DIFF_REJECTED" "tab-B")
  (let* ((result (alist-get 'result (mcp-ide-test--last)))
         (content (alist-get 'content result)))
    (mcp-ide-test--check "openDiff-reject-status"
                         (alist-get 'text (aref content 0)) "DIFF_REJECTED")
    (mcp-ide-test--check "openDiff-reject-tab"
                         (alist-get 'text (aref content 1)) "tab-B")))

;;;; complete-open-diff is a no-op when nothing is pending

(let ((s (mcp-ide-test--session)))
  (setq mcp-ide-test--sent nil)
  (mcp-emacs-ide--complete-open-diff s "missing" "FILE_SAVED" "x")
  (mcp-ide-test--check "complete-no-pending-noop" mcp-ide-test--sent nil))

;;;; lockfile write + remove round-trip

(let* ((mcp-emacs-ide-lockfile-directory
        (expand-file-name "mcp-ide-test-lock/" temporary-file-directory))
       (path (mcp-emacs-ide--write-lockfile 45678 "/tmp/proj/")))
  (mcp-ide-test--check "lockfile-exists" (file-exists-p path) t)
  (let ((data (json-parse-string
               (with-temp-buffer (insert-file-contents path) (buffer-string))
               :object-type 'alist)))
    (mcp-ide-test--check "lockfile-idename" (alist-get 'ideName data) "Emacs")
    (mcp-ide-test--check "lockfile-transport" (alist-get 'transport data) "ws")
    (mcp-ide-test--check "lockfile-pid" (alist-get 'pid data) (emacs-pid)))
  (mcp-emacs-ide--remove-lockfile path)
  (mcp-ide-test--check "lockfile-removed" (file-exists-p path) nil))

;;;; close_tab cleans up a tracked diff and its buffer

(let ((s (mcp-ide-test--session))
      (buffer-b (generate-new-buffer " *ide-test-b*")))
  (puthash "tab-C"
           (list :buffer-a nil :buffer-b buffer-b :control nil :result (list nil))
           (mcp-emacs-ide-session-diffs s))
  (puthash "tab-C" 9 (mcp-emacs-ide-session-deferred s))
  (mcp-emacs-ide--cleanup-diff s "tab-C")
  (mcp-ide-test--check "close_tab-diff-gone"
                       (gethash "tab-C" (mcp-emacs-ide-session-diffs s)) nil)
  (mcp-ide-test--check "close_tab-deferred-gone"
                       (gethash "tab-C" (mcp-emacs-ide-session-deferred s)) nil)
  (mcp-ide-test--check "close_tab-buffer-killed" (buffer-live-p buffer-b) nil))

(advice-remove 'mcp-emacs-ide--send #'mcp-ide-test--capture)

;;; mcp-emacs-ide-test.el ends here
