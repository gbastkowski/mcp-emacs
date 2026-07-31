;;; orgspec.el --- Org-native spec workflow (OpenSpec-inspired)  -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; orgspec is a thin, org-native, dependency-free port of the load-bearing
;; core of OpenSpec: a structure parser, a delta-fold, and (later) a
;; validator, living in Emacs and exposed to agents through mcp-emacs.  See
;; issue #5 for the full design.
;;
;; This file holds the marker table -- the single place that names the delta
;; op tags, the routing/traceability properties, the clarification and RFC-2119
;; regexes, and the TODO-role mapping -- so nothing downstream hardcodes a
;; marker or a headline depth.

;;; Code:

(defgroup orgspec nil
  "Org-native spec workflow."
  :group 'tools)

;;;; Delta op tags

(defconst orgspec-op-tags
  '(("ADDED" . added)
    ("MODIFIED" . modified)
    ("REMOVED" . removed)
    ("RENAMED" . renamed))
  "Alist mapping the org op tag (as written on a delta headline) to a symbol.
Each delta requirement headline in a change file is tagged with exactly
one of these.")

(defun orgspec-op-from-tags (tags)
  "Return the orgspec op symbol found among TAGS, or nil.
TAGS is a list of org tag strings (as from `org-get-tags')."
  (seq-some (lambda (cell) (and (member (car cell) tags) (cdr cell)))
            orgspec-op-tags))

(defun orgspec-op-tag-name (op)
  "Return the org tag string for op symbol OP, or nil."
  (car (rassq op orgspec-op-tags)))

;;;; Properties and drawers

(defconst orgspec-area-property "AREA"
  "Org property naming the target spec file for a delta requirement.
Stripped from the requirement when it is folded into a spec -- it is
routing metadata, not durable spec content.")

(defconst orgspec-from-property "FROM"
  "Org property giving a renamed requirement's previous name.")

(defconst orgspec-impl-drawer "IMPL"
  "Org drawer holding requirement->code traceability links.
Kept when a requirement is folded into a spec -- durable provenance.")

;;;; Regexes

(defconst orgspec-clarification-regexp
  "\\[NEEDS CLARIFICATION:[^]]*\\]"
  "Regexp for an unresolved clarification marker.
Its presence blocks `apply'/`archive' until resolved.")

(defconst orgspec-normative-regexp
  "\\<\\(SHALL\\|MUST\\)\\>"
  "Regexp for an RFC-2119 normative keyword.
An ADDED/MODIFIED requirement body must contain one (validator rule).")

;;;; TODO-role mapping (issue #5 agenda lifecycle; used by MVP+)

(defcustom orgspec-todo-blocked "WAIT"
  "TODO keyword meaning a requirement is blocked on a clarification."
  :type 'string :group 'orgspec)

(defcustom orgspec-todo-active "STRT"
  "TODO keyword meaning `apply' is currently working a requirement."
  :type 'string :group 'orgspec)

(defcustom orgspec-todo-removed "KILL"
  "TODO keyword corresponding to a `:REMOVED:' requirement."
  :type 'string :group 'orgspec)

;;;; Fold apply order (OpenSpec parity)

(defconst orgspec-fold-order '(renamed removed modified added)
  "Fixed order in which delta ops are applied during a fold.")

(provide 'orgspec)
;;; orgspec.el ends here
