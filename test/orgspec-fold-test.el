;;; orgspec-fold-test.el --- Tests for folding a delta into the specs -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'orgspec-parse)
(require 'orgspec-fold)

;; Parse a `* Delta' change string into its requirements (in order).
(defun fold-test--reqs (change)
  (with-temp-buffer
    (let ((org-inhibit-startup t)) (org-mode))
    (insert change)
    (orgspec-change-requirements (orgspec-parse-change "t"))))

;; --- ADDED: new requirement appended, cleaned -------------------------------

(let* ((delta "* Delta
** TODO New thing                                    :ADDED:
:PROPERTIES:
:AREA: auth
:END:
The system SHALL do the new thing.
*** New scenario
- GIVEN a
- WHEN b
- THEN c
")
       (out (orgspec-fold-area "" (fold-test--reqs delta))))
  (describe "orgspec-fold-area with an ADDED requirement"
    (it "appends the new requirement as a top-level headline"
      (check-that (string-match-p "^\\* New thing" out)))
    (it "appends its scenarios one level below the requirement"
      (check-that (string-match-p "^\\*\\* New scenario" out)))
    (it "strips the TODO keyword from the folded headline"
      (check (string-match-p "\\* TODO " out) nil))
    (it "drops the delta operation tag"
      (check (string-match-p ":ADDED:" out) nil))
    (it "strips the AREA property that routed the requirement"
      (check (string-match-p ":AREA:" out) nil))
    (it "keeps the SHALL body text"
      (check-that (string-match-p "SHALL" out)))))

;; --- ADDED with IMPL drawer kept --------------------------------------------

(let* ((delta "* Delta
** New thing                                         :ADDED:
:PROPERTIES:
:AREA: auth
:END:
:IMPL:
[[file:auth.el::x][x]]
:END:
The system SHALL do it.
*** S
- GIVEN a
- WHEN b
- THEN c
")
       (out (orgspec-fold-area "" (fold-test--reqs delta))))
  (describe "orgspec-fold-area with a hand-written IMPL drawer"
    (it "preserves the IMPL drawer through the fold"
      (check-that (string-match-p ":IMPL:" out)))))

;; --- REMOVED: existing requirement deleted ----------------------------------

(let* ((spec "* Keep me
The system SHALL stay.
** S1
- GIVEN a
* Drop me
The system SHALL go.
** S2
- GIVEN a
")
       (delta "* Delta
** Drop me                                           :REMOVED:
:PROPERTIES:
:AREA: auth
:END:
Removed.
")
       (out (orgspec-fold-area spec (fold-test--reqs delta))))
  (describe "orgspec-fold-area with a REMOVED requirement"
    (it "deletes the named requirement from the spec"
      (check (string-match-p "Drop me" out) nil))
    (it "leaves the other requirements untouched"
      (check-that (string-match-p "^\\* Keep me" out)))))

;; --- RENAMED: headline renamed via :FROM: -----------------------------------

(let* ((spec "* Old name
The system SHALL exist.
** S1
- GIVEN a
")
       (delta "* Delta
** New name                                          :RENAMED:
:PROPERTIES:
:AREA: auth
:FROM: Old name
:END:
Renamed.
")
       (out (orgspec-fold-area spec (fold-test--reqs delta))))
  (describe "orgspec-fold-area with a RENAMED requirement"
    (it "renames the requirement identified by FROM to the new headline"
      (check-that (string-match-p "^\\* New name" out)))
    (it "leaves no requirement under the old name"
      (check (string-match-p "^\\* Old name" out) nil))))

;; --- MODIFIED: replace, keeping all current scenarios -----------------------

(let* ((spec "* Feature
The system SHALL do old.
** Keep scenario
- GIVEN a
")
       (delta "* Delta
** Feature                                           :MODIFIED:
:PROPERTIES:
:AREA: auth
:END:
The system SHALL do new and improved.
*** Keep scenario
- GIVEN a
*** Extra scenario
- GIVEN b
")
       (out (orgspec-fold-area spec (fold-test--reqs delta))))
  (describe "orgspec-fold-area with a MODIFIED requirement"
    (it "replaces the requirement body with the new wording"
      (check-that (string-match-p "new and improved" out)))
    (it "drops the superseded body text"
      (check (string-match-p "SHALL do old" out) nil))
    (it "carries over the scenarios the delta restates"
      (check-that (string-match-p "Keep scenario" out)))
    (it "adds the scenarios the delta introduces"
      (check-that (string-match-p "Extra scenario" out)))))

;; --- MODIFIED drop-guard: dropping a current scenario is an error -----------

(let* ((spec "* Feature
The system SHALL do it.
** Important scenario
- GIVEN a
")
       (delta "* Delta
** Feature                                           :MODIFIED:
:PROPERTIES:
:AREA: auth
:END:
The system SHALL do it differently.
*** Different scenario
- GIVEN b
"))
  (describe "orgspec-fold-area drop guard"
    (it "signals rather than silently dropping a current scenario"
      (check (condition-case _
                 (progn (orgspec-fold-area spec (fold-test--reqs delta)) nil)
               (orgspec-fold-error t))
             t))))

;; --- Fixed apply order: REMOVED before ADDED (same name reused) -------------

(let* ((spec "* Thing
The system SHALL do v1.
** S
- GIVEN a
")
       ;; Remove old Thing, then add a new Thing with the same name. Order
       ;; renamed->removed->modified->added means removed runs first, so the
       ;; add does not collide.
       (delta "* Delta
** Thing                                             :ADDED:
:PROPERTIES:
:AREA: auth
:END:
The system SHALL do v2.
*** S
- GIVEN a
** Thing                                             :REMOVED:
:PROPERTIES:
:AREA: auth
:END:
Removed.
")
       (out (orgspec-fold-area spec (fold-test--reqs delta))))
  (describe "orgspec-fold-area apply order"
    (it "applies REMOVED before ADDED so a reused name does not collide"
      (check (and (string-match-p "SHALL do v2" out)
                  (not (string-match-p "SHALL do v1" out)) t) t))))

;;; orgspec-fold-test.el ends here
