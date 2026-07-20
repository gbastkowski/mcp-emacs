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

;; Selection reference: file-with-region, file-no-region, non-file.
(let* ((root (expand-file-name "./"))
       (file (expand-file-name "elisp/mcp-emacs-run.el" root)))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () root)))
    (with-current-buffer (find-file-noselect file)
      ;; region spanning lines 2..4 (put point at start of line 5 so bol trims to 4)
      (goto-char (point-min)) (forward-line 1) (let ((b (point)))
        (goto-char (point-min)) (forward-line 4)
        (set-mark b) (activate-mark))
      (check "ref-file-region"
             (mcp-emacs-run--selection-reference) "@elisp/mcp-emacs-run.el:2-4")
      (deactivate-mark)
      (goto-char (point-min)) (forward-line 11) ; line 12
      (check "ref-file-no-region"
             (mcp-emacs-run--selection-reference) "@elisp/mcp-emacs-run.el:12")
      (kill-buffer))))
(with-temp-buffer
  (insert "alpha\nbeta\ngamma\n")
  (goto-char (point-min)) (set-mark (point)) (goto-char (line-end-position)) (activate-mark)
  (check "ref-nonfile-region" (mcp-emacs-run--selection-reference) "alpha")
  (deactivate-mark)
  (goto-char (point-min)) (forward-line 1)
  (check "ref-nonfile-no-region" (mcp-emacs-run--selection-reference) "beta"))

;; Send guard: no live session -> user-error, no launch.
(let ((root "/tmp/send-guard/"))
  (clrhash mcp-emacs-run--sessions)
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () root)))
    (check "send-no-session-errors"
           (condition-case _ (progn (mcp-emacs-run-send-prompt "hi") 'no)
             (user-error 'yes))
           'yes)))

;; Send delivery: --send feeds the string to the buffer's eat terminal.
(let ((root "/tmp/send-deliver/")
      (buf (generate-new-buffer "*claude:send*"))
      sent)
  (clrhash mcp-emacs-run--sessions)
  (with-current-buffer buf (setq-local eat-terminal 'fake-term))
  (puthash root buf mcp-emacs-run--sessions)
  (cl-letf (((symbol-function 'eat-term-send-string)
             (lambda (term string) (push (cons term string) sent))))
    (unwind-protect
        (progn
          (mcp-emacs-run--send root "hello")
          (check "send-delivers-string" (car sent) '(fake-term . "hello")))
      (kill-buffer buf)
      (clrhash mcp-emacs-run--sessions))))
