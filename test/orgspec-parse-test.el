;;; orgspec-parse-test.el --- Tests for the orgspec parser -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'orgspec-parse)

(defun parse-test--change (s)
  (with-temp-buffer
    (let ((org-inhibit-startup t)) (org-mode))
    (insert s)
    (orgspec-parse-change "t")))

(describe "orgspec-parse-change on a delta requirement"
  (let* ((chg (parse-test--change "* Delta
** TODO Notify on lockout                            :ADDED:
:PROPERTIES:
:AREA: auth
:END:
:IMPL:
[[file:auth.el::x][x]]
:END:
The system SHALL notify.
*** Lockout triggered
- GIVEN a
- WHEN b
- THEN c
"))
         (req (car (orgspec-change-requirements chg))))
    (it "reads the operation from the headline tag"
      (check (orgspec-requirement-op req) 'added))
    (it "takes the requirement name from the headline text"
      (check (orgspec-requirement-name req) "Notify on lockout"))
    (it "reads the area from the AREA property"
      (check (orgspec-requirement-area req) "auth"))
    (it "collects the scenarios below the requirement"
      (check (length (orgspec-requirement-scenarios req)) 1))
    (it "names each scenario after its headline"
      (check (orgspec-scenario-name (car (orgspec-requirement-scenarios req)))
             "Lockout triggered"))
    (it "collects the links in the IMPL drawer"
      (check (length (orgspec-requirement-impl req)) 1))
    (it "keeps the normative wording in the body"
      (check-that (string-match-p orgspec-normative-regexp
                                  (orgspec-requirement-body req))))
    (it "retains the whole subtree as the source text"
      (check-that (string-match-p "Notify on lockout"
                                  (orgspec-requirement-source req))))))

(describe "orgspec-parse-change on a RENAMED requirement"
  (let* ((chg (parse-test--change "* Delta
** New name                                          :RENAMED:
:PROPERTIES:
:AREA: auth
:FROM: Old name
:END:
Renamed.
"))
         (req (car (orgspec-change-requirements chg))))
    (it "reads the renamed operation from the headline tag"
      (check (orgspec-requirement-op req) 'renamed))
    (it "carries the previous name from the FROM property"
      (check (orgspec-requirement-from req) "Old name"))))

(describe "orgspec-parse-spec"
  (let* ((reqs (with-temp-buffer
                 (let ((org-inhibit-startup t)) (org-mode))
                 (insert "* Req one\nThe system SHALL a.\n** S1\n- GIVEN x\n* Req two\nThe system SHALL b.\n")
                 (orgspec-parse-spec))))
    (it "treats every level-one headline as a requirement"
      (check (length reqs) 2))
    (it "leaves the operation unset, since a spec records no delta"
      (check (orgspec-requirement-op (car reqs)) nil))
    (it "takes the requirement name from the headline text"
      (check (orgspec-requirement-name (car reqs)) "Req one"))))

(test-helper-summary)

;;; orgspec-parse-test.el ends here
