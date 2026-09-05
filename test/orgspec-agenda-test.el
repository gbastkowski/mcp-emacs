;;; orgspec-agenda-test.el --- Tests for the orgspec agenda integration -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'orgspec-agenda)

;; Build a temp changes dir: two active changes, one archived, one with no
;; change.org at all.
(let* ((root (make-temp-file "orgspec-agenda-" t))
       (changes (expand-file-name "changes" root)))
  (dolist (id '("add-auth" "fix-lockout"))
    (let ((d (expand-file-name id changes)))
      (make-directory d t)
      (with-temp-file (expand-file-name "change.org" d) (insert "* Delta\n"))))
  (let ((a (expand-file-name "archive/old-change" changes)))
    (make-directory a t)
    (with-temp-file (expand-file-name "change.org" a) (insert "* Delta\n")))
  (make-directory (expand-file-name "half-baked" changes) t)

  (describe "orgspec-agenda-files"
    (let ((files (orgspec-agenda-files changes)))
      (it "collects one file per active change"
        (check (length files) 2))
      (it "excludes changes under archive/"
        (check-that (seq-every-p (lambda (f) (not (string-match-p "/archive/" f)))
                                 files)))
      (it "returns only files that exist, skipping dirs without change.org"
        (check-that (seq-every-p #'file-exists-p files)))))

  (describe "orgspec-agenda-install"
    (let ((org-agenda-custom-commands nil)
          (orgspec-agenda-key "o"))
      (orgspec-agenda-install changes)
      (it "registers exactly one agenda command"
        (check (length org-agenda-custom-commands) 1))
      (it "registers it under `orgspec-agenda-key'"
        (check (car (car org-agenda-custom-commands)) "o"))
      (orgspec-agenda-install changes)
      (it "keeps a single entry when installed twice"
        (check (length org-agenda-custom-commands) 1))
      (let ((entry (car org-agenda-custom-commands)))
        (it "registers a tags-todo search"
          (check (nth 2 entry) 'tags-todo))
        (it "matches every delta operation keyword"
          (check-that (and (string-match-p "ADDED" (nth 3 entry))
                           (string-match-p "RENAMED" (nth 3 entry)))))))))

(describe "orgspec-agenda-files with a missing directory"
  (it "returns no files rather than signalling"
    (check (orgspec-agenda-files "/nonexistent/xyz") nil)))

(test-helper-summary)

;;; orgspec-agenda-test.el ends here
