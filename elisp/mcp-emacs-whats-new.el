;;; mcp-emacs-whats-new.el --- Show release notes since the last seen version -*- lexical-binding: t; -*-

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

;; A user who upgrades mcp-emacs should be able to find out what changed
;; without reading the git log.  `release.yml' writes a release-notes Org
;; file (`news/release-<ver>.org', one top-level headline per release)
;; into the checkout on every release; this module renders the files
;; newer than the last seen version in a read-only Org buffer.
;;
;; The "previously installed version" is recorded locally in a stamp file
;; (`.mcp-emacs-last-seen' by default), so deciding what is new needs no
;; network.  The installed version itself comes from the `Version:' header
;; of `mcp-emacs.el'.  With no stamp, every shipped release is shown
;; rather than none, so a first run is not silent.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org nil t)

(defgroup mcp-emacs-whats-new nil
  "Show what changed in mcp-emacs since the last seen version."
  :group 'tools
  :prefix "mcp-emacs-whats-new-")

(defcustom mcp-emacs-whats-new--stamp-file
  (locate-user-emacs-file ".mcp-emacs-last-seen")
  "File recording the last mcp-emacs version whose notes were shown.
It answers \"previously installed version\" without touching the
network, so each upgrade shows only the releases since the stamp."
  :type 'file
  :group 'mcp-emacs-whats-new)

(defcustom mcp-emacs-whats-new--release-notes-directory
  (locate-user-emacs-file "mcp-emacs-news")
  "Directory searched for release-notes Org files.
Only consulted when no `news/' directory ships next to the installed
`mcp-emacs.el'."
  :type 'directory
  :group 'mcp-emacs-whats-new)

(defconst mcp-emacs-whats-new--buffer-name "*mcp-emacs-whats-new*"
  "Name of the buffer showing the mcp-emacs release notes.")

(defun mcp-emacs-whats-new--installed-version (&optional file)
  "Return the version in the `Version:' header of FILE.
FILE defaults to the installed `mcp-emacs.el'.  Returns \"0.0.0\" when
the file cannot be read or carries no version header."
  (let ((file (or file (locate-library "mcp-emacs"))))
    (if (and file (file-readable-p file))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (if (re-search-forward "^;; Version:[ \t]*\\([^ \t\n]+\\)" nil t)
              (match-string 1)
            "0.0.0"))
      "0.0.0")))

(defun mcp-emacs-whats-new--read-stamp (&optional file)
  "Return the version recorded in stamp FILE, or nil when absent.
FILE defaults to `mcp-emacs-whats-new--stamp-file'."
  (let ((file (or file mcp-emacs-whats-new--stamp-file)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (let ((version (string-trim (buffer-string))))
          (unless (string-empty-p version)
            version))))))

(defun mcp-emacs-whats-new--write-stamp (version &optional file)
  "Write VERSION to stamp FILE, creating its parent directory.
FILE defaults to `mcp-emacs-whats-new--stamp-file'.  Returns VERSION."
  (let ((file (or file mcp-emacs-whats-new--stamp-file)))
    (make-directory (file-name-directory (expand-file-name file)) t)
    (with-temp-file file
      (insert version "\n")))
  version)

(defun mcp-emacs-whats-new--notes-directory ()
  "Return the directory holding the shipped release-notes Org files.
Prefer `news/' next to the installed `mcp-emacs.el' so a checkout works,
falling back to `mcp-emacs-whats-new--release-notes-directory' for a
manual copy."
  (let ((next-to-elisp
         (when-let ((library (locate-library "mcp-emacs")))
           (expand-file-name "news" (file-name-directory library)))))
    (if (and next-to-elisp (file-directory-p next-to-elisp))
        next-to-elisp
      mcp-emacs-whats-new--release-notes-directory)))

(defun mcp-emacs-whats-new--version-list (version)
  "Return VERSION as (MAJOR MINOR PATCH), or nil when it is malformed.
A leading `v' is accepted, so both `v1.2.3' and `1.2.3' parse."
  (when (and (stringp version)
             (string-match "\\`v?\\([0-9]+\\)\\.\\([0-9]+\\)\\.\\([0-9]+\\)\\'"
                           version))
    (list (string-to-number (match-string 1 version))
          (string-to-number (match-string 2 version))
          (string-to-number (match-string 3 version)))))

