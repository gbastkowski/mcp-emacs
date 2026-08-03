(add-to-list 'load-path (expand-file-name "elisp"))
(require 'cl-lib)
(require 'orgspec-commands)
(require 'orgspec-review)

(defun check (l g w) (princ (format "%s %s\n" (if (equal g w) "PASS" "FAIL") l)))

(defun review-test--project ()
  "Create a temp project with one change touching two areas; return its root."
  (let* ((root (make-temp-file "orgspec-review-" t))
         (cdir (expand-file-name "orgspec/changes/add-two/" root)))
    (make-directory cdir t)
    (with-temp-file (expand-file-name "change.org" cdir)
      (insert "#+TITLE: add-two\n* Tasks\n- [ ] x\n* Delta\n"
              "** Auth requirement :ADDED:\n:PROPERTIES:\n:AREA: auth\n:END:\n"
              "The system SHALL authenticate.\n*** ok\n- GIVEN a\n"
              "** Billing requirement :ADDED:\n:PROPERTIES:\n:AREA: billing\n:END:\n"
              "The system MUST bill.\n*** ok\n- GIVEN b\n"))
    root))

(cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))

  ;; fold-build: two areas, each with the folded (file . text), nothing written.
  (let* ((root (review-test--project))
         (default-directory (file-name-as-directory root))
         (orgspec-root "orgspec")
         (built (orgspec-commands-fold-build "add-two")))
    (check "build-count" (length built) 2)
    (check "build-areas"
           (sort (mapcar (lambda (c) (file-name-base (car c))) built) #'string<)
           '("auth" "billing"))
    (check "build-folded-has-req"
           (and (seq-some (lambda (c) (string-match-p "Auth requirement" (cdr c))) built) t) t)
    (check "build-folded-plain-headline"
           ;; re-leveled to L1, op tag stripped
           (and (seq-some (lambda (c)
                            (string-match-p "^\\* Auth requirement$" (cdr c))) built) t) t)
    (check "build-writes-nothing"
           (file-exists-p (expand-file-name "orgspec/specs/auth.org" root)) nil))

  ;; archive: writes both specs and returns their files; change moves to archive.
  (let* ((root (review-test--project))
         (default-directory (file-name-as-directory root))
         (orgspec-root "orgspec"))
    (cl-letf (((symbol-function 'orgspec-commands--archive-move) (lambda (_id) nil)))
      (let ((written (orgspec-archive "add-two")))
        (check "archive-returns-two" (length written) 2)
        (check "archive-wrote-auth"
               (file-exists-p (expand-file-name "orgspec/specs/auth.org" root)) t)
        (check "archive-wrote-billing"
               (file-exists-p (expand-file-name "orgspec/specs/billing.org" root)) t)
        (check "archive-auth-content"
               (with-temp-buffer
                 (insert-file-contents (expand-file-name "orgspec/specs/auth.org" root))
                 (and (string-match-p "Auth requirement" (buffer-string)) t)) t))))

  ;; review-fold: builds and diffs each area, writing nothing; ediff stubbed.
  (let* ((root (review-test--project))
         (default-directory (file-name-as-directory root))
         (orgspec-root "orgspec")
         (ediff-calls 0))
    (cl-letf (((symbol-function 'orgspec-review--ediff)
               (lambda (&rest _) (setq ediff-calls (1+ ediff-calls)))))
      (let ((reviewed (orgspec-review-fold "add-two")))
        (check "review-count" (length reviewed) 2)
        (check "review-ediff-per-area" ediff-calls 2)
        (check "review-writes-nothing"
               (file-exists-p (expand-file-name "orgspec/specs/auth.org" root)) nil)))))
