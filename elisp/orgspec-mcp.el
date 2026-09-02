;;; orgspec-mcp.el --- Typed MCP tools for orgspec  -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.8.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Typed MCP tools over the orgspec command verbs and the agenda lifecycle
;; (issue #5, step 7).  Promotes the `eval'-driven MVP shortcut to a proper
;; agent surface: each tool has a name, a JSON schema, and a handler that
;; returns human/agent-readable text.
;;
;; The tools are registered onto `mcp-emacs-server-extra-tools' at load time
;; (the server splices that in via `mcp-emacs-server--all-tools'), so requiring
;; this file is all it takes to expose them -- no edit to the core tool list.
;;
;; Tools:
;;   orgspec_new       scaffold changes/<id>/change.org
;;   orgspec_status    task-checkbox counts for one change or all
;;   orgspec_parse     a change's delta as structured data
;;   orgspec_archive   fold the delta into specs/ and archive the change
;;   orgspec_advance   set a delta requirement's lifecycle keyword
;;   orgspec_agenda    register the in-flight agenda command

;;; Code:

(require 'orgspec)
(require 'orgspec-model)
(require 'orgspec-commands)
(require 'orgspec-lifecycle)
(require 'orgspec-agenda)
(require 'orgspec-review)
(require 'orgspec-validate)
(require 'mcp-emacs-server)

;;;; Result formatting

(defun orgspec-mcp--format-status (alist)
  "Render an `orgspec-status' ALIST as readable lines."
  (if (null alist)
      "no active changes"
    (mapconcat (lambda (c) (format "%s: %d/%d tasks done"
                                   (car c) (cadr c) (cddr c)))
               alist "\n")))

(defun orgspec-mcp--format-change (change)
  "Render an `orgspec-change' CHANGE as a readable per-requirement summary."
  (let ((reqs (orgspec-change-requirements change)))
    (if (null reqs)
        (format "%s: no delta requirements" (orgspec-change-id change))
      (mapconcat
       (lambda (r)
         (format "- %s [%s] area=%s%s scenarios=%d"
                 (orgspec-requirement-name r)
                 (or (orgspec-requirement-op r) "?")
                 (or (orgspec-requirement-area r) "?")
                 (if (orgspec-requirement-from r)
                     (format " from=%S" (orgspec-requirement-from r)) "")
                 (length (orgspec-requirement-scenarios r))))
       reqs "\n"))))

;;;; Handlers

(defun orgspec-mcp--new (args)
  (orgspec-new (alist-get 'id args)))

(defun orgspec-mcp--status (args)
  (orgspec-mcp--format-status (orgspec-status (alist-get 'id args))))

(defun orgspec-mcp--parse (args)
  (orgspec-mcp--format-change
   (orgspec-commands--read-change (alist-get 'id args))))

(defun orgspec-mcp--archive (args)
  (let ((written (orgspec-archive (alist-get 'id args))))
    (format "wrote:\n%s" (mapconcat #'identity written "\n"))))

(defun orgspec-mcp--review (args)
  (let ((reviewed (orgspec-review-fold (alist-get 'id args))))
    (format "reviewing (ediff, nothing written):\n%s"
            (mapconcat #'identity reviewed "\n"))))

(defun orgspec-mcp--validate (args)
  (let ((errors (orgspec-validate-change
                 (orgspec-commands--read-change (alist-get 'id args)))))
    (if errors
        (format "invalid:\n- %s" (mapconcat #'identity errors "\n- "))
      "valid")))

(defun orgspec-mcp--advance (args)
  (let* ((id (alist-get 'id args))
         (name (alist-get 'requirement args))
         (role (intern (alist-get 'role args)))
         (file (orgspec-commands--change-file id)))
    (format "%s -> %s" name (orgspec-lifecycle-advance file name role))))

(defun orgspec-mcp--agenda (&optional _args)
  (orgspec-agenda-install (orgspec-commands--changes-dir))
  (format "registered agenda command under key %S" orgspec-agenda-key))

;;;; Project routing
;;
;; A caller reaching these tools over HTTP cannot see, let alone choose,
;; which buffer the target Emacs is visiting, so leaving the project to
;; `project-current' makes the acted-on repository unspecifiable from the
;; caller's side.  Every tool therefore accepts an optional `root'.

(defconst orgspec-mcp--root-description
  "Absolute path of the project to act on. Omit to use the Emacs session's current project."
  "Shared description for the `root' argument of every orgspec tool.")

(defun orgspec-mcp--with-root (handler)
  "Return HANDLER wrapped to honour the `root' argument in its args alist.
Binds `orgspec-project-root', so every orgspec path the handler resolves
belongs to the requested project rather than to whichever buffer the
Emacs session happens to be in."
  (lambda (args)
    (let ((orgspec-project-root (or (alist-get 'root args)
                                    orgspec-project-root)))
      (funcall handler args))))

(defun orgspec-mcp--root-prop ()
  "Return the `root' property pair for a tool schema."
  (list "root" (mcp-emacs-server--prop
                "string" orgspec-mcp--root-description)))

(defun orgspec-mcp--id-schema (desc)
  (mcp-emacs-server--obj
   "type" "object"
   "properties" (apply #'mcp-emacs-server--obj
                       (append
                        (list "id" (mcp-emacs-server--prop "string" desc))
                        (orgspec-mcp--root-prop)))
   "required" (vector "id")))

(defconst orgspec-mcp--tools
  (list
   (list :name "orgspec_new"
         :description "Scaffold a new orgspec change (changes/<id>/change.org)"
         :schema (orgspec-mcp--id-schema "Change id (kebab-case)")
         :handler #'orgspec-mcp--new)
   (list :name "orgspec_status"
         :description "Report task-checkbox completion for one change or all active changes"
         :schema (mcp-emacs-server--obj
                  "type" "object"
                  "properties" (apply #'mcp-emacs-server--obj
                                      (append
                                       (list "id" (mcp-emacs-server--prop
                                                   "string" "Change id, or omit for all active changes"))
                                       (orgspec-mcp--root-prop))))
         :handler #'orgspec-mcp--status)
   (list :name "orgspec_parse"
         :description "Read a change's delta as structured data (per-requirement op/area/scenarios)"
         :schema (orgspec-mcp--id-schema "Change id to parse")
         :handler #'orgspec-mcp--parse)
   (list :name "orgspec_archive"
         :description "Fold a change's delta into specs/ and move the change to archive"
         :schema (orgspec-mcp--id-schema "Change id to archive")
         :handler #'orgspec-mcp--archive)
   (list :name "orgspec_review"
         :description "Ediff a change's fold against the current specs before writing (writes nothing)"
         :schema (orgspec-mcp--id-schema "Change id to review")
         :handler #'orgspec-mcp--review)
   (list :name "orgspec_validate"
         :description "Run the hard-gate validator over a change; report problems or \"valid\""
         :schema (orgspec-mcp--id-schema "Change id to validate")
         :handler #'orgspec-mcp--validate)
   (list :name "orgspec_advance"
         :description "Set a delta requirement's lifecycle TODO keyword (active/blocked/removed/done)"
         :schema (mcp-emacs-server--obj
                  "type" "object"
                  "properties" (apply #'mcp-emacs-server--obj
                                      (append
                                       (list "id" (mcp-emacs-server--prop "string" "Change id")
                                             "requirement" (mcp-emacs-server--prop
                                                            "string" "Exact requirement headline text")
                                             "role" (mcp-emacs-server--obj
                                                     "type" "string"
                                                     "description" "Lifecycle role"
                                                     "enum" (vector "active" "blocked" "removed" "done")))
                                       (orgspec-mcp--root-prop)))
                  "required" (vector "id" "requirement" "role"))
         :handler #'orgspec-mcp--advance)
   (list :name "orgspec_agenda"
         :description "Register the orgspec in-flight-requirements agenda custom command"
         :schema (mcp-emacs-server--obj
                  "type" "object"
                  "properties" (apply #'mcp-emacs-server--obj
                                      (orgspec-mcp--root-prop)))
         :handler #'orgspec-mcp--agenda))
  "orgspec MCP tool descriptors, registered onto the server's extra-tools.")

;;;; Registration

(defun orgspec-mcp--routed-tools ()
  "Return `orgspec-mcp--tools' with every handler wrapped for `root'.
Wrapping once here, rather than in each handler, keeps the routing off
the handlers and applies to any tool added later."
  (mapcar (lambda (tl)
            (let ((copy (copy-sequence tl)))
              (plist-put copy :handler
                         (orgspec-mcp--with-root (plist-get tl :handler)))))
          orgspec-mcp--tools))

(defun orgspec-mcp-call (name args)
  "Invoke orgspec tool NAME with ARGS through its registered handler.
Goes via `orgspec-mcp--routed-tools', so `root' routing applies exactly
as it does for a request arriving at the server."
  (let ((tool (seq-find (lambda (tl) (equal (plist-get tl :name) name))
                        (orgspec-mcp--routed-tools))))
    (unless tool (error "No orgspec tool named %s" name))
    (funcall (plist-get tool :handler) args)))

(defun orgspec-mcp-register ()
  "Register the orgspec tools onto `mcp-emacs-server-extra-tools'.
Idempotent: replaces any previously registered orgspec descriptors."
  (let ((names (mapcar (lambda (tl) (plist-get tl :name)) orgspec-mcp--tools)))
    (setq mcp-emacs-server-extra-tools
          (append (orgspec-mcp--routed-tools)
                  (seq-remove (lambda (tl) (member (plist-get tl :name) names))
                              mcp-emacs-server-extra-tools)))))

(orgspec-mcp-register)

(provide 'orgspec-mcp)
;;; orgspec-mcp.el ends here
