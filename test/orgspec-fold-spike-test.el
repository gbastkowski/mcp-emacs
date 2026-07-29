;;; orgspec-fold-spike-test.el --- de-risk the orgspec fold re-leveling  -*- lexical-binding: t; -*-

;; Issue #5, step 1 — the one real unknown of the orgspec port: can a delta
;; requirement, stored at L2/L3 under a `* Delta` heading in a change file, be
;; folded into a spec file (where requirements are L1 and scenarios L2) with
;; correct re-leveling, the TODO keyword stripped, the op tag dropped, and the
;; :IMPL: traceability drawer kept?
;;
;; This is a spike, not the real fold — it proves the org primitives behave, so
;; orgspec-fold.el can be built on `org-copy-subtree` + `org-paste-subtree`
;; rather than a hand-rolled promote/demote loop. Run with:
;;   emacs --batch -L elisp -l test/orgspec-fold-spike-test.el
;; A FAIL line in the output fails the run (CI greps for FAIL).

(require 'org)
(require 'org-element)

(defun check (l g w)
  (princ (format "%s %s\n" (if (equal g w) "PASS" "FAIL") l)))

;; A delta requirement as stored in a change file: L2 headline carrying a TODO
;; keyword and an :ADDED: op tag, an :AREA: routing property, an :IMPL: drawer,
;; and an L3 scenario.
(defvar orgspec-fold-spike--change "\
* Delta
** TODO Notify on account lockout                    :ADDED:
:PROPERTIES:
:AREA: auth
:END:
:IMPL:
[[file:auth.el::defun lockout][lockout]]
:END:
The system SHALL send a notification email when an account is locked out.
*** Lockout triggered
- GIVEN an account just crossed the failed-attempt threshold
- WHEN the lockout is applied
- THEN a notification email is sent to the account address
")

;; The target spec file: an existing L1 requirement with an L2 scenario.
(defvar orgspec-fold-spike--spec "\
* Existing requirement
The system SHALL already do a thing.
** Existing scenario
- GIVEN x
- WHEN y
- THEN z
")

(let ((org-todo-keywords '((sequence "TODO" "|" "DONE")))
      cut-text)
  ;; 1. Cut the delta requirement subtree from the change buffer.
  (with-temp-buffer
    (let ((org-inhibit-startup t)) (org-mode))
    (insert orgspec-fold-spike--change)
    (goto-char (point-min))
    (re-search-forward "^\\*\\* .*Notify on account lockout")
    (org-back-to-heading t)
    (org-copy-subtree)
    (setq cut-text (current-kill 0)))

  ;; 2. Paste into the spec buffer forced to L1; org re-levels the whole subtree.
  (with-temp-buffer
    (let ((org-inhibit-startup t)) (org-mode))
    (insert orgspec-fold-spike--spec)
    (goto-char (point-max))
    (org-paste-subtree 1 cut-text)

    ;; 3. Apply the fold rules on the pasted subtree.
    (goto-char (point-min))
    (re-search-forward "Notify on account lockout")
    (org-back-to-heading t)
    (org-todo 'none)                    ; strip TODO keyword
    (org-set-tags nil)                  ; drop :ADDED: op tag

    (let ((result (buffer-string)))
      ;; requirement re-leveled L2 -> L1, scenario L3 -> L2
      (check "requirement is L1"
             (and (string-match-p "^\\* Notify on account lockout" result) t) t)
      (check "scenario is L2"
             (and (string-match-p "^\\*\\* Lockout triggered" result) t) t)
      ;; workflow state removed from the durable spec
      (check "TODO stripped" (string-match-p "\\* TODO " result) nil)
      (check "op tag dropped" (string-match-p ":ADDED:" result) nil)
      ;; traceability kept
      (check "IMPL drawer kept"
             (and (string-match-p ":IMPL:" result) t) t)
      ;; existing content untouched
      (check "existing requirement intact"
             (and (string-match-p "^\\* Existing requirement" result) t) t))))

;;; orgspec-fold-spike-test.el ends here
