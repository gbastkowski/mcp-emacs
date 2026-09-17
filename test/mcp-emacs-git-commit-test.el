;;; mcp-emacs-git-commit-test.el --- Tests for the magit commit dialog tool -*- lexical-binding: t; -*-

;; The `git_commit' tool defers to a human the way `apply_diff' does: it
;; opens magit's commit dialog with a proposed message and answers from
;; magit's finish/abort hooks instead of from the process filter (which
;; would leave no command loop for the dialog).  magit and with-editor
;; are soft dependencies absent from the batch test Emacs, so these
;; suites stub the magit surface -- the same technique the apply-diff
;; tests use for `ediff-buffers' -- and then drive the dialog lifecycle
;; by hand: the guard paths (magit absent, empty index) run with the
;; stubs doing nothing, and the resolve paths run the with-editor hooks
;; exactly the way the real with-editor code runs them.

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'cl-lib)
(require 'eieio)
(require 'mcp-emacs)
;; `mcp-emacs-server' hard-requires web-server, which is usually absent
;; in batch.  Satisfy the require with a stub feature before loading it;
;; these tests only read the tool registry, never open a socket.
(unless (require 'web-server nil t)
  (defun ws-response-header (&rest _) nil)
  (defun ws-start (&rest _) nil)
  (defun ws-stop (&rest _) nil)
  (defclass ws-server () ((requests :initarg :requests :accessor ws-requests
                                    :initform nil)))
  (defclass ws-request () ((process :initarg :process :accessor ws-process
                                    :initform nil)))
  (provide 'web-server))
(require 'mcp-emacs-server)

(defmacro mcp--with-git-commit-magit (magit-p staged &rest body)
  "Run BODY with the magit commit surface stubbed.
MAGIT-P controls whether `(require 'magit)' looks up (nil = absent);
STAGED is the staged-file list `magit-git-lines' reports for the index.
Inside BODY:
- `head-sha' is the SHA `magit-rev-parse' reports for HEAD (setq it to
  change what confirmation would observe);
- `commit-calls' counts calls to `magit-commit-create' (the only thing
  that launches `git commit');
- `commit-buffer' is a live fake of the commit-message buffer;
- `commit-buffer-fn' controls what `magit-commit-message-buffer'
  returns (setq it to stage a concurrent with-editor session);
- `visit' runs the with-editor visit in COMMIT-BUFFER (this is where the
  real with-editor runs `with-editor-filter-visit-hook': prefill plus
  installation of the buffer-local resolve hooks);
- `finish' and `abort' run that buffer's `with-editor-post-finish-hook'
  and `with-editor-post-cancel-hook'."
  (declare (indent 2))
  `(let* ((orig-require (symbol-function 'require))
          (head-sha "old-head")
          (commit-calls 0)
          (commit-buffer (generate-new-buffer " *fake-commit*"))
          (commit-buffer-fn
           (lambda ()
             (if (buffer-live-p commit-buffer) commit-buffer nil)))
          (visit (lambda ()
                   (when (buffer-live-p commit-buffer)
                     (with-current-buffer commit-buffer
                       (run-hooks 'with-editor-filter-visit-hook)))))
          (finish (lambda ()
                    (when (buffer-live-p commit-buffer)
                      (with-current-buffer commit-buffer
                        (run-hooks 'with-editor-post-finish-hook)))))
          (abort (lambda ()
                   (when (buffer-live-p commit-buffer)
                     (with-current-buffer commit-buffer
                       (run-hooks 'with-editor-post-cancel-hook))))))
     (unwind-protect
         (cl-letf (((symbol-function 'require)
                    (lambda (feature &optional file no-error)
                      (if (eq feature 'magit)
                          (if ,magit-p t (error "magit is not installed"))
                        (funcall orig-require feature file no-error))))
                   ((symbol-function 'magit-git-lines)
                    (lambda (&rest _args) ,staged))
                   ((symbol-function 'magit-rev-parse)
                    (lambda (&rest _args) head-sha))
                   ((symbol-function 'magit-commit-message-buffer)
                    (lambda () (funcall commit-buffer-fn)))
                   ((symbol-function 'magit-commit-create)
                    (lambda (&optional _args)
                      (setq commit-calls (1+ commit-calls)))))
           ,@body)
       (when (buffer-live-p commit-buffer)
         (kill-buffer commit-buffer)))))

;;;; Guard: magit absent

;; The tool must refuse with a clear status instead of signalling -- a
;; human cannot answer an error -- and must do so without touching any
;; magit symbol (which would fall over on undefined functions in a
;; magit-less session).  The `require' stub below makes magit look
;; absent even though the helper's own guard runs in production too.
(describe "mcp-emacs-git-commit-async without magit"
  (mcp--with-git-commit-magit nil '("staged.txt")
    (let ((calls nil))
      (let ((ret (mcp-emacs-git-commit-async
                  "proposed message" 60 (lambda (out) (push out calls)))))
        (it "returns immediately instead of blocking"
          (check ret nil))
        (it "does not open a commit dialog"
          (check commit-calls 0))
        (it "answers exactly once"
          (check (length calls) 1))
        (it "reports that magit is unavailable, not a made-up result"
          (check (car calls) "Status: magit unavailable"))))))

;;;; Guard: empty index

;; Committing is the human's call on what gets included: the tool
;; commits only what is already staged, so an empty index is a refusal,
;; never an attempt to stage or to open a dialog.
(describe "mcp-emacs-git-commit-async with an empty index"
  (mcp--with-git-commit-magit t nil
    (let ((calls nil))
      (let ((ret (mcp-emacs-git-commit-async
                  "proposed message" 60 (lambda (out) (push out calls)))))
        (it "returns immediately instead of blocking"
          (check ret nil))
        (it "answers exactly once"
          (check (length calls) 1))
        (it "refuses with a nothing-staged status"
          (check (car calls) "Status: nothing staged"))
        (it "does not open the commit dialog"
          (check commit-calls 0))))))

;;;; Tool registration

(describe "the git_commit tool registration"
  (let* ((tool (mcp-emacs-server--find-tool "git_commit"))
         (schema (plist-get tool :schema))
         (props (cdr (assoc "properties" schema)))
         (required (cdr (assoc "required" schema))))
    (it "is registered under the git_commit name"
      (check (and tool (equal (plist-get tool :name) "git_commit")) t))
    (it "requires the message argument"
      (check (seq-position required "message") 0))
    (it "types message as a string"
      (check (cdr (assoc "type" (cdr (assoc "message" props)))) "string"))
    (it "offers an integer timeout defaulting like apply_diff"
      (check (cdr (assoc "type" (cdr (assoc "timeout" props)))) "integer"))
    (it "carries an async handler for the human-answered deferral"
      (check-that (functionp (plist-get tool :async-handler))))
    (it "keeps a synchronous handler for direct dispatch"
      (check-that (functionp (plist-get tool :handler))))))

;; The async handler must route through `mcp-emacs-git-commit-async':
;; calling it defers the answer (nothing yet), opens the dialog, and
;; resolves through the helper once the human acts.
(describe "the git_commit tool's async handler"
  (mcp--with-git-commit-magit t '("staged.txt")
    (let ((tool (mcp-emacs-server--find-tool "git_commit"))
          (calls nil))
      (funcall (plist-get tool :async-handler)
               (list (cons 'message "proposed message")
                     (cons 'timeout 60))
               (lambda (out) (push out calls)))
      (it "defers: does not answer synchronously"
        (check calls nil))
      (it "opens the commit dialog"
        (check commit-calls 1))
      (funcall visit)
      (funcall abort)
      (it "resolves through the helper once the human acts"
        (check (length calls) 1))
      (it "reports the helper's abort outcome"
        (check (car calls) "Status: aborted")))))

;;;; Abort fails closed

;; An abort must answer "Status: aborted" and must never run a commit
;; behind the human's back: `magit-commit-create' -- the only thing that
;; launches `git commit' -- is stubbed to just count, so a cancelled
;; dialog leaving that count unchanged proves no commit was attempted.
(describe "aborting the commit dialog fails closed"
  (mcp--with-git-commit-magit t '("staged.txt")
    (let ((calls nil))
      (mcp-emacs-git-commit-async
       "proposed message" 60 (lambda (out) (push out calls)))
      (funcall visit)
      (funcall abort)
      (it "prefilled the proposal into the commit buffer"
        (check (with-current-buffer commit-buffer (buffer-string))
               "proposed message"))
      (it "reports the abort, not a commit"
        (check (car calls) "Status: aborted"))
      (it "answers exactly once"
        (check (length calls) 1))
      (it "runs no commit command on abort"
        (check commit-calls 1)))))

;;;; Confirmation returns the new SHA

;; `with-editor-finish' signals git and the commit object is created
;; asynchronously a moment later, so the helper reads HEAD after a short
;; beat; a HEAD different from the pre-dialog one is the new SHA.
(describe "confirming the commit reports the new SHA"
  (mcp--with-git-commit-magit t '("staged.txt")
    (let ((calls nil))
      (mcp-emacs-git-commit-async
       "proposed message" 60 (lambda (out) (push out calls)))
      (funcall visit)
      (setq head-sha "new-head-sha")
      (funcall finish)
      (sleep-for 1)
      (it "answers exactly once on confirmation"
        (check (length calls) 1))
      (it "reports committed with the new commit's SHA"
        (check (car calls) "Status: committed\nnew-head-sha")))))

;;;; Single delivery

;; The finish hook and the abort hook (and the timeout timer) race;
;; whichever resolves first must be the only answer.  Firing finish then
;; abort must deliver exactly one answer, and the pending SHA read and
;; timeout timer are cancelled once that answer is in.
(describe "the commit dialog resolving twice"
  (mcp--with-git-commit-magit t '("staged.txt")
    (let ((calls nil)
          (timers (length timer-list)))
      (mcp-emacs-git-commit-async
       "proposed message" 60 (lambda (out) (push out calls)))
      (funcall visit)
      (it "prefills the commit buffer with the proposal"
        (check (with-current-buffer commit-buffer (buffer-string))
               "proposed message"))
      (it "arms a timeout timer while the dialog waits"
        (check (> (length timer-list) timers) t))
      (funcall finish)
      (funcall abort)
      (it "answers exactly once when finish and abort both fire"
        (check (length calls) 1))
      (it "answers with the abort, not the pending confirmation"
        (check (car calls) "Status: aborted"))
      (it "cancels the pending timers once resolved"
        (check (length timer-list) timers)))))

;;;; Timeout

;; A human who never shows up must not leave the request hanging: the
;; timeout answers "Status: timeout" exactly once and ignores anything
;; that tries to resolve afterwards.
(describe "a timeout on the commit dialog"
  (mcp--with-git-commit-magit t '("staged.txt")
    (let ((calls nil) late-cancel)
      (mcp-emacs-git-commit-async
       "proposed message" 1 (lambda (out) (push out calls)))
      (it "has not answered while the dialog is still open"
        (check calls nil))
      (funcall visit)
      ;; Keep a handle on the abort resolve so a human deciding late can
      ;; be driven after the timeout has already claimed the request.
      (setq late-cancel
            (car (buffer-local-value 'with-editor-post-cancel-hook
                                     commit-buffer)))
      (sleep-for 2)
      (it "reports a timeout status when nobody resolves"
        (check (car calls) "Status: timeout"))
      (it "answers exactly once on timeout"
        (check (length calls) 1))
      (when (functionp late-cancel)
        (funcall late-cancel))
      (it "ignores a late resolve after the timeout"
        (check (length calls) 1)))))

;;;; Prefill scoping

;; The prefill hook runs for every with-editor session, so it must
;; recognize which buffer is this call's commit buffer and leave any
;; concurrent session untouched; only then is the proposal inserted.
(describe "prefilling stays scoped to this call's commit buffer"
  (mcp--with-git-commit-magit t '("staged.txt")
    (let ((calls nil)
          (decoy (generate-new-buffer " *decoy-commit*")))
      (unwind-protect
          (progn
            (mcp-emacs-git-commit-async
             "proposed message" 60 (lambda (out) (push out calls)))
            ;; A concurrent with-editor session (another repo, another
            ;; tool) visits a different buffer: the hook must recognize
            ;; it is not this dialog and leave it alone.
            (setq commit-buffer-fn (lambda () nil))
            (with-current-buffer decoy
              (run-hooks 'with-editor-filter-visit-hook))
            (it "does not touch an unrelated with-editor buffer"
              (check (with-current-buffer decoy (buffer-string)) ""))
            (it "still has not answered"
              (check calls nil))
            ;; This call's dialog then shows up and is the one prefilled.
            (setq commit-buffer-fn (lambda () commit-buffer))
            (funcall visit)
            (it "prefills only this call's commit buffer"
              (check (with-current-buffer commit-buffer (buffer-string))
                     "proposed message")))
        (when (buffer-live-p decoy)
          (kill-buffer decoy))))))

;;;; Synchronous variant

;; `mcp-emacs-git-commit' blocks waiting for the human, which needs a
;; command loop; a process filter has none (Emacs binds `inhibit-quit'
;; to t there), so it must signal and name the async way out rather
;; than hang an editor with a dialog nobody can answer.
(describe "mcp-emacs-git-commit under a process filter"
  (let ((err (let ((inhibit-quit t))
               (condition-case e
                   (progn (mcp-emacs-git-commit "proposed message" 60) nil)
                 (error e)))))
    (it "signals rather than hanging with a dialog nobody can answer"
      (check-that (and err t)))
    (it "names the async variant so the caller knows the way out"
      (check-that (string-match-p "async" (format "%S" err))))))

(test-helper-summary)

;;; mcp-emacs-git-commit-test.el ends here