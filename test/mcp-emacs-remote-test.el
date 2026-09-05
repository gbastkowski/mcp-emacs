;;; mcp-emacs-remote-test.el --- Tests for the remote transcript tap -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
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

;; The hook variables the taps subscribe to are owned by `agent-backend' and
;; `mcp-emacs'; the remote module only forward-declares them, and a valueless
;; `defvar' marks a symbol special just inside its own file.  Requiring the
;; owners gets the real defvars, so a `let' below rebinds the same variable
;; `add-hook' writes -- without them the test binds a lexical local and reads
;; nil back.  Neither owner pulls in websocket.el or web-server, which is why
;; these can be required where the two modules above are stubbed.
(require 'agent-backend)
(require 'mcp-emacs)

(defun remote--kill-transcripts ()
  (dolist (b (buffer-list))
    (when (string-prefix-p "*claude: " (buffer-name b))
      (let ((kill-buffer-query-functions nil)) (kill-buffer b)))))

;; --- 5.1 Prompt input --------------------------------------------------------

(describe "mcp-emacs-remote--send"
  (let ((sent nil))
    (cl-letf (((symbol-function 'mcp-emacs-run-send-prompt) (lambda (tx) (setq sent tx))))
      (it "rejects an empty prompt"
        (check (condition-case _ (progn (mcp-emacs-remote--send "") nil) (user-error t)) t))
      (it "rejects a whitespace-only prompt"
        (check (condition-case _ (progn (mcp-emacs-remote--send "  \n ") nil) (user-error t)) t))
      (it "sends nothing when the prompt is rejected"
        (check sent nil))))

  (let ((sent nil))
    (cl-letf (((symbol-function 'mcp-emacs-run-send-prompt) (lambda (tx) (setq sent tx))))
      (mcp-emacs-remote--send "hello claude")
      (it "delivers a non-empty prompt via send-prompt"
        (check sent "hello claude")))))

(describe "mcp-emacs-remote-prompt-buffer"
  (let ((sent nil))
    (cl-letf (((symbol-function 'mcp-emacs-run-send-prompt) (lambda (tx) (setq sent tx))))
      (with-temp-buffer
        (it "rejects an empty buffer"
          (check (condition-case _ (progn (mcp-emacs-remote-prompt-buffer) nil) (user-error t)) t)))
      (it "sends nothing when the buffer is empty"
        (check sent nil))
      (with-temp-buffer
        (insert "line one\nline two\n")
        (mcp-emacs-remote-prompt-buffer))
      (it "delivers the whole buffer text"
        (check sent "line one\nline two\n")))))

;; --- 5.2 Transcript: one buffer per project, tool call recorded --------------

(remote--kill-transcripts)
(describe "mcp-emacs-remote-record-tool-call"
  (let ((mcp-emacs-remote-enabled t))
    (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-alpha")))
      (mcp-emacs-remote-record-tool-call "openDiff" '((tab_name . "t1")))
      (mcp-emacs-remote-record-tool-call "openDiff" '((tab_name . "t2"))))
    (let ((buf (get-buffer "*claude: proj-alpha*")))
      (it "creates a transcript buffer named after the project"
        (check-that buf))
      (it "reuses one buffer per project across calls"
        (check (length (seq-filter (lambda (b) (string-prefix-p "*claude: " (buffer-name b)))
                                   (buffer-list)))
               1))
      (with-current-buffer buf
        (it "records the tool name as a heading"
          (check-that (string-match-p "🔧 openDiff" (buffer-string))))
        (it "records the tool arguments as a json block"
          (check-that (string-match-p "begin_src json" (buffer-string)))))))

  (let ((mcp-emacs-remote-enabled t))
    (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-beta")))
      (mcp-emacs-remote-record-tool-call "openDiff" '((tab_name . "x"))))
    (it "gives distinct projects distinct transcript buffers"
      (check-that (and (get-buffer "*claude: proj-alpha*")
                       (get-buffer "*claude: proj-beta*")))))

  (progn
    (remote--kill-transcripts)
    (let ((mcp-emacs-remote-enabled t))
      (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-q")))
        (mcp-emacs-remote-record-tool-call "getDiagnostics" '()))
      (with-current-buffer (get-buffer "*claude: proj-q*")
        (it "notes a quiet tool compactly instead of as a heading"
          (check-that (and (not (string-match-p "🔧 getDiagnostics" (buffer-string)))
                           (string-match-p "getDiagnostics" (buffer-string)))))))))

;; --- 5.3 Diff outcome --------------------------------------------------------

(remote--kill-transcripts)
(describe "mcp-emacs-remote-record-diff-outcome"
  (let ((mcp-emacs-remote-enabled t))
    (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-d")))
      (mcp-emacs-remote-record-diff-outcome "tab-A" "FILE_SAVED" "new content")
      (mcp-emacs-remote-record-diff-outcome "tab-B" "DIFF_REJECTED" "tab-B"))
    (with-current-buffer (get-buffer "*claude: proj-d*")
      (let ((s (buffer-string)))
        (it "records a saved diff as accepted, naming the tab"
          (check-that (string-match-p "openDiff accepted :: tab-A" s)))
        (it "records a rejected diff as rejected, naming the tab"
          (check-that (string-match-p "openDiff rejected :: tab-B" s)))))))

;; --- 5.4 Passive safety ------------------------------------------------------

(remote--kill-transcripts)
(describe "mcp-emacs-remote--tap-call-tool"
  (let ((mcp-emacs-remote-enabled nil))
    (mcp-emacs-remote--tap-call-tool nil "openDiff" '((tab_name . "z")) 1)
    (it "records nothing while recording is disabled"
      (check (seq-find (lambda (b) (string-prefix-p "*claude: " (buffer-name b))) (buffer-list))
             nil)))

  (progn
    (remote--kill-transcripts)
    (let ((mcp-emacs-remote-enabled t))
      (cl-letf (((symbol-function 'mcp-emacs-remote--append)
                 (lambda (&rest _) (error "boom"))))
        (it "swallows a rendering failure while recording a tool call"
          (check (condition-case _ (progn (mcp-emacs-remote-record-tool-call "openDiff" '()) t)
                   (error nil))
                 t))
        (it "swallows a rendering failure while recording a diff outcome"
          (check (condition-case _ (progn (mcp-emacs-remote-record-diff-outcome "t" "FILE_SAVED") t)
                   (error nil))
                 t)))))

  (let ((mcp-emacs-remote-enabled t))
    (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-r")))
      (it "returns nil so it cannot alter the wrapped call's return value"
        (check (mcp-emacs-remote--tap-call-tool nil "getDiagnostics" '() 1) nil)))))

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

(remote--kill-transcripts)
(describe "mcp-emacs-remote--tap-runner-event"
  (let ((mcp-emacs-remote-enabled t))
    (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-s")))
      (mcp-emacs-remote--tap-runner-event
       nil (list :kind 'started :session "abc-123" :model "claude-opus-5"))
      (let ((text (remote--transcript-text)))
        (it "opens a Runner heading when the runner starts"
          (check-that (string-match-p "^\\* Runner" text)))
        (it "records the session id of a started runner"
          (check-that (string-match-p ":SESSION: abc-123" text)))
        (it "records the model of a started runner"
          (check-that (string-match-p ":MODEL: claude-opus-5" text))))))

  (progn
    (remote--kill-transcripts)
    (let ((mcp-emacs-remote-enabled t))
      (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-s")))
        (mcp-emacs-remote--tap-runner-event nil (list :kind 'text :text "hello there"))
        (it "records assistant text on the assistant channel"
          (check-that (string-match-p "assistant :: hello there" (remote--transcript-text)))))))

  ;; A tool call reuses the existing tool-call recorder, so runner tool calls
  ;; and IDE-surface tool calls render identically in the transcript.
  (progn
    (remote--kill-transcripts)
    (let ((mcp-emacs-remote-enabled t))
      (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-s")))
        (mcp-emacs-remote--tap-runner-event
         nil (list :kind 'tool-use :name "mcp__emacs__apply_diff"
                   :input '((path . "/tmp/x"))))
        (let ((text (remote--transcript-text)))
          (it "renders a runner tool call with the same heading as an IDE tool call"
            (check-that (string-match-p "🔧 mcp__emacs__apply_diff" text)))
          (it "records the runner tool call's input arguments"
            (check-that (string-match-p "/tmp/x" text)))))))

  (progn
    (remote--kill-transcripts)
    (let ((mcp-emacs-remote-enabled t))
      (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-s")))
        (mcp-emacs-remote--tap-runner-event
         nil (list :kind 'tool-result :text "Status: applied\nnew\n"))
        (it "records only the first line of a tool result"
          (check-that (string-match-p "result :: Status: applied"
                                      (remote--transcript-text)))))))

  (progn
    (remote--kill-transcripts)
    (let ((mcp-emacs-remote-enabled t))
      (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-s")))
        (mcp-emacs-remote--tap-runner-event nil (list :kind 'finished :subtype "success"))
        (it "records how the runner finished"
          (check-that (string-match-p "runner success" (remote--transcript-text)))))))

  ;; Recording is off by default: the subscriber must stay silent (and create
  ;; no transcript buffer) unless the feature is enabled.
  (progn
    (remote--kill-transcripts)
    (let ((mcp-emacs-remote-enabled nil))
      (mcp-emacs-remote--tap-runner-event nil (list :kind 'text :text "should not appear"))
      (it "stays silent and creates no transcript while disabled"
        (check (remote--transcript-text) nil))))

  ;; The human's own writes land in the same transcript, on the same channel
  ;; as the runner's events -- one shared record, not two.
  (progn
    (remote--kill-transcripts)
    (let ((mcp-emacs-remote-enabled t))
      (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-s")))
        (mcp-emacs-remote--tap-runner-event
         nil (list :kind 'note :text "check the error path" :pending t))
        (it "records a human note in the same transcript as the runner's events"
          (check-that (string-match-p "human :: check the error path"
                                      (remote--transcript-text)))))))

  (progn
    (remote--kill-transcripts)
    (let ((mcp-emacs-remote-enabled t))
      (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-s")))
        (mcp-emacs-remote--tap-runner-event
         nil (list :kind 'notes-delivered :notes '("a" "b")))
        (it "records how many notes were carried into the turn"
          (check-that (string-match-p "carried 2 note" (remote--transcript-text)))))))

  ;; An unknown event kind is ignored rather than guessed at, so adding a new
  ;; kind to the runner cannot produce a malformed transcript entry.
  (progn
    (remote--kill-transcripts)
    (let ((mcp-emacs-remote-enabled t))
      (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-s")))
        (mcp-emacs-remote--tap-runner-event nil (list :kind 'brand-new-kind :text "x"))
        (it "ignores an unknown event kind rather than guessing at it"
          (check (remote--transcript-text) nil)))))

  (progn
    (remote--kill-transcripts)
    (let ((mcp-emacs-remote-enabled t))
      (cl-letf (((symbol-function 'mcp-emacs-remote--append)
                 (lambda (&rest _) (error "boom"))))
        (it "never propagates a transcript failure into the runner"
          (check (condition-case _
                     (progn (mcp-emacs-remote--tap-runner-event
                             nil (list :kind 'text :text "x"))
                            t)
                   (error nil))
                 t))))))

(describe "mcp-emacs-remote-enable and mcp-emacs-remote-disable"
  (let ((agent-backend-event-functions nil))
    (cl-letf (((symbol-function 'advice-add) #'ignore)
              ((symbol-function 'advice-remove) #'ignore))
      (mcp-emacs-remote-enable)
      (it "subscribes the runner tap to the event hook"
        (check-that (memq #'mcp-emacs-remote--tap-runner-event
                          agent-backend-event-functions)))
      (mcp-emacs-remote-enable)
      (it "keeps a single runner subscription when enabled twice"
        (check (length (seq-filter (lambda (f) (eq f #'mcp-emacs-remote--tap-runner-event))
                                   agent-backend-event-functions))
               1))
      (mcp-emacs-remote-disable)
      (it "unsubscribes the runner tap again"
        (check (memq #'mcp-emacs-remote--tap-runner-event agent-backend-event-functions)
               nil)))))

(remote--kill-transcripts)

;; --- Org-task subscriber (issue #39) -----------------------------------------
;;
;; The Org file is the aggregate; these events only observe that it changed.
;; They land in the same transcript as the runner's, so one record shows both
;; the human's Org edits and the AI's activity in the order they happened.

(remote--kill-transcripts)
(describe "mcp-emacs-remote--tap-org-task-event"
  (let ((mcp-emacs-remote-enabled t))
    (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-o")))
      (mcp-emacs-remote--tap-org-task-event
       (list :kind 'session-status :path "/tmp/s.org" :status "STRT"))
      (it "records an Org session status change"
        (check-that (string-match-p "org session :: STRT" (remote--transcript-text))))))

  (progn
    (remote--kill-transcripts)
    (let ((mcp-emacs-remote-enabled t))
      (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-o")))
        (mcp-emacs-remote--tap-org-task-event
         (list :kind 'item-status :path "/tmp/s.org" :ref "write tests" :status "DONE"))
        (it "records an Org item status change, naming the item"
          (check-that (string-match-p "org item :: write tests"
                                      (remote--transcript-text)))))))

  (progn
    (remote--kill-transcripts)
    (let ((mcp-emacs-remote-enabled t))
      (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-o")))
        (mcp-emacs-remote--tap-org-task-event
         (list :kind 'item-added :path "/tmp/s.org" :text "new thing" :status "TODO"))
        (it "records a newly added Org item with its keyword and text"
          (check-that (string-match-p "org item added :: TODO new thing"
                                      (remote--transcript-text)))))))

  (progn
    (remote--kill-transcripts)
    (let ((mcp-emacs-remote-enabled t))
      (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-o")))
        (mcp-emacs-remote--tap-org-task-event
         (list :kind 'note :path "/tmp/s.org" :text "first line\nsecond"))
        (it "records only the first line of a multi-line Org note"
          (check-that (and (string-match-p "org note :: first line" (remote--transcript-text))
                           (not (string-match-p "second" (remote--transcript-text)))))))))

  (progn
    (remote--kill-transcripts)
    (let ((mcp-emacs-remote-enabled nil))
      (mcp-emacs-remote--tap-org-task-event
       (list :kind 'session-status :path "/tmp/s.org" :status "STRT"))
      (it "stays silent and creates no transcript while disabled"
        (check (remote--transcript-text) nil))))

  (progn
    (remote--kill-transcripts)
    (let ((mcp-emacs-remote-enabled t))
      (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/proj-o")))
        (mcp-emacs-remote--tap-org-task-event (list :kind 'brand-new :path "/tmp/s.org"))
        (it "ignores an unknown Org event kind rather than guessing at it"
          (check (remote--transcript-text) nil)))))

  (progn
    (remote--kill-transcripts)
    (let ((mcp-emacs-remote-enabled t))
      (cl-letf (((symbol-function 'mcp-emacs-remote--append)
                 (lambda (&rest _) (error "boom"))))
        (it "never lets a transcript failure break the Org write being observed"
          (check (condition-case _
                     (progn (mcp-emacs-remote--tap-org-task-event
                             (list :kind 'note :path "/tmp/s.org" :text "x"))
                            t)
                   (error nil))
                 t))))))

(describe "mcp-emacs-remote-enable and mcp-emacs-remote-disable for org-task events"
  (let ((mcp-emacs-org-task-event-functions nil)
        (agent-backend-event-functions nil))
    (cl-letf (((symbol-function 'advice-add) #'ignore)
              ((symbol-function 'advice-remove) #'ignore))
      (mcp-emacs-remote-enable)
      (it "subscribes the org-task tap to the org-task event hook"
        (check-that (memq #'mcp-emacs-remote--tap-org-task-event
                          mcp-emacs-org-task-event-functions)))
      (mcp-emacs-remote-disable)
      (it "unsubscribes the org-task tap again"
        (check (memq #'mcp-emacs-remote--tap-org-task-event
                     mcp-emacs-org-task-event-functions)
               nil)))))

(remote--kill-transcripts)

(test-helper-summary)

;;; mcp-emacs-remote-test.el ends here
