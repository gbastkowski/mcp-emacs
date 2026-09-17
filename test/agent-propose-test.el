;;; agent-propose-test.el --- Tests for the editable draft review -*- lexical-binding: t; -*-

;; Batch tests for `agent-propose.el' and the propose_text helpers' two
;; layers: the editable review buffer with its single-answer registry, and
;; the async/sync helpers in `mcp-emacs.el' that raise it.  No HTTP: the
;; buffer is raised and answered directly, which is the same path the MCP
;; tool takes.
;;
;; One trap worth naming, because it cost a debugging round: never wait on
;; a timeout with `sleep-for'.  It does not run timers, so the deadline
;; never fires and the expectation passes while checking nothing.  A fixed
;; `sit-for' is not enough either -- resolution takes two timer rounds, and
;; batch is less generous than a daemon -- so wait on the condition with
;; `agent-propose-test--wait-for'.

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'cl-lib)
(require 'mcp-emacs)
(require 'agent-propose)

(defun agent-propose-test--reset ()
  "Drop any proposal left pending by an earlier expectation."
  (dolist (id (agent-propose-pending-ids))
    (agent-propose--resolve id 'reject))
  (setq agent-propose--pending nil))

(defun agent-propose-test--wait-for (predicate &optional seconds)
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

;; The propose buffer's body text, for assertions that read a review back.
(defun agent-propose-test--text (buffer-name)
  "Return the plain text of the review buffer named BUFFER-NAME."
  (with-current-buffer buffer-name
    (buffer-substring-no-properties (point-min) (point-max))))

;;;; Raising and answering the review buffer

(describe "raising a proposal"
  (agent-propose-test--reset)
  (let ((answers nil))
    (agent-propose-request
     "prop-1" "Fix the thing\n" :label "commit message"
     :resolve (lambda (a) (push a answers)))
    (it "registers the proposal as pending"
      (check (agent-propose-pending-ids) '("prop-1")))
    (it "shows the proposed text in the buffer"
      (check (agent-propose-test--text "*agent-propose: prop-1*")
             "Fix the thing\n"))
    (it "leaves the body editable, since a draft exists to be changed"
      (check (with-current-buffer "*agent-propose: prop-1*" buffer-read-only)
             nil))
    (it "names the proposal in the header line"
      (check-that (string-match-p
                   "commit message"
                   (with-current-buffer "*agent-propose: prop-1*"
                     (format "%s" header-line-format)))))
    (agent-propose-test--reset)))

(describe "answering a proposal"
  (agent-propose-test--reset)
  (let ((answers nil))
    (agent-propose-request
     "prop-accept" "draft\n" :resolve (lambda (a) (push a answers)))
    (with-current-buffer "*agent-propose: prop-accept*" (agent-propose-accept))
    (agent-propose-test--wait-for (lambda () answers))
    (it "resolves an accepted proposal with the text exactly as given"
      (check (car answers) "draft\n"))
    (it "kills the buffer once answered"
      (check (get-buffer "*agent-propose: prop-accept*") nil)))
  (agent-propose-test--reset)
  (let ((answers nil))
    (agent-propose-request
     "prop-edit" "old draft\n" :resolve (lambda (a) (push a answers)))
    (with-current-buffer "*agent-propose: prop-edit*"
      (erase-buffer) (insert "the human's version\n"))
    (with-current-buffer "*agent-propose: prop-edit*" (agent-propose-accept))
    (agent-propose-test--wait-for (lambda () answers))
    (it "resolves an edited and accepted proposal with the edited text"
      (check (car answers) "the human's version\n")))
  (agent-propose-test--reset)
  (let ((answers nil))
    (agent-propose-request
     "prop-deny" "draft\n" :resolve (lambda (a) (push a answers)))
    (with-current-buffer "*agent-propose: prop-deny*" (agent-propose-reject))
    (agent-propose-test--wait-for (lambda () answers))
    (it "resolves a rejected proposal as `reject'"
      (check (car answers) 'reject)))
  (agent-propose-test--reset))

