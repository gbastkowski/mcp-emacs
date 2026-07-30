(add-to-list 'load-path (expand-file-name "elisp"))
(require 'cl-lib)

;; Stub the two upstream modules the remote module requires, so the tests
;; run without websocket.el / web-server / a live session.  Only the symbols
;; the remote module actually touches are provided.
(unless (featurep 'mcp-emacs-run)
  (defun mcp-emacs-run-send-prompt (_text) nil)
  (defun mcp-emacs-run--project-root () "/tmp/proj-xyz")
  (provide 'mcp-emacs-run))
(unless (featurep 'mcp-emacs-ide)
  (cl-defstruct (mcp-emacs-ide-session (:constructor mcp-emacs-ide--make-session))
    client port project-dir)
  (defvar mcp-emacs-ide--session nil)
  (defun mcp-emacs-ide--call-tool (_s _n _a _i) nil)
  (defun mcp-emacs-ide--complete-open-diff (_s _t _st &rest _e) nil)
  (defun mcp-emacs-ide-start () nil)
  (defun mcp-emacs-ide-stop () nil)
  (provide 'mcp-emacs-ide))

(require 'mcp-emacs-remote)

(defun check (l g w) (princ (format "%s %s\n" (if (equal g w) "PASS" "FAIL") l)))

(defun remote--kill-transcripts ()
  (dolist (b (buffer-list))
    (when (string-prefix-p "*claude: " (buffer-name b))
      (let ((kill-buffer-query-functions nil)) (kill-buffer b)))))

;; --- 5.1 Prompt input --------------------------------------------------------

;; Empty / whitespace prompt -> user-error, nothing sent.
(let ((sent nil))
  (cl-letf (((symbol-function 'mcp-emacs-run-send-prompt) (lambda (tx) (setq sent tx))))
    (check "empty-prompt-errors"
           (condition-case _ (progn (mcp-emacs-remote--send "") nil) (user-error t)) t)
    (check "whitespace-prompt-errors"
           (condition-case _ (progn (mcp-emacs-remote--send "  \n ") nil) (user-error t)) t)
    (check "empty-prompt-sends-nothing" sent nil)))

;; Non-empty prompt -> delivered via send-prompt.
(let ((sent nil))
  (cl-letf (((symbol-function 'mcp-emacs-run-send-prompt) (lambda (tx) (setq sent tx))))
    (mcp-emacs-remote--send "hello claude")
    (check "prompt-delivered" sent "hello claude")))

;; Whole-buffer send: empty buffer errors; non-empty delivers buffer text.
(let ((sent nil))
  (cl-letf (((symbol-function 'mcp-emacs-run-send-prompt) (lambda (tx) (setq sent tx))))
    (with-temp-buffer
      (check "buffer-empty-errors"
             (condition-case _ (progn (mcp-emacs-remote-prompt-buffer) nil) (user-error t)) t))
    (check "buffer-empty-sends-nothing" sent nil)
    (with-temp-buffer
      (insert "line one\nline two\n")
      (mcp-emacs-remote-prompt-buffer))
    (check "buffer-delivered" sent "line one\nline two\n")))

;; --- 5.2 Transcript: one buffer per project, tool call recorded --------------

(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled t))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-alpha")))
    (mcp-emacs-remote-record-tool-call "openDiff" '((tab_name . "t1")))
    (mcp-emacs-remote-record-tool-call "openDiff" '((tab_name . "t2"))))
  (let ((buf (get-buffer "*claude: proj-alpha*")))
    (check "transcript-buffer-created" (and buf t) t)
    (check "transcript-reused-single-buffer"
           (length (seq-filter (lambda (b) (string-prefix-p "*claude: " (buffer-name b)))
                               (buffer-list)))
           1)
    (with-current-buffer buf
      (check "tool-heading-recorded"
             (and (string-match-p "🔧 openDiff" (buffer-string)) t) t)
      (check "tool-args-recorded"
             (and (string-match-p "begin_src json" (buffer-string)) t) t))))

;; Distinct projects -> distinct buffers.
(let ((mcp-emacs-remote-enabled t))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-beta")))
    (mcp-emacs-remote-record-tool-call "openDiff" '((tab_name . "x"))))
  (check "distinct-projects-distinct-buffers"
         (and (get-buffer "*claude: proj-alpha*") (get-buffer "*claude: proj-beta*") t) t))

;; Quiet tools get a compact note, not a heading.
(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled t))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-q")))
    (mcp-emacs-remote-record-tool-call "getDiagnostics" '()))
  (with-current-buffer (get-buffer "*claude: proj-q*")
    (check "quiet-tool-no-heading"
           (and (not (string-match-p "🔧 getDiagnostics" (buffer-string)))
                (string-match-p "getDiagnostics" (buffer-string)) t) t)))

;; --- 5.3 Diff outcome --------------------------------------------------------

(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled t))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-d")))
    (mcp-emacs-remote-record-diff-outcome "tab-A" "FILE_SAVED" "new content")
    (mcp-emacs-remote-record-diff-outcome "tab-B" "DIFF_REJECTED" "tab-B"))
  (with-current-buffer (get-buffer "*claude: proj-d*")
    (let ((s (buffer-string)))
      (check "accept-recorded"
             (and (string-match-p "openDiff accepted :: tab-A" s) t) t)
      (check "reject-recorded"
             (and (string-match-p "openDiff rejected :: tab-B" s) t) t))))

;; --- 5.4 Passive safety ------------------------------------------------------

;; Disabled -> the tap records nothing.
(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled nil))
  (mcp-emacs-remote--tap-call-tool nil "openDiff" '((tab_name . "z")) 1)
  (check "disabled-records-nothing"
         (seq-find (lambda (b) (string-prefix-p "*claude: " (buffer-name b))) (buffer-list))
         nil))

;; A rendering failure never propagates out of the recorder.
(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled t))
  (cl-letf (((symbol-function 'mcp-emacs-remote--append)
             (lambda (&rest _) (error "boom"))))
    (check "render-error-swallowed-tool"
           (condition-case _ (progn (mcp-emacs-remote-record-tool-call "openDiff" '()) t)
             (error nil))
           t)
    (check "render-error-swallowed-diff"
           (condition-case _ (progn (mcp-emacs-remote-record-diff-outcome "t" "FILE_SAVED") t)
             (error nil))
           t)))

;; The :before tap returns nil (does not alter the wrapped call's return).
(let ((mcp-emacs-remote-enabled t))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-r")))
    (check "tap-returns-nil"
           (mcp-emacs-remote--tap-call-tool nil "getDiagnostics" '() 1) nil)))

(remote--kill-transcripts)
