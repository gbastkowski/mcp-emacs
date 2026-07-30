;;; mcp-emacs-report.el --- Report tooling issues about mcp-emacs -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.2.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A helper to file a bug report or feature request about mcp-emacs
;; itself -- the MCP server's tools or a plugin skill -- as a GitHub
;; issue on the mcp-emacs repository, from inside the assistant.
;;
;; Filing tries the `gh' CLI first (`gh issue create'), then a direct
;; `gh api' call.  A GitHub MCP tool, when available, is preferred by the
;; orchestrating skill before this helper is reached; this module owns the
;; CLI and API fallbacks.  When no mechanism is available the composed
;; title and body are returned so the user can file the issue by hand.
;;
;; The target repository is fixed: this files issues about mcp-emacs, not
;; arbitrary repositories.

;;; Code:

(require 'cl-lib)
(require 'json)

(defconst mcp-emacs-report-repo "gbastkowski/mcp-emacs"
  "The GitHub repository issues are filed against.
This tool reports issues about mcp-emacs itself, so the target is
fixed rather than caller-chosen.")

(defconst mcp-emacs-report-kinds '("bug" "feature" "skill" "server")
  "Accepted values for the issue category.
Each is applied to the created issue as a GitHub label.")

(defun mcp-emacs-report--gh-available-p ()
  "Return non-nil when the `gh' CLI is on `exec-path'."
  (and (executable-find "gh") t))

(defun mcp-emacs-report--run (&rest args)
  "Run `gh' with ARGS, returning (cons EXIT-CODE TRIMMED-OUTPUT).
Combines stdout and stderr into the output string."
  (with-temp-buffer
    (let ((code (apply #'call-process "gh" nil t nil args)))
      (cons code (string-trim (buffer-string))))))

(defun mcp-emacs-report--create-via-cli (title body)
  "Create the issue via `gh issue create', returning the issue URL or nil.
TITLE and BODY are the issue title and body.  Returns nil when the CLI
call fails for any reason, so the caller can fall back to the API."
  (let* ((args (append (list "issue" "create"
                             "--repo" mcp-emacs-report-repo
                             "--title" title)
                       (when (and body (not (string-empty-p body)))
                         (list "--body" body))))
         (result (apply #'mcp-emacs-report--run args)))
    (when (zerop (car result))
      ;; `gh issue create' prints the new issue URL on success.
      (let ((url (car (last (split-string (cdr result) "\n" t)))))
        (and url (string-match-p "^https?://" url) url)))))

(defun mcp-emacs-report--api-create (title body)
  "Create the issue via `gh api' with a temp-file payload; URL or nil.
TITLE and BODY are the issue title and body.  Lowest-level fallback for
when `gh issue create' is unavailable.  A temp file carries the JSON
payload because `call-process' cannot both send stdin and capture
output."
  (let ((tmp (make-temp-file "mcp-emacs-report" nil ".json"
                             (json-encode
                              (append (list (cons "title" title))
                                      (when (and body (not (string-empty-p body)))
                                        (list (cons "body" body))))))))
    (unwind-protect
        (let ((result (mcp-emacs-report--run
                       "api" (format "repos/%s/issues" mcp-emacs-report-repo)
                       "--method" "POST"
                       "--input" tmp
                       "-q" ".html_url")))
          (when (zerop (car result))
            (let ((url (string-trim (cdr result))))
              (and (string-match-p "^https?://" url) url))))
      (delete-file tmp))))

(defun mcp-emacs-report--apply-label (url kind)
  "Best-effort: apply KIND as a label to the issue at URL.
A missing label (or any labeling failure) is ignored -- the issue is
already created, which is what matters."
  (when (and kind url)
    (ignore-errors
      (mcp-emacs-report--run
       "issue" "edit" url "--repo" mcp-emacs-report-repo "--add-label" kind))))

(defun mcp-emacs-report--manual-fallback (title body)
  "Return the manual-filing text for TITLE and BODY.
Used when no filing mechanism is available."
  (format "Could not file the issue automatically (no GitHub mechanism available).
File it manually at https://github.com/%s/issues/new with:

Title: %s

%s"
          mcp-emacs-report-repo title (or body "")))

(defun mcp-emacs-report-tooling-issue (title &optional description kind)
  "File a GitHub issue about mcp-emacs and return a result string.
TITLE is required.  DESCRIPTION is the optional issue body.  KIND, when
given, must be one of `mcp-emacs-report-kinds' and is applied as a label
best-effort.  Files via `gh issue create', falling back to `gh api'.
On success returns \"Created issue: URL\"; when no mechanism is available
returns the manual-filing text so the caller can file by hand.  Signals a
`user-error' on a missing title or an out-of-set KIND."
  (unless (and (stringp title) (not (string-empty-p (string-trim title))))
    (user-error "A title is required to file an issue"))
  (when (and kind (not (member kind mcp-emacs-report-kinds)))
    (user-error "Invalid kind %S; must be one of: %s"
                kind (string-join mcp-emacs-report-kinds ", ")))
  (if (not (mcp-emacs-report--gh-available-p))
      (mcp-emacs-report--manual-fallback title description)
    (let ((url (or (mcp-emacs-report--create-via-cli title description)
                   (mcp-emacs-report--api-create title description))))
      (if url
          (progn
            (mcp-emacs-report--apply-label url kind)
            (format "Created issue: %s" url))
        (mcp-emacs-report--manual-fallback title description)))))

(provide 'mcp-emacs-report)
;;; mcp-emacs-report.el ends here
