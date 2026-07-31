(add-to-list 'load-path (expand-file-name "elisp"))
(require 'orgspec-parse)
(require 'orgspec-fold)

(defun check (l g w) (princ (format "%s %s\n" (if (equal g w) "PASS" "FAIL") l)))

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
  (check "added-requirement-L1" (and (string-match-p "^\\* New thing" out) t) t)
  (check "added-scenario-L2" (and (string-match-p "^\\*\\* New scenario" out) t) t)
  (check "added-todo-stripped" (string-match-p "\\* TODO " out) nil)
  (check "added-op-tag-dropped" (string-match-p ":ADDED:" out) nil)
  (check "added-area-stripped" (string-match-p ":AREA:" out) nil)
  (check "added-shall-kept" (and (string-match-p "SHALL" out) t) t))

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
  (check "added-impl-kept" (and (string-match-p ":IMPL:" out) t) t))

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
  (check "removed-gone" (string-match-p "Drop me" out) nil)
  (check "removed-keeps-others" (and (string-match-p "^\\* Keep me" out) t) t))

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
  (check "renamed-to-new" (and (string-match-p "^\\* New name" out) t) t)
  (check "renamed-old-gone" (string-match-p "^\\* Old name" out) nil))

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
  (check "modified-body-updated" (and (string-match-p "new and improved" out) t) t)
  (check "modified-old-body-gone" (string-match-p "SHALL do old" out) nil)
  (check "modified-keeps-scenario" (and (string-match-p "Keep scenario" out) t) t)
  (check "modified-adds-scenario" (and (string-match-p "Extra scenario" out) t) t))

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
  (check "modified-drop-guard-signals"
         (condition-case _
             (progn (orgspec-fold-area spec (fold-test--reqs delta)) nil)
           (orgspec-fold-error t))
         t))

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
  (check "order-removed-then-added" (and (string-match-p "SHALL do v2" out)
                                         (not (string-match-p "SHALL do v1" out)) t) t))
