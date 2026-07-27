(add-to-list 'load-path (expand-file-name "elisp"))
(require 'cl-lib)
(require 'mcp-emacs-run)
(defun check (l g w) (princ (format "%s %s\n" (if (equal g w) "PASS" "FAIL") l)))
;; project-root from a subdir resolves to the git repo root
(let ((default-directory (expand-file-name "elisp/"))
      (repo (expand-file-name "./")))
  (check "project-root-is-repo" (mcp-emacs-run--project-root) repo))
(check "buffer-name" (mcp-emacs-run--buffer-name "/tmp/foo/" 1) "*claude:foo:1*")
(check "buffer-name-2" (mcp-emacs-run--buffer-name "/tmp/foo/" 2) "*claude:foo:2*")

;; Discovery + numbering: sessions are found from live *claude:*:<n>* buffers,
;; each matched to its project by the buffer's own default-directory.
(let* ((root (expand-file-name "/tmp/numproj/"))
       (b1 (generate-new-buffer "*claude:numproj:1*"))
       (b3 (generate-new-buffer "*claude:numproj:3*")))
  (with-current-buffer b1 (setq default-directory root))
  (with-current-buffer b3 (setq default-directory root))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () root)))
    (unwind-protect
        (progn
          (check "sessions-list-finds-both"
                 (sort (mapcar #'buffer-name (mcp-emacs-run--project-sessions root)) #'string<)
                 '("*claude:numproj:1*" "*claude:numproj:3*"))
          ;; lowest free slot fills the gap left by the killed 2
          (check "next-number-refills-gap" (mcp-emacs-run--next-number root) 2)
          (kill-buffer b3)
          (check "next-number-after-kill" (mcp-emacs-run--next-number root) 2))
      (when (buffer-live-p b1) (kill-buffer b1))
      (when (buffer-live-p b3) (kill-buffer b3))))
  ;; no sessions -> first number is 1
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () root)))
    (check "next-number-fresh" (mcp-emacs-run--next-number root) 1)))
