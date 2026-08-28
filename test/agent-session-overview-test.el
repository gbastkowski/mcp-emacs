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
  ;; The mode only has to be fbound for `--mode-match-p' to consult it, and
  ;; the stub must be a lambda rather than a symbol like #'ignore: Emacs
  ;; 29's `provided-mode-derived-p' treats a symbol-valued function as an
  ;; alias and follows it, so `derived-mode-p' would compare against
  ;; `ignore' and the buffer would not match.  Emacs 30 dropped that branch,
  ;; which is why #'ignore passed locally and failed on CI's 29.4.
  (cl-letf (((symbol-function 'claude-client-mode) (lambda () nil)))
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

(defmacro with-row-at-point (entry &rest body)
  "Run BODY in a buffer whose point sits on a row carrying ENTRY as its id.
`tabulated-list-get-id' is a `defsubst', so a `cl-letf' on its symbol
function is inlined away when this file's callee is byte-compiled and the
stub never fires.  Put the real text property in a real buffer instead,
which is what the compiled and uncompiled paths both read."
  (declare (indent 1))
  `(with-temp-buffer
     (insert (propertize "row\n" 'tabulated-list-id ,entry))
     (goto-char (point-min))
     ,@body))

;; Interrupting a session that is not mid-turn is refused rather than
;; attempted.
(with-session-buffers '("*claude-client:p:1*")
  (with-current-buffer "*claude-client:p:1*"
    (setq-local claude-client--turn-active nil)
    (setq-local claude-client--process nil))
  (let ((entry (entry-for "*claude-client:p:1*")))
    (with-row-at-point entry
      (check "interrupt refuses when idle"
             (condition-case err
                 (progn (agent-session-overview-interrupt-session) 'no-error)
               (user-error (error-message-string err)))
             "No turn is running for this session"))))

;; A row whose buffer has been killed is reported, not chased.
(let ((entry (list :buffer (generate-new-buffer "*overview-dead*")
                   :backend 'claude-client :state 'idle)))
  (kill-buffer (plist-get entry :buffer))
  (with-row-at-point entry
    ;; `user-error' curls the apostrophe, so match on substance not glyph.
    (check "dead buffer is reported"
           (condition-case err
               (progn (agent-session-overview-visit) 'no-error)
             (user-error (and (string-match-p "buffer is gone"
                                             (error-message-string err))
                              'reported)))
           'reported)))

;;;; Help

;; The key hint names every binding, so the list stays the one source of
;; truth for what the buffer can do.
(let ((terse (agent-session-overview--key-hint))
      (verbose (agent-session-overview--key-hint t)))
  (dolist (binding agent-session-overview--help)
    (check (format "hint names %s" (car binding))
           (and (string-match-p (regexp-quote (car binding)) terse) t) t)
    (check (format "verbose hint describes %s" (car binding))
           (and (string-match-p (regexp-quote (cadr binding)) verbose) t) t)))

;; Every documented key is actually bound -- documenting an action that
;; does nothing is worse than not documenting it.  `g' and `q' come from
;; the parent mode, so look them up through the real keymap.
(with-temp-buffer
  (agent-session-overview-mode)
  (dolist (binding agent-session-overview--help)
    (let ((key (car binding)))
      (check (format "%s is bound" key)
             (and (commandp (key-binding (kbd key))) t)
             t))))

;; `?' opens a help buffer rather than signalling.
(check "help renders"
       (progn (agent-session-overview-help)
              (and (get-buffer "*ai-sessions help*") t))
       t)

;; The help text explains the per-backend state precision, which is the
;; one thing about this buffer that surprises people.
(with-current-buffer "*ai-sessions help*"
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (check "help explains claude states"
           (and (string-match-p "working / idle / finished" text) t) t)
    (check "help explains liveness-only backends"
           (and (string-match-p "live / dead" text) t) t)))
(kill-buffer "*ai-sessions help*")

;; The column headers keep the header-line, since only tabulated-list
;; aligns them with the data; the hint lives in the mode line and must
;; actually render there.
(with-temp-buffer
  (agent-session-overview-mode)
  (check "columns keep the header-line" tabulated-list-use-header-line t)
  ;; `format-mode-line' renders to "" in batch (there is no window), so
  ;; assert the construct is installed and that it produces the keys.
  (check "mode line carries the hint"
         (and (member '(:eval (agent-session-overview--key-hint)) mode-line-format) t)
         t)
  (let ((hint (substring-no-properties (agent-session-overview--key-hint))))
    (check "hint renders the keys"
           (and (string-match-p "RET" hint) (string-match-p "\\?" hint) t) t)))

;;;; Evil integration

;; Evil's state maps outrank a major mode's keymap, so the single-letter
;; keys must be re-registered per state or they are all dead in a
;; Doom-style config.  Evil is absent in batch, so record what the setup
;; would bind by capturing `evil-define-key*' calls.
(let (registered)
  (cl-letf (((symbol-function 'evil-define-key*)
             (lambda (states _map key def &rest _)
               (push (list states (key-description key) def) registered))))
    (agent-session-overview--setup-evil)
    (let ((keys (mapcar #'cadr registered)))
      (check "evil gets RET" (and (member "RET" keys) t) t)
      (check "evil gets k" (and (member "k" keys) t) t)
      (check "evil gets i" (and (member "i" keys) t) t)
      (check "evil gets ?" (and (member "?" keys) t) t)
      ;; `g' is already an evil prefix whose `g r' reverts, and `q'
      ;; quits the window -- taking either would break a convention.
      (check "evil keeps g" (member "g" keys) nil)
      (check "evil keeps q" (member "q" keys) nil))
    (check "evil bindings target normal and motion"
           (seq-every-p (lambda (r) (equal (car r) '(normal motion))) registered) t)
    (check "evil bindings are commands"
           (seq-every-p (lambda (r) (commandp (nth 2 r))) registered) t)))

;; Absent evil, setup must be a silent no-op rather than an error.
(cl-letf (((symbol-function 'fboundp) (lambda (s) (not (eq s 'evil-define-key*)))))
  (check "no-op without evil"
         (progn (agent-session-overview--setup-evil) 'survived) 'survived))

(princ (format "\n%s\n" (if (zerop failures) "ALL PASS" (format "%d FAILURE(S)" failures))))
(kill-emacs (if (zerop failures) 0 1))
;;; agent-session-overview-test.el ends here