(describe "a proposal is answered exactly once"
  ;; Whoever is waiting is blocked until the answer arrives, so a second
  ;; resolution would answer a call that already happened.
  (agent-propose-test--reset)
  (let* ((answers nil)
         (_ (agent-propose-request
             "prop-once" "draft\n" :resolve (lambda (a) (push a answers))))
         (first (agent-propose--resolve "prop-once" "first answer\n"))
         (second (agent-propose--resolve "prop-once" 'reject)))
    (agent-propose-test--wait-for (lambda () answers))
    (it "reports the first answer as the one that resolved it"
      (check first t))
    (it "reports a second answer as having resolved nothing"
      (check second nil))
    (it "delivers only the first answer"
      (check answers '("first answer\n"))))
  (agent-propose-test--reset))

(describe "an unanswered proposal denies itself"
  (agent-propose-test--reset)
  (let ((answers nil))
    (agent-propose-request
     "prop-timeout" "draft\n" :timeout 1
     :resolve (lambda (a) (push a answers)))
    (agent-propose-test--wait-for (lambda () answers))
    (it "answers `timeout' rather than waiting forever"
      (check (car answers) 'timeout))
    (it "answers `timeout', a status distinct from `reject'"
      (check-that (not (eq (car answers) 'reject))))
    (it "leaves nothing pending"
      (check (agent-propose-pending-ids) nil)))
  (agent-propose-test--reset))

(describe "raising the same id twice"
  (agent-propose-test--reset)
  (agent-propose-request "prop-dup" "one\n")
  (it "signals rather than leaving two callers waiting on one answer"
    (check-that (condition-case nil
                    (progn (agent-propose-request "prop-dup" "two\n") nil)
                  (error t))))
  (agent-propose-test--reset))

;;;; The propose_text helpers (async/sync)

;; `mcp-emacs-propose-text-async' must return immediately and answer later
;; via ON-DONE: blocking here is exactly the bug the async shape exists to
;; avoid.  These tests stub `agent-propose-request' the way the apply-diff
;; tests stub `mcp-emacs--ediff-review': capture the resolve continuation
;; and the options the helper passed, and fire the continuation by hand.

(defmacro agent-propose-test--with-stub (bindings &rest body)
  "Run BODY with `agent-propose-request' stubbed for a helper test.
BINDINGS is a list of (VAR . INIT) forms evaluated before the stub is
installed.  Inside BODY, `resolve' calls the captured :resolve closure
with one argument, `stub-id' is the registry id the helper passed,
`stub-text' the proposed text, and `stub-opts' the OPTIONS plist."
  (declare (indent 1))
  `(let* ((stub-id nil) (stub-text nil) (stub-opts nil) (stub-resolve nil)
          ,@bindings)
     (cl-letf (((symbol-function 'agent-propose-request)
                (lambda (id text &rest options)
                  (setq stub-id id
                        stub-text text
                        stub-opts options
                        stub-resolve (plist-get options :resolve))
                  nil)))
       (cl-flet ((resolve (answer)
                   (when stub-resolve (funcall stub-resolve answer))))
         ,@body))))

(describe "mcp-emacs-propose-text-async"
  ;; Returns immediately instead of blocking until a human answer.
  (let ((calls nil))
    (agent-propose-test--with-stub ()
      (let ((ret (mcp-emacs-propose-text-async
                  "draft\n" "commit message" 60
                  (lambda (out) (push out calls)))))
        (it "returns immediately instead of blocking until an answer"
          (check ret nil))
        (it "does not invoke the callback before the human answers"
          (check calls nil)))))

  ;; The final text is what comes back: unchanged on a plain accept...
  (let ((calls nil))
    (agent-propose-test--with-stub ()
      (mcp-emacs-propose-text-async
       "draft\n" nil 60 (lambda (out) (push out calls)))
      (resolve "draft\n")
      (it "answers with the accepted text"
        (check (car calls) "draft\n"))))

  ;; ...and edited on an edit-and-accept, never the original proposal.
  (let ((calls nil))
    (agent-propose-test--with-stub ()
      (mcp-emacs-propose-text-async
       "draft\n" nil 60 (lambda (out) (push out calls)))
      (resolve "the human changed this\n")
      (it "answers with the edited text, not the original proposal"
        (check (car calls) "the human changed this\n"))))

  ;; A rejection reports as such.
  (let ((calls nil))
    (agent-propose-test--with-stub ()
      (mcp-emacs-propose-text-async
       "draft\n" nil 60 (lambda (out) (push out calls)))
      (resolve 'reject)
      (it "reports a rejected status"
        (check (car calls) "Status: rejected"))))

  ;; A timeout reports a status of its own, distinct from rejected.
  (let ((calls nil))
    (agent-propose-test--with-stub ()
      (mcp-emacs-propose-text-async
       "draft\n" nil 60 (lambda (out) (push out calls)))
      (resolve 'timeout)
      (it "reports a timeout status, distinct from rejected"
        (check (car calls) "Status: timeout"))))

  ;; Single delivery: a second resolution after the first is a no-op.
  (let ((calls nil))
    (agent-propose-test--with-stub ()
      (mcp-emacs-propose-text-async
       "draft\n" nil 60 (lambda (out) (push out calls)))
      (resolve "first\n")
      (resolve 'reject)
      (it "delivers one answer even when the proposal resolves twice"
        (check (length calls) 1))
      (it "keeps the first answer, not the second"
        (check (car calls) "first\n"))))

  ;; The timeout asked of the registry is capped and defaulted.
  (agent-propose-test--with-stub ()
    (mcp-emacs-propose-text-async "draft\n" nil 999999 (lambda (_) nil))
    (it "caps the timeout at the configured maximum"
      (check (plist-get stub-opts :timeout)
             mcp-emacs-propose-text-max-timeout)))
  (agent-propose-test--with-stub ()
    (mcp-emacs-propose-text-async "draft\n" nil nil (lambda (_) nil))
    (it "defaults the timeout when the call omits it"
      (check (plist-get stub-opts :timeout)
             mcp-emacs-propose-text-default-timeout)))
  (agent-propose-test--with-stub ()
    (mcp-emacs-propose-text-async "draft\n" nil 5 (lambda (_) nil))
    (it "passes an explicit timeout through as given"
      (check (plist-get stub-opts :timeout) 5)))

  ;; The label and the text reach the review buffer.
  (agent-propose-test--with-stub ()
    (mcp-emacs-propose-text-async "draft\n" "MR description" 60
                                  (lambda (_) nil))
    (it "passes the label through to the review buffer"
      (check (plist-get stub-opts :label) "MR description"))
    (it "passes the proposed text through to the review buffer"
      (check stub-text "draft\n")))

  ;; Each call raises its own registry id, so concurrent proposals cannot
  ;; collide in `agent-propose--pending'.
  (let ((ids nil))
    (agent-propose-test--with-stub ()
      (mcp-emacs-propose-text-async "one\n" nil 60 (lambda (_) nil))
      (push stub-id ids)
      (mcp-emacs-propose-text-async "two\n" nil 60 (lambda (_) nil))
      (push stub-id ids)
      (it "gives each call its own registry id"
        (check (equal (car ids) (cadr ids)) nil)))))

(describe "mcp-emacs-propose-text under a process filter"
  ;; The synchronous variant must refuse to run under a process filter.  A
  ;; filter has no command loop to deliver the human's edits and keys to
  ;; the review buffer, and Emacs binds `inhibit-quit' to t there -- the
  ;; review would display with dead keys and freeze Emacs until the
  ;; timeout.  Failing fast is what makes that a bug report instead of a
  ;; hung editor.
  (let ((err (let ((inhibit-quit t))
               (condition-case e
                   (progn (mcp-emacs-propose-text "draft\n" nil 60) nil)
                 (error e)))))
    (it "signals rather than hanging with a review nobody can answer"
      (check-that (and err t)))
    (it "names the async variant so the caller knows the way out"
      (check-that (string-match-p "async" (format "%S" err))))))

(describe "mcp-emacs-propose-text synchronous wait"
  ;; The sync variant delegates to the async one and waits on the result
  ;; cell.  Stub the async to answer inline, so the outcome is deterministic
  ;; without sleeping: the poll loop sees the cell filled on its first
  ;; check.
  (cl-letf (((symbol-function 'mcp-emacs-propose-text-async)
             (lambda (_text _label _timeout on-done)
               (funcall on-done "the answer"))))
    (it "returns the async outcome as its own"
      (check (mcp-emacs-propose-text "draft\n" nil 60) "the answer"))))

(test-helper-summary)
;;; agent-propose-test.el ends here