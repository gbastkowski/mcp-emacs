;;; orgspec-fold.el --- Fold a change delta into the spec files  -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.8.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The fold: apply a change's delta requirements to the accumulating spec
;; files.  This is the load-bearing OpenSpec port (issue #5).
;;
;; Design, all ported from OpenSpec / the fold spike:
;; - Apply order is fixed: RENAMED -> REMOVED -> MODIFIED -> ADDED.
;; - Subtree surgery on org buffers, not text splicing: cut a delta
;;   requirement (stored L2 under `* Delta') and `org-paste-subtree'-it into
;;   the spec at L1, letting org re-level the whole subtree; then strip the
;;   TODO keyword, the op tag, and the `:AREA:' routing property, and keep the
;;   `:IMPL:' drawer.  (Proven in test/orgspec-fold-spike-test.el.)
;; - Validate-all-then-write-all: every target spec is built in a temp buffer
;;   and the whole set validated before anything is written, so a late failure
;;   leaves the on-disk specs untouched.
;; - MODIFIED must not silently drop a scenario present in the current spec
;;   requirement (port of OpenSpec's findMissingCurrentScenarios) -- a dropped
;;   scenario is an error, not a silent loss.

;;; Code:

(require 'org)
(require 'cl-lib)
(require 'orgspec)
(require 'orgspec-model)
(require 'orgspec-parse)

(define-error 'orgspec-fold-error "orgspec fold error")

(defun orgspec-fold--group-by-area (requirements)
  "Group REQUIREMENTS by their `:AREA:'; return an alist (AREA . REQS).
Signals `orgspec-fold-error' if any requirement has no area."
  (let (groups)
    (dolist (req requirements)
      (let ((area (orgspec-requirement-area req)))
        (unless area
          (signal 'orgspec-fold-error
                  (list (format "requirement %S has no :AREA:"
                                (orgspec-requirement-name req)))))
        (let ((cell (assoc area groups)))
          (if cell (setcdr cell (cons req (cdr cell)))
            (push (cons area (list req)) groups)))))
    (mapcar (lambda (cell) (cons (car cell) (nreverse (cdr cell)))) groups)))

(defun orgspec-fold--find-requirement (name)
  "Move point to the L1 spec requirement headline named NAME; return non-nil.
Point is left on the headline.  Returns nil and does not move if absent."
  (let ((found nil) (pos (point)))
    (goto-char (point-min))
    (while (and (not found)
                (re-search-forward "^\\* \\(.*\\)$" nil t))
      (when (equal (string-trim (match-string 1)) name)
        (org-back-to-heading t)
        (setq found (point))))
    (unless found (goto-char pos))
    found))

(defun orgspec-fold--scenario-names-at-point ()
  "Return the L2 scenario headline names under the L1 requirement at point."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (org-end-of-subtree t t)))
          names)
      (forward-line 1)
      (while (re-search-forward "^\\*\\* \\(.*\\)$" end t)
        (push (string-trim (match-string 1)) names))
      (nreverse names))))

(defun orgspec-fold--clean-pasted ()
  "Clean the requirement subtree at point after a fold paste.
Strip the TODO keyword, the op tag, and the `:AREA:' routing property;
keep the `:IMPL:' drawer.  Point must be on the requirement headline."
  (org-back-to-heading t)
  (org-todo 'none)
  (org-set-tags nil)
  (org-entry-delete (point) orgspec-area-property))

(defun orgspec-fold--paste-requirement (req)
  "Paste delta requirement REQ into the current spec buffer at L1, cleaned.
Point should be where the requirement is to land (end of buffer for an
add).  REQ's subtree text is taken from its stored source region."
  (org-paste-subtree 1 (orgspec-requirement-source req))
  (save-excursion
    (org-back-to-heading t)
    (orgspec-fold--clean-pasted)))

;;;; Per-op application (operate on the current spec buffer)

(defun orgspec-fold--apply-renamed (req)
  "Rename the spec requirement from REQ's `:FROM:' to REQ's name."
  (let ((from (orgspec-requirement-from req))
        (to (orgspec-requirement-name req)))
    (unless from
      (signal 'orgspec-fold-error
              (list (format "renamed %S has no :FROM:" to))))
    (unless (orgspec-fold--find-requirement from)
      (signal 'orgspec-fold-error
              (list (format "renamed source %S not found" from))))
    (org-edit-headline to)))

(defun orgspec-fold--apply-removed (req)
  "Remove the spec requirement named by REQ."
  (let ((name (orgspec-requirement-name req)))
    (unless (orgspec-fold--find-requirement name)
      (signal 'orgspec-fold-error
              (list (format "removed target %S not found" name))))
    (org-cut-subtree)))

(defun orgspec-fold--apply-modified (req)
  "Replace the spec requirement named by REQ, guarding against scenario loss.
The MODIFIED delta must carry every scenario the current spec requirement
has; a dropped scenario signals `orgspec-fold-error'."
  (let ((name (orgspec-requirement-name req)))
    (unless (orgspec-fold--find-requirement name)
      (signal 'orgspec-fold-error
              (list (format "modified target %S not found" name))))
    (let* ((current (orgspec-fold--scenario-names-at-point))
           (incoming (mapcar #'orgspec-scenario-name
                             (orgspec-requirement-scenarios req)))
           (missing (seq-remove (lambda (s) (member s incoming)) current)))
      (when missing
        (signal 'orgspec-fold-error
                (list (format "modified %S drops scenario(s): %s"
                              name (string-join missing ", "))))))
    (org-cut-subtree)
    (orgspec-fold--paste-requirement req)))

(defun orgspec-fold--apply-added (req)
  "Append the ADDED requirement REQ to the end of the current spec buffer.
Signals if a requirement of the same name already exists."
  (let ((name (orgspec-requirement-name req)))
    (when (orgspec-fold--find-requirement name)
      (signal 'orgspec-fold-error
              (list (format "added %S already exists in spec" name))))
    (goto-char (point-max))
    (orgspec-fold--paste-requirement req)))

(defun orgspec-fold--apply-one (req)
  "Apply a single delta requirement REQ to the current spec buffer."
  (pcase (orgspec-requirement-op req)
    ('renamed (orgspec-fold--apply-renamed req))
    ('removed (orgspec-fold--apply-removed req))
    ('modified (orgspec-fold--apply-modified req))
    ('added (orgspec-fold--apply-added req))
    (op (signal 'orgspec-fold-error (list (format "unknown op %S" op))))))

(defun orgspec-fold-area (spec-text requirements)
  "Return the new spec text for one area.
SPEC-TEXT is the current on-disk spec (empty string for a new area).
REQUIREMENTS is the area's delta requirements.  Applies the four ops in
`orgspec-fold-order'.  Pure: builds the result in a temp buffer and
returns the string; writes nothing."
  (with-temp-buffer
    (let ((org-inhibit-startup t)) (org-mode))
    (insert (or spec-text ""))
    (dolist (op orgspec-fold-order)
      (dolist (req requirements)
        (when (eq (orgspec-requirement-op req) op)
          (goto-char (point-min))
          (orgspec-fold--apply-one req))))
    (buffer-string)))

(provide 'orgspec-fold)
;;; orgspec-fold.el ends here
