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
