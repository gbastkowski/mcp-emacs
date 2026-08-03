(add-to-list 'load-path (expand-file-name "elisp"))
(require 'orgspec-parse)
(require 'orgspec-validate)

(defun check (l g w) (princ (format "%s %s\n" (if (equal g w) "PASS" "FAIL") l)))

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

;; A canonical valid change: ADDED with SHALL + a scenario.
(check "valid-clean"
       (val-test--errors "* Delta
** Notify on lockout :ADDED:
:PROPERTIES:
:AREA: auth
:END:
The system SHALL notify.
*** ok
- GIVEN a
")
       nil)

;; No delta requirements at all.
(check "no-delta"
       (val-test--has "* Delta\n" "at least one delta") t)

;; ADDED without SHALL/MUST.
(check "added-no-shall"
       (val-test--has "* Delta
** Weak req :ADDED:
:PROPERTIES:
:AREA: a
:END:
This just describes something.
*** ok
- GIVEN a
" "must contain SHALL or MUST") t)

;; MODIFIED without a scenario.
(check "modified-no-scenario"
       (val-test--has "* Delta
** Change it :MODIFIED:
:PROPERTIES:
:AREA: a
:END:
The system SHALL change.
" "must include at least one scenario") t)

;; Duplicate name within ADDED.
(check "dup-added"
       (val-test--has "* Delta
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
" "Duplicate requirement in ADDED: \"Dup\"") t)

;; Cross-op: same name in MODIFIED and REMOVED.
(check "modified-and-removed"
       (val-test--has "* Delta
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
" "both MODIFIED and REMOVED: \"X\"") t)

;; Cross-op: ADDED and REMOVED.
(check "added-and-removed"
       (val-test--has "* Delta
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
" "both ADDED and REMOVED: \"Y\"") t)

;; RENAMED TO collides with ADDED.
(check "renamed-collides-added"
       (val-test--has "* Delta
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
" "RENAMED TO collides with ADDED for \"NewName\"") t)

;; or-signal raises on invalid, returns t on valid.
(check "signal-raises"
       (condition-case _ (progn (orgspec-validate-change-or-signal
                                 (val-test--change "* Delta\n")) 'no-error)
         (user-error 'raised))
       'raised)
(check "signal-ok"
       (orgspec-validate-change-or-signal
        (val-test--change "* Delta
** Good :ADDED:
:PROPERTIES:
:AREA: a
:END:
The system SHALL work.
*** s
- GIVEN a
"))
       t)
