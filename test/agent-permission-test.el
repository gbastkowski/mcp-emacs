;;; agent-permission-test.el --- Tests for the permission gate -*- lexical-binding: t; -*-

;; Batch tests for `agent-permission.el' and the gate's two ends: the
;; server endpoint that raises a decision, and the rule writer behind
;; "always allow".  No CLI and no HTTP: decisions are raised and resolved
;; directly, which is the same path the endpoint and opencode both take.
;;
;; One trap worth naming, because it cost a debugging round: never wait on
;; a timeout with `sleep-for'.  It does not run timers, so the deadline
;; never fires and the expectation passes while checking nothing.  A fixed
;; `sit-for' is not enough either -- resolution takes two timer rounds, and
;; batch is less generous than a daemon -- so wait on the condition with
;; `agent-permission-test--wait-for'..

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'cl-lib)
(require 'json)
(require 'agent-permission)

(defun agent-permission-test--reset ()
  "Drop any decision left pending by an earlier expectation."
  (dolist (id (agent-permission-pending-ids))
    (agent-permission--resolve id 'deny "test cleanup"))
  (setq agent-permission--pending nil))

(defun agent-permission-test--tempdir ()
  "Return a fresh directory for a settings-file expectation."
  (file-name-as-directory (make-temp-file "agent-permission-test" t)))

;;;; Raising and answering

(describe "raising a permission decision"
  (agent-permission-test--reset)
  (let ((answers nil))
    (agent-permission-request
     "req-1" "Bash" '((command . "echo hello") (description . "Say hello"))
     :cwd "/tmp"
     :resolve (lambda (d r) (push (cons d r) answers)))
    (it "registers the decision as pending"
      (check (agent-permission-pending-ids) '("req-1")))
    (it "shows the tool and the command the human is judging"
      (check (with-current-buffer "*agent-permission: req-1*"
               (buffer-substring-no-properties (point-min) (point-max)))
             "Bash\nin /tmp\n\necho hello\n\n(Say hello)\n"))
    (it "makes the buffer read-only, since a decision is a choice not text"
      (check (with-current-buffer "*agent-permission: req-1*" buffer-read-only) t))
    (agent-permission-test--reset)))

(describe "answering a decision"
  (agent-permission-test--reset)
  (let ((answers nil))
    (agent-permission-request
     "req-allow" "Bash" '((command . "ls"))
     :resolve (lambda (d _r) (push d answers)))
    (with-current-buffer "*agent-permission: req-allow*" (agent-permission-allow))
    (sit-for 0.2)
    (it "delivers `allow' when the human allows"
      (check answers '(allow)))
    (it "kills the buffer once answered"
      (check (get-buffer "*agent-permission: req-allow*") nil)))
  (agent-permission-test--reset)
  (let ((answers nil))
    (agent-permission-request
     "req-deny" "Bash" '((command . "rm -rf /"))
     :resolve (lambda (d _r) (push d answers)))
    (with-current-buffer "*agent-permission: req-deny*" (agent-permission-deny))
    (sit-for 0.2)
    (it "delivers `deny' when the human denies"
      (check answers '(deny))))
  (agent-permission-test--reset))

(describe "a decision is answered exactly once"
  ;; Whoever is waiting is blocked until the answer arrives, so a second
  ;; resolution would answer a call that already happened.
  (agent-permission-test--reset)
  (let* ((answers nil)
         (_ (agent-permission-request
             "req-once" "Bash" '((command . "ls"))
             :resolve (lambda (d _r) (push d answers))))
         (first (agent-permission--resolve "req-once" 'deny "first"))
         (second (agent-permission--resolve "req-once" 'allow "second")))
    (sit-for 0.2)
    (it "reports the first answer as the one that resolved it"
      (check first t))
    (it "reports a second answer as having resolved nothing"
      (check second nil))
    (it "delivers only the first answer"
      (check answers '(deny))))
  (agent-permission-test--reset))

(defun agent-permission-test--wait-for (predicate &optional seconds)
  "Yield until PREDICATE returns non-nil, or SECONDS elapse.
Resolution takes two timer rounds -- the deadline fires, and the
continuation it schedules runs -- and a fixed `sit-for' is only reliably
long enough for both under a daemon, not in batch.  So wait on the
condition rather than on the clock.

`sleep-for' would be wrong here whatever the duration: it does not run
timers at all, so the deadline never fires and the expectation passes
while checking nothing."
  (let ((deadline (+ (float-time) (or seconds 5))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (sit-for 0.05))
    (funcall predicate)))

(describe "an unanswered decision denies itself"
  (agent-permission-test--reset)
  (let ((answers nil))
    (agent-permission-request
     "req-timeout" "Bash" '((command . "sleep 1"))
     :timeout 1
     :resolve (lambda (d r) (push (cons d r) answers)))
    (agent-permission-test--wait-for (lambda () answers))
    (it "answers `timeout' rather than waiting forever"
      (check (car (car answers)) 'timeout))
    (it "says in the reason that nobody answered"
      (check-that (string-match-p "No answer within" (or (cdr (car answers)) ""))))
    (it "leaves nothing pending"
      (check (agent-permission-pending-ids) nil)))
  (agent-permission-test--reset))

(describe "raising the same id twice"
  (agent-permission-test--reset)
  (agent-permission-request "req-dup" "Bash" '((command . "ls")))
  (it "signals rather than leaving two callers waiting on one answer"
    (check-that (condition-case nil
                    (progn (agent-permission-request "req-dup" "Bash" nil) nil)
                  (error t))))
  (agent-permission-test--reset))

;;;; Rendering

(describe "rendering a tool input"
  (it "shows a shell command as the command itself"
    (check (agent-permission--format-input '((command . "git status")))
           "git status"))
  (it "shows a non-shell input as its key/value pairs"
    (check (agent-permission--format-input '((file_path . "/tmp/x")))
           "file_path: /tmp/x"))
  (it "says so when there is no input at all"
    (check (agent-permission--format-input nil) "(no input)"))
  (it "elides an input too long to read, and says how much it dropped"
    (let* ((long (make-string 5000 ?x))
           (shown (agent-permission--elide long)))
      (check-that (and (< (length shown) 5000)
                       (string-match-p "characters elided" shown))))))

;;;; Rules

(describe "proposing a rule from a call"
  ;; The exact form is the default because the prefix form's `*' reaches
  ;; past `&&' into a second command: `Bash(echo *)' matches
  ;; `echo hi && rm -rf ...'.  Measured against the CLI, not assumed.
  (let ((input '((command . "bin/test-emacs.sh --quiet"))))
    (it "proposes the exact command, which cannot match anything else"
      (check (agent-permission-rule-exact "Bash" input)
             "Bash(bin/test-emacs.sh --quiet)"))
    (it "proposes a first-word prefix as the broader alternative"
      (check (agent-permission-rule-prefix "Bash" input)
             "Bash(bin/test-emacs.sh *)")))
  (let ((input '((file_path . "/tmp/x"))))
    (it "falls back to the bare tool name when there is no command"
      (check (agent-permission-rule-exact "Read" input) "Read"))
    (it "offers no prefix rule when there is no command to take one from"
      (check (agent-permission-rule-prefix "Read" input) nil))))

(describe "writing a rule to the settings file"
  (let* ((dir (agent-permission-test--tempdir))
         (path (expand-file-name ".claude/settings.local.json" dir)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path
      (insert (json-encode
               '((permissions . ((allow . ["Bash(git status)"])
                                 (deny . [])
                                 (ask . [])))
                 (enabledMcpjsonServers . ["emacs"])))))
    (agent-permission-add-rule "Bash(echo hi)" path)
    (let* ((json-object-type 'alist)
           (json-array-type 'list)
           (json-key-type 'symbol)
           (written (with-temp-buffer (insert-file-contents path)
                                      (json-read-from-string (buffer-string))))
           (allow (alist-get 'allow (alist-get 'permissions written))))
      (it "keeps the rules that were already there"
        (check-that (member "Bash(git status)" allow)))
      (it "adds the new rule"
        (check-that (member "Bash(echo hi)" allow)))
      (it "leaves settings it does not own alone"
        (check (append (alist-get 'enabledMcpjsonServers written) nil)
               '("emacs")))
      ;; An empty JSON array parses to nil and re-encodes as `null'.  This
      ;; file is shared with the terminal CLI, so writing "deny": null back
      ;; into it would corrupt someone else's settings.
      (it "writes empty lists back as arrays rather than null"
        (check-that (string-match-p "\"deny\":\\[\\]"
                                    (with-temp-buffer (insert-file-contents path)
                                                      (buffer-string))))))
    (it "adds nothing when the rule is already present"
      (let ((before (with-temp-buffer (insert-file-contents path) (buffer-string))))
        (agent-permission-add-rule "Bash(echo hi)" path)
        (check (with-temp-buffer (insert-file-contents path) (buffer-string))
               before)))))

(describe "writing a rule where no settings file exists yet"
  (let* ((dir (agent-permission-test--tempdir))
         (path (expand-file-name ".claude/settings.local.json" dir)))
    (agent-permission-add-rule "Bash(ls *)" path)
    (it "creates the file with just that rule"
      (let* ((json-object-type 'alist)
             (json-array-type 'list)
             (json-key-type 'symbol)
             (written (with-temp-buffer (insert-file-contents path)
                                        (json-read-from-string (buffer-string)))))
        (check (alist-get 'allow (alist-get 'permissions written))
               '("Bash(ls *)"))))))

(test-helper-summary)
;;; agent-permission-test.el ends here
