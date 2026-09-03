;;; orgspec-lifecycle.el --- TODO lifecycle for orgspec delta requirements  -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.9.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The org-leverage layer's TODO lifecycle (issue #5, step 8).  Delta
;; requirements in a change file carry the user's existing TODO keywords, so
;; `apply' can move a requirement through its lifecycle.  The agenda dashboard
;; that reads these states lives in orgspec-agenda.el.
;;
;; Lifecycle role -> keyword (all read from the defcustoms in orgspec.el, so
;; nothing here invents workflow states):
;;   active   -> `orgspec-todo-active'   (STRT): `apply' is working it
;;   blocked  -> `orgspec-todo-blocked'  (WAIT): stuck on [NEEDS CLARIFICATION]
;;   removed  -> `orgspec-todo-removed'  (KILL): a :REMOVED: requirement
;;   done     -> org's own done state (`org-todo' with `done')
;;
;; The fold strips the TODO keyword on the way into specs/ (see orgspec-fold);
;; workflow state lives only in the change file, never the accumulating spec.

;;; Code:

(require 'org)
(require 'orgspec)

(defun orgspec-lifecycle-goto-requirement (name)
  "Move point to the delta requirement headline NAME in the current buffer.
A delta requirement is a level-2 headline under `* Delta'.  Returns
point on success, nil (and leaves point unmoved) if not found."
  (let ((start (point)))
    (goto-char (point-min))
    (if (re-search-forward
         (format "^\\*\\* +\\(?:[A-Z]+ +\\)?%s *\\(?::.*:\\)?$"
                 (regexp-quote name))
         nil t)
        (progn (org-back-to-heading t) (point))
      (goto-char start)
      nil)))

(defun orgspec-lifecycle--keyword-for-role (role)
  "Return the TODO keyword string for lifecycle ROLE, or the symbol `done'.
ROLE is one of the symbols `active', `blocked', `removed', `done'."
  (pcase role
    ('active orgspec-todo-active)
    ('blocked orgspec-todo-blocked)
    ('removed orgspec-todo-removed)
    ('done 'done)
    (_ (error "Unknown orgspec lifecycle role: %S" role))))

(defun orgspec-lifecycle-advance-at-point (role)
  "Set the requirement headline at point to lifecycle ROLE.
For `done' this uses org's own done handling (so logging/CLOSED behave
normally); otherwise it sets the mapped keyword explicitly."
  (org-back-to-heading t)
  (let ((kw (orgspec-lifecycle--keyword-for-role role)))
    (if (eq kw 'done)
        (org-todo 'done)
      (org-todo kw))))

(defun orgspec-lifecycle-advance (file name role)
  "In change FILE, advance delta requirement NAME to lifecycle ROLE.
Opens FILE, moves to the requirement, sets its keyword, and saves.
Signals a `user-error' if the requirement is not found.  Returns the
keyword that was set."
  (let ((buf (find-file-noselect file)))
    (with-current-buffer buf
      (save-excursion
        (unless (orgspec-lifecycle-goto-requirement name)
          (user-error "No delta requirement %S in %s" name file))
        (orgspec-lifecycle-advance-at-point role)
        (save-buffer)
        (org-get-todo-state)))))

(provide 'orgspec-lifecycle)
;;; orgspec-lifecycle.el ends here
