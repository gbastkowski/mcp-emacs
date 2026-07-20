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

;; Single-keystroke senders: each delivers its exact byte sequence.
(let ((root "/tmp/keystroke/")
      (buf (generate-new-buffer "*claude:keys*"))
      sent)
  (clrhash mcp-emacs-run--sessions)
  (with-current-buffer buf (setq-local eat-terminal 'fake-term))
  (puthash root buf mcp-emacs-run--sessions)
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () root))
            ((symbol-function 'eat-term-send-string)
             (lambda (_term string) (setq sent string))))
    (unwind-protect
        (dolist (case '(("send-return"    mcp-emacs-run-send-return    "\r")
                        ("send-1"         mcp-emacs-run-send-1         "1")
                        ("send-2"         mcp-emacs-run-send-2         "2")
                        ("send-3"         mcp-emacs-run-send-3         "3")
                        ("send-shift-tab" mcp-emacs-run-send-shift-tab "\e[Z")
                        ("send-up"        mcp-emacs-run-send-up        "\e[A")
                        ("send-down"      mcp-emacs-run-send-down      "\e[B")))
          (setq sent nil)
          (funcall (nth 1 case))
          (check (format "keystroke-%s" (nth 0 case)) sent (nth 2 case)))
      (kill-buffer buf)
      (clrhash mcp-emacs-run--sessions))))

