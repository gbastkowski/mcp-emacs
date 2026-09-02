;;; orgspec-commands.el --- Interactive orgspec verbs  -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.8.0
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
(require 'orgspec-validate)

(defcustom orgspec-root "orgspec"
  "Directory (relative to the project root) holding specs and changes."
  :type 'string :group 'orgspec)

(declare-function project-root "project" (project))

(defvar orgspec-project-root nil
  "Project root the orgspec commands act on, overriding project detection.
Nil means resolve from ambient editor state -- `project-current', then
`default-directory'.  Bind or set this when the caller knows the project
and the current buffer is not in it: an agent driving the `orgspec_*' MCP
tools has no control over which buffer the Emacs it is talking to happens
to be visiting, so \"whatever `project-current' says\" is not an input it
can supply.  Every orgspec path is derived from this, so one binding
covers new/status/apply/archive alike.")

(defun orgspec-commands--base ()
  "Return the project directory the orgspec root lives under.
`orgspec-project-root' wins when set; otherwise fall back to the ambient
project, then `default-directory'."
  (file-name-as-directory
   (expand-file-name
    (or orgspec-project-root
        (and (fboundp 'project-current)
             (when-let* ((p (project-current nil)))
               (project-root p)))
        default-directory))))

(defun orgspec-commands--root ()
  "Return the absolute orgspec root for the project being acted on."
  (expand-file-name orgspec-root (orgspec-commands--base)))

(defun orgspec-commands--guessed-project-p ()
  "Return non-nil when the acted-on project was inferred, not stated.
`orgspec-project-root' and a real `project-current' are both statements
about which project is meant; falling through to `default-directory' is
a guess, and a guess is what silently plants an `orgspec/' tree in an
unrelated repository."
  (not (or orgspec-project-root
           (and (fboundp 'project-current) (project-current nil)))))

(defun orgspec-commands--assert-initialised ()
  "Signal a `user-error' unless it is safe to act on the resolved root.
An existing `orgspec/' means the project already opted in, so anything
goes.  Without one, only a *stated* project may create the tree: a root
that came from `default-directory' alone is a guess, and creating a
spec tree there is the silent-write bug this guards."
  (let ((root (orgspec-commands--root)))
    (when (and (not (file-directory-p root))
               (orgspec-commands--guessed-project-p))
      (user-error
       (concat "Refusing to create %s: no project was stated and none was "
               "detected, so this path is a guess from `default-directory'. "
               "Set `orgspec-project-root' (or the `root' tool argument) "
               "to the project you mean")
       root))))

(defun orgspec-commands--assert-exists ()
  "Signal a `user-error' unless the resolved orgspec root exists.
For commands that read or rewrite an established tree, where creating
one would make no sense."
  (let ((root (orgspec-commands--root)))
    (unless (file-directory-p root)
      (user-error
       (concat "No orgspec root at %s. "
               "Set `orgspec-project-root' if this is the wrong project, "
               "or run `orgspec-init' to start using orgspec here")
       root))))

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
(defun orgspec-init ()
  "Create the orgspec root for the project being acted on.
The one command that may bring `orgspec/' into existence, so that every
other command can refuse a root that is not there rather than silently
creating one in whichever project happened to be resolved.  Returns the
root; harmless if it already exists."
  (interactive)
  (let ((root (orgspec-commands--root)))
    (make-directory (expand-file-name "changes" root) t)
    (make-directory (expand-file-name "specs" root) t)
    (when (called-interactively-p 'interactive)
      (message "orgspec root: %s" root))
    root))

;;;###autoload
(defun orgspec-new (id)
  "Scaffold a new change ID under the orgspec changes directory.
Creates changes/ID/change.org from the template.  Returns the file path.
Brings the orgspec root into existence when the project is a stated one,
but refuses to create a tree at a path merely guessed from
`default-directory' -- see `orgspec-commands--assert-initialised'."
  (interactive "sChange id: ")
  (orgspec-commands--assert-initialised)
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
  (orgspec-commands--assert-exists)
  (orgspec-commands--assert-no-clarifications id)
  (let* ((change (orgspec-commands--read-change id))
         (reqs (orgspec-change-requirements change))
         (groups (orgspec-fold--group-by-area reqs))
         built)
    ;; Hard gate: run the full validator before folding anything, so all
    ;; structural problems are reported up front (covers the no-delta case).
    (orgspec-validate-change-or-signal change)
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
