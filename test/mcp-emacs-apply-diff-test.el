(add-to-list 'load-path (expand-file-name "elisp"))
(require 'cl-lib)
(require 'mcp-emacs)
(defun check (l g w) (princ (format "%s %s\n" (if (equal g w) "PASS" "FAIL") l)))

(defun mcp--make-session (a-text b-text)
  "Return (buffer-a buffer-b entry-content result) for a fake diff session."
  (let ((buffer-a (generate-new-buffer " *a*"))
        (buffer-b (generate-new-buffer " *b*")))
    (with-current-buffer buffer-a (insert a-text))
    (with-current-buffer buffer-b (insert b-text))
    (list buffer-a buffer-b a-text (list nil))))

(defun mcp--a-text (buffer-a)
  (with-current-buffer buffer-a
    (buffer-substring-no-properties (point-min) (point-max))))

;; 4.1 Accept unchanged -> applied, proposal applied to A.
(let* ((s (mcp--make-session "old\n" "new\n"))
       (a (nth 0 s)) (b (nth 1 s)) (entry (nth 2 s)) (result (nth 3 s)))
  (unwind-protect
      (progn
        (mcp-emacs--apply-diff-accept a b entry result)
        (check "accept-unchanged-status" (car result) 'applied)
        (check "accept-unchanged-content" (mcp--a-text a) "new\n"))
    (kill-buffer a) (kill-buffer b)))

;; 4.2 Reject -> rejected, A unchanged.
(let* ((s (mcp--make-session "old\n" "new\n"))
       (a (nth 0 s)) (b (nth 1 s)) (result (nth 3 s)))
  (unwind-protect
      (progn
        (mcp-emacs--apply-diff-reject result)
        (check "reject-status" (car result) 'rejected)
        (check "reject-content-unchanged" (mcp--a-text a) "old\n"))
    (kill-buffer a) (kill-buffer b)))

;; 4.3 Human edits A then accepts -> applied with the edited content, not B.
(let* ((s (mcp--make-session "old\n" "new\n"))
       (a (nth 0 s)) (b (nth 1 s)) (entry (nth 2 s)) (result (nth 3 s)))
  (unwind-protect
      (progn
        (with-current-buffer a (erase-buffer) (insert "hand-edited\n"))
        (mcp-emacs--apply-diff-accept a b entry result)
        (check "edit-accept-status" (car result) 'applied)
        (check "edit-accept-keeps-edit" (mcp--a-text a) "hand-edited\n"))
    (kill-buffer a) (kill-buffer b)))

;; 4.4 Quit without accepting -> the quit-hook default resolves to rejected.
;; Model the quit hook: on quit, if result is unset, set it to rejected.
(let* ((s (mcp--make-session "old\n" "new\n"))
       (a (nth 0 s)) (b (nth 1 s)) (result (nth 3 s)))
  (unwind-protect
      (progn
        (unless (car result) (setcar result 'rejected)) ; mirrors ediff-quit-hook
        (check "quit-default-rejected" (car result) 'rejected)
        (check "quit-content-unchanged" (mcp--a-text a) "old\n"))
    (kill-buffer a) (kill-buffer b)))

;; Accept must not override a decision already recorded (quit hook is a no-op
;; once set): the hook only defaults when result is still nil.
(let* ((s (mcp--make-session "old\n" "new\n"))
       (a (nth 0 s)) (b (nth 1 s)) (entry (nth 2 s)) (result (nth 3 s)))
  (unwind-protect
      (progn
        (mcp-emacs--apply-diff-accept a b entry result)
        (unless (car result) (setcar result 'rejected)) ; quit hook runs after
        (check "accept-survives-quit-hook" (car result) 'applied))
    (kill-buffer a) (kill-buffer b)))

;;;; Window-layout save/restore (#21)

;; `mcp-emacs--ediff-review' captures the window configuration up front and
;; restores it in the quit hook, for both callers.  Stub `ediff-buffers' so
;; the setup lambda runs (installing the key bindings and quit hook on a fake
;; control buffer) without a real ediff session, then fire the quit hook and
;; assert the layout is put back.
(let* ((buffer-a (generate-new-buffer " *win-a*"))
       (buffer-b (generate-new-buffer " *win-b*"))
       (result (list nil))
       (control (generate-new-buffer " *fake-control*"))
       (restored nil)
       (mcp-emacs-ediff-window-direction 'plain))
  (with-current-buffer buffer-a (insert "old\n"))
  (with-current-buffer buffer-b (insert "new\n"))
  (unwind-protect
      (cl-letf (((symbol-function 'ediff-buffers)
                 (lambda (_a _b setup-hooks &rest _)
                   ;; ediff would bind `ediff-control-buffer' and run the
                   ;; setup hooks; emulate just enough for the setup lambda.
                   (let ((ediff-control-buffer control))
                     (dolist (fn setup-hooks) (funcall fn)))
                   control))
                ((symbol-function 'set-window-configuration)
                 (lambda (&rest _) (setq restored t))))
        (let ((ctl (mcp-emacs--ediff-review buffer-a buffer-b "old\n" result)))
          (check "review-returns-control" ctl control)
          (check "quit-hook-installed"
                 (and (with-current-buffer control ediff-quit-hook) t) t)
          ;; Fire the quit hook (the single quit path).
          (with-current-buffer control (run-hooks 'ediff-quit-hook))
          (check "quit-defaults-rejected" (car result) 'rejected)
          (check "layout-restored-on-quit" restored t)))
    (dolist (b (list buffer-a buffer-b control))
      (when (buffer-live-p b) (kill-buffer b)))))

;; The restore fires exactly once even though the hook could be entered per
;; keypress: a second run with the decision already set must not re-default it.
(let* ((result (list 'applied))
       (restored-count 0)
       (control (generate-new-buffer " *fake-control-2*")))
  (unwind-protect
      (cl-letf (((symbol-function 'set-window-configuration)
                 (lambda (&rest _) (setq restored-count (1+ restored-count)))))
        (with-current-buffer control
          (setq-local ediff-quit-hook
                      (list (lambda ()
                              (unless (car result) (setcar result 'rejected))
                              (ignore-errors (set-window-configuration nil))))))
        (with-current-buffer control (run-hooks 'ediff-quit-hook))
        (check "accept-preserved-through-restore" (car result) 'applied)
        (check "restore-called-once-per-quit" restored-count 1))
    (when (buffer-live-p control) (kill-buffer control))))

;;;; Async apply-diff (deferred resolution)
;;
;; `mcp-emacs-apply-diff-async' must return immediately and answer later via
;; its callback: blocking here is exactly the bug it exists to avoid (a
;; process filter has `inhibit-quit' set and no command loop, so the ediff
;; panel renders but cannot be answered).  These tests stub `ediff-buffers'
;; the same way the layout tests above do, capture the ON-RESOLVE callback
;; that `mcp-emacs--ediff-review' installs, and fire it by hand.

(defmacro mcp--with-async-review (bindings &rest body)
  "Run BODY with `ediff-buffers' stubbed for an async apply-diff test.
BINDINGS is a list of (VAR . INIT) forms evaluated before the stub is
installed.  Inside BODY, `resolve' calls the captured ON-RESOLVE callback
and `control' is the fake control buffer."
  (declare (indent 1))
  `(let* ((control (generate-new-buffer " *fake-async-control*"))
          (captured nil)
          ,@bindings)
     (unwind-protect
         (cl-letf (((symbol-function 'ediff-buffers)
                    (lambda (_a _b setup-hooks &rest _)
                      (let ((ediff-control-buffer control))
                        (dolist (fn setup-hooks) (funcall fn)))
                      control))
                   ;; Never touch the real window layout from batch.
                   ((symbol-function 'set-window-configuration)
                    (lambda (&rest _) nil))
                   ;; Capture ON-RESOLVE instead of driving a real ediff.
                   ((symbol-function 'mcp-emacs--ediff-review)
                    (lambda (_a _b _entry _result &optional on-resolve _tab)
                      (setq captured on-resolve)
                      control)))
           (cl-flet ((resolve () (when captured (funcall captured))))
             ,@body))
       (when (buffer-live-p control) (kill-buffer control)))))

;; A temp file to review against; `mcp-emacs-apply-diff-async' opens PATH
;; with `find-file-noselect', so it must exist on disk.
(defun mcp--async-fixture ()
  "Return a fresh temp file path containing \"old\\n\"."
  (let ((f (make-temp-file "mcp-async-" nil ".txt" "old\n")))
    f))

;; Returns immediately (nil) rather than blocking until a decision, and does
;; not invoke the callback before the human resolves.
(let ((file (mcp--async-fixture)))
  (unwind-protect
      (mcp--with-async-review ((calls nil))
        (let ((ret (mcp-emacs-apply-diff-async
                    file "new\n" 60 (lambda (out) (push out calls)))))
          (check "async-returns-immediately" ret nil)
          (check "async-no-callback-before-resolve" calls nil)))
    (delete-file file)))

;; Accept -> the callback gets "Status: applied" plus buffer A's content.
;; The stub must expose the RESULT cell so the test can record an accept the
;; way the real accept key binding does; otherwise only the reject branch is
;; ever reachable and the applied path goes untested.
(let ((file (mcp--async-fixture)))
  (unwind-protect
      (let* ((control (generate-new-buffer " *fake-async-control*"))
             (captured nil)
             (cell nil)
             (calls nil))
        (unwind-protect
            (cl-letf (((symbol-function 'mcp-emacs--ediff-review)
                       (lambda (_a _b _entry result &optional on-resolve _tab)
                         (setq captured on-resolve
                               cell result)
                         control)))
              (mcp-emacs-apply-diff-async
               file "new\n" 60 (lambda (out) (push out calls)))
              ;; Mirror the accept command: record the decision, and put the
              ;; proposal into buffer A (which is what gets reported back).
              (setcar cell 'applied)
              (let ((buf (find-buffer-visiting file)))
                (with-current-buffer buf (erase-buffer) (insert "new\n")))
              (funcall captured)
              (check "async-accept-count" (length calls) 1)
              (check "async-accept-status"
                     (car calls) "Status: applied\nnew\n"))
          (when (buffer-live-p control) (kill-buffer control))))
    (let ((buf (find-buffer-visiting file)))
      (when buf (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf)))
    (delete-file file)))

;; Resolving twice must deliver exactly one answer: the quit hook can fire
;; again (e.g. a second `q') after the decision is already recorded.
(let ((file (mcp--async-fixture)))
  (unwind-protect
      (mcp--with-async-review ((calls nil))
        (mcp-emacs-apply-diff-async
         file "new\n" 60 (lambda (out) (push out calls)))
        (resolve)
        (resolve)
        (check "async-single-delivery" (length calls) 1))
    (let ((buf (find-buffer-visiting file)))
      (when buf (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf)))
    (delete-file file)))

;; Rejection surfaces as "Status: rejected" (result cell left unset).
(let ((file (mcp--async-fixture)))
  (unwind-protect
      (mcp--with-async-review ((calls nil))
        (mcp-emacs-apply-diff-async
         file "new\n" 60 (lambda (out) (push out calls)))
        (resolve)
        (check "async-reject-status" (car calls) "Status: rejected"))
    (let ((buf (find-buffer-visiting file)))
      (when buf (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf)))
    (delete-file file)))

;; Timeout fires the callback with "Status: timeout" when nobody resolves.
;; A 1-second timeout keeps the batch run short.
(let ((file (mcp--async-fixture)))
  (unwind-protect
      (mcp--with-async-review ((calls nil))
        (mcp-emacs-apply-diff-async
         file "new\n" 1 (lambda (out) (push out calls)))
        (check "async-timeout-not-yet" calls nil)
        (sleep-for 2)
        (check "async-timeout-status" (car calls) "Status: timeout")
        (check "async-timeout-single" (length calls) 1)
        ;; A late human resolve after a timeout must not answer twice.
        (resolve)
        (check "async-timeout-then-resolve-single" (length calls) 1))
    (let ((buf (find-buffer-visiting file)))
      (when buf (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf)))
    (delete-file file)))

;; The timeout timer is cancelled once the review resolves, so a finished
;; review leaves nothing pending behind it.
(let ((file (mcp--async-fixture)))
  (unwind-protect
      (mcp--with-async-review ((calls nil))
        ;; Assert on `timer-list' directly.  The single-delivery guard would
        ;; suppress a second callback even if the timer were never cancelled,
        ;; so counting calls cannot tell the two mechanisms apart -- only an
        ;; uncancelled timer shows up here.
        (let ((before (length timer-list)))
          (mcp-emacs-apply-diff-async
           file "new\n" 30 (lambda (out) (push out calls)))
          (check "async-timer-armed" (> (length timer-list) before) t)
          (resolve)
          (check "async-resolve-before-timeout" (length calls) 1)
          (check "async-timer-cancelled" (length timer-list) before)))
    (let ((buf (find-buffer-visiting file)))
      (when buf (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf)))
    (delete-file file)))

;; A path that does not exist is NOT an error: `find-file-noselect' happily
;; makes a buffer for a new file, so the review opens as usual.  What matters
;; for the deferred HTTP reply is that the callback still fires on its own —
;; the request must never hang waiting for a session nobody will answer.
;; (Uses a real ediff rather than the stub, hence the 1-second timeout.)
(let ((calls nil))
  (mcp-emacs-apply-diff-async
   "/nonexistent-dir-mcp-test/nope.txt" "new\n" 1
   (lambda (out) (push out calls)))
  (check "async-missing-path-defers" calls nil)
  (sleep-for 2)
  (check "async-missing-path-answers" (length calls) 1))
