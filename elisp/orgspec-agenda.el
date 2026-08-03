;;; orgspec-agenda.el --- In-flight dashboard for orgspec  -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The org-leverage layer's in-flight dashboard (issue #5, step 8).  Because
;; delta requirements carry the user's TODO keywords (set by the lifecycle
;; helpers in orgspec-lifecycle.el), one `org-agenda-custom-commands' entry
;; over the change files becomes the "in-flight requirements" view OpenSpec had
;; to build by hand.  This file owns only the read/dashboard side; advancing a
;; requirement's state is orgspec-lifecycle.el.

;;; Code:

(require 'org)
(require 'org-agenda)
(require 'orgspec)

(defcustom orgspec-agenda-key "o"
  "Dispatch key for the orgspec in-flight agenda custom command."
  :type 'string :group 'orgspec)

(defun orgspec-agenda-files (changes-dir)
  "Return the list of change.org files under CHANGES-DIR (active only).
Archived changes (under an `archive/' subdir) are excluded."
  (when (file-directory-p changes-dir)
    (seq-filter
     #'file-exists-p
     (mapcar (lambda (id) (expand-file-name (format "%s/change.org" id)
                                            changes-dir))
             (seq-filter
              (lambda (n) (and (not (member n '("." ".." "archive")))
                               (file-directory-p (expand-file-name n changes-dir))))
              (directory-files changes-dir))))))

(defun orgspec-agenda-install (changes-dir)
  "Register the orgspec in-flight agenda command over CHANGES-DIR.
Adds an `org-agenda-custom-commands' entry under `orgspec-agenda-key'
that lists every delta requirement (any op tag) with an active TODO
state across the change files.  Idempotent."
  (let* ((tag-match (mapconcat #'car orgspec-op-tags "|"))
         (entry
          `(,orgspec-agenda-key "orgspec in-flight requirements"
            tags-todo ,(format "+{%s}" tag-match)
            ((org-agenda-files ',(orgspec-agenda-files changes-dir))
             (org-agenda-overriding-header
              "orgspec: in-flight delta requirements")))))
    (setq org-agenda-custom-commands
          (cons entry
                (assoc-delete-all orgspec-agenda-key org-agenda-custom-commands)))
    entry))

(provide 'orgspec-agenda)
;;; orgspec-agenda.el ends here
