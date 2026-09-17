;;; mcp-emacs-report.el --- Report tooling issues about mcp-emacs -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.12.0
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
;;
;; Two interactive entry points -- `mcp-emacs-report-bug' and
;; `mcp-emacs-report-feature' -- let the human file without an assistant
;; in the loop (issues #83, #82).  Both open a composition buffer rather
;; than reading the minibuffer, because the point is to write the report
;; down and get back to work: an idea worth filing usually arrives
;; mid-task, and a minibuffer that cannot hold a paragraph is how it gets
;; dropped instead.  The buffer is `agent-prompt-read', which already
;; solves the composition shape (multiline, `C-c C-c' to file, `C-c C-k'
;; to abandon, `ZZ'/`ZQ' and insert state under evil) -- a second author
;; buffer would only drift from it.
;;
;; Filing happens from that buffer's callback, so the two commands are
;; asynchronous: they return as soon as the buffer is up, and the issue
;; URL arrives in the echo area later.  The non-interactive core
;; (`mcp-emacs-report-tooling-issue') stays synchronous and directly
;; callable, so the MCP tool and the tests are unaffected.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)

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

;;;; Composing a report interactively

;; The composition buffer collects one piece of text, and an issue needs
;; two fields.  Rather than ask twice -- a second prompt is exactly the
;; interruption these commands exist to avoid -- the first line is the
;; title and the rest is the body, the shape `git commit' already trained
;; everyone on.

(declare-function agent-prompt-read "agent-prompt"
                  (callback &optional initial label output-window source))
(declare-function agent-prompt-region-seed "agent-prompt" (&optional buffer))

(defgroup mcp-emacs-report nil
  "Filing issues about mcp-emacs itself."
  :group 'tools
  :prefix "mcp-emacs-report-")

(defconst mcp-emacs-report--templates
  '(("bug" . "What happened:\n\nWhat you expected:\n\nHow to reproduce:\n"))
  "Body scaffolding offered per kind, keyed by `mcp-emacs-report-kinds' value.
Only kinds that benefit from scaffolding are covered -- the prompts are
the things a report is useless without, so a note written in thirty
seconds still says enough to act on later.  `feature' receives none and
opens empty (modulo an active region), the same as
`mcp-emacs-report-template' being nil.  Headings left empty are stripped
before filing, so the scaffold costs nothing when the human would rather
just write a sentence.")

(defcustom mcp-emacs-report-template t
  "When non-nil, seed the report buffer with per-kind prompting headings.
See `mcp-emacs-report--templates'.  Nil opens an empty buffer for anyone
who finds the scaffold more noise than help."
  :type 'boolean
  :group 'mcp-emacs-report)

(defvar mcp-emacs-report-last-text nil
  "Text of the most recently composed report.
Kept so a report is recoverable when filing fails after the composition
buffer has already been closed.")

(defun mcp-emacs-report--heading-p (line)
  "Return non-nil when LINE is a template heading with nothing after it.
Headings are the `Something:' lines from `mcp-emacs-report--templates'."
  (and line (string-match-p "\\`[A-Z][^\n]*:[ \t]*\\'" line)))

(defun mcp-emacs-report--strip-empty-headings (body)
  "Return BODY with template headings that were never filled in removed.
A heading followed by nothing but another heading, or by the end of the
text, is scaffolding the human declined to use -- shipping it makes the
issue look answered when it is not."
  (let ((lines (split-string (or body "") "\n"))
        (kept nil))
    (while lines
      (let ((line (car lines))
            (rest (cdr lines)))
        ;; Look ahead past blank lines: a heading survives only when
        ;; something other than another heading follows it.
        (if (and (mcp-emacs-report--heading-p line)
                 (let ((ahead (seq-drop-while #'string-blank-p rest)))
                   (or (null ahead)
                       (mcp-emacs-report--heading-p (car ahead)))))
            (setq lines (seq-drop-while #'string-blank-p rest))
          (push line kept)
          (setq lines rest))))
    (string-trim (string-join (nreverse kept) "\n"))))

(defun mcp-emacs-report--split (text)
  "Split TEXT into (TITLE . BODY) at its first line.
The first line is the title; everything after it is the body, with
template headings the human left untouched removed.  BODY is nil when
nothing is left, so a one-line report files as a bare title."
  (let* ((trimmed (string-trim text))
         (newline (string-search "\n" trimmed))
         (title (string-trim (if newline (substring trimmed 0 newline) trimmed)))
         (rest (and newline (substring trimmed (1+ newline))))
         (body (mcp-emacs-report--strip-empty-headings rest)))
    (cons title (and (not (string-empty-p body)) body))))

(defun mcp-emacs-report--recover (result text)
  "Show RESULT in `*mcp-emacs-report*', appending TEXT when absent from it.
Called when filing did not produce an issue: the composition buffer is
gone by then, so what the human wrote has to land somewhere visible."
  (with-current-buffer (get-buffer-create "*mcp-emacs-report*")
    (erase-buffer)
    (insert result)
    (unless (string-search text result)
      (insert "\n\nWhat you wrote:\n\n" text))
    (goto-char (point-min))
    (display-buffer (current-buffer))))

(defun mcp-emacs-report--file-composed (kind text)
  "File TEXT as an issue of KIND and report the outcome.
TEXT is a composition buffer's contents, split by
`mcp-emacs-report--split'.  Runs after that buffer is gone, so a failure
must not lose what was typed: the text goes to
`mcp-emacs-report-last-text', and anything short of a created issue also
goes to `*mcp-emacs-report*' where it can be recovered."
  (setq mcp-emacs-report-last-text text)
  (pcase-let ((`(,title . ,body) (mcp-emacs-report--split text)))
    (if (string-empty-p title)
        (message "Nothing to file: the report needs at least a title")
      (let ((result (condition-case err
                        (mcp-emacs-report-tooling-issue title body kind)
                      (error (format "Filing failed: %s"
                                     (error-message-string err))))))
        ;; A "Created issue: URL" line is the whole story and belongs in
        ;; the echo area.  Anything else is text the human now has to act
        ;; on -- the manual-filing fallback, or an error -- so it gets a
        ;; buffer instead of scrolling past in a message.
        (if (string-prefix-p "Created issue: " result)
            (message "%s" result)
          (mcp-emacs-report--recover result text)
          (message "Could not file the issue; see *mcp-emacs-report*"))))))

(defun mcp-emacs-report--initial (kind source)
  "Return the seed text for a KIND report composed from SOURCE.
An active region in SOURCE goes in first -- the code in front of you is
usually what the report is about -- followed by KIND's template.  A
leading blank line keeps the first line free for the title."
  (let* ((seed (and source
                    (fboundp 'agent-prompt-region-seed)
                    (agent-prompt-region-seed source)))
         (template (and mcp-emacs-report-template
                        (cdr (assoc kind mcp-emacs-report--templates))))
         (below (string-join (delq nil (list seed template)) "\n\n")))
    (unless (string-empty-p below)
      (concat "\n\n" below))))

(defun mcp-emacs-report--compose (kind label)
  "Open a composition buffer for an issue of KIND, named LABEL.
The first line becomes the title and the rest the body; see
`mcp-emacs-report--split'."
  (require 'agent-prompt)
  (let ((buffer (agent-prompt-read
                 (lambda (text) (mcp-emacs-report--file-composed kind text))
                 (mcp-emacs-report--initial kind (current-buffer))
                 label)))
    ;; `agent-prompt-read' leaves point after the seed, which is right for
    ;; a prompt and wrong here: the title is line 1.
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (goto-char (point-min))))
    (message "%s: first line is the title, %s to file"
             (capitalize label)
             (substitute-command-keys "\\<agent-prompt-mode-map>\\[agent-prompt-send]"))
    buffer))

;;;###autoload
(defun mcp-emacs-report-bug ()
  "Compose a bug report about mcp-emacs and file it as a GitHub issue.
Opens a composition buffer: the first line is the issue title, the rest
is the body.  `C-c C-c' files it (labelled `bug'), `C-c C-k' abandons
it.  Filing happens after the buffer closes; the issue URL arrives in
the echo area."
  (interactive)
  (mcp-emacs-report--compose "bug" "bug report"))

;;;###autoload
(defun mcp-emacs-report-feature ()
  "Compose a feature request for mcp-emacs and file it as a GitHub issue.
Opens a composition buffer: the first line is the issue title, the rest
is the body.  `C-c C-c' files it (labelled `feature'), `C-c C-k' abandons
it.  Filing happens after the buffer closes; the issue URL arrives in
the echo area."
  (interactive)
  (mcp-emacs-report--compose "feature" "feature request"))

(provide 'mcp-emacs-report)
;;; mcp-emacs-report.el ends here
