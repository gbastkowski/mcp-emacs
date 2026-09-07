;;; mcp-emacs-wait-tick-test.el --- Tests for the cooperative wait tick -*- lexical-binding: t; -*-

;; Tool handlers that wait for a human run synchronously from the web
;; server's process filter (`ws-call-handler' funcalls them inline).  These
;; loops used to yield with `accept-process-output', which will not re-enter
;; the filter of the process it is already filtering: it returned at once,
;; the poll loop degenerated into a busy spin, and one `org_task_wait_for_change'
;; call pinned a core for its whole timeout.  Left to repeat -- client gives
;; up, `ws-send-500' fails on the dead socket, next request spins again -- it
;; kept an Emacs at 100% CPU for 19 hours.
;;
;; What these tests pin down is that a wait tick actually waits, including in
;; the case `sit-for' alone does not cover (input pending, where it returns
;; nil immediately), and that the loop built on it polls at its interval
;; rather than as fast as the CPU allows.

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'cl-lib)
(require 'mcp-emacs)
(require 'org)

(defun mcp--elapsed (thunk)
  "Return seconds spent calling THUNK."
  (let ((start (float-time)))
    (funcall thunk)
    (- (float-time) start)))

;;;; The tick itself

;; A caveat on what can and cannot be pinned down from batch: the production
;; failure needs a `ws-filter' on the stack, and there is none here, so
;; `accept-process-output' waits perfectly well in this harness.  The spin
;; itself is therefore not reproducible in batch -- these tests pin the
;; contract the fix relies on instead, and the one below that fails against
;; the old body does so because `sit-for' is reached at all.

(describe "mcp-emacs--wait-tick"
  ;; The plain case: no input pending, `sit-for' does the waiting.  Asserting
  ;; a lower bound only -- batch Emacs can oversleep, and that is harmless.
  (it "waits for approximately the interval it was given"
    (check-that (>= (mcp--elapsed (lambda () (mcp-emacs--wait-tick 0.2))) 0.15)))

  ;; The fallback.  `sit-for' returns nil the moment input is pending, without
  ;; waiting, which on its own would spin the poll loop just as the old yield
  ;; did in a filter; `sleep-for' has to cover that case.
  ;;
  ;; Driven with a stub rather than real pending input: binding
  ;; `unread-command-events' around the call does not make `sit-for' inside
  ;; the callee return early in batch (measured: it sleeps the full interval),
  ;; so the realistic-looking version of this test asserted nothing.  Stubbing
  ;; `sit-for' to nil reproduces the branch condition directly.
  (let ((elapsed (cl-letf (((symbol-function 'sit-for) (lambda (&rest _) nil)))
                   (mcp--elapsed (lambda () (mcp-emacs--wait-tick 0.2))))))
    (it "falls back to `sleep-for' when `sit-for' declines to wait"
      (check-that (>= elapsed 0.15))))

  ;; The tick must not yield with `accept-process-output' -- that is the call
  ;; that cannot re-enter the filter it is running under, and so the call that
  ;; caused the spin.  Asserted by stubbing it and checking it goes unused:
  ;; the function is byte-compiled, so grepping its printed form for a call
  ;; name silently never matches and would pass vacuously.
  (let ((used nil))
    (cl-letf (((symbol-function 'accept-process-output)
               (lambda (&rest _) (setq used t) nil)))
      (mcp-emacs--wait-tick 0.05))
    (it "does not yield with the process-filter-blind `accept-process-output'"
      (check used nil))))

;;;; The loop that uses it

;; `mcp-emacs-org-task-wait-for-change' is the handler that actually spun:
;; it is registered with `:handler' only (no `:async-handler'), so over HTTP
;; it runs inline in the filter for up to its 300-second cap.
(describe "mcp-emacs-org-task-wait-for-change while nothing changes"
  (let* ((file (make-temp-file "mcp-wait-" nil ".org"
                               "* TODO Task\n:PROPERTIES:\n:SESSION: s1\n:END:\n"))
         (ticks 0)
         elapsed)
    (unwind-protect
        (let ((baseline (with-current-buffer (find-file-noselect file)
                          (mcp-emacs-org-task--token))))
          ;; Count the loop's iterations.  This says the loop polls through
          ;; the tick at roughly its interval -- it cannot by itself prove the
          ;; tick waits, since a tick that returned instantly would show up as
          ;; a high count only if it also failed to sleep, which is what the
          ;; tick's own tests above cover.
          (cl-letf* ((real (symbol-function 'mcp-emacs--wait-tick))
                     ((symbol-function 'mcp-emacs--wait-tick)
                      (lambda (secs) (setq ticks (1+ ticks)) (funcall real secs))))
            (setq elapsed
                  (mcp--elapsed
                   (lambda ()
                     (mcp-emacs-org-task-wait-for-change file baseline 1)))))
          (it "waits out its timeout rather than returning at once"
            (check-that (>= elapsed 0.9)))
          (it "polls at its interval instead of spinning the CPU"
            ;; ~5 ticks for a 1s timeout at 0.2s; allow slack for a loaded
            ;; batch run, but nowhere near a spin's iteration count.
            (check-that (<= ticks 25)))
          (it "reports no change when the file stayed put"
            (check-that (string-match-p "\\`Changed: no"
                                        (mcp-emacs-org-task-wait-for-change
                                         file baseline 0.1)))))
      (let ((b (find-buffer-visiting file)))
        (when b (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
      (delete-file file))))

;; The early-return paths must not wait at all: a nil baseline means the
;; caller has no token to compare against, and an already-advanced tick means
;; the change it was waiting for has happened.
(describe "mcp-emacs-org-task-wait-for-change with nothing to wait for"
  (let ((file (make-temp-file "mcp-wait-" nil ".org"
                              "* TODO Task\n:PROPERTIES:\n:SESSION: s1\n:END:\n")))
    (unwind-protect
        (progn
          (it "returns immediately when given no baseline token"
            (check-that (< (mcp--elapsed
                            (lambda ()
                              (mcp-emacs-org-task-wait-for-change file nil 30)))
                           0.5)))
          (it "returns immediately when the token is already stale"
            (check-that (< (mcp--elapsed
                            (lambda ()
                              ;; A baseline the tick can never equal.
                              (mcp-emacs-org-task-wait-for-change file 1 30)))
                           0.5)))
          (it "reports a change when the baseline is already stale"
            (check-that (string-match-p
                         "\\`Changed: yes"
                         (mcp-emacs-org-task-wait-for-change file 1 30)))))
      (let ((b (find-buffer-visiting file)))
        (when b (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
      (delete-file file))))

(test-helper-summary)

;;; mcp-emacs-wait-tick-test.el ends here
