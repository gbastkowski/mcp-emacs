;;; orgspec-commands.el --- Interactive orgspec verbs  -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The orgspec command verbs (issue #5, step 6): `new', `status', `archive'.
;; MVP-drivable through mcp-emacs' `eval' tool -- e.g. (orgspec-archive "id").
;;
;; Layout under the orgspec root (default `orgspec/'):
;;   orgspec/specs/<area>.org           accumulating source of truth
;;   orgspec/changes/<id>/change.org    a change (human sections + `* Delta')
;;   orgspec/changes/archive/<id>/      archived changes
;;
;; `archive' folds a change's delta into the specs with the same
;; validate-all-then-write-all discipline `orgspec-fold-area' gives per area:
;; every target spec is rebuilt in memory and the whole set is only written
;; once all folds succeed, so a late failure leaves `specs/' untouched.

;;; Code:

(require 'cl-lib)
(require 'orgspec)
(require 'orgspec-model)
(require 'orgspec-parse)
(require 'orgspec-fold)

(defcustom orgspec-root "orgspec"
  "Directory (relative to the project root) holding specs and changes."
  :type 'string :group 'orgspec)

(defun orgspec-commands--root ()
  "Return the absolute orgspec root for the current project."
  (let ((base (or (and (fboundp 'project-current)
                       (when-let ((p (project-current nil)))
                         (project-root p)))
                  default-directory)))
    (expand-file-name orgspec-root base)))

(defun orgspec-commands--changes-dir () (expand-file-name "changes" (orgspec-commands--root)))
(defun orgspec-commands--specs-dir () (expand-file-name "specs" (orgspec-commands--root)))
(defun orgspec-commands--change-file (id)
  (expand-file-name (format "changes/%s/change.org" id) (orgspec-commands--root)))
(defun orgspec-commands--spec-file (area)
  (expand-file-name (format "specs/%s.org" area) (orgspec-commands--root)))

;;;; new

(defconst orgspec-commands--change-template "\
#+TITLE: %s

* Intent
* Scope
* Approach
* Tasks
- [ ] first task

* Delta
")

;;;###autoload
(defun orgspec-new (id)
  "Scaffold a new change ID under the orgspec changes directory.
Creates changes/ID/change.org from the template.  Returns the file path."
  (interactive "sChange id: ")
  (let ((file (orgspec-commands--change-file id)))
    (when (file-exists-p file)
      (user-error "Change %s already exists" id))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (format orgspec-commands--change-template id)))
    file))

;;;; status

(defun orgspec-commands--count-tasks (file)
  "Return (DONE . TOTAL) checkbox counts in change FILE."
  (let ((done 0) (total 0))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward "^[ \t]*- \\[\\([ xX]\\)\\]" nil t)
          (setq total (1+ total))
          (unless (equal (match-string 1) " ") (setq done (1+ done))))))
    (cons done total)))

;;;###autoload
(defun orgspec-status (&optional id)
  "Report task completion for change ID, or all active changes.
Returns an alist (ID (DONE . TOTAL) ...); as a command, messages it."
  (interactive)
  (let* ((dir (orgspec-commands--changes-dir))
         (ids (if id (list id)
                (when (file-directory-p dir)
                  (seq-filter
                   (lambda (n) (and (not (member n '("." ".." "archive")))
                                    (file-directory-p (expand-file-name n dir))))
                   (directory-files dir)))))
         (result (mapcar
                  (lambda (i)
                    (cons i (orgspec-commands--count-tasks
                             (orgspec-commands--change-file i))))
                  ids)))
    (when (called-interactively-p 'interactive)
      (message "%s"
               (mapconcat (lambda (c) (format "%s: %d/%d done"
                                              (car c) (cadr c) (cddr c)))
                          result "  ")))
    result))

;;;; archive

(defun orgspec-commands--read-change (id)
  "Parse change ID's change.org into an `orgspec-change'."
  (let ((file (orgspec-commands--change-file id)))
    (unless (file-exists-p file)
      (user-error "No change file for %s" id))
    (with-temp-buffer
      (insert-file-contents file)
      (let ((org-inhibit-startup t)) (org-mode))
      (orgspec-parse-change id))))

(defun orgspec-commands--assert-no-clarifications (id)
  "Signal a `user-error' if change ID still has a NEEDS CLARIFICATION marker."
  (let ((file (orgspec-commands--change-file id)))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (when (re-search-forward orgspec-clarification-regexp nil t)
        (user-error "Change %s has an unresolved [NEEDS CLARIFICATION] marker" id)))))

(defun orgspec-commands-fold-build (id)
  "Fold change ID's delta in memory; return an alist (SPEC-FILE . NEW-TEXT).
Every affected spec is rebuilt in a temp buffer (validate-all) and the
whole set returned without writing anything, so callers can write it
atomically (`orgspec-archive') or diff it before writing
(`orgspec-review-fold').  Signals if the change has no delta
requirements.  Order matches the change's area grouping."
  (orgspec-commands--assert-no-clarifications id)
  (let* ((change (orgspec-commands--read-change id))
         (reqs (orgspec-change-requirements change))
         (groups (orgspec-fold--group-by-area reqs))
         built)
    (unless reqs
      (user-error "Change %s has no delta requirements" id))
    (dolist (group groups)
      (let* ((area (car group))
             (file (orgspec-commands--spec-file area))
             (current (when (file-exists-p file)
                        (with-temp-buffer (insert-file-contents file)
                                          (buffer-string)))))
        (push (cons file (orgspec-fold-area current (cdr group))) built)))
    (nreverse built)))

;;;###autoload
(defun orgspec-archive (id)
  "Fold change ID's delta into the specs, then move the change to archive.
Validate-all-then-write-all: every affected spec is rebuilt in memory
via `orgspec-commands-fold-build' and only written once all folds
succeed, so a failure leaves specs/ untouched.  Uses `git mv' to archive
the change when the project is a git repo, else a plain rename.  Returns
the list of spec files written."
  (interactive "sChange id to archive: ")
  (let ((built (orgspec-commands-fold-build id)))
    ;; Write every target (write-all) only after all folds succeeded.
    (dolist (cell built)
      (make-directory (file-name-directory (car cell)) t)
      (with-temp-file (car cell) (insert (cdr cell))))
    ;; Move the change into archive.
    (orgspec-commands--archive-move id)
    (mapcar #'car built)))

(defun orgspec-commands--archive-move (id)
  "Move change ID's directory into changes/archive/, via `git mv' if possible."
  (let* ((src (expand-file-name id (orgspec-commands--changes-dir)))
         (archive (expand-file-name "archive" (orgspec-commands--changes-dir)))
         (dst (expand-file-name id archive)))
    (make-directory archive t)
    (if (and (executable-find "git")
             (zerop (call-process "git" nil nil nil "-C"
                                  (file-name-directory (directory-file-name src))
                                  "rev-parse" "--is-inside-work-tree")))
        (unless (zerop (call-process "git" nil nil nil "mv" src dst))
          (rename-file src dst))
      (rename-file src dst))))

(provide 'orgspec-commands)
;;; orgspec-commands.el ends here
