;;; agent-session-overview-test.el --- Tests for the session overview -*- lexical-binding: t; -*-

;; Batch tests for the cross-backend session list.  The load-bearing
;; logic is enumeration (a buffer-name scan across three different naming
;; schemes, one of which carries no project) and state classification
;; (which must not report a state more precisely than its backend can
;; observe).  Both are pure functions of buffer names and buffer-local
;; state, so they test without a live CLI or server.

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'cl-lib)
(require 'agent-session-overview)

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

(describe "agent-session-overview--sessions across naming schemes"
  (with-session-buffers '("*claude-client:mcp-emacs:1*"
                          "*claude:rdm-core:1*"
                          "*opencode:some-title*")
    (it "recognises a claude-client buffer as the claude backend"
      (check (plist-get (entry-for "*claude-client:mcp-emacs:1*") :label) "claude"))
    (it "recognises an eat runner buffer as the eat backend"
      (check (plist-get (entry-for "*claude:rdm-core:1*") :label) "eat"))
    (it "recognises an opencode buffer as the opencode backend"
      (check (plist-get (entry-for "*opencode:some-title*") :label) "opencode"))
    (it "lists all three naming schemes together"
      (check (length (agent-session-overview--sessions)) 3))))

(describe "agent-session-overview--sessions identity from the buffer name"
  (with-session-buffers '("*claude-client:mcp-emacs:2*")
    (let ((e (entry-for "*claude-client:mcp-emacs:2*")))
      (it "takes the project out of the buffer name"
        (check (plist-get e :project) "mcp-emacs"))
      (it "takes the session out of the buffer name"
        (check (plist-get e :session) "mcp-emacs:2"))))

  ;; Two conversations in one project stay distinguishable -- the session
  ;; number is what separates them.
  (with-session-buffers '("*claude-client:mcp-emacs:1*" "*claude-client:mcp-emacs:2*")
    (let ((sessions (mapcar (lambda (e) (plist-get e :session))
                            (agent-session-overview--sessions))))
      (it "lists two rows for two conversations in one project"
        (check (length sessions) 2))
      (it "keeps the two sessions in one project distinguishable by number"
        (check (equal (nth 0 sessions) (nth 1 sessions)) nil))))

  ;; Opencode names buffers by title, so its project falls back to the
  ;; buffer's own directory rather than being parsed out of the name.
  (with-session-buffers '("*opencode:my-chat*")
    (with-current-buffer "*opencode:my-chat*"
      (setq-local default-directory "/tmp/some-project/"))
    (let ((e (entry-for "*opencode:my-chat*")))
      (it "falls back to the buffer's directory for an opencode project"
        (check (plist-get e :project) "some-project"))
      (it "uses the title as the session for opencode"
        (check (plist-get e :session) "my-chat")))))

(describe "agent-session-overview--sessions rejecting non-sessions"
  (with-session-buffers '("*scratch-not-a-session*" "*claude-ish*")
    (it "does not mistake a similarly named buffer for a session"
      (check (length (agent-session-overview--sessions)) 0)))

  ;; Mode matching must not drag in a buffer that merely sets some
  ;; claude-client variable without being a conversation.
  (with-session-buffers '("*not-a-conversation*")
    (with-current-buffer "*not-a-conversation*"
      (setq-local claude-client--turn-active t))
    (it "needs the major mode, not just a claude-client variable"
      (check (entry-for "*not-a-conversation*") nil)))

  (it "returns nothing when no session is live"
    (check (agent-session-overview--sessions) nil)))

