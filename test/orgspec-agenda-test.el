(add-to-list 'load-path (expand-file-name "elisp"))
(require 'orgspec-agenda)

(defun check (l g w) (princ (format "%s %s\n" (if (equal g w) "PASS" "FAIL") l)))

;; Build a temp changes dir: two active changes + one archived.
(let* ((root (make-temp-file "orgspec-agenda-" t))
       (changes (expand-file-name "changes" root)))
  (dolist (id '("add-auth" "fix-lockout"))
    (let ((d (expand-file-name id changes)))
      (make-directory d t)
      (with-temp-file (expand-file-name "change.org" d) (insert "* Delta\n"))))
  ;; An archived change must be excluded.
  (let ((a (expand-file-name "archive/old-change" changes)))
    (make-directory a t)
    (with-temp-file (expand-file-name "change.org" a) (insert "* Delta\n")))
  ;; A change dir with no change.org must be skipped.
  (make-directory (expand-file-name "half-baked" changes) t)

  (let ((files (orgspec-agenda-files changes)))
    (check "files-count" (length files) 2)
    (check "files-active-only"
           (and (seq-every-p (lambda (f) (not (string-match-p "/archive/" f))) files) t)
           t)
    (check "files-existing"
           (and (seq-every-p #'file-exists-p files) t) t))

  ;; install registers one entry under the key, idempotently.
  (let ((org-agenda-custom-commands nil)
        (orgspec-agenda-key "o"))
    (orgspec-agenda-install changes)
    (check "install-one" (length org-agenda-custom-commands) 1)
    (check "install-key" (car (car org-agenda-custom-commands)) "o")
    (orgspec-agenda-install changes)
    (check "install-idempotent" (length org-agenda-custom-commands) 1)
    (let ((entry (car org-agenda-custom-commands)))
      (check "install-type" (nth 2 entry) 'tags-todo)
      (check "install-match-has-ops"
             (and (string-match-p "ADDED" (nth 3 entry))
                  (string-match-p "RENAMED" (nth 3 entry)) t)
             t))))

;; A missing changes dir yields no files (no error).
(check "files-missing" (orgspec-agenda-files "/nonexistent/xyz") nil)
