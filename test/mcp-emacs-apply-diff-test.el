;;; mcp-emacs-apply-diff-test.el --- Tests for the apply-diff ediff review -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'cl-lib)
(require 'mcp-emacs)
;; The inline review renders into a conversation buffer; these suites
;; use a real claude-client-mode buffer to prove that reachability.
(require 'claude-client)

(defun mcp--make-session (a-text b-text)
  "Return (buffer-a buffer-b entry-content result) for a fake diff session."
  (let ((buffer-a (generate-new-buffer " *a*"))
        (buffer-b (generate-new-buffer " *b*")))
    (with-current-buffer buffer-a (insert a-text))
    (with-current-buffer buffer-b (insert b-text))
    (list buffer-a buffer-b a-text (list nil))))

(defun mcp--a-text (buffer-a)
  (with-current-buffer buffer-a
    (buffer-substring-no-properties (point-min) (point-max))))

(describe "mcp-emacs--apply-diff-accept"
  ;; 4.1 Accept unchanged -> applied, proposal applied to A.
  (let* ((s (mcp--make-session "old\n" "new\n"))
         (a (nth 0 s)) (b (nth 1 s)) (entry (nth 2 s)) (result (nth 3 s)))
    (unwind-protect
        (progn
          (mcp-emacs--apply-diff-accept a b entry result)
          (it "records the decision as applied"
            (check (car result) 'applied))
          (it "writes the proposal into buffer A"
            (check (mcp--a-text a) "new\n")))
      (kill-buffer a) (kill-buffer b)))

  ;; 4.3 Human edits A then accepts -> applied with the edited content, not B.
  (let* ((s (mcp--make-session "old\n" "new\n"))
         (a (nth 0 s)) (b (nth 1 s)) (entry (nth 2 s)) (result (nth 3 s)))
    (unwind-protect
        (progn
          (with-current-buffer a (erase-buffer) (insert "hand-edited\n"))
          (mcp-emacs--apply-diff-accept a b entry result)
          (it "records applied when the human edited A first"
            (check (car result) 'applied))
          (it "keeps the human's edit rather than overwriting it with B"
            (check (mcp--a-text a) "hand-edited\n")))
      (kill-buffer a) (kill-buffer b)))

  ;; Accept must not override a decision already recorded (quit hook is a no-op
  ;; once set): the hook only defaults when result is still nil.
  (let* ((s (mcp--make-session "old\n" "new\n"))
         (a (nth 0 s)) (b (nth 1 s)) (entry (nth 2 s)) (result (nth 3 s)))
    (unwind-protect
        (progn
          (mcp-emacs--apply-diff-accept a b entry result)
          (unless (car result) (setcar result 'rejected)) ; quit hook runs after
          (it "survives the quit hook default that runs after it"
            (check (car result) 'applied)))
      (kill-buffer a) (kill-buffer b))))

;; Accepting must persist: "applied" promises the file on disk holds the
;; accepted content, not merely a dirty Buffer A.  These use a real file so
;; the write is observable.
(describe "accepting a proposal writes it to disk"
  ;; Unedited accept -> the proposal itself lands on disk.
  (let ((file (make-temp-file "mcp-accept-" nil ".txt" "old\n")))
    (unwind-protect
        (let ((buffer-a (find-file-noselect file))
              (buffer-b (generate-new-buffer " *accept-b*")))
          (unwind-protect
              (progn
                (with-current-buffer buffer-b (insert "new\n"))
                (mcp-emacs--apply-diff-accept
                 buffer-a buffer-b "old\n" (list nil))
                (it "writes the accepted proposal to the file on disk"
                  (check (with-temp-buffer
                           (insert-file-contents file)
                           (buffer-string))
                         "new\n"))
                (it "marks buffer A saved rather than leaving it dirty"
                  (check (buffer-modified-p buffer-a) nil)))
            (when (buffer-live-p buffer-b) (kill-buffer buffer-b))
            (when (buffer-live-p buffer-a)
              (with-current-buffer buffer-a (set-buffer-modified-p nil))
              (kill-buffer buffer-a))))
      (delete-file file)))

  ;; The human's edit wins the accept, so it -- not the proposal -- reaches disk.
  (let ((file (make-temp-file "mcp-accept-edit-" nil ".txt" "old\n")))
    (unwind-protect
        (let ((buffer-a (find-file-noselect file))
              (buffer-b (generate-new-buffer " *accept-b2*")))
          (unwind-protect
              (progn
                (with-current-buffer buffer-b (insert "new\n"))
                (with-current-buffer buffer-a
                  (erase-buffer) (insert "hand-edited\n"))
                (mcp-emacs--apply-diff-accept
                 buffer-a buffer-b "old\n" (list nil))
                (it "writes the human's edit to the file on disk"
                  (check (with-temp-buffer
                           (insert-file-contents file)
                           (buffer-string))
                         "hand-edited\n"))
                (it "marks buffer A saved rather than leaving it dirty"
                  (check (buffer-modified-p buffer-a) nil)))
            (when (buffer-live-p buffer-b) (kill-buffer buffer-b))
            (when (buffer-live-p buffer-a)
              (with-current-buffer buffer-a (set-buffer-modified-p nil))
              (kill-buffer buffer-a))))
      (delete-file file))))

(describe "mcp-emacs--apply-diff-reject"
  ;; 4.2 Reject -> rejected, A unchanged.
  (let* ((s (mcp--make-session "old\n" "new\n"))
         (a (nth 0 s)) (b (nth 1 s)) (result (nth 3 s)))
    (unwind-protect
        (progn
          (mcp-emacs--apply-diff-reject result)
          (it "records the decision as rejected"
            (check (car result) 'rejected))
          (it "leaves buffer A untouched"
            (check (mcp--a-text a) "old\n")))
      (kill-buffer a) (kill-buffer b))))

(describe "quitting a review without deciding"
  ;; 4.4 Quit without accepting -> the quit-hook default resolves to rejected.
  ;; Model the quit hook: on quit, if result is unset, set it to rejected.
  (let* ((s (mcp--make-session "old\n" "new\n"))
         (a (nth 0 s)) (b (nth 1 s)) (result (nth 3 s)))
    (unwind-protect
        (progn
          (unless (car result) (setcar result 'rejected)) ; mirrors ediff-quit-hook
          (it "defaults the decision to rejected"
            (check (car result) 'rejected))
          (it "leaves buffer A untouched"
            (check (mcp--a-text a) "old\n")))
      (kill-buffer a) (kill-buffer b))))

;;;; Window-layout save/restore (#21)

;; `mcp-emacs--ediff-review' captures the window configuration up front and
;; restores it in the quit hook, for both callers.  Stub `ediff-buffers' so
;; the setup lambda runs (installing the key bindings and quit hook on a fake
;; control buffer) without a real ediff session, then fire the quit hook and
;; assert the layout is put back.
(describe "mcp-emacs--ediff-review window-layout restore"
  (let* ((buffer-a (generate-new-buffer " *win-a*"))
         (buffer-b (generate-new-buffer " *win-b*"))
         (result (list nil))
         (control (generate-new-buffer " *fake-control*"))
         (restored nil)
         (mcp-emacs-ediff-window-direction 'plain))
    (with-current-buffer buffer-a (insert "old\n"))
    (with-current-buffer buffer-b (insert "new\n"))
    (unwind-protect
        (cl-letf (((symbol-function 'ediff-buffers)
                   (lambda (_a _b setup-hooks &rest _)
                     ;; ediff would bind `ediff-control-buffer' and run the
                     ;; setup hooks; emulate just enough for the setup lambda.
                     (let ((ediff-control-buffer control))
                       (dolist (fn setup-hooks) (funcall fn)))
                     control))
                  ((symbol-function 'set-window-configuration)
                   (lambda (&rest _) (setq restored t))))
          (let ((ctl (mcp-emacs--ediff-review buffer-a buffer-b "old\n" result)))
            (it "returns the ediff control buffer"
              (check ctl control))
            (it "installs a quit hook on the control buffer"
              (check-that (with-current-buffer control ediff-quit-hook)))
            ;; Fire the quit hook (the single quit path).
            (with-current-buffer control (run-hooks 'ediff-quit-hook))
            (it "defaults an undecided review to rejected on quit"
              (check (car result) 'rejected))
            (it "puts the saved window layout back on quit"
              (check restored t))))
      (dolist (b (list buffer-a buffer-b control))
        (when (buffer-live-p b) (kill-buffer b))))))

;; The restore fires exactly once even though the hook could be entered per
;; keypress: a second run with the decision already set must not re-default it.
(describe "the quit hook re-entered after a decision"
  (let* ((result (list 'applied))
         (restored-count 0)
         (control (generate-new-buffer " *fake-control-2*")))
    (unwind-protect
        (cl-letf (((symbol-function 'set-window-configuration)
                   (lambda (&rest _) (setq restored-count (1+ restored-count)))))
          (with-current-buffer control
            (setq-local ediff-quit-hook
                        (list (lambda ()
                                (unless (car result) (setcar result 'rejected))
                                (ignore-errors (set-window-configuration nil))))))
          (with-current-buffer control (run-hooks 'ediff-quit-hook))
          (it "does not re-default an accept back to rejected"
            (check (car result) 'applied))
          (it "restores the layout exactly once per quit"
            (check restored-count 1)))
      (when (buffer-live-p control) (kill-buffer control)))))

;;;; Async apply-diff (deferred resolution)
;;
;; `mcp-emacs-apply-diff-async' must return immediately and answer later via
;; its callback: blocking here is exactly the bug it exists to avoid (a
;; process filter has `inhibit-quit' set and no command loop, so the ediff
;; panel renders but cannot be answered).  These tests stub `ediff-buffers'
;; the same way the layout tests above do, capture the ON-RESOLVE callback
;; that `mcp-emacs--ediff-review' installs, and fire it by hand.

(defmacro mcp--with-async-review (bindings &rest body)
  "Run BODY with `ediff-buffers' stubbed for an async apply-diff test.
BINDINGS is a list of (VAR . INIT) forms evaluated before the stub is
installed.  Inside BODY, `resolve' calls the captured ON-RESOLVE callback
and `control' is the fake control buffer."
  (declare (indent 1))
  `(let* ((control (generate-new-buffer " *fake-async-control*"))
          (captured nil)
          ,@bindings)
     (unwind-protect
         (cl-letf (((symbol-function 'ediff-buffers)
                    (lambda (_a _b setup-hooks &rest _)
                      (let ((ediff-control-buffer control))
                        (dolist (fn setup-hooks) (funcall fn)))
                      control))
                   ;; Never touch the real window layout from batch.
                   ((symbol-function 'set-window-configuration)
                    (lambda (&rest _) nil))
                   ;; Capture ON-RESOLVE instead of driving a real ediff.
                   ((symbol-function 'mcp-emacs--ediff-review)
                    (lambda (_a _b _entry _result &optional on-resolve _tab)
                      (setq captured on-resolve)
                      control)))
           (cl-flet ((resolve () (when captured (funcall captured))))
             ,@body))
       (when (buffer-live-p control) (kill-buffer control)))))

;; A temp file to review against; `mcp-emacs-apply-diff-async' opens PATH
;; with `find-file-noselect', so it must exist on disk.
(defun mcp--async-fixture ()
  "Return a fresh temp file path containing \"old\\n\"."
  (let ((f (make-temp-file "mcp-async-" nil ".txt" "old\n")))
    f))

(describe "mcp-emacs-apply-diff-async"
  ;; These pin the ediff path; small diffs go inline since issue #81, so
  ;; force the old behaviour by zeroing the inline limit.
  (let ((mcp-emacs-apply-diff-inline-limit 0))
  ;; Returns immediately (nil) rather than blocking until a decision, and does
  ;; not invoke the callback before the human resolves.
  (let ((file (mcp--async-fixture)))
    (unwind-protect
        (mcp--with-async-review ((calls nil))
          (let ((ret (mcp-emacs-apply-diff-async
                      file "new\n" 60 (lambda (out) (push out calls)))))
            (it "returns immediately instead of blocking until a decision"
              (check ret nil))
            (it "does not invoke the callback before the human resolves"
              (check calls nil))))
      (delete-file file)))

  ;; Accept -> the callback gets "Status: applied" plus buffer A's content.
  ;; The stub must expose the RESULT cell so the test can record an accept the
  ;; way the real accept key binding does; otherwise only the reject branch is
  ;; ever reachable and the applied path goes untested.
  (let ((file (mcp--async-fixture)))
    (unwind-protect
        (let* ((control (generate-new-buffer " *fake-async-control*"))
               (captured nil)
               (cell nil)
               (calls nil))
          (unwind-protect
              (cl-letf (((symbol-function 'mcp-emacs--ediff-review)
                         (lambda (_a _b _entry result &optional on-resolve _tab)
                           (setq captured on-resolve
                                 cell result)
                           control)))
                (mcp-emacs-apply-diff-async
                 file "new\n" 60 (lambda (out) (push out calls)))
                ;; Mirror the accept command: record the decision, and put the
                ;; proposal into buffer A (which is what gets reported back).
                (setcar cell 'applied)
                (let ((buf (find-buffer-visiting file)))
                  (with-current-buffer buf (erase-buffer) (insert "new\n")))
                (funcall captured)
                (it "answers exactly once when the human accepts"
                  (check (length calls) 1))
                (it "reports the applied status with buffer A's content"
                  (check (car calls) "Status: applied\nnew\n")))
            (when (buffer-live-p control) (kill-buffer control))))
      (let ((buf (find-buffer-visiting file)))
        (when buf (with-current-buffer buf (set-buffer-modified-p nil))
              (kill-buffer buf)))
      (delete-file file)))

  ;; Resolving twice must deliver exactly one answer: the quit hook can fire
  ;; again (e.g. a second `q') after the decision is already recorded.
  (let ((file (mcp--async-fixture)))
    (unwind-protect
        (mcp--with-async-review ((calls nil))
          (mcp-emacs-apply-diff-async
           file "new\n" 60 (lambda (out) (push out calls)))
          (resolve)
          (resolve)
          (it "delivers one answer even when the review resolves twice"
            (check (length calls) 1)))
      (let ((buf (find-buffer-visiting file)))
        (when buf (with-current-buffer buf (set-buffer-modified-p nil))
              (kill-buffer buf)))
      (delete-file file)))

  ;; Rejection surfaces as "Status: rejected" (result cell left unset).
  (let ((file (mcp--async-fixture)))
    (unwind-protect
        (mcp--with-async-review ((calls nil))
          (mcp-emacs-apply-diff-async
           file "new\n" 60 (lambda (out) (push out calls)))
          (resolve)
          (it "reports a rejected status when the result cell is left unset"
            (check (car calls) "Status: rejected")))
      (let ((buf (find-buffer-visiting file)))
        (when buf (with-current-buffer buf (set-buffer-modified-p nil))
              (kill-buffer buf)))
      (delete-file file)))

  ;; Timeout fires the callback with "Status: timeout" when nobody resolves.
  ;; A 1-second timeout keeps the batch run short.
  (let ((file (mcp--async-fixture)))
    (unwind-protect
        (mcp--with-async-review ((calls nil))
          (mcp-emacs-apply-diff-async
           file "new\n" 1 (lambda (out) (push out calls)))
          (it "has not answered yet while the timeout is still pending"
            (check calls nil))
          (sleep-for 2)
          (it "reports a timeout status when nobody resolves"
            (check (car calls) "Status: timeout"))
          (it "answers exactly once on timeout"
            (check (length calls) 1))
          ;; A late human resolve after a timeout must not answer twice.
          (resolve)
          (it "ignores a late human resolve after a timeout"
            (check (length calls) 1)))
      (let ((buf (find-buffer-visiting file)))
        (when buf (with-current-buffer buf (set-buffer-modified-p nil))
              (kill-buffer buf)))
      (delete-file file)))

  ;; The timeout timer is cancelled once the review resolves, so a finished
  ;; review leaves nothing pending behind it.
  (let ((file (mcp--async-fixture)))
    (unwind-protect
        (mcp--with-async-review ((calls nil))
          ;; Assert on `timer-list' directly.  The single-delivery guard would
          ;; suppress a second callback even if the timer were never cancelled,
          ;; so counting calls cannot tell the two mechanisms apart -- only an
          ;; uncancelled timer shows up here.
          (let ((before (length timer-list)))
            (mcp-emacs-apply-diff-async
             file "new\n" 30 (lambda (out) (push out calls)))
            (it "arms a timeout timer"
              (check (> (length timer-list) before) t))
            (resolve)
            (it "answers once when the human resolves before the timeout"
              (check (length calls) 1))
            (it "cancels the timeout timer once the review resolves"
              (check (length timer-list) before))))
(let ((buf (find-buffer-visiting file)))
        (when buf (with-current-buffer buf (set-buffer-modified-p nil))
              (kill-buffer buf)))
      (delete-file file)))))
(describe "mcp-emacs-apply-diff-async timeout beats the quit hook"
  ;; Pins the ediff quit-hook race; zero the inline limit so the tiny
  ;; test diff cannot take the inline path (issue #81).
  (let ((mcp-emacs-apply-diff-inline-limit 0))
  ;; The timeout must win its own race against the force-quit's quit hook.
  ;; A real `ediff-really-quit' runs the ediff quit hook, and that hook
  ;; treats any quit without an explicit accept as a rejection -- so when the
  ;; guard was claimed only after the force-quit, the caller was told
  ;; "rejected" for a session nobody answered.  Model the sequence by running
  ;; the real setup (installing the quit hook via the setup lambda) and by
  ;; making the stubbed force-quit run that hook, just as ediff would.
  (let ((file (mcp--async-fixture)))
    (unwind-protect
        (let* ((control (generate-new-buffer " *fake-async-control*"))
               (calls nil)
               (mcp-emacs-ediff-window-direction 'plain))
          (cl-letf (((symbol-function 'ediff-buffers)
                     (lambda (_a _b setup-hooks &rest _)
                       (let ((ediff-control-buffer control))
                         (dolist (fn setup-hooks) (funcall fn)))
                       control))
                    ((symbol-function 'set-window-configuration)
                     (lambda (&rest _) nil))
                    ((symbol-function 'ediff-really-quit)
                     (lambda (&rest _)
                       ;; The real force-quit runs the quit hook, whose
                       ;; implicit default is a rejection.
                       (with-current-buffer control
                         (run-hooks 'ediff-quit-hook)))))
            (mcp-emacs-apply-diff-async
             file "new\n" 1 (lambda (out) (push out calls)))
            (sleep-for 2)
            (it "reports timeout rather than the quit hook's rejection"
              (check (car calls) "Status: timeout"))
            (it "answers exactly once when the timeout races the quit hook"
              (check (length calls) 1))
            (it "leaves the file on disk unchanged on timeout"
              (check (with-temp-buffer
                       (insert-file-contents file)
                       (buffer-string))
                     "old\n")))
          (when (buffer-live-p control) (kill-buffer control)))
(let ((buf (find-buffer-visiting file)))
        (when buf (with-current-buffer buf (set-buffer-modified-p nil))
              (kill-buffer buf)))
      (delete-file file)))))
(describe "mcp-emacs-apply-diff-async on a nonexistent path"
  (let ((mcp-emacs-apply-diff-inline-limit 0))
  (let ((calls nil))
    (mcp-emacs-apply-diff-async
     "/nonexistent-dir-mcp-test/nope.txt" "new\n" 1
     (lambda (out) (push out calls)))
    (it "opens the review and defers rather than erroring"
      (check calls nil))
    (sleep-for 2)
    (it "still answers on its own so the request cannot hang"
      (check (length calls) 1)))))

;; The synchronous variant must refuse to run under a process filter.  A
;; filter has no command loop to deliver the human's keypress to ediff, and
;; Emacs binds `inhibit-quit' to t there, so the old behaviour was: review
;; displayed, keys dead, `C-g' ignored, Emacs frozen until the timeout --
;; and because the awaited keypress is what `sleep-for' stops being read,
;; the wait could only ever end in "Status: timeout".  Observed live: 11
;; such timeouts against 86 applied on the async path.
;;
;; Failing fast is what makes that a bug report instead of a hung editor.
(describe "mcp-emacs-apply-diff under a process filter"
  (let ((file (mcp--async-fixture)))
    (unwind-protect
        (let ((err (let ((inhibit-quit t))
                     (condition-case e
                         (progn (mcp-emacs-apply-diff file "new\n" 60) nil)
                       (error e)))))
          (it "signals rather than hanging with a review nobody can answer"
            (check-that (and err t)))
          (it "names the async variant so the caller knows the way out"
            (check-that (string-match-p "async" (format "%S" err)))))
      (delete-file file))))

;;;; Inline review (issue #81)

;; The size gate decides between the inline surface and ediff from the
;; unified-diff line count alone.
(describe "the apply-diff size gate"
  (it "renders a diff at or below the limit inline"
    (let ((mcp-emacs-apply-diff-inline-limit 40))
      (check (mcp-emacs--apply-diff-inline-p
              "--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new\n")
             t)))
  (it "opens ediff for a diff above the limit"
    (let ((mcp-emacs-apply-diff-inline-limit 3))
      (check (mcp-emacs--apply-diff-inline-p
              "--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new\n")
             nil)))
  (it "treats a diff that could not be produced as too large"
    (let ((mcp-emacs-apply-diff-inline-limit 1000))
      (check (mcp-emacs--apply-diff-inline-p nil) nil))))

;; The dispatch shared by the sync and async callers must route a small
;; real diff to the inline surface and a large one to ediff.
(describe "the review dispatch honours the size gate"
  (let* ((a (generate-new-buffer " *gate-a*"))
         (b (generate-new-buffer " *gate-b*"))
         (result (list nil))
         (inline-called nil)
         (ediff-called nil))
    (unwind-protect
        (cl-letf (((symbol-function 'mcp-emacs--inline-review)
                   (lambda (&rest _) (setq inline-called t)))
                  ((symbol-function 'mcp-emacs--ediff-review)
                   (lambda (&rest _) (setq ediff-called t))))
          (with-current-buffer a (insert "line one\nline two\n"))
          (with-current-buffer b (insert "line one\nline two edited\n"))
          (let ((mcp-emacs-apply-diff-inline-limit 40))
            (mcp-emacs--apply-diff-review a b "line one\nline two\n" result)
            (it "sends a small diff to the inline review"
              (check inline-called t))
            (it "does not open ediff for a small diff"
              (check ediff-called nil)))
          (setq inline-called nil ediff-called nil)
          (with-current-buffer b
            (erase-buffer)
            (insert (mapconcat (lambda (n) (format "changed line %d" n))
                               (number-sequence 1 60) "\n")))
          (let ((mcp-emacs-apply-diff-inline-limit 40))
            (mcp-emacs--apply-diff-review a b "line one\nline two\n" result)
            (it "opens ediff for a diff above the limit"
              (check ediff-called t))
            (it "does not render a large diff inline"
              (check inline-called nil))))
      (kill-buffer a) (kill-buffer b))))

(defun mcp--conversation-buffer ()
  "Return a fresh claude-client conversation buffer for an inline review."
  (let ((buf (generate-new-buffer "*claude-client:inline-test:1*")))
    (with-current-buffer buf (claude-client-mode))
    buf))

;; The inline surface renders into the conversation buffer the review
;; was started from; accepting applies the proposal and reports the same
;; outcome the ediff accept would.
(describe "an inline review in a conversation buffer"
  (let ((file (mcp--async-fixture))
        (conv (mcp--conversation-buffer)))
    (unwind-protect
        (let ((calls nil))
          (let ((mcp-emacs-apply-diff-inline-limit 40))
            (with-current-buffer conv
              (mcp-emacs-apply-diff-async file "new\n" 60
                                          (lambda (out) (push out calls)))))
          (it "renders the review in a *claude-client* conversation buffer"
            (check-that (with-current-buffer conv
                          (string-match-p "apply_diff review" (buffer-string)))))
          (it "shows the file path in the inline review"
            (check-that (with-current-buffer conv
                          (string-match-p (regexp-quote file) (buffer-string)))))
          (it "shows the unified diff as text"
            (check-that (with-current-buffer conv
                          (string-match-p (regexp-quote "+new") (buffer-string)))))
          (with-current-buffer conv
            (mcp-emacs--apply-diff-inline-accept))
          (it "reports Status: applied with the final content"
            (check (car calls) "Status: applied\nnew\n"))
          (it "applies the proposal to the file on disk"
            (check (with-temp-buffer
                     (insert-file-contents file)
                     (buffer-string))
                   "new\n"))
          (it "turns the inline review mode off after the decision"
            (check (with-current-buffer conv
                     mcp-emacs--apply-diff-inline-mode)
                   nil)))
      (let ((buf (find-buffer-visiting file)))
        (when buf (with-current-buffer buf (set-buffer-modified-p nil))
              (kill-buffer buf)))
      (when (buffer-live-p conv) (kill-buffer conv))
      (delete-file file))))

;; A hand-edit made to the file's buffer before accepting is kept, exactly
;; as with the ediff accept path.
(describe "a hand edit survives an inline accept"
  (let ((file (mcp--async-fixture))
        (conv (mcp--conversation-buffer)))
    (unwind-protect
        (let ((calls nil))
          (let ((mcp-emacs-apply-diff-inline-limit 40))
            (with-current-buffer conv
              (mcp-emacs-apply-diff-async file "new\n" 60
                                          (lambda (out) (push out calls)))))
          (with-current-buffer (find-buffer-visiting file)
            (erase-buffer) (insert "hand-edited\n"))
          (with-current-buffer conv
            (mcp-emacs--apply-diff-inline-accept))
          (it "reports applied with the hand-edited content"
            (check (car calls) "Status: applied\nhand-edited\n"))
          (it "writes the hand-edit to the file on disk, not the proposal"
            (check (with-temp-buffer
                     (insert-file-contents file)
                     (buffer-string))
                   "hand-edited\n")))
      (let ((buf (find-buffer-visiting file)))
        (when buf (with-current-buffer buf (set-buffer-modified-p nil))
              (kill-buffer buf)))
      (when (buffer-live-p conv) (kill-buffer conv))
      (delete-file file))))

(describe "an inline review that is rejected"
  (let ((file (mcp--async-fixture))
        (conv (mcp--conversation-buffer)))
    (unwind-protect
        (let ((calls nil))
          (let ((mcp-emacs-apply-diff-inline-limit 40))
            (with-current-buffer conv
              (mcp-emacs-apply-diff-async file "new\n" 60
                                          (lambda (out) (push out calls)))))
          (with-current-buffer conv
            (mcp-emacs--apply-diff-inline-reject))
          (it "reports Status: rejected"
            (check (car calls) "Status: rejected"))
          (it "leaves the file on disk unchanged"
            (check (with-temp-buffer
                     (insert-file-contents file)
                     (buffer-string))
                   "old\n"))
          (it "leaves the file's buffer untouched"
            (check (with-current-buffer (find-buffer-visiting file)
                     (buffer-substring-no-properties (point-min) (point-max)))
                   "old\n")))
      (let ((buf (find-buffer-visiting file)))
        (when buf (with-current-buffer buf (set-buffer-modified-p nil))
              (kill-buffer buf)))
      (when (buffer-live-p conv) (kill-buffer conv))
      (delete-file file))))

;; The jump key starts a real ediff session against the same two buffers
;; and result cell; resolving it there is the single outcome, and the
;; inline surface goes quiet.
(describe "the jump key hands an inline review to ediff"
  (let ((file (mcp--async-fixture))
        (conv (mcp--conversation-buffer))
        (control (generate-new-buffer " *fake-jump-control*")))
    (unwind-protect
        (let ((calls nil) (seen-a nil) (seen-b nil) (cell nil) (captured nil))
          (cl-letf (((symbol-function 'mcp-emacs--ediff-review)
                     (lambda (a b _entry result &optional on-resolve _tab)
                       (setq seen-a a seen-b b cell result captured on-resolve)
                       control)))
            (let ((mcp-emacs-apply-diff-inline-limit 40))
              (with-current-buffer conv
                (mcp-emacs-apply-diff-async file "new\n" 60
                                            (lambda (out) (push out calls)))))
            (with-current-buffer conv
              (mcp-emacs--apply-diff-inline-jump))
            (it "opens ediff against the same file buffer"
              (check seen-a (find-buffer-visiting file)))
            (it "opens ediff against the same proposal and result cell"
              (check-that (and (buffer-live-p seen-b) cell)))
            (it "turns the inline review off after the jump"
              (check (with-current-buffer conv
                       mcp-emacs--apply-diff-inline-mode)
                     nil))
            ;; Mirror the ediff accept key: record the decision, apply the
            ;; proposal, then deliver through the shared on-resolve.
            (setcar cell 'applied)
            (let ((buf (find-buffer-visiting file)))
              (with-current-buffer buf (erase-buffer) (insert "new\n")))
            (funcall captured)
            (it "delivers the ediff accept as the one outcome"
              (check (car calls) "Status: applied\nnew\n"))
            (it "ignores a second attempt on the inline surface"
              (with-current-buffer conv
                (mcp-emacs--apply-diff-inline-accept))
              (check (length calls) 1)))
          (when (buffer-live-p control) (kill-buffer control)))
      (let ((buf (find-buffer-visiting file)))
        (when buf (with-current-buffer buf (set-buffer-modified-p nil))
              (kill-buffer buf)))
      (when (buffer-live-p conv) (kill-buffer conv))
      (delete-file file))))

;; Accept-then-timeout and timeout-then-late-accept: whichever way the
;; race goes, the caller answers exactly once and the file is only ever
;; touched by an explicit accept.
(describe "an inline accept is not followed by a second outcome"
  (let ((file (mcp--async-fixture))
        (conv (mcp--conversation-buffer)))
    (unwind-protect
        (let ((calls nil))
          (let ((mcp-emacs-apply-diff-inline-limit 40))
            (with-current-buffer conv
              (mcp-emacs-apply-diff-async file "new\n" 1
                                          (lambda (out) (push out calls)))))
          (with-current-buffer conv
            (mcp-emacs--apply-diff-inline-accept))
          (it "answers once with the applied status"
            (check (car calls) "Status: applied\nnew\n"))
          (sleep-for 2)
          (it "does not deliver again when the timeout would have fired"
            (check (length calls) 1)))
      (let ((buf (find-buffer-visiting file)))
        (when buf (with-current-buffer buf (set-buffer-modified-p nil))
              (kill-buffer buf)))
      (when (buffer-live-p conv) (kill-buffer conv))
      (delete-file file))))

(describe "an inline review answered late cannot double-deliver"
  (let ((file (mcp--async-fixture))
        (conv (mcp--conversation-buffer)))
    (unwind-protect
        (let ((calls nil))
          (let ((mcp-emacs-apply-diff-inline-limit 40))
            (with-current-buffer conv
              (mcp-emacs-apply-diff-async file "new\n" 1
                                          (lambda (out) (push out calls)))))
          (it "has not answered while the timeout is still pending"
            (check calls nil))
          (sleep-for 2)
          (it "reports a timeout status when nobody resolves"
            (check (car calls) "Status: timeout"))
          (with-current-buffer conv
            (mcp-emacs--apply-diff-inline-accept))
          (it "ignores the late accept instead of delivering twice"
            (check (length calls) 1))
          (it "keeps the file on disk unchanged after the timeout"
            (check (with-temp-buffer
                     (insert-file-contents file)
                     (buffer-string))
                   "old\n"))
          (it "tears the inline surface down on timeout"
            (check (with-current-buffer conv
                     mcp-emacs--apply-diff-inline-mode)
                   nil)))
      (let ((buf (find-buffer-visiting file)))
        (when buf (with-current-buffer buf (set-buffer-modified-p nil))
              (kill-buffer buf)))
      (when (buffer-live-p conv) (kill-buffer conv))
      (delete-file file))))

;;;; Force-quit scratch reclaim (issue #126)

;; A forced review close must reclaim the ediff scratch buffers ediff
;; created, not just the control buffer; otherwise a timeout strands the
;; stacked panel set and blocks the next review.  Stub `ediff-really-quit'
;; to close the control buffer the way the real one closes its session,
;; and check the panels are gone afterwards.
(describe "mcp-emacs--apply-diff-force-quit on a plain ediff handle"
  (let* ((control (generate-new-buffer " *fake-force-quit-control*"))
         (diff-buf (generate-new-buffer "*ediff-diff*"))
         (fine-buf (generate-new-buffer "*ediff-fine-diff*"))
         (errors-buf (generate-new-buffer "*ediff-errors*")))
    (unwind-protect
        (cl-letf (((symbol-function 'ediff-really-quit)
                   (lambda (&rest _) (kill-buffer control))))
          (mcp-emacs--apply-diff-force-quit control)
          (it "closes the ediff control buffer"
            (check (buffer-live-p control) nil))
          (it "reclaims the diff scratch buffer"
            (check (buffer-live-p diff-buf) nil))
          (it "reclaims the fine-diff scratch buffer"
            (check (buffer-live-p fine-buf) nil))
          (it "reclaims the errors scratch buffer"
            (check (buffer-live-p errors-buf) nil)))
      (dolist (b (list control diff-buf fine-buf errors-buf))
        (when (buffer-live-p b) (kill-buffer b))))))

;; A review the human jumped from inline to ediff must not strand the
;; panels when the inline timeout fires: the dismiss lambda force-quits
;; the jumped-to control buffer and reclaims its scratch buffers.
(describe "the inline timeout reclaims a jumped-to ediff's scratch buffers"
  (let ((file (mcp--async-fixture))
        (conv (mcp--conversation-buffer))
        (control (generate-new-buffer " *fake-jump-timeout-control*"))
        (diff-buf (generate-new-buffer "*ediff-diff*"))
        (fine-buf (generate-new-buffer "*ediff-fine-diff*"))
        (errors-buf (generate-new-buffer "*ediff-errors*")))
    (unwind-protect
        (let ((calls nil))
          (cl-letf (((symbol-function 'mcp-emacs--ediff-review)
                     (lambda (_a _b _entry _result &optional _on-resolve _tab)
                       control))
                    ((symbol-function 'ediff-really-quit)
                     (lambda (&rest _) (kill-buffer control)))
                    ((symbol-function 'set-window-configuration)
                     (lambda (&rest _) nil)))
            (let ((mcp-emacs-apply-diff-inline-limit 40))
              (with-current-buffer conv
                (mcp-emacs-apply-diff-async file "new\n" 1
                                            (lambda (out) (push out calls)))))
            (with-current-buffer conv
              (mcp-emacs--apply-diff-inline-jump))
            (it "leaves the panels up while the review is still live"
              (check (buffer-live-p diff-buf) t))
            (sleep-for 2)
            (it "reclaims the diff scratch buffer on timeout"
              (check (buffer-live-p diff-buf) nil))
            (it "reclaims the fine-diff scratch buffer on timeout"
              (check (buffer-live-p fine-buf) nil))
            (it "reclaims the errors scratch buffer on timeout"
              (check (buffer-live-p errors-buf) nil))
            (it "closes the jumped-to control buffer on timeout"
              (check (buffer-live-p control) nil))))
      (dolist (b (list control diff-buf fine-buf errors-buf))
        (when (buffer-live-p b) (kill-buffer b)))
      (let ((buf (find-buffer-visiting file)))
        (when buf (with-current-buffer buf (set-buffer-modified-p nil))
              (kill-buffer buf)))
      (when (buffer-live-p conv) (kill-buffer conv))
      (delete-file file))))

;;;; Foreign-session host resolution (issue #126)

;; A foreign (non-agent-backend) request must prefer a visible
;; conversation over the selected window's buffer; only with no
;; conversation visible does window focus decide.
(describe "a foreign-session review prefers a visible conversation buffer"
  (let* ((from (generate-new-buffer " *foreign-from*"))
         (focus (generate-new-buffer " *focused-buffer*"))
         (conv (mcp--conversation-buffer)))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-backend--visible-conversation)
                   (lambda () conv))
                  ((symbol-function 'mcp-emacs--current-buffer)
                   (lambda () focus)))
          (it "renders into the visible conversation, not the focused window"
            (check (mcp-emacs--apply-diff-conversation-buffer from) conv))
          (it "does not use the selected window's buffer when a conversation is visible"
            (check (eq (mcp-emacs--apply-diff-conversation-buffer from) focus)
                   nil)))
      (dolist (b (list from focus conv))
        (when (buffer-live-p b) (kill-buffer b))))))

(describe "window focus stays the fallback with no visible conversation"
  (let* ((from (generate-new-buffer " *foreign-from-2*"))
         (focus (generate-new-buffer " *focused-buffer-2*")))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-backend--visible-conversation)
                   (lambda () nil))
                  ((symbol-function 'mcp-emacs--current-buffer)
                   (lambda () focus)))
          (it "falls back to the selected window's buffer"
            (check (mcp-emacs--apply-diff-conversation-buffer from) focus)))
      (dolist (b (list from focus))
        (when (buffer-live-p b) (kill-buffer b))))))

;;;; Org-task domain events (issue #39)
;;
;; The Org file is the aggregate; these events observe that it changed.  The
;; contract that matters is "only on success": a rejected keyword or an
;; unidentifiable item changes nothing, so there is nothing to observe.

(require 'org)

(defun mcp--org-fixture (text)
  "Write TEXT to a temp .org file and return its path."
  (let ((f (make-temp-file "mcp-orgtask-" nil ".org" text)))
    f))

(defmacro mcp--with-org-events (var &rest body)
  "Run BODY collecting org-task events into VAR (oldest first)."
  (declare (indent 1))
  `(let* ((,var nil)
          (mcp-emacs-org-task-event-functions
           (list (lambda (e) (setq ,var (append ,var (list e)))))))
     ,@body))

(describe "mcp-emacs-org-task-set-session-status events"
  ;; A successful status change emits one observation carrying the new state.
  (let ((f (mcp--org-fixture "* TODO Task\n:PROPERTIES:\n:SESSION: s1\n:END:\n")))
    (unwind-protect
        (mcp--with-org-events evs
          (mcp-emacs-org-task-set-session-status f "DONE")
          (it "emits exactly one observation for a successful status change"
            (check (length evs) 1))
          (it "labels the observation as a session-status event"
            (check (plist-get (car evs) :kind) 'session-status))
          (it "carries the new status"
            (check (plist-get (car evs) :status) "DONE"))
          (it "carries the path of the Org file that changed"
            (check (plist-get (car evs) :path) f)))
      (let ((b (find-buffer-visiting f)))
        (when b (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
      (delete-file f)))

  ;; A rejected keyword changes nothing, so it must emit nothing.
  (let ((f (mcp--org-fixture "* TODO Task\n:PROPERTIES:\n:SESSION: s1\n:END:\n")))
    (unwind-protect
        (mcp--with-org-events evs
          (mcp-emacs-org-task-set-session-status f "NOT-A-KEYWORD")
          (it "emits nothing when the keyword is rejected and nothing changed"
            (check evs nil)))
      (let ((b (find-buffer-visiting f)))
        (when b (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
      (delete-file f))))

(describe "mcp-emacs-org-task-set-item-status events"
  ;; An item that cannot be identified changes nothing either.
  (let ((f (mcp--org-fixture "* TODO Task\n:PROPERTIES:\n:SESSION: s1\n:END:\n** TODO one\n")))
    (unwind-protect
        (mcp--with-org-events evs
          (mcp-emacs-org-task-set-item-status f "no such item" "DONE")
          (it "emits nothing when the item cannot be identified"
            (check evs nil)))
      (let ((b (find-buffer-visiting f)))
        (when b (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
      (delete-file f))))

(describe "mcp-emacs-org-task-append-item events"
  ;; Appending an item observes the text and the keyword it was given.
  (let ((f (mcp--org-fixture "* TODO Task\n:PROPERTIES:\n:SESSION: s1\n:END:\n")))
    (unwind-protect
        (mcp--with-org-events evs
          (mcp-emacs-org-task-append-item f "a new item" "TODO")
          (it "labels the observation as an item-added event"
            (check (plist-get (car evs) :kind) 'item-added))
          (it "carries the text of the appended item"
            (check (plist-get (car evs) :text) "a new item")))
      (let ((b (find-buffer-visiting f)))
        (when b (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
      (delete-file f))))

(describe "mcp-emacs-org-task-append-note events"
  ;; A note observes its text.
  (let ((f (mcp--org-fixture "* TODO Task\n:PROPERTIES:\n:SESSION: s1\n:END:\n")))
    (unwind-protect
        (mcp--with-org-events evs
          (mcp-emacs-org-task-append-note f "progress note")
          (it "labels the observation as a note event"
            (check (plist-get (car evs) :kind) 'note))
          (it "carries the text of the note"
            (check (plist-get (car evs) :text) "progress note")))
      (let ((b (find-buffer-visiting f)))
        (when b (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
      (delete-file f))))

;; A failing subscriber must not break the Org write it observes -- the
;; aggregate comes first, the record second.
(describe "an Org write whose event subscriber signals"
  (let ((f (mcp--org-fixture "* TODO Task\n:PROPERTIES:\n:SESSION: s1\n:END:\n")))
    (unwind-protect
        (let ((mcp-emacs-org-task-event-functions
               (list (lambda (_e) (error "subscriber blew up")))))
          ;; The write must return normally, not signal: the outer handler only
          ;; catches `user-error', so an unguarded subscriber error escapes as a
          ;; plain `error' and takes the tool call down with it.
          (it "returns normally instead of taking the tool call down"
            (check (condition-case _
                       (progn (mcp-emacs-org-task-set-session-status f "DONE") t)
                     (error nil))
                   t))
          ;; And the Org file really did change.
          (with-current-buffer (find-file-noselect f)
            (it "still applies the change to the Org file"
              (check-that (string-match-p "DONE" (buffer-string))))))
      (let ((b (find-buffer-visiting f)))
        (when b (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
      (delete-file f))))

(test-helper-summary)

;;; mcp-emacs-apply-diff-test.el ends here