;; Keystroke senders inherit the no-live-session guard.
(let ((root "/tmp/keystroke-none/"))
  (clrhash mcp-emacs-run--sessions)
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () root)))
    (check "keystroke-no-session-errors"
           (condition-case _ (progn (mcp-emacs-run-send-return) 'no) (user-error 'yes))
           'yes)))

;;; Popup output window.

(check "popup-buffer-name" (mcp-emacs-run--popup-buffer-name "explain") "*mcp-emacs:explain*")

(check "markdown-guard-errors"
       (cl-letf (((symbol-function 'gfm-view-mode) nil))
         ;; fboundp is nil when the symbol has no function cell
         (fmakunbound 'gfm-view-mode)
         (condition-case _ (progn (mcp-emacs-run--ensure-markdown) 'no) (user-error 'yes)))
       'yes)

;; Popup render: stub gfm-view-mode and the display step so no real window
;; machinery or markdown-mode is needed; assert content, read-only, fontify.
(let (mode-ran displayed)
  (cl-letf (((symbol-function 'gfm-view-mode)
             (lambda () (setq mode-ran t) (setq buffer-read-only t)))
            ((symbol-function 'mcp-emacs-run--display-popup)
             (lambda (buf) (setq displayed buf))))
    (when (get-buffer "*mcp-emacs:explain*") (kill-buffer "*mcp-emacs:explain*"))
    (let ((buf (mcp-emacs-popup-show "# Title\n\nbody\n" "explain")))
      (unwind-protect
          (progn
            (check "popup-returns-buffer" (bufferp buf) t)
            (check "popup-buffer-named" (buffer-name buf) "*mcp-emacs:explain*")
            (check "popup-mode-ran" mode-ran t)
            (check "popup-displayed" (eq displayed buf) t)
            (with-current-buffer buf
              (check "popup-content" (buffer-string) "# Title\n\nbody\n")
              (check "popup-read-only" buffer-read-only t)
              (check "popup-fontify-local"
                     (buffer-local-value 'markdown-fontify-code-blocks-natively buf) t)
              (check "popup-point-at-top" (point) (point-min))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

;; Reuse per kind: second render same kind -> same buffer, content replaced.
(let (displayed)
  (cl-letf (((symbol-function 'gfm-view-mode) #'ignore)
            ((symbol-function 'mcp-emacs-run--display-popup)
             (lambda (buf) (setq displayed buf))))
    (when (get-buffer "*mcp-emacs:explain*") (kill-buffer "*mcp-emacs:explain*"))
    (let ((first (mcp-emacs-popup-show "one" "explain")))
      (let ((second (mcp-emacs-popup-show "two" "explain")))
        (unwind-protect
            (progn
              (check "popup-reuse-same-buffer" (eq first second) t)
              (check "popup-reuse-content"
                     (with-current-buffer second (buffer-string)) "two"))
          (when (buffer-live-p first) (kill-buffer first)))))))

;; Distinct kinds -> distinct buffers.
(let (displayed)
  (cl-letf (((symbol-function 'gfm-view-mode) #'ignore)
            ((symbol-function 'mcp-emacs-run--display-popup)
             (lambda (buf) (setq displayed buf))))
    (dolist (n '("*mcp-emacs:explain*" "*mcp-emacs:diag*"))
      (when (get-buffer n) (kill-buffer n)))
    (let ((a (mcp-emacs-popup-show "a" "explain"))
          (b (mcp-emacs-popup-show "b" "diag")))
      (unwind-protect
          (check "popup-distinct-kinds" (not (eq a b)) t)
        (when (buffer-live-p a) (kill-buffer a))
        (when (buffer-live-p b) (kill-buffer b))))))

;;; Headless query.

;; Command line: claude -p PROMPT --output-format text, run from project root.
(let (cmd dir sentinel-fn out-buf)
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/qproj/"))
            ((symbol-function 'make-process)
             (lambda (&rest args)
               (setq cmd (plist-get args :command))
               (setq dir default-directory)
               (setq sentinel-fn (plist-get args :sentinel))
               (setq out-buf (plist-get args :buffer))
               'fake-proc)))
    (let (result)
      (mcp-emacs-run--query-headless "explain @x:1" (lambda (o) (setq result o)))
      (check "query-command"
             cmd (list mcp-emacs-run-executable "-p" "explain @x:1" "--output-format" "text"))
      (check "query-runs-in-project-root" dir "/tmp/qproj/")
      ;; Simulate a successful exit: fill stdout, drive the sentinel.
      (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
                ((symbol-function 'process-exit-status) (lambda (_) 0)))
        (with-current-buffer out-buf (insert "the answer"))
        (funcall sentinel-fn 'fake-proc "finished\n")
        (check "query-success-callback" result "the answer")))))

;; Non-zero exit: callback is NOT invoked.
(let (sentinel-fn out-buf err-buf called)
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () "/tmp/qproj/"))
            ((symbol-function 'make-process)
             (lambda (&rest args)
               (setq sentinel-fn (plist-get args :sentinel))
               (setq out-buf (plist-get args :buffer))
               (setq err-buf (plist-get args :stderr))
               'fake-proc)))
    (mcp-emacs-run--query-headless "p" (lambda (_) (setq called t)))
    (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_) 1)))
      (with-current-buffer err-buf (insert "boom"))
      (funcall sentinel-fn 'fake-proc "exited abnormally\n")
      (check "query-failure-no-callback" called nil))))

;;; Explain routing by session visibility.

(let* ((root "/tmp/explain-route/") fired)
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () root))
            ((symbol-function 'mcp-emacs-run--selection-reference) (lambda () "@x:1"))
            ((symbol-function 'mcp-emacs-run-send-prompt) (lambda (&rest _) (push 'tui fired)))
            ((symbol-function 'mcp-emacs-popup-show) (lambda (&rest _) (push 'popup fired)))
            ((symbol-function 'mcp-emacs-run--query-headless) (lambda (&rest _) (push 'headless fired))))
    ;; Visible session -> TUI only.
    (cl-letf (((symbol-function 'mcp-emacs-run--live-buffer) (lambda (_) 'buf))
              ((symbol-function 'mcp-emacs-run--session-visible-p) (lambda (_) t)))
      (setq fired nil)
      (mcp-emacs-explain-selection-in-current-session)
      (check "explain-visible-routes-tui" (reverse fired) '(tui)))
    ;; Hidden session -> popup placeholder + headless.
    (cl-letf (((symbol-function 'mcp-emacs-run--live-buffer) (lambda (_) 'buf))
              ((symbol-function 'mcp-emacs-run--session-visible-p) (lambda (_) nil)))
      (setq fired nil)
      (mcp-emacs-explain-selection-in-current-session)
      (check "explain-hidden-routes-popup" (reverse fired) '(popup headless)))
    ;; No session -> headless popup (no error, no TUI).
    (cl-letf (((symbol-function 'mcp-emacs-run--live-buffer) (lambda (_) nil))
              ((symbol-function 'mcp-emacs-run--session-visible-p) (lambda (_) nil)))
      (setq fired nil)
      (mcp-emacs-explain-selection-in-current-session)
      (check "explain-no-session-routes-popup" (reverse fired) '(popup headless)))))
