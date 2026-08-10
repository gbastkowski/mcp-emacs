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

;; --- Runner subscriber (issue #39) -------------------------------------------
;;
;; The transcript subscribes to `agent-backend-event-functions' rather than
;; advising anything: the runner publishes an append-only event log and this
;; is one reader of it.

(defun remote--transcript-text ()
  "Return the text of the (single) transcript buffer, or nil."
  (let ((buf (seq-find (lambda (b) (string-prefix-p "*claude: " (buffer-name b)))
                       (buffer-list))))
    (when buf
      (with-current-buffer buf
        (buffer-substring-no-properties (point-min) (point-max))))))

;; Each event kind lands in the transcript.
(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled t))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-s")))
    (mcp-emacs-remote--tap-runner-event
     nil (list :kind 'started :session "abc-123" :model "claude-opus-5"))
    (let ((text (remote--transcript-text)))
      (check "runner-started-heading"
             (and (string-match-p "^\\* Runner" text) t) t)
      (check "runner-started-session"
             (and (string-match-p ":SESSION: abc-123" text) t) t)
      (check "runner-started-model"
             (and (string-match-p ":MODEL: claude-opus-5" text) t) t))))

(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled t))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-s")))
    (mcp-emacs-remote--tap-runner-event nil (list :kind 'text :text "hello there"))
    (check "runner-text-recorded"
           (and (string-match-p "assistant :: hello there" (remote--transcript-text)) t)
           t)))

;; A tool call reuses the existing tool-call recorder, so runner tool calls
;; and IDE-surface tool calls render identically in the transcript.
(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled t))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-s")))
    (mcp-emacs-remote--tap-runner-event
     nil (list :kind 'tool-use :name "mcp__emacs__apply_diff"
               :input '((path . "/tmp/x"))))
    (let ((text (remote--transcript-text)))
      (check "runner-tool-heading"
             (and (string-match-p "🔧 mcp__emacs__apply_diff" text) t) t)
      (check "runner-tool-args"
             (and (string-match-p "/tmp/x" text) t) t))))

(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled t))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-s")))
    (mcp-emacs-remote--tap-runner-event
     nil (list :kind 'tool-result :text "Status: applied\nnew\n"))
    (check "runner-result-first-line"
           (and (string-match-p "result :: Status: applied" (remote--transcript-text)) t)
           t)))

(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled t))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-s")))
    (mcp-emacs-remote--tap-runner-event nil (list :kind 'finished :subtype "success"))
    (check "runner-finished"
           (and (string-match-p "runner success" (remote--transcript-text)) t) t)))

;; Recording is off by default: the subscriber must stay silent (and create
;; no transcript buffer) unless the feature is enabled.
(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled nil))
  (mcp-emacs-remote--tap-runner-event nil (list :kind 'text :text "should not appear"))
  (check "runner-disabled-silent" (remote--transcript-text) nil))

;; The human's own writes land in the same transcript, on the same channel
;; as the runner's events -- one shared record, not two.
(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled t))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-s")))
    (mcp-emacs-remote--tap-runner-event
     nil (list :kind 'note :text "check the error path" :pending t))
    (check "runner-note-recorded"
           (and (string-match-p "human :: check the error path"
                                (remote--transcript-text))
                t)
           t)))

(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled t))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-s")))
    (mcp-emacs-remote--tap-runner-event
     nil (list :kind 'notes-delivered :notes '("a" "b")))
    (check "runner-notes-delivered-recorded"
           (and (string-match-p "carried 2 note" (remote--transcript-text)) t) t)))

;; An unknown event kind is ignored rather than guessed at, so adding a new
;; kind to the runner cannot produce a malformed transcript entry.
(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled t))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-s")))
    (mcp-emacs-remote--tap-runner-event nil (list :kind 'brand-new-kind :text "x"))
    (check "runner-unknown-kind-ignored" (remote--transcript-text) nil)))

;; A failure inside the transcript must never propagate into the runner.
(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled t))
  (cl-letf (((symbol-function 'mcp-emacs-remote--append)
             (lambda (&rest _) (error "boom"))))
    (check "runner-error-swallowed"
           (condition-case _
               (progn (mcp-emacs-remote--tap-runner-event
                       nil (list :kind 'text :text "x"))
                      t)
             (error nil))
           t)))

;; enable/disable manage hook membership, and both are idempotent.
(let ((agent-backend-event-functions nil))
  (cl-letf (((symbol-function 'advice-add) #'ignore)
            ((symbol-function 'advice-remove) #'ignore))
    (mcp-emacs-remote-enable)
    (check "enable-subscribes"
           (and (memq #'mcp-emacs-remote--tap-runner-event
                      agent-backend-event-functions) t) t)
    (mcp-emacs-remote-enable)
    (check "enable-idempotent"
           (length (seq-filter (lambda (f) (eq f #'mcp-emacs-remote--tap-runner-event))
                               agent-backend-event-functions))
           1)
    (mcp-emacs-remote-disable)
    (check "disable-unsubscribes"
           (memq #'mcp-emacs-remote--tap-runner-event agent-backend-event-functions)
           nil)))

(remote--kill-transcripts)

;; --- Org-task subscriber (issue #39) -----------------------------------------
;;
;; The Org file is the aggregate; these events only observe that it changed.
;; They land in the same transcript as the runner's, so one record shows both
;; the human's Org edits and the AI's activity in the order they happened.

(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled t))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-o")))
    (mcp-emacs-remote--tap-org-task-event
     (list :kind 'session-status :path "/tmp/s.org" :status "STRT"))
    (check "org-session-status-recorded"
           (and (string-match-p "org session :: STRT" (remote--transcript-text)) t) t)))

(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled t))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-o")))
    (mcp-emacs-remote--tap-org-task-event
     (list :kind 'item-status :path "/tmp/s.org" :ref "write tests" :status "DONE"))
    (check "org-item-status-recorded"
           (and (string-match-p "org item :: write tests" (remote--transcript-text)) t) t)))

(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled t))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-o")))
    (mcp-emacs-remote--tap-org-task-event
     (list :kind 'item-added :path "/tmp/s.org" :text "new thing" :status "TODO"))
    (check "org-item-added-recorded"
           (and (string-match-p "org item added :: TODO new thing"
                                (remote--transcript-text)) t) t)))

(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled t))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-o")))
    (mcp-emacs-remote--tap-org-task-event
     (list :kind 'note :path "/tmp/s.org" :text "first line\nsecond"))
    (check "org-note-first-line-only"
           (and (string-match-p "org note :: first line" (remote--transcript-text))
                (not (string-match-p "second" (remote--transcript-text))) t)
           t)))

;; Disabled -> silent, and no transcript buffer created.
(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled nil))
  (mcp-emacs-remote--tap-org-task-event
   (list :kind 'session-status :path "/tmp/s.org" :status "STRT"))
  (check "org-disabled-silent" (remote--transcript-text) nil))

;; Unknown kinds are ignored rather than guessed at.
(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled t))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-o")))
    (mcp-emacs-remote--tap-org-task-event (list :kind 'brand-new :path "/tmp/s.org"))
    (check "org-unknown-kind-ignored" (remote--transcript-text) nil)))

;; A transcript failure must never break the Org write being observed.
(remote--kill-transcripts)
(let ((mcp-emacs-remote-enabled t))
  (cl-letf (((symbol-function 'mcp-emacs-remote--append)
             (lambda (&rest _) (error "boom"))))
    (check "org-error-swallowed"
           (condition-case _
               (progn (mcp-emacs-remote--tap-org-task-event
                       (list :kind 'note :path "/tmp/s.org" :text "x"))
                      t)
             (error nil))
           t)))

;; enable/disable manage the org-task hook too.
(let ((mcp-emacs-org-task-event-functions nil)
      (agent-backend-event-functions nil))
  (cl-letf (((symbol-function 'advice-add) #'ignore)
            ((symbol-function 'advice-remove) #'ignore))
    (mcp-emacs-remote-enable)
    (check "org-enable-subscribes"
           (and (memq #'mcp-emacs-remote--tap-org-task-event
                      mcp-emacs-org-task-event-functions) t) t)
    (mcp-emacs-remote-disable)
    (check "org-disable-unsubscribes"
           (memq #'mcp-emacs-remote--tap-org-task-event
                 mcp-emacs-org-task-event-functions)
           nil)))

(remote--kill-transcripts)