(defun mcp-emacs-whats-new--file-version (file)
  "Return the version tag encoded in a release-notes FILE name, or nil.
A file named `release-v1.2.3.org' yields \"v1.2.3\"."
  (let ((basename (file-name-nondirectory file)))
    (when (string-match "\\`release-\\(v?[0-9]+\\.[0-9]+\\.[0-9]+\\)\\.org\\'"
                        basename)
      (match-string 1 basename))))

(defun mcp-emacs-whats-new--version-newer-p (a b)
  "Return non-nil when version A is strictly newer than version B."
  (let ((va (mcp-emacs-whats-new--version-list a))
        (vb (mcp-emacs-whats-new--version-list b)))
    (and va vb (version-list-< vb va))))

(defun mcp-emacs-whats-new--release-notes-files (&optional directory)
  "Return the release-notes Org files, newest version first.
Search DIRECTORY, defaulting to `mcp-emacs-whats-new--notes-directory'."
  (let* ((directory (or directory (mcp-emacs-whats-new--notes-directory)))
         (files (and (file-directory-p directory)
                     (directory-files directory t "\\`release-.*\\.org\\'"))))
    (sort files
          (lambda (a b)
            (mcp-emacs-whats-new--version-newer-p
             (mcp-emacs-whats-new--file-version a)
             (mcp-emacs-whats-new--file-version b))))))

(defun mcp-emacs-whats-new--select-newer (files stamp)
  "Return the FILES newer than STAMP, keeping their order.
When STAMP is nil or does not parse as a version, every FILE is
returned, so a first run shows all shipped notes."
  (if (mcp-emacs-whats-new--version-list stamp)
      (cl-remove-if-not
       (lambda (file)
         (mcp-emacs-whats-new--version-newer-p
          (mcp-emacs-whats-new--file-version file) stamp))
       files)
    files))

(defun mcp-emacs-whats-new--render (files)
  "Insert the contents of FILES into the current buffer.
Each file already carries its own top-level `* Release ...' headline, so
they are concatenated with a blank line between them."
  (insert (mapconcat
           (lambda (file)
             (with-temp-buffer
               (insert-file-contents file)
               (string-trim (buffer-string))))
           files
           "\n\n")))

;;;###autoload
(defun mcp-emacs-whats-new ()
  "Show mcp-emacs release notes newer than the last seen version.
Opens the shipped release-notes Org files newer than the version in
`mcp-emacs-whats-new--stamp-file' in a read-only Org buffer, one
top-level headline per release, then records the installed version (the
`Version:' header of `mcp-emacs.el') in the stamp so nothing is shown
twice.  With no stamp, every shipped release is shown; when nothing is
newer, no buffer is shown.  Returns the display buffer, or nil when
there was nothing new."
  (interactive)
  (let* ((installed (mcp-emacs-whats-new--installed-version))
         (stamp (mcp-emacs-whats-new--read-stamp))
         (files (mcp-emacs-whats-new--select-newer
                 (mcp-emacs-whats-new--release-notes-files) stamp)))
    (prog1 (when files
             (let ((buffer (get-buffer-create mcp-emacs-whats-new--buffer-name)))
               (with-current-buffer buffer
                 (let ((inhibit-read-only t))
                   (erase-buffer)
                   (mcp-emacs-whats-new--render files)
                   (goto-char (point-min)))
                 (when (fboundp 'org-mode)
                   (org-mode))
                 (setq buffer-read-only t))
               (switch-to-buffer buffer)))
      (mcp-emacs-whats-new--write-stamp installed))))

(provide 'mcp-emacs-whats-new)
;;; mcp-emacs-whats-new.el ends here
