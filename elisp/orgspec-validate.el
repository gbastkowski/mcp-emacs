;;; orgspec-validate.el --- Hard-gate validator for orgspec changes  -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.9.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The hard-gate validator (issue #33, the "Full" rules from #5).  It runs the
;; ERROR rules over a parsed `orgspec-change' and returns the list of problems;
;; `orgspec-validate-change-or-signal' turns a non-empty result into a
;; `user-error', so `archive' can gate on it.
;;
;; Rules (ported from OpenSpec's validator; messages adapted to org since the
;; original wording is Markdown-parser specific):
;;   - An ADDED/MODIFIED requirement body must contain SHALL or MUST.
;;   - An ADDED/MODIFIED requirement must have at least one scenario.
;;   - No duplicate requirement names within a single op (ADDED / MODIFIED /
;;     REMOVED), and no duplicate FROM or TO across RENAMED.
;;   - No cross-op conflicts: a name in both MODIFIED and REMOVED, both MODIFIED
;;     and ADDED, or both ADDED and REMOVED; a RENAMED TO that collides with an
;;     ADDED name.
;;   - At least one delta requirement across the whole change.
;; The fold already enforces some of this implicitly (its scenario drop-guard,
;; the no-delta check in `orgspec-archive'); this makes the rules explicit and
;; reports them all up front, before any fold runs.

;;; Code:

(require 'cl-lib)
(require 'orgspec)
(require 'orgspec-model)

(defun orgspec-validate--op-name (op)
  "Return the uppercase op-tag string for op symbol OP."
  (or (orgspec-op-tag-name op) (upcase (symbol-name op))))

(defun orgspec-validate--dups (names)
  "Return the list of NAMES that occur more than once, each once."
  (let (seen dups)
    (dolist (n names)
      (if (member n seen)
          (unless (member n dups) (push n dups))
        (push n seen)))
    (nreverse dups)))

(defun orgspec-validate-change (change)
  "Return the list of validation ERROR messages for CHANGE (empty if valid)."
  (let* ((reqs (orgspec-change-requirements change))
         (by-op (lambda (op) (seq-filter
                              (lambda (r) (eq (orgspec-requirement-op r) op)) reqs)))
         (names-of (lambda (rs) (mapcar #'orgspec-requirement-name rs)))
         (added (funcall by-op 'added))
         (modified (funcall by-op 'modified))
         (removed (funcall by-op 'removed))
         (renamed (funcall by-op 'renamed))
         (added-names (funcall names-of added))
         (modified-names (funcall names-of modified))
         (removed-names (funcall names-of removed))
         errors)
    (cl-flet ((err (fmt &rest args) (push (apply #'format fmt args) errors)))
      ;; At least one delta requirement overall.
      (unless reqs
        (err "Change must have at least one delta"))
      ;; SHALL/MUST + scenarios for ADDED and MODIFIED.
      (dolist (r (append added modified))
        (let ((op (orgspec-validate--op-name (orgspec-requirement-op r)))
              (name (orgspec-requirement-name r)))
          (unless (string-match-p orgspec-normative-regexp
                                  (or (orgspec-requirement-body r) ""))
            (err "%s \"%s\" must contain SHALL or MUST" op name))
          (unless (orgspec-requirement-scenarios r)
            (err "%s \"%s\" must include at least one scenario" op name))))
      ;; Duplicate names within an op.
      (dolist (cell (list (cons 'added added-names)
                          (cons 'modified modified-names)
                          (cons 'removed removed-names)))
        (dolist (dup (orgspec-validate--dups (cdr cell)))
          (err "Duplicate requirement in %s: \"%s\""
               (orgspec-validate--op-name (car cell)) dup)))
      ;; Duplicate FROM / TO across RENAMED.
      (dolist (dup (orgspec-validate--dups
                    (delq nil (mapcar #'orgspec-requirement-from renamed))))
        (err "Duplicate FROM in RENAMED: \"%s\"" dup))
      (dolist (dup (orgspec-validate--dups (funcall names-of renamed)))
        (err "Duplicate TO in RENAMED: \"%s\"" dup))
      ;; Cross-op conflicts.
      (dolist (n (seq-intersection modified-names removed-names))
        (err "Requirement present in both MODIFIED and REMOVED: \"%s\"" n))
      (dolist (n (seq-intersection modified-names added-names))
        (err "Requirement present in both MODIFIED and ADDED: \"%s\"" n))
      (dolist (n (seq-intersection added-names removed-names))
        (err "Requirement present in both ADDED and REMOVED: \"%s\"" n))
      (dolist (r renamed)
        (let ((to (orgspec-requirement-name r)))
          (when (member to added-names)
            (err "RENAMED TO collides with ADDED for \"%s\"" to)))))
    (nreverse errors)))

(defun orgspec-validate-change-or-signal (change)
  "Validate CHANGE; signal a `user-error' listing every problem, else return t."
  (let ((errors (orgspec-validate-change change)))
    (when errors
      (user-error "orgspec validation failed:\n- %s"
                  (string-join errors "\n- ")))
    t))

(provide 'orgspec-validate)
;;; orgspec-validate.el ends here
