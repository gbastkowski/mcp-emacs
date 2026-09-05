;;; mcp-emacs-run-test.el --- Tests for the Claude terminal runner -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'cl-lib)
(require 'mcp-emacs-run)

(describe "mcp-emacs-run--project-root"
  (let ((default-directory (expand-file-name "elisp/"))
        (repo (expand-file-name "./")))
    (it "resolves to the git repo root from a subdirectory"
      (check (mcp-emacs-run--project-root) repo))))

(describe "mcp-emacs-run--buffer-name"
  (it "names the first session after the project directory"
    (check (mcp-emacs-run--buffer-name "/tmp/foo/" 1) "*claude:foo:1*"))
  (it "distinguishes sessions by their number"
    (check (mcp-emacs-run--buffer-name "/tmp/foo/" 2) "*claude:foo:2*")))

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
          (describe "mcp-emacs-run--project-sessions"
            (it "finds every live session buffer of the project"
              (check
                 (sort (mapcar #'buffer-name (mcp-emacs-run--project-sessions root)) #'string<)
                 '("*claude:numproj:1*" "*claude:numproj:3*"))))
          (describe "mcp-emacs-run--next-number"
            (it "fills the lowest free slot left by a killed session"
              (check (mcp-emacs-run--next-number root) 2))
            (kill-buffer b3)
            (it "still picks the lowest free slot after the highest is killed"
              (check (mcp-emacs-run--next-number root) 2))))
      (when (buffer-live-p b1) (kill-buffer b1))
      (when (buffer-live-p b3) (kill-buffer b3))))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () root)))
    (describe "mcp-emacs-run--next-number with no sessions"
      (it "starts numbering at 1"
        (check (mcp-emacs-run--next-number root) 1)))))

(describe "mcp-emacs-run--ensure-eat"
  (it "signals a user-error when eat is unavailable"
    (check (condition-case _ (progn (mcp-emacs-run--ensure-eat) 'no) (user-error 'yes)) 'yes)))

;; resolved width: columns preferred, clamped to max-fraction of frame width.
(cl-letf (((symbol-function 'frame-width) (lambda (&optional _) 400)))
  (describe "mcp-emacs-run--resolved-width"
    (let ((mcp-emacs-run-window-width-columns 120)
          (mcp-emacs-run-window-max-width-fraction 0.5))
      (it "uses the configured columns when they fit under the clamp"
        (check (mcp-emacs-run--resolved-width) 120)))
    (let ((mcp-emacs-run-window-width-columns 300)
          (mcp-emacs-run-window-max-width-fraction 0.5))
      (it "reduces configured columns that exceed the clamp to the cap"
        (check (mcp-emacs-run--resolved-width) 200)))
    (let ((mcp-emacs-run-window-width-columns nil)
          (mcp-emacs-run-window-width 0.4)
          (mcp-emacs-run-window-max-width-fraction 0.5))
      (it "falls back to the width fraction when no columns are configured"
        (check (mcp-emacs-run--resolved-width) 160)))))

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
          (let ((buf (mcp-emacs-run-start)))
            (describe "mcp-emacs-run-start"
              (it "launches a numbered session for the project"
                (check (buffer-name buf) "*claude:headless-proj:1*"))
              (it "makes the new session discoverable"
                (check (memq buf (mcp-emacs-run--project-sessions root)) (list buf)))
              (it "shows no window for the new session"
                (check (get-buffer-window buf) nil))
              (let ((again (mcp-emacs-run-start)))
                (it "never reuses an existing session"
                  (check (eq again buf) nil))
                (it "gives the second session the next number"
                  (check (buffer-name again) "*claude:headless-proj:2*"))
                (it "leaves both sessions running side by side"
                  (check (length (mcp-emacs-run--project-sessions root)) 2))))
            ;; toggle with 2 sessions prompts; stub the picker to choose buf
            (cl-letf (((symbol-function 'mcp-emacs-run--pick-session)
                       (lambda (cands &optional _p) (car cands))))
              (mcp-emacs-run-toggle)
              (describe "mcp-emacs-run-toggle"
                (it "reveals the picked session in a window"
                  (check (and (get-buffer-window (car (mcp-emacs-run--project-sessions root))) t) t))))
            (dolist (w (window-list))
              (when (memq (window-buffer w) (mcp-emacs-run--project-sessions root))
                (ignore-errors (delete-window w))))))
      (dolist (b made) (when (buffer-live-p b) (kill-buffer b))))))

;; Selection reference: file-with-region, file-no-region, non-file.
(let* ((root (expand-file-name "./"))
       (file (expand-file-name "elisp/mcp-emacs-run.el" root)))
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () root)))
    (with-current-buffer (find-file-noselect file)
      (describe "mcp-emacs-run--selection-reference in a file buffer"
        ;; region spanning lines 2..4 (put point at start of line 5 so bol trims to 4)
        (goto-char (point-min)) (forward-line 1) (let ((b (point)))
          (goto-char (point-min)) (forward-line 4)
          (set-mark b) (activate-mark))
        (it "cites the project-relative path with the region's line range"
          (check (mcp-emacs-run--selection-reference) "@elisp/mcp-emacs-run.el:2-4"))
        (deactivate-mark)
        (goto-char (point-min)) (forward-line 11) ; line 12
        (it "cites just the line at point when there is no region"
          (check (mcp-emacs-run--selection-reference) "@elisp/mcp-emacs-run.el:12")))
      (kill-buffer))))
