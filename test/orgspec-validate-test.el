;;; orgspec-validate-test.el --- Tests for the orgspec delta validator -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'orgspec-parse)
(require 'orgspec-validate)

(defun val-test--change (s)
  (with-temp-buffer
    (let ((org-inhibit-startup t)) (org-mode))
    (insert s)
    (orgspec-parse-change "t")))

(defun val-test--errors (s) (orgspec-validate-change (val-test--change s)))
(defun val-test--has (s substr)
  (and (seq-some (lambda (e) (string-match-p (regexp-quote substr) e))
                 (val-test--errors s))
       t))

(describe "orgspec-validate-change"
  (it "reports no problems for an ADDED requirement with SHALL and a scenario"
    (check (val-test--errors "* Delta
** Notify on lockout :ADDED:
:PROPERTIES:
:AREA: auth
:END:
The system SHALL notify.
*** ok
- GIVEN a
")
           nil))

  (it "rejects a delta with no requirements at all"
    (check (val-test--has "* Delta\n" "at least one delta") t))

  (it "rejects an ADDED requirement whose text lacks SHALL or MUST"
    (check (val-test--has "* Delta
** Weak req :ADDED:
:PROPERTIES:
:AREA: a
:END:
This just describes something.
*** ok
- GIVEN a
" "must contain SHALL or MUST") t))

  (it "rejects a MODIFIED requirement with no scenario"
    (check (val-test--has "* Delta
** Change it :MODIFIED:
:PROPERTIES:
:AREA: a
:END:
The system SHALL change.
" "must include at least one scenario") t))

  (it "rejects the same requirement name twice within ADDED"
    (check (val-test--has "* Delta
** Dup :ADDED:
:PROPERTIES:
:AREA: a
:END:
SHALL a.
*** s
- GIVEN a
** Dup :ADDED:
:PROPERTIES:
:AREA: a
:END:
SHALL b.
*** s
- GIVEN b
" "Duplicate requirement in ADDED: \"Dup\"") t))

  (it "rejects a name that is both MODIFIED and REMOVED"
    (check (val-test--has "* Delta
** X :MODIFIED:
:PROPERTIES:
:AREA: a
:END:
SHALL x.
*** s
- GIVEN a
** X :REMOVED:
:PROPERTIES:
:AREA: a
:END:
gone.
" "both MODIFIED and REMOVED: \"X\"") t))

  (it "rejects a name that is both ADDED and REMOVED"
    (check (val-test--has "* Delta
** Y :ADDED:
:PROPERTIES:
:AREA: a
:END:
SHALL y.
*** s
- GIVEN a
** Y :REMOVED:
:PROPERTIES:
:AREA: a
:END:
gone.
" "both ADDED and REMOVED: \"Y\"") t))

  (it "rejects a RENAMED target name that collides with an ADDED one"
    (check (val-test--has "* Delta
** NewName :ADDED:
:PROPERTIES:
:AREA: a
:END:
SHALL n.
*** s
- GIVEN a
** NewName :RENAMED:
:PROPERTIES:
:AREA: a
:FROM: OldName
:END:
SHALL n.
*** s
- GIVEN a
" "RENAMED TO collides with ADDED for \"NewName\"") t)))

(describe "orgspec-validate-change-or-signal"
  (it "raises a user-error on an invalid change"
    (check (condition-case _ (progn (orgspec-validate-change-or-signal
                                     (val-test--change "* Delta\n")) 'no-error)
             (user-error 'raised))
           'raised))

  (it "returns t on a valid change"
    (check (orgspec-validate-change-or-signal
            (val-test--change "* Delta
** Good :ADDED:
:PROPERTIES:
:AREA: a
:END:
The system SHALL work.
*** s
- GIVEN a
"))
           t)))

(test-helper-summary)

;;; orgspec-validate-test.el ends here
