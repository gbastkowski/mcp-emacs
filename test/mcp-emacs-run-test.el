(add-to-list 'load-path (expand-file-name "elisp"))
(require 'cl-lib)
(require 'mcp-emacs-run)
(defun check (l g w) (princ (format "%s %s\n" (if (equal g w) "PASS" "FAIL") l)))
;; project-root from a subdir resolves to the git repo root
(let ((default-directory (expand-file-name "elisp/"))
      (repo (expand-file-name "./")))
  (check "project-root-is-repo" (mcp-emacs-run--project-root) repo))
(check "buffer-name" (mcp-emacs-run--buffer-name "/tmp/foo/") "*claude:foo*")
(let ((buf (generate-new-buffer "*claude:foo*")))
  (puthash "/tmp/foo/" buf mcp-emacs-run--sessions)
  (check "registry-live" (mcp-emacs-run--live-buffer "/tmp/foo/") buf)
  (kill-buffer buf)
  (check "registry-dead-cleared" (mcp-emacs-run--live-buffer "/tmp/foo/") nil))
(check "eat-guard-errors"
       (condition-case _ (progn (mcp-emacs-run--ensure-eat) 'no) (user-error 'yes)) 'yes)

;; Headless launch: stub eat so no real terminal is spawned.  eat-make returns a
;; plain buffer; ensure-eat is satisfied via a faked `eat' feature.
(let ((root "/tmp/headless-proj/")
      made)
  (clrhash mcp-emacs-run--sessions)
  (cl-letf (((symbol-function 'eat-make)
             (lambda (name &rest _) (setq made (generate-new-buffer (format "*%s*" name)))))
            ((symbol-function 'mcp-emacs-run--ensure-eat) #'ignore)
            ((symbol-function 'mcp-emacs-run--project-root) (lambda () root)))
    (unwind-protect
        (progn
          ;; headless start registers a session but shows no window
          (let ((buf (mcp-emacs-run-start)))
            (check "headless-registers" (mcp-emacs-run--live-buffer root) buf)
            (check "headless-no-window" (get-buffer-window buf) nil)
            ;; starting again reuses the same buffer, still no window
            (let ((again (mcp-emacs-run-start)))
              (check "headless-reuses" again buf)
              (check "headless-reuse-no-window" (get-buffer-window again) nil))
            ;; toggle reveals the hidden session
            (mcp-emacs-run-toggle)
            (check "headless-toggle-reveals" (and (get-buffer-window buf) t) t)
            (when (get-buffer-window buf) (delete-window (get-buffer-window buf)))))
      (when (buffer-live-p made) (kill-buffer made))
      (clrhash mcp-emacs-run--sessions))))