(with-temp-buffer
  (insert "alpha\nbeta\ngamma\n")
  (describe "mcp-emacs-run--selection-reference in a non-file buffer"
    (goto-char (point-min)) (set-mark (point)) (goto-char (line-end-position)) (activate-mark)
    (it "quotes the selected text instead of a file reference"
      (check (mcp-emacs-run--selection-reference) "alpha"))
    (deactivate-mark)
    (goto-char (point-min)) (forward-line 1)
    (it "quotes the line at point when there is no region"
      (check (mcp-emacs-run--selection-reference) "beta"))))

(describe "mcp-emacs-run-send-prompt with no live session"
  (cl-letf (((symbol-function 'mcp-emacs-run--sessions-list) (lambda () nil)))
    (it "signals a user-error rather than launching a session"
      (check
         (condition-case _ (progn (mcp-emacs-run-send-prompt "hi") 'no)
           (user-error 'yes))
         'yes))))

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
        (describe "mcp-emacs-run--send"
          (mcp-emacs-run--send "hello")
          (it "feeds the string to the resolved session's terminal"
            (check (car sent) '(fake-term . "hello"))))
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
        (describe "single-keystroke senders"
          (it "each deliver their exact byte sequence"
            (dolist (case '(("send-return"    mcp-emacs-run-send-return    "\r")
                            ("send-1"         mcp-emacs-run-send-1         "1")
                            ("send-2"         mcp-emacs-run-send-2         "2")
                            ("send-3"         mcp-emacs-run-send-3         "3")
                            ("send-shift-tab" mcp-emacs-run-send-shift-tab "\e[Z")
                            ("send-up"        mcp-emacs-run-send-up        "\e[A")
                            ("send-down"      mcp-emacs-run-send-down      "\e[B")))
              (setq sent nil)
              (funcall (nth 1 case))
              (check sent (nth 2 case) (format "%s delivers its exact byte sequence" (nth 0 case))))))
      (kill-buffer buf))))

(describe "mcp-emacs-run-send-return with no live session"
  (cl-letf (((symbol-function 'mcp-emacs-run--sessions-list) (lambda () nil)))
    (it "inherits the no-live-session guard and signals a user-error"
      (check
         (condition-case _ (progn (mcp-emacs-run-send-return) 'no) (user-error 'yes))
         'yes))))

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
        (describe "mcp-emacs-run--resolve-session"
          (setq visible (list a2) picks nil)
          (it "prefers the visible session of the current project"
            (check (mcp-emacs-run--resolve-session) a2))
          (it "does not prompt when the winning tier holds one candidate"
            (check picks nil))
          (setq visible nil picks nil)
          (mcp-emacs-run--resolve-session)
          (it "prompts once when the current project has several hidden sessions"
            (check (length picks) 1)))
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
        (describe "mcp-emacs-run--resolve-session with no session in the current project"
          (it "falls back to a visible session of another project"
            (check (mcp-emacs-run--resolve-session) y1)))
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
        (describe "mcp-emacs-run-send-prompt with an ambiguous tier"
          (mcp-emacs-run-send-prompt "hi")
          (it "invokes the picker once for the whole operation"
            (check picks 1))
          (it "sends the text and then a return"
            (check (reverse sent) '("hi" "\r"))))
      (dolist (b (list b1 b2)) (when (buffer-live-p b) (kill-buffer b))))))

;;; Quit: sends the quit sequence, arms a timer, force-kills + removes buffer.

(let* ((buf (generate-new-buffer "*claude:quit:1*"))
       sent timers)
  (with-current-buffer buf (setq-local eat-terminal 'fake-term))
  (cl-letf (((symbol-function 'mcp-emacs-run--resolve-session) (lambda () buf))
            ((symbol-function 'eat-term-send-string) (lambda (_t s) (push s sent)))
            ((symbol-function 'run-with-timer)
             (lambda (secs _rep _fn &rest _args) (push secs timers) 'fake-timer)))
    (unwind-protect
        (describe "mcp-emacs-run-quit"
          (mcp-emacs-run-quit)
          (it "sends Ctrl-C twice to the resolved session"
            (check (car sent) "\003\003"))
          (it "arms exactly one force-kill timer"
            (check (length timers) 1))
          (it "arms that timer for the configured quit timeout"
            (check (car timers) mcp-emacs-run-quit-timeout)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(let (sent)
  (cl-letf (((symbol-function 'mcp-emacs-run--sessions-list) (lambda () nil))
            ((symbol-function 'eat-term-send-string) (lambda (_t s) (push s sent))))
    (describe "mcp-emacs-run-quit with no live session"
      (it "signals a user-error"
        (check
           (condition-case _ (progn (mcp-emacs-run-quit) 'no) (user-error 'yes)) 'yes))
      (it "sends nothing"
        (check sent nil)))))

;; Use a real long-lived process so the real delete-process/kill-buffer run.
(let* ((buf (generate-new-buffer "*claude:quit-force:1*"))
       (proc (make-process :name "quit-force-test" :buffer buf
                           :command '("sleep" "60") :noquery t)))
  (describe "mcp-emacs-run--force-kill-buffer with a still-live process"
    (it "starts from a live process, so the kill is actually exercised"
      (check (and (process-live-p proc) t) t))
    (mcp-emacs-run--force-kill-buffer buf)
    (it "force-kills the still-live process"
      (check (process-live-p proc) nil))
    (it "kills the buffer"
      (check (buffer-live-p buf) nil))))

(let ((buf (generate-new-buffer "*claude:quit-noproc:1*")))
  (describe "mcp-emacs-run--force-kill-buffer with no process"
    (mcp-emacs-run--force-kill-buffer buf)
    (it "just kills the buffer, without error"
      (check (buffer-live-p buf) nil))))

(let ((buf (generate-new-buffer "*claude:quit-dead:1*")))
  (kill-buffer buf)
  (describe "mcp-emacs-run--force-kill-buffer with an already-killed buffer"
    (it "is a no-op rather than an error"
      (check
         (condition-case _ (progn (mcp-emacs-run--force-kill-buffer buf) 'ok) (error 'err))
         'ok))))

;;; Popup output window.

(describe "mcp-emacs-run--popup-buffer-name"
  (it "names the popup buffer after its kind"
    (check (mcp-emacs-run--popup-buffer-name "explain") "*mcp-emacs:explain*")))

(describe "mcp-emacs-run--ensure-markdown"
  (it "signals a user-error when markdown-mode is unavailable"
    (check
       (cl-letf (((symbol-function 'gfm-view-mode) nil))
         ;; fboundp is nil when the symbol has no function cell
         (fmakunbound 'gfm-view-mode)
         (condition-case _ (progn (mcp-emacs-run--ensure-markdown) 'no) (user-error 'yes)))
       'yes)))

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
          (describe "mcp-emacs-popup-show"
            (it "returns a buffer"
              (check (bufferp buf) t))
            (it "names that buffer after the kind"
              (check (buffer-name buf) "*mcp-emacs:explain*"))
            (it "puts the buffer in markdown view mode"
              (check mode-ran t))
            (it "displays the buffer it returns"
              (check (eq displayed buf) t))
            (with-current-buffer buf
              (it "holds the rendered markdown verbatim"
                (check (buffer-string) "# Title\n\nbody\n"))
              (it "leaves the buffer read-only"
                (check buffer-read-only t))
              (it "fontifies code blocks natively, buffer-locally"
                (check
                       (buffer-local-value 'markdown-fontify-code-blocks-natively buf) t))
              (it "leaves point at the top of the output"
                (check (point) (point-min)))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(let (displayed)
  (cl-letf (((symbol-function 'gfm-view-mode) #'ignore)
            ((symbol-function 'mcp-emacs-run--display-popup)
             (lambda (buf) (setq displayed buf))))
    (when (get-buffer "*mcp-emacs:explain*") (kill-buffer "*mcp-emacs:explain*"))
    (let ((first (mcp-emacs-popup-show "one" "explain")))
      (let ((second (mcp-emacs-popup-show "two" "explain")))
        (unwind-protect
            (describe "mcp-emacs-popup-show rendered twice for the same kind"
              (it "reuses the same buffer"
                (check (eq first second) t))
              (it "replaces the previous content"
                (check
                       (with-current-buffer second (buffer-string)) "two")))
          (when (buffer-live-p first) (kill-buffer first)))))))

(let (displayed)
  (cl-letf (((symbol-function 'gfm-view-mode) #'ignore)
            ((symbol-function 'mcp-emacs-run--display-popup)
             (lambda (buf) (setq displayed buf))))
    (dolist (n '("*mcp-emacs:explain*" "*mcp-emacs:diag*"))
      (when (get-buffer n) (kill-buffer n)))
    (let ((a (mcp-emacs-popup-show "a" "explain"))
          (b (mcp-emacs-popup-show "b" "diag")))
      (unwind-protect
          (describe "mcp-emacs-popup-show for distinct kinds"
            (it "gives each kind its own buffer"
              (check (not (eq a b)) t)))
        (when (buffer-live-p a) (kill-buffer a))
        (when (buffer-live-p b) (kill-buffer b))))))

;;; Headless query.

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
      (describe "mcp-emacs-run--query-headless"
        (mcp-emacs-run--query-headless "explain @x:1" (lambda (o) (setq result o)))
        (it "runs claude -p PROMPT with text output format"
          (check
                 cmd (list mcp-emacs-run-executable "-p" "explain @x:1" "--output-format" "text")))
        (it "runs the process from the project root"
          (check dir "/tmp/qproj/"))
        ;; Simulate a successful exit: fill stdout, drive the sentinel.
        (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
                  ((symbol-function 'process-exit-status) (lambda (_) 0)))
          (with-current-buffer out-buf (insert "the answer"))
          (funcall sentinel-fn 'fake-proc "finished\n")
          (it "passes the collected stdout to the callback on success"
            (check result "the answer")))))))

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
      (describe "mcp-emacs-run--query-headless on a non-zero exit"
        (it "does not invoke the callback"
          (check called nil))))))

;;; Explain routing by session visibility.

(let* ((root "/tmp/explain-route/") fired)
  (cl-letf (((symbol-function 'mcp-emacs-run--project-root) (lambda () root))
            ((symbol-function 'mcp-emacs-run--selection-reference) (lambda () "@x:1"))
            ((symbol-function 'mcp-emacs-run-send-prompt) (lambda (&rest _) (push 'tui fired)))
            ((symbol-function 'mcp-emacs-popup-show) (lambda (&rest _) (push 'popup fired)))
            ((symbol-function 'mcp-emacs-run--query-headless) (lambda (&rest _) (push 'headless fired))))
    (describe "mcp-emacs-explain-selection-in-current-session"
      (cl-letf (((symbol-function 'mcp-emacs-run--session-visible-p) (lambda (_) t)))
        (setq fired nil)
        (mcp-emacs-explain-selection-in-current-session)
        (it "routes to the TUI only when a session is visible"
          (check (reverse fired) '(tui))))
      (cl-letf (((symbol-function 'mcp-emacs-run--session-visible-p) (lambda (_) nil)))
        (setq fired nil)
        (mcp-emacs-explain-selection-in-current-session)
        (it "shows a popup placeholder and queries headless when the session is hidden"
          (check (reverse fired) '(popup headless))))
      (cl-letf (((symbol-function 'mcp-emacs-run--session-visible-p) (lambda (_) nil)))
        (setq fired nil)
        (mcp-emacs-explain-selection-in-current-session)
        (it "falls back to the headless popup with no session, without erroring"
          (check (reverse fired) '(popup headless)))))))

(test-helper-summary)

;;; mcp-emacs-run-test.el ends here
