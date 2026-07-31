(add-to-list 'load-path (expand-file-name "elisp"))
(require 'orgspec-parse)

(defun check (l g w) (princ (format "%s %s\n" (if (equal g w) "PASS" "FAIL") l)))

(defun parse-test--change (s)
  (with-temp-buffer
    (let ((org-inhibit-startup t)) (org-mode))
    (insert s)
    (orgspec-parse-change "t")))

;; A delta requirement: op, area, from, body, scenarios, impl all extracted.
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
  (check "parse-op" (orgspec-requirement-op req) 'added)
  (check "parse-name" (orgspec-requirement-name req) "Notify on lockout")
  (check "parse-area" (orgspec-requirement-area req) "auth")
  (check "parse-scenarios" (length (orgspec-requirement-scenarios req)) 1)
  (check "parse-scenario-name"
         (orgspec-scenario-name (car (orgspec-requirement-scenarios req)))
         "Lockout triggered")
  (check "parse-impl" (length (orgspec-requirement-impl req)) 1)
  (check "parse-normative"
         (and (string-match-p orgspec-normative-regexp
                              (orgspec-requirement-body req)) t) t)
  (check "parse-source-has-subtree"
         (and (string-match-p "Notify on lockout"
                              (orgspec-requirement-source req)) t) t))

;; RENAMED carries :FROM:.
(let* ((chg (parse-test--change "* Delta
** New name                                          :RENAMED:
:PROPERTIES:
:AREA: auth
:FROM: Old name
:END:
Renamed.
"))
       (req (car (orgspec-change-requirements chg))))
  (check "parse-renamed-op" (orgspec-requirement-op req) 'renamed)
  (check "parse-from" (orgspec-requirement-from req) "Old name"))

;; A spec buffer parses to plain (op nil) requirements at L1.
(let* ((reqs (with-temp-buffer
               (let ((org-inhibit-startup t)) (org-mode))
               (insert "* Req one\nThe system SHALL a.\n** S1\n- GIVEN x\n* Req two\nThe system SHALL b.\n")
               (orgspec-parse-spec))))
  (check "parse-spec-count" (length reqs) 2)
  (check "parse-spec-no-op" (orgspec-requirement-op (car reqs)) nil)
  (check "parse-spec-name" (orgspec-requirement-name (car reqs)) "Req one"))
