;;; agent-session-overview-test.el --- Tests for the session overview -*- lexical-binding: t; -*-

;; Batch tests for the cross-backend session list.  The load-bearing
;; logic is enumeration (a buffer-name scan across three different naming
;; schemes, one of which carries no project) and state classification
;; (which must not report a state more precisely than its backend can
;; observe).  Both are pure functions of buffer names and buffer-local
;; state, so they test without a live CLI or server.

(add-to-list 'load-path (expand-file-name "elisp"))
(require 'cl-lib)
(require 'agent-session-overview)

(defvar failures 0)
(defun check (l g w)
  (unless (equal g w) (setq failures (1+ failures)))
  (princ (format "%s %s: got=%S want=%S\n" (if (equal g w) "PASS" "FAIL") l g w)))

(defmacro with-session-buffers (names &rest body)
  "Create buffers NAMES, run BODY, then kill them."
  (declare (indent 1))
  `(let ((bufs (mapcar #'get-buffer-create ,names)))
     (unwind-protect (progn ,@body)
       (mapc #'kill-buffer bufs))))

(defun entry-for (name)
  "Return the overview entry whose session buffer is named NAME."
  (seq-find (lambda (e) (equal (buffer-name (plist-get e :buffer)) name))
            (agent-session-overview--sessions)))

;;;; Enumeration

;; All three naming schemes are recognised, and each row knows its backend.
(with-session-buffers '("*claude-client:mcp-emacs:1*"
                        "*claude:rdm-core:1*"
                        "*opencode:some-title*")
  (check "claude-client recognised"
         (plist-get (entry-for "*claude-client:mcp-emacs:1*") :label) "claude")
  (check "eat recognised"
         (plist-get (entry-for "*claude:rdm-core:1*") :label) "eat")
  (check "opencode recognised"
         (plist-get (entry-for "*opencode:some-title*") :label) "opencode")
  (check "all three listed together"
         (length (agent-session-overview--sessions)) 3))

;; Project and session identity come out of the buffer name where it
;; carries them.
(with-session-buffers '("*claude-client:mcp-emacs:2*")
  (let ((e (entry-for "*claude-client:mcp-emacs:2*")))
    (check "project from name" (plist-get e :project) "mcp-emacs")
    (check "session from name" (plist-get e :session) "mcp-emacs:2")))

;; Two conversations in one project stay distinguishable -- the session
;; number is what separates them.
(with-session-buffers '("*claude-client:mcp-emacs:1*" "*claude-client:mcp-emacs:2*")
  (let ((sessions (mapcar (lambda (e) (plist-get e :session))
                          (agent-session-overview--sessions))))
    (check "two rows in one project" (length sessions) 2)
    (check "sessions distinguishable" (equal (nth 0 sessions) (nth 1 sessions)) nil)))

;; Opencode names buffers by title, so its project falls back to the
;; buffer's own directory rather than being parsed out of the name.
(with-session-buffers '("*opencode:my-chat*")
  (with-current-buffer "*opencode:my-chat*"
    (setq-local default-directory "/tmp/some-project/"))
  (let ((e (entry-for "*opencode:my-chat*")))
    (check "opencode project from directory" (plist-get e :project) "some-project")
    (check "opencode session is its title" (plist-get e :session) "my-chat")))

;; Unrelated buffers are not sessions.
(with-session-buffers '("*scratch-not-a-session*" "*claude-ish*")
  (check "no false positives" (length (agent-session-overview--sessions)) 0))

;; A session buffer whose name predates the `:<project>:<n>' scheme --
;; plain `*claude-client*' -- is still a live session and must be listed.
;; Found in a real Emacs, where exactly such a buffer was being missed.
(with-session-buffers '("*claude-client*")
  (with-current-buffer "*claude-client*"
    (setq major-mode 'claude-client-mode)
    (setq-local claude-client--turn-active nil)
    (setq-local claude-client--process nil))
  (cl-letf (((symbol-function 'claude-client-mode) #'ignore))
    (let ((e (entry-for "*claude-client*")))
      (check "unnumbered session is listed" (and e t) t)
      (check "unnumbered session backend" (plist-get e :label) "claude")
      (check "unnumbered session identity" (plist-get e :session) "*claude-client*")
      (check "unnumbered session state" (plist-get e :state) 'finished))))

;; Mode matching must not drag in a buffer that merely sets some
;; claude-client variable without being a conversation.
(with-session-buffers '("*not-a-conversation*")
  (with-current-buffer "*not-a-conversation*"
    (setq-local claude-client--turn-active t))
  (check "mode match needs the mode" (entry-for "*not-a-conversation*") nil))

;; Nothing live at all.
(check "no sessions when none exist" (agent-session-overview--sessions) nil)

;;;; State classification

;; claude-client reports working / idle / finished from its own state.
(with-session-buffers '("*claude-client:p:1*")
  (with-current-buffer "*claude-client:p:1*"
    (setq-local claude-client--turn-active t)
    (setq-local claude-client--process nil))
  (check "mid-turn is working"
         (plist-get (entry-for "*claude-client:p:1*") :state) 'working))

(with-session-buffers '("*claude-client:p:1*")
  (with-current-buffer "*claude-client:p:1*"
    (setq-local claude-client--turn-active nil)
    (setq-local claude-client--process nil))
  (check "exited is finished"
         (plist-get (entry-for "*claude-client:p:1*") :state) 'finished))

;; A live process with no turn running is idle, not finished.  The
;; process here is a real one so `process-live-p' has something true to
;; say without a CLI.
(with-session-buffers '("*claude-client:p:1*")
  (let ((proc (start-process "overview-test-idle" nil "sleep" "30")))
    (unwind-protect
        (progn
          (with-current-buffer "*claude-client:p:1*"
            (setq-local claude-client--turn-active nil)
            (setq-local claude-client--process proc))
          (check "live process between turns is idle"
                 (plist-get (entry-for "*claude-client:p:1*") :state) 'idle))
      (delete-process proc))))

;; The eat runner and opencode report liveness only -- never a turn
;; state, because neither publishes one.
(with-session-buffers '("*claude:p:1*" "*opencode:t*")
  (check "eat with no process is dead"
         (plist-get (entry-for "*claude:p:1*") :state) 'dead)
  (check "opencode with no process is dead"
         (plist-get (entry-for "*opencode:t*") :state) 'dead)
  (check "eat never reports working"
         (memq (plist-get (entry-for "*claude:p:1*") :state) '(working idle)) nil)
  (check "opencode never reports working"
         (memq (plist-get (entry-for "*opencode:t*") :state) '(working idle)) nil))

;; A turn-active flag left in an eat buffer must not promote it: eat's
;; classifier reads the process, not stray buffer-local state.
(with-session-buffers '("*claude:p:1*")
  (with-current-buffer "*claude:p:1*"
    (setq-local claude-client--turn-active t))
  (check "eat ignores a turn flag"
         (plist-get (entry-for "*claude:p:1*") :state) 'dead))

;;;; Rendering and the event subscriber

;; Rows render as the four displayed columns.
(with-session-buffers '("*claude-client:mcp-emacs:1*")
  (let ((row (cadr (car (agent-session-overview--entries)))))
    (check "row is 4 columns" (length row) 4)
    (check "row backend column" (aref row 0) "claude")
    (check "row state column" (aref row 3) "finished")))

;; The subscriber must not let a render failure escape into the session
;; that published the event.
(cl-letf (((symbol-function 'agent-session-overview--render)
           (lambda () (error "boom"))))
  (check "render error is contained"
         (progn (agent-session-overview--on-event nil '(:kind started)) 'survived)
         'survived))

;; Irrelevant kinds do not trigger a render at all.
(let ((rendered 0))
  (cl-letf (((symbol-function 'agent-session-overview--render)
             (lambda () (setq rendered (1+ rendered)))))
    (agent-session-overview--on-event nil '(:kind text))
    (check "text does not re-render" rendered 0)
    (agent-session-overview--on-event nil '(:kind finished))
    (check "finished re-renders" rendered 1)
    (agent-session-overview--on-event nil '(:kind some-future-kind))
    (check "unknown kind ignored" rendered 1)))

;;;; Actions

;; Interrupting a session that is not mid-turn is refused rather than
;; attempted.
(with-session-buffers '("*claude-client:p:1*")
  (with-current-buffer "*claude-client:p:1*"
    (setq-local claude-client--turn-active nil)
    (setq-local claude-client--process nil))
  (let ((entry (entry-for "*claude-client:p:1*")))
    (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () entry)))
      (check "interrupt refuses when idle"
             (condition-case err
                 (progn (agent-session-overview-interrupt-session) 'no-error)
               (user-error (error-message-string err)))
             "No turn is running for this session"))))

;; A row whose buffer has been killed is reported, not chased.
(let ((entry (list :buffer (generate-new-buffer "*overview-dead*")
                   :backend 'claude-client :state 'idle)))
  (kill-buffer (plist-get entry :buffer))
  (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () entry)))
    ;; `user-error' curls the apostrophe, so match on substance not glyph.
    (check "dead buffer is reported"
           (condition-case err
               (progn (agent-session-overview-visit) 'no-error)
             (user-error (and (string-match-p "buffer is gone"
                                             (error-message-string err))
                              'reported)))
           'reported)))

(princ (format "\n%s\n" (if (zerop failures) "ALL PASS" (format "%d FAILURE(S)" failures))))
(kill-emacs (if (zerop failures) 0 1))
;;; agent-session-overview-test.el ends here
