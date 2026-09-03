;;; orgspec-model.el --- Data model for orgspec  -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.9.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The three structures the orgspec parser produces and the fold/validator
;; consume: a scenario, a requirement, and a change.  See issue #5.
;;
;; Identity rules (issue #5, "Grammar gotchas"):
;; - Requirement identity is its exact headline text; renames are handled via
;;   the `:FROM:' property (captured in `orgspec-requirement-from').
;; - Scenario identity is its headline text (used by the MODIFIED drop guard).

;;; Code:

(require 'cl-lib)

(cl-defstruct (orgspec-scenario (:constructor orgspec-scenario-create))
  "One scenario under a requirement.
NAME is the scenario headline text (its identity).  BODY is the raw
GIVEN/WHEN/THEN text, kept verbatim -- orgspec counts scenario headlines,
not their body lines."
  name
  body)

(cl-defstruct (orgspec-requirement (:constructor orgspec-requirement-create))
  "One requirement, in a change delta or in a spec.
NAME is the headline text (identity).  OP is the delta operation keyword
\(`added' / `modified' / `removed' / `renamed', from the org op tag) or nil
for a plain spec requirement.  AREA is the target spec name (from the
`:AREA:' property).  FROM is the previous name for a rename (from `:FROM:').
BODY is the requirement prose (must carry SHALL/MUST for ADDED/MODIFIED).
SCENARIOS is a list of `orgspec-scenario'.  IMPL is the list of raw
traceability entries from the `:IMPL:' drawer, kept through the fold.
SOURCE is the requirement's raw org subtree text, used verbatim by the
fold's `org-paste-subtree' (so the pasted content matches the change file
exactly, drawers and all)."
  name
  op
  area
  from
  body
  (scenarios nil)
  (impl nil)
  source)

(cl-defstruct (orgspec-change (:constructor orgspec-change-create))
  "A parsed change: its id and the delta requirements it carries.
ID is the change directory name.  REQUIREMENTS is a list of
`orgspec-requirement', each with a non-nil OP."
  id
  (requirements nil))

(provide 'orgspec-model)
;;; orgspec-model.el ends here
