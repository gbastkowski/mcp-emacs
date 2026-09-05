;;; test-helper.el --- Shared assertion vocabulary for the suites -*- lexical-binding: t; -*-

;; These suites are batch scripts, not `ert' suites: loading a file runs it,
;; and an assertion is a `check' call that princ's one line.  That stays --
;; it keeps a suite debuggable with `emacs --batch -l', and bin/test-emacs.sh
;; builds its report from those lines.
;;
;; What changes here is that the line says what was being tested rather than
;; naming a symbol.  `install-idempotent' tells you which call failed; "keeps
;; a single entry when installed twice" tells you what the code was supposed
;; to do, which is the part you need when the failure is a surprise.  So:
;;
;;   (describe "orgspec-agenda-install"
;;     (it "keeps a single entry when installed twice"
;;       (check (length org-agenda-custom-commands) 1)))
;;
;; prints
;;
;;   DESCRIBE orgspec-agenda-install
;;   PASS keeps a single entry when installed twice
;;
;; Three drifted copies of `check' existed before this file (one per naming
;; scheme, one of which also printed got/want); they are now one.

;;; Code:

(require 'cl-lib)

(defvar test-helper-failures 0
  "Count of failed assertions in this suite run.")

(defvar test-helper--context nil
  "Description of the `describe' block currently being run, if any.")

(defvar test-helper--current nil
  "Description of the `it' block currently being run, if any.")

(defun test-helper-report (ok label &optional got want show-values)
  "Print one PASS/FAIL line for LABEL and count a failure unless OK.
GOT and WANT are included when SHOW-VALUES is non-nil, or whenever the
assertion failed -- on failure the values are the whole point, but on a
green run they are noise that buries the description."
  (unless ok (setq test-helper-failures (1+ test-helper-failures)))
  (princ (format "%s %s%s\n"
                 (if ok "PASS" "FAIL")
                 label
                 (if (or show-values (not ok))
                     (format ": got=%S want=%S" got want)
                   ""))))

(defmacro describe (description &rest body)
  "Group the assertions in BODY under DESCRIPTION.
Prints a DESCRIBE line so the report can indent what follows under it.
This is a grouping form only: BODY is spliced in place, so fixtures bound
outside are still visible inside and `let' bindings inside still work the
way they read."
  (declare (indent 1))
  `(progn
     (princ (format "DESCRIBE %s\n" ,description))
     (let ((test-helper--context ,description))
       ,@body)))

(defmacro it (description &rest body)
  "Run BODY as the expectation DESCRIPTION.
Any bare `check' inside reports against DESCRIPTION, so the common case
is one `check' per `it' and no repeated label.  An error escaping BODY is
reported as a failure of this expectation rather than killing the suite,
so one broken fixture does not hide every later result."
  (declare (indent 1))
  `(let ((test-helper--current ,description))
     (condition-case err
         (progn ,@body)
       (error
        (test-helper-report nil ,description
                            (error-message-string err) 'no-error t)))))

(defun check (got want &optional label)
  "Assert GOT equals WANT, reporting under the enclosing `it'.
LABEL overrides that description, which is what a loop generating several
assertions needs; outside any `it' it is required, since a report line
with nothing to identify it is useless.

Beware when converting a suite: the old per-suite `check' took
\(LABEL GOT WANT), so the argument order here is deliberately different
and a call left unconverted compares a label against a value.  The guard
against that is the assertion count -- a converted suite must report the
same number of passes as before."
  (let ((description (or label test-helper--current
                         (error "check outside `it' needs a label"))))
    (test-helper-report (equal got want) description got want)))

(defun check-that (got &optional label)
  "Assert GOT is non-nil.  LABEL behaves as in `check'.
Saves writing `(check (and ... t) t)', which was the common shape when
the predicate under test returns a truthy value rather than exactly t."
  (check (and got t) t label))

(defun test-helper-summary ()
  "Print the suite's own tally.  Call at the end of a suite."
  (princ (format "\n%s\n"
                 (if (zerop test-helper-failures)
                     "ALL PASS"
                   (format "%d FAILURE(S)" test-helper-failures)))))

(provide 'test-helper)

;;; test-helper.el ends here
