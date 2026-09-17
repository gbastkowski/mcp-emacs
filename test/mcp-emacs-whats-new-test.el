;;; mcp-emacs-whats-new-test.el --- Tests for the What's new screen -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'cl-lib)
(require 'mcp-emacs-whats-new)

(defun mcp-emacs-whats-new-test--release-file (directory version)
  "Write a release-notes Org file for VERSION under DIRECTORY.
Returns the file's path."
  (let ((file (expand-file-name (format "release-%s.org" version) directory)))
    (with-temp-file file
      (insert (format "* Release %s\n\n## What changed\n\n- a change\n" version)))
    file))

;;;; Installed version

(describe "mcp-emacs-whats-new--installed-version"
  (it "parses the Version header of mcp-emacs.el"
    (let ((file (make-temp-file
                 "mcp-emacs" nil ".el"
                 ";;; mcp-emacs.el --- x -*- lexical-binding: t; -*-\n;; Version: 9.8.7\n")))
      (unwind-protect
          (check (mcp-emacs-whats-new--installed-version file) "9.8.7")
        (delete-file file))))
  (it "falls back to 0.0.0 when the header is missing"
    (let ((file (make-temp-file "mcp-emacs" nil ".el" ";;; mcp-emacs.el --- x\n")))
      (unwind-protect
          (check (mcp-emacs-whats-new--installed-version file) "0.0.0")
        (delete-file file)))))

;;;; Selecting the notes to show

(let* ((root (make-temp-file "whats-new-select-" t))
       (files nil))
  (mcp-emacs-whats-new-test--release-file root "v1.0.0")
  (mcp-emacs-whats-new-test--release-file root "v1.1.0")
  (mcp-emacs-whats-new-test--release-file root "v1.2.0")
  (setq files (mcp-emacs-whats-new--release-notes-files root))
  (describe "mcp-emacs-whats-new--release-notes-files"
    (it "orders the release files newest version first"
      (check (mapcar #'file-name-nondirectory files)
             '("release-v1.2.0.org" "release-v1.1.0.org" "release-v1.0.0.org"))))
  (describe "mcp-emacs-whats-new--select-newer"
    (it "keeps only releases strictly newer than the stamp"
      (check (mapcar #'file-name-nondirectory
                     (mcp-emacs-whats-new--select-newer files "1.1.0"))
             '("release-v1.2.0.org")))
    (it "drops a release equal to the stamp"
      (check (mcp-emacs-whats-new--select-newer files "1.2.0") nil))
    (it "shows every release when there is no stamp"
      (check (length (mcp-emacs-whats-new--select-newer files nil)) 3))))

;;;; The command: rendering and re-stamping

(let* ((root (make-temp-file "whats-new-show-" t))
       (stamp-file (expand-file-name ".mcp-emacs-last-seen" root))
       (mcp-emacs-whats-new--stamp-file stamp-file))
  (mcp-emacs-whats-new-test--release-file root "v1.0.0")
  (mcp-emacs-whats-new-test--release-file root "v1.1.0")
  (cl-letf (((symbol-function 'mcp-emacs-whats-new--installed-version)
             (lambda (&optional _) "1.1.0"))
            ((symbol-function 'mcp-emacs-whats-new--notes-directory)
             (lambda () root)))
    (describe "mcp-emacs-whats-new with no stamp"
      (when (get-buffer mcp-emacs-whats-new--buffer-name)
        (kill-buffer mcp-emacs-whats-new--buffer-name))
      (it "shows one top-level headline per release"
        (mcp-emacs-whats-new)
        (check (with-current-buffer mcp-emacs-whats-new--buffer-name
                 (count-matches "^\\* Release " (point-min) (point-max)))
               2))
      (it "creates the stamp at the installed version"
        (check (mcp-emacs-whats-new--read-stamp stamp-file) "1.1.0")))))

(let* ((root (make-temp-file "whats-new-current-" t))
       (stamp-file (expand-file-name ".mcp-emacs-last-seen" root))
       (mcp-emacs-whats-new--stamp-file stamp-file))
  (mcp-emacs-whats-new-test--release-file root "v1.0.0")
  (with-temp-file stamp-file (insert "1.2.0\n"))
  (cl-letf (((symbol-function 'mcp-emacs-whats-new--installed-version)
             (lambda (&optional _) "1.3.0"))
            ((symbol-function 'mcp-emacs-whats-new--notes-directory)
             (lambda () root)))
    (describe "mcp-emacs-whats-new with nothing newer than the stamp"
      (when (get-buffer mcp-emacs-whats-new--buffer-name)
        (kill-buffer mcp-emacs-whats-new--buffer-name))
      (it "shows nothing"
        (check (progn (mcp-emacs-whats-new)
                      (get-buffer mcp-emacs-whats-new--buffer-name))
               nil))
      (it "still re-stamps the installed version"
        (check (mcp-emacs-whats-new--read-stamp stamp-file) "1.3.0")))))

(test-helper-summary)

;;; mcp-emacs-whats-new-test.el ends here
