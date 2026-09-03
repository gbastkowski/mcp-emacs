;;; orgspec-parse.el --- Parse orgspec change/spec buffers into the model  -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.9.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Extract the orgspec model from org buffers using `org-element'.  Going
;; org-native removes the two hardest OpenSpec ports: `org-element' already
;; sees code blocks/drawers and headline levels correctly, so there is no
;; code-fence mask and no hand-rolled section-tree parser (issue #5).
;;
;; Two entry points:
;; - `orgspec-parse-change'  : a change buffer's `* Delta' subtree ->
;;                             `orgspec-change' (L2 requirements, L3 scenarios).
;; - `orgspec-parse-spec'    : a spec buffer -> list of `orgspec-requirement'
;;                             (L1 requirements, L2 scenarios, no op).

;;; Code:

(require 'org)
(require 'org-element)
(require 'orgspec)
(require 'orgspec-model)

(defun orgspec-parse--section-elements (headline)
  "Return the elements in HEADLINE's own section (its direct prose/drawers).
`org-element' nests a headline's non-headline content under a `section'
element; descend into it so paragraphs and drawers are visible."
  (let ((section (seq-find (lambda (el) (eq (org-element-type el) 'section))
                           (org-element-contents headline))))
    (and section (org-element-contents section))))

(defun orgspec-parse--body (headline)
  "Return the plain paragraph text directly under HEADLINE, trimmed.
Excludes child headlines, drawers, and property drawers -- just the
requirement/scenario prose."
  (let ((parts '()))
    (dolist (el (orgspec-parse--section-elements headline))
      (when (memq (org-element-type el) '(paragraph plain-list))
        (push (string-trim
               (buffer-substring-no-properties
                (org-element-property :contents-begin el)
                (org-element-property :contents-end el)))
              parts)))
    (string-trim (string-join (nreverse parts) "\n"))))

(defun orgspec-parse--impl (headline)
  "Return the list of non-empty lines in HEADLINE's IMPL drawer, or nil."
  (let (lines)
    (dolist (el (orgspec-parse--section-elements headline))
      (when (and (eq (org-element-type el) 'drawer)
                 (equal (org-element-property :drawer-name el)
                        orgspec-impl-drawer))
        (setq lines
              (seq-remove
               #'string-empty-p
               (mapcar #'string-trim
                       (split-string
                        (buffer-substring-no-properties
                         (org-element-property :contents-begin el)
                         (org-element-property :contents-end el))
                        "\n" t))))))
    lines))

(defun orgspec-parse--scenarios (headline)
  "Return the list of `orgspec-scenario' for the child headlines of HEADLINE."
  (let (scenarios)
    (dolist (child (org-element-contents headline))
      (when (eq (org-element-type child) 'headline)
        (push (orgspec-scenario-create
               :name (org-element-property :raw-value child)
               :body (orgspec-parse--body child))
              scenarios)))
    (nreverse scenarios)))

(defun orgspec-parse--requirement (headline)
  "Build an `orgspec-requirement' from a requirement HEADLINE element.
Reads the op from the headline tags, AREA/FROM from properties, the IMPL
drawer, the body prose, and the child scenarios."
  (orgspec-requirement-create
   :name (org-element-property :raw-value headline)
   :op (orgspec-op-from-tags (org-element-property :tags headline))
   :area (org-element-property
          (intern (concat ":" orgspec-area-property)) headline)
   :from (org-element-property
          (intern (concat ":" orgspec-from-property)) headline)
   :body (orgspec-parse--body headline)
   :scenarios (orgspec-parse--scenarios headline)
   :impl (orgspec-parse--impl headline)
   :source (buffer-substring-no-properties
            (org-element-property :begin headline)
            (org-element-property :end headline))))

(defun orgspec-parse-change (&optional id)
  "Parse the current buffer's `* Delta' subtree into an `orgspec-change'.
ID names the change (its directory).  Delta requirements are the level-2
headlines under the top-level `Delta' headline; their scenarios are the
level-3 children."
  (let ((tree (org-element-parse-buffer))
        requirements)
    (org-element-map tree 'headline
      (lambda (hl)
        (when (and (= (org-element-property :level hl) 1)
                   (equal (org-element-property :raw-value hl) "Delta"))
          (dolist (child (org-element-contents hl))
            (when (eq (org-element-type child) 'headline)
              (push (orgspec-parse--requirement child) requirements))))))
    (orgspec-change-create :id id
                           :requirements (nreverse requirements))))

(defun orgspec-parse-spec ()
  "Parse the current buffer as a spec into a list of `orgspec-requirement'.
Requirements are the level-1 headlines; scenarios their level-2 children.
Spec requirements carry no op."
  (let ((tree (org-element-parse-buffer))
        requirements)
    (org-element-map tree 'headline
      (lambda (hl)
        (when (= (org-element-property :level hl) 1)
          (push (orgspec-parse--requirement hl) requirements))))
    (nreverse requirements)))

(provide 'orgspec-parse)
;;; orgspec-parse.el ends here