;; A session buffer whose name predates the `:<project>:<n>' scheme --
;; plain `*claude-client*' -- is still a live session and must be listed.
;; Found in a real Emacs, where exactly such a buffer was being missed.
(describe "agent-session-overview--sessions with an unnumbered buffer name"
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
        (it "lists a session whose name predates the numbering scheme"
          (check-that e))
        (it "still identifies its backend"
          (check (plist-get e :label) "claude"))
        (it "uses the whole buffer name as the session"
          (check (plist-get e :session) "*claude-client*"))
        (it "still classifies its state"
          (check (plist-get e :state) 'finished))))))

;;;; State classification

(describe "agent-session-overview state for claude-client"
  (with-session-buffers '("*claude-client:p:1*")
    (with-current-buffer "*claude-client:p:1*"
      (setq-local claude-client--turn-active t)
      (setq-local claude-client--process nil))
    (it "reports working while a turn is running"
      (check (plist-get (entry-for "*claude-client:p:1*") :state) 'working)))

  (with-session-buffers '("*claude-client:p:1*")
    (with-current-buffer "*claude-client:p:1*"
      (setq-local claude-client--turn-active nil)
      (setq-local claude-client--process nil))
    (it "reports finished once the process is gone"
      (check (plist-get (entry-for "*claude-client:p:1*") :state) 'finished)))

  ;; The process here is a real one so `process-live-p' has something true
  ;; to say without a CLI.
  (with-session-buffers '("*claude-client:p:1*")
    (let ((proc (start-process "overview-test-idle" nil "sleep" "30")))
      (unwind-protect
          (progn
            (with-current-buffer "*claude-client:p:1*"
              (setq-local claude-client--turn-active nil)
              (setq-local claude-client--process proc))
            (it "reports idle, not finished, for a live process between turns"
              (check (plist-get (entry-for "*claude-client:p:1*") :state) 'idle)))
        (delete-process proc)))))

;; The eat runner and opencode report liveness only -- never a turn
;; state, because neither publishes one.
(describe "agent-session-overview state for liveness-only backends"
  (with-session-buffers '("*claude:p:1*" "*opencode:t*")
    (it "reports an eat session with no process as dead"
      (check (plist-get (entry-for "*claude:p:1*") :state) 'dead))
    (it "reports an opencode session with no process as dead"
      (check (plist-get (entry-for "*opencode:t*") :state) 'dead))
    (it "never reports a turn state for eat"
      (check (memq (plist-get (entry-for "*claude:p:1*") :state) '(working idle)) nil))
    (it "never reports a turn state for opencode"
      (check (memq (plist-get (entry-for "*opencode:t*") :state) '(working idle)) nil)))

  ;; A turn-active flag left in an eat buffer must not promote it: eat's
  ;; classifier reads the process, not stray buffer-local state.
  (with-session-buffers '("*claude:p:1*")
    (with-current-buffer "*claude:p:1*"
      (setq-local claude-client--turn-active t))
    (it "ignores a stray turn flag in an eat buffer"
      (check (plist-get (entry-for "*claude:p:1*") :state) 'dead))))

;;;; Rendering and the event subscriber

(describe "agent-session-overview--entries"
  (with-session-buffers '("*claude-client:mcp-emacs:1*")
    (let ((row (cadr (car (agent-session-overview--entries)))))
      (it "renders a row as the four displayed columns"
        (check (length row) 4))
      (it "puts the backend in the first column"
        (check (aref row 0) "claude"))
      (it "puts the state in the last column"
        (check (aref row 3) "finished")))))

(describe "agent-session-overview--on-event"
  ;; The subscriber must not let a render failure escape into the session
  ;; that published the event.
  (cl-letf (((symbol-function 'agent-session-overview--render)
             (lambda () (error "boom"))))
    (it "contains a render error instead of raising it into the publisher"
      (check (progn (agent-session-overview--on-event nil '(:kind started)) 'survived)
             'survived)))

  ;; Irrelevant kinds do not trigger a render at all.
  (let ((rendered 0))
    (cl-letf (((symbol-function 'agent-session-overview--render)
               (lambda () (setq rendered (1+ rendered)))))
      (agent-session-overview--on-event nil '(:kind text))
      (it "does not re-render on a text event"
        (check rendered 0))
      (agent-session-overview--on-event nil '(:kind finished))
      (it "re-renders on a finished event"
        (check rendered 1))
      (agent-session-overview--on-event nil '(:kind some-future-kind))
      (it "ignores an unknown event kind"
        (check rendered 1)))))

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

(describe "agent-session-overview-interrupt-session"
  (with-session-buffers '("*claude-client:p:1*")
    (with-current-buffer "*claude-client:p:1*"
      (setq-local claude-client--turn-active nil)
      (setq-local claude-client--process nil))
    (let ((entry (entry-for "*claude-client:p:1*")))
      (with-row-at-point entry
        (it "refuses rather than attempting when no turn is running"
          (check (condition-case err
                     (progn (agent-session-overview-interrupt-session) 'no-error)
                   (user-error (error-message-string err)))
                 "No turn is running for this session"))))))

;; `k' is evil's `evil-previous-line', so an unconfirmed kill here ended
;; sessions the human was only scrolling past.
(describe "agent-session-overview-quit-session"
  (with-session-buffers '("*claude-client:p:2*")
    (with-current-buffer "*claude-client:p:2*"
      (setq-local claude-client--turn-active nil)
      (setq-local claude-client--process nil))
    (let ((entry (entry-for "*claude-client:p:2*")))
      (with-row-at-point entry
        (it "leaves the process alone when the confirmation is declined"
          (check (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
                           ((symbol-function 'claude-client-quit)
                            (lambda (&rest _) (error "should not be reached"))))
                   (condition-case err
                       (progn (agent-session-overview-quit-session) 'no-error)
                     (user-error (error-message-string err))))
                 "Session left running"))
        (it "still quits the session when the confirmation is accepted"
          (check (let ((quit nil))
                   (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                             ((symbol-function 'claude-client-quit)
                              (lambda (&rest _) (setq quit t)))
                             ((symbol-function 'agent-session-overview--render)
                              #'ignore))
                     (agent-session-overview-quit-session)
                     quit))
                 t))))))

(describe "agent-session-overview-visit"
  (let ((entry (list :buffer (generate-new-buffer "*overview-dead*")
                     :backend 'claude-client :state 'idle)))
    (kill-buffer (plist-get entry :buffer))
    (with-row-at-point entry
      ;; `user-error' curls the apostrophe, so match on substance not glyph.
      (it "reports a killed buffer rather than chasing it"
        (check (condition-case err
                   (progn (agent-session-overview-visit) 'no-error)
                 (user-error (and (string-match-p "buffer is gone"
                                                  (error-message-string err))
                                  'reported)))
               'reported)))))

;;;; Help

;; The key hint names every binding, so the list stays the one source of
;; truth for what the buffer can do.
(describe "agent-session-overview--key-hint"
  (let ((terse (agent-session-overview--key-hint))
        (verbose (agent-session-overview--key-hint t)))
    (dolist (binding agent-session-overview--help)
      (it "names every documented key in the terse hint"
        (check-that (string-match-p (regexp-quote (car binding)) terse)
                    (format "names %s in the terse hint" (car binding))))
      (it "describes every documented key in the verbose hint"
        (check-that (string-match-p (regexp-quote (cadr binding)) verbose)
                    (format "describes %s in the verbose hint" (car binding)))))))

;; Every documented key is actually bound -- documenting an action that
;; does nothing is worse than not documenting it.  `g' and `q' come from
;; the parent mode, so look them up through the real keymap.
(describe "agent-session-overview-mode keymap"
  (with-temp-buffer
    (agent-session-overview-mode)
    (dolist (binding agent-session-overview--help)
      (let ((key (car binding)))
        (it "actually binds every key the help documents"
          (check-that (commandp (key-binding (kbd key)))
                      (format "binds %s" key)))))))

(describe "agent-session-overview-help"
  (it "opens a help buffer rather than signalling"
    (check (progn (agent-session-overview-help)
                  (and (get-buffer "*ai-sessions help*") t))
           t))

  ;; The help text explains the per-backend state precision, which is the
  ;; one thing about this buffer that surprises people.
  (with-current-buffer "*ai-sessions help*"
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (it "explains which states claude-client can report"
        (check-that (string-match-p "working / idle / finished" text)))
      (it "explains that other backends report liveness only"
        (check-that (string-match-p "live / dead" text))))))
(kill-buffer "*ai-sessions help*")

;; Issue #59: reading the help used to dismiss the overview behind it,
;; because both buffers matched a popup rule and `q' in the help was
;; Doom's `+popup/quit-window', which tears down the whole popup stack
;; rather than the selected window.  The fix forces the help into an
;; ordinary window split off the overview's own, so `q' is the plain
;; `quit-window' and only the help closes.
;;
;; The bug needs a popup-managing framework to reproduce, and neither
;; `+popup' nor its `q' binding exists in batch -- with stock window
;; handling `with-help-window' already splits plainly, so asserting on
;; the resulting window would pass against the unfixed code and prove
;; nothing.  What the fix actually adds is *precedence*: its placement
;; must beat a matching `display-buffer-alist' entry, since that is how
;; the framework imposes a side window.  So stand in for the framework
;; with a rule that would force one, and require it to lose.
(describe "agent-session-overview-help window placement"
  (let ((overview (get-buffer-create agent-session-overview-buffer-name)))
    (unwind-protect
        (let ((display-buffer-alist
               `((,(regexp-quote agent-session-overview--help-buffer-name)
                  (display-buffer-in-side-window)
                  (side . bottom)))))
          (delete-other-windows)
          (switch-to-buffer overview)
          (let ((overview-window (selected-window)))
            (agent-session-overview-help)
            (let ((help-window (get-buffer-window
                                agent-session-overview--help-buffer-name)))
              (it "gives the help its own live window"
                (check-that (window-live-p help-window)))
              ;; The assertion that fails without the fix: a side window is
              ;; the popup failure mode, and a plain split is what keeps `q'
              ;; from taking the overview with it.
              (it "wins over a display-buffer rule forcing a side window"
                (check (window-parameter help-window 'window-side) nil))
              (it "splits off the overview's window instead of replacing it"
                (check (and (window-live-p overview-window)
                            (eq (window-buffer overview-window) overview))
                       t))
              ;; The point of the issue: closing the help returns you to the
              ;; list instead of taking it down too.
              (quit-window nil help-window)
              (it "leaves the overview standing when the help is quit"
                (check-that (window-live-p (get-buffer-window overview)))))))
      (when (get-buffer agent-session-overview--help-buffer-name)
        (kill-buffer agent-session-overview--help-buffer-name))
      (kill-buffer overview)
      (delete-other-windows))))

;; The column headers keep the header-line, since only tabulated-list
;; aligns them with the data; the hint lives in the mode line and must
;; actually render there.
(describe "agent-session-overview-mode display"
  (with-temp-buffer
    (agent-session-overview-mode)
    (it "keeps the header-line so tabulated-list aligns the columns"
      (check tabulated-list-use-header-line t))
    ;; `format-mode-line' renders to "" in batch (there is no window), so
    ;; assert the construct is installed and that it produces the keys.
    (it "installs the key hint in the mode line"
      (check (and (member '(:eval (agent-session-overview--key-hint)) mode-line-format) t)
             t))
    (let ((hint (substring-no-properties (agent-session-overview--key-hint))))
      (it "renders the keys into the hint text"
        (check (and (string-match-p "RET" hint) (string-match-p "\\?" hint) t) t)))))

;;;; Evil integration

;; Evil's state maps outrank a major mode's keymap, so the single-letter
;; keys must be re-registered per state or they are all dead in a
;; Doom-style config.  Evil is absent in batch, so record what the setup
;; would bind by capturing `evil-define-key*' calls.
(describe "agent-session-overview--setup-evil"
  (let (registered)
    (cl-letf (((symbol-function 'evil-define-key*)
               (lambda (states _map key def &rest _)
                 (push (list states (key-description key) def) registered))))
      (agent-session-overview--setup-evil)
      (let ((keys (mapcar #'cadr registered)))
        (it "re-registers RET for evil"
          (check (and (member "RET" keys) t) t))
        (it "re-registers k for evil"
          (check (and (member "k" keys) t) t))
        (it "re-registers i for evil"
          (check (and (member "i" keys) t) t))
        (it "re-registers ? for evil"
          (check (and (member "?" keys) t) t))
        ;; `g' is already an evil prefix whose `g r' reverts, and `q'
        ;; quits the window -- taking either would break a convention.
        (it "leaves g to evil's own prefix"
          (check (member "g" keys) nil))
        (it "leaves q to evil's window quit"
          (check (member "q" keys) nil)))
      (it "registers every binding for the normal and motion states"
        (check (seq-every-p (lambda (r) (equal (car r) '(normal motion))) registered) t))
      (it "binds only commands"
        (check (seq-every-p (lambda (r) (commandp (nth 2 r))) registered) t))))

  ;; Absent evil, setup must be a silent no-op rather than an error.
  (cl-letf (((symbol-function 'fboundp) (lambda (s) (not (eq s 'evil-define-key*)))))
    (it "is a silent no-op when evil is absent"
      (check (progn (agent-session-overview--setup-evil) 'survived) 'survived))))

(test-helper-summary)

;;; agent-session-overview-test.el ends here
