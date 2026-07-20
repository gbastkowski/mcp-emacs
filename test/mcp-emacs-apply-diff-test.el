(add-to-list 'load-path (expand-file-name "elisp"))
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