(check "eat-guard-errors"
       (condition-case _ (progn (mcp-emacs-run--ensure-eat) 'no) (user-error 'yes)) 'yes)

;; resolved width: columns preferred, clamped to max-fraction of frame width.
(cl-letf (((symbol-function 'frame-width) (lambda (&optional _) 400)))
  ;; configured columns fit under the clamp (0.5 * 400 = 200)
  (let ((mcp-emacs-run-window-width-columns 120)
        (mcp-emacs-run-window-max-width-fraction 0.5))
    (check "width-columns-under-clamp" (mcp-emacs-run--resolved-width) 120))
  ;; configured columns exceed the clamp -> reduced to the cap
  (let ((mcp-emacs-run-window-width-columns 300)
        (mcp-emacs-run-window-max-width-fraction 0.5))
    (check "width-columns-clamped" (mcp-emacs-run--resolved-width) 200))
  ;; nil columns -> fall back to the fraction (0.4 * 400 = 160, under cap)
  (let ((mcp-emacs-run-window-width-columns nil)
        (mcp-emacs-run-window-width 0.4)
        (mcp-emacs-run-window-max-width-fraction 0.5))
    (check "width-fraction-fallback" (mcp-emacs-run--resolved-width) 160)))

;; Headless launch: stub eat so no real terminal is spawned.  eat-make returns a
;; plain buffer whose default-directory is the project root (so discovery works).
(let ((root (expand-file-name "/tmp/headless-proj/"))
      made)
  (cl-letf (((symbol-function 'eat-make)
             (lambda (name &rest _)
               (let ((b (generate-new-buffer (format "*%s*" name))))
                 (with-current-buffer b (setq default-directory root))
                 (push b made) b)))
            ((symbol-function 'mcp-emacs-run--ensure-eat) #'ignore)
            ((symbol-function 'mcp-emacs-run--project-root) (lambda () root)))
    (unwind-protect
        (progn
          ;; headless start launches a numbered session, shows no window
          (let ((buf (mcp-emacs-run-start)))
            (check "headless-buffer-numbered" (buffer-name buf) "*claude:headless-proj:1*")
            (check "headless-discoverable" (memq buf (mcp-emacs-run--project-sessions root)) (list buf))
            (check "headless-no-window" (get-buffer-window buf) nil)
            ;; starting again always launches a NEW numbered session (no reuse)
            (let ((again (mcp-emacs-run-start)))
              (check "headless-start-is-new" (eq again buf) nil)
              (check "headless-second-numbered" (buffer-name again) "*claude:headless-proj:2*")
              (check "headless-two-sessions"
                     (length (mcp-emacs-run--project-sessions root)) 2))
            ;; toggle with 2 sessions prompts; stub the picker to choose buf
            (cl-letf (((symbol-function 'mcp-emacs-run--pick-session)
                       (lambda (cands &optional _p) (car cands))))
              (mcp-emacs-run-toggle)
              (check "headless-toggle-reveals" (and (get-buffer-window (car (mcp-emacs-run--project-sessions root))) t) t))
            (dolist (w (window-list))
              (when (memq (window-buffer w) (mcp-emacs-run--project-sessions root))
                (ignore-errors (delete-window w))))))
      (dolist (b made) (when (buffer-live-p b) (kill-buffer b))))))

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

;; Send guard: no live session anywhere -> user-error, no launch.
(cl-letf (((symbol-function 'mcp-emacs-run--sessions-list) (lambda () nil)))
  (check "send-no-session-errors"
         (condition-case _ (progn (mcp-emacs-run-send-prompt "hi") 'no)
           (user-error 'yes))
         'yes))

;; Send delivery: --send resolves the single session and feeds its terminal.
(let ((root (expand-file-name "/tmp/send-deliver/"))
      (buf (generate-new-buffer "*claude:send-deliver:1*"))
      sent)
  (with-current-buffer buf
    (setq default-directory root)
    (setq-local eat-terminal 'fake-term))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () root))
            ((symbol-function 'eat-term-send-string)
             (lambda (term string) (push (cons term string) sent))))
    (unwind-protect
        (progn
          (mcp-emacs-run--send "hello")
          (check "send-delivers-string" (car sent) '(fake-term . "hello")))
      (kill-buffer buf))))

;; Single-keystroke senders: each delivers its exact byte sequence.
(let ((root (expand-file-name "/tmp/keystroke/"))
      (buf (generate-new-buffer "*claude:keystroke:1*"))
      sent)
  (with-current-buffer buf
    (setq default-directory root)
    (setq-local eat-terminal 'fake-term))
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
      (kill-buffer buf))))

;; Keystroke senders inherit the no-live-session guard.
(cl-letf (((symbol-function 'mcp-emacs-run--sessions-list) (lambda () nil)))
  (check "keystroke-no-session-errors"
         (condition-case _ (progn (mcp-emacs-run-send-return) 'no) (user-error 'yes))
         'yes))

;; Resolution tiers: same-project+visible beats same-project+hidden beats
;; cross-project; ambiguity within the winning tier invokes the picker once.
(let* ((rootA (expand-file-name "/tmp/resolveA/"))
       (rootB (expand-file-name "/tmp/resolveB/"))
       (a1 (generate-new-buffer "*claude:resolveA:1*"))
       (a2 (generate-new-buffer "*claude:resolveA:2*"))
       (b1 (generate-new-buffer "*claude:resolveB:1*"))
       (visible '())
       (picks '()))
  (dolist (b (list a1 a2)) (with-current-buffer b (setq default-directory rootA)))
  (with-current-buffer b1 (setq default-directory rootB))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () rootA))
            ((symbol-function 'get-buffer-window)
             (lambda (buf &optional _all) (and (memq buf visible) t)))
            ;; count real prompts by stubbing completing-read, but keep the real
            ;; --pick-session so its "1 candidate = no prompt" logic is exercised
            ((symbol-function 'completing-read)
             (lambda (_p coll &rest _) (push coll picks) (caar coll))))
    (unwind-protect
        (progn
          ;; only a2 visible -> tier 1 has exactly a2, no prompt
          (setq visible (list a2) picks nil)
          (check "resolve-visible-same-project" (mcp-emacs-run--resolve-session) a2)
          (check "resolve-visible-no-pick" picks nil)
          ;; none visible -> tier 2 (same project) has a1 & a2 -> one prompt
          (setq visible nil picks nil)
          (mcp-emacs-run--resolve-session)
          (check "resolve-hidden-same-project-picks" (length picks) 1))
      (dolist (b (list a1 a2 b1)) (when (buffer-live-p b) (kill-buffer b))))))

;; Cross-project fallback: current project has no session; a visible session of
;; another project is chosen.
(let* ((rootX (expand-file-name "/tmp/resolveX/"))    ; current, no sessions
       (rootY (expand-file-name "/tmp/resolveY/"))
       (y1 (generate-new-buffer "*claude:resolveY:1*")))
  (with-current-buffer y1 (setq default-directory rootY))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () rootX))
            ((symbol-function 'get-buffer-window) (lambda (buf &optional _a) (eq buf y1))))
    (unwind-protect
        (check "resolve-cross-project-fallback" (mcp-emacs-run--resolve-session) y1)
      (kill-buffer y1))))

;; send-prompt resolves once: ambiguous tier -> picker invoked exactly once for
;; the whole text+return operation.
(let* ((root (expand-file-name "/tmp/once/"))
       (b1 (generate-new-buffer "*claude:once:1*"))
       (b2 (generate-new-buffer "*claude:once:2*"))
       (picks 0) sent)
  (dolist (b (list b1 b2)) (with-current-buffer b
                             (setq default-directory root)
                             (setq-local eat-terminal 'fake-term)))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () root))
            ((symbol-function 'get-buffer-window) (lambda (&rest _) nil)) ; none visible
            ((symbol-function 'mcp-emacs-run--pick-session)
             (lambda (cands &optional _p) (setq picks (1+ picks)) (car cands)))
            ((symbol-function 'eat-term-send-string)
             (lambda (_t s) (push s sent))))
    (unwind-protect
        (progn
          (mcp-emacs-run-send-prompt "hi")
          (check "send-prompt-resolves-once" picks 1)
          (check "send-prompt-sends-text-then-return" (reverse sent) '("hi" "\r")))
      (dolist (b (list b1 b2)) (when (buffer-live-p b) (kill-buffer b))))))

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
    (cl-letf (((symbol-function 'mcp-emacs-run--session-visible-p) (lambda (_) t)))
      (setq fired nil)
      (mcp-emacs-explain-selection-in-current-session)
      (check "explain-visible-routes-tui" (reverse fired) '(tui)))
    ;; Hidden session -> popup placeholder + headless.
    (cl-letf (((symbol-function 'mcp-emacs-run--session-visible-p) (lambda (_) nil)))
      (setq fired nil)
      (mcp-emacs-explain-selection-in-current-session)
      (check "explain-hidden-routes-popup" (reverse fired) '(popup headless)))
    ;; No session -> headless popup (no error, no TUI).
    (cl-letf (((symbol-function 'mcp-emacs-run--session-visible-p) (lambda (_) nil)))
      (setq fired nil)
      (mcp-emacs-explain-selection-in-current-session)
      (check "explain-no-session-routes-popup" (reverse fired) '(popup headless)))))
