;;; orgspec-review-test.el --- Tests for the orgspec fold/review/archive commands -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'cl-lib)
(require 'orgspec-commands)
(require 'orgspec-review)

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

  (describe "orgspec-commands-fold-build"
    (let* ((root (review-test--project))
           (default-directory (file-name-as-directory root))
           (orgspec-root "orgspec")
           (built (orgspec-commands-fold-build "add-two")))
      (it "returns one fold per area touched by the change"
        (check (length built) 2))
      (it "names each fold after the area it belongs to"
        (check (sort (mapcar (lambda (c) (file-name-base (car c))) built) #'string<)
               '("auth" "billing")))
      (it "carries the requirement text in the folded content"
        (check-that (seq-some (lambda (c) (string-match-p "Auth requirement" (cdr c))) built)))
      (it "re-levels requirements to level 1 and strips the operation tag"
        (check-that (seq-some (lambda (c)
                                (string-match-p "^\\* Auth requirement$" (cdr c))) built)))
      (it "writes no spec file, only returning the fold"
        (check (file-exists-p (expand-file-name "orgspec/specs/auth.org" root)) nil))))

  (describe "orgspec-archive"
    (let* ((root (review-test--project))
           (default-directory (file-name-as-directory root))
           (orgspec-root "orgspec"))
      (cl-letf (((symbol-function 'orgspec-commands--archive-move) (lambda (_id) nil)))
        (let ((written (orgspec-archive "add-two")))
          (it "returns one written file per area"
            (check (length written) 2))
          (it "writes the auth spec"
            (check (file-exists-p (expand-file-name "orgspec/specs/auth.org" root)) t))
          (it "writes the billing spec"
            (check (file-exists-p (expand-file-name "orgspec/specs/billing.org" root)) t))
          (it "puts the folded requirement into the spec it wrote"
            (check-that (with-temp-buffer
                          (insert-file-contents
                           (expand-file-name "orgspec/specs/auth.org" root))
                          (string-match-p "Auth requirement" (buffer-string)))))))))

  (describe "orgspec-review-fold"
    (let* ((root (review-test--project))
           (default-directory (file-name-as-directory root))
           (orgspec-root "orgspec")
           (ediff-calls 0))
      (cl-letf (((symbol-function 'orgspec-review--ediff)
                 (lambda (&rest _) (setq ediff-calls (1+ ediff-calls)))))
        (let ((reviewed (orgspec-review-fold "add-two")))
          (it "reviews one fold per area"
            (check (length reviewed) 2))
          (it "starts an ediff for each area"
            (check ediff-calls 2))
          (it "writes no spec file, leaving the specs untouched"
            (check (file-exists-p (expand-file-name "orgspec/specs/auth.org" root)) nil)))))))

(test-helper-summary)

;;; orgspec-review-test.el ends here
