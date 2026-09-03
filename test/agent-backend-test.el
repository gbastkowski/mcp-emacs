;;; agent-backend-test.el --- Tests for the shared agent-backend -*- lexical-binding: t; -*-

;; Batch tests for the shared core.  The preference dispatcher is the
;; load-bearing new logic: which backend agent-backend-start picks is a
;; per-machine decision, since a CLI can be installed yet unusable (no
;; subscription), so the signal is the defcustom, not a runtime probe.

(add-to-list 'load-path (expand-file-name "elisp"))
(require 'cl-lib)
(require 'agent-backend)
(defun check (l g w) (princ (format "%s %s: got=%S want=%S
" (if (equal g w) "PASS" "FAIL") l g w)))

;; Explicit preference wins regardless of server state.
(cl-letf (((symbol-function 'opencode-client--health) (lambda () t)))
  (let ((agent-backend-preference 'opencode))
    (check "forced-opencode" (agent-backend-prefer-opencode-p) t)))

(cl-letf (((symbol-function 'opencode-client--health) (lambda () nil)))
  (let ((agent-backend-preference 'opencode))
    (check "forced-opencode-despite-unhealthy" (agent-backend-prefer-opencode-p) t)))

(let ((agent-backend-preference 'claude))
  (check "forced-claude" (agent-backend-prefer-opencode-p) nil))

;; auto consults the server only for opencode.  Provide a stub
;; opencode-client feature first so the require inside
;; prefer-opencode-p finds it and cannot clobber the stub with the
;; real (server-probing) function.
(defun agent-backend-test--health (healthy)
  (lambda () healthy))
(unless (featurep 'opencode-client)
  (fset 'opencode-client--health (lambda () nil))
  (provide 'opencode-client))
(cl-letf (((symbol-function 'opencode-client--health) (lambda () t)))
  (let ((agent-backend-preference 'auto))
    (check "auto-healthy-opencode" (agent-backend-prefer-opencode-p) t)))
(cl-letf (((symbol-function 'opencode-client--health) (lambda () nil)))
  (let ((agent-backend-preference 'auto))
    (check "auto-unhealthy-falls-to-claude" (agent-backend-prefer-opencode-p) nil)))

;; Default is auto.
(check "default-preference" agent-backend-preference 'auto)

;; The class dispatches note-policy from the slot.
(let ((b (make-instance 'agent-backend)))
  (check "default-note-policy" (agent-backend-note-policy b) :steer)
  (oset b note-policy :queue)
  (check "oset-note-policy" (agent-backend-note-policy b) :queue))

;;;; Sharing a selection (issue #56)

(require 'project)

;; The reference is a project-relative pointer, not the text itself: the
;; agent can read the file for itself, and a pointer stays right as the
;; file moves on.
(let ((buf (find-file-noselect
            (expand-file-name "elisp/agent-backend.el"))))
  (with-current-buffer buf
    (goto-char (point-min))
    (forward-line 11)
    (let ((beg (point)))
      (forward-line 3)
      (let ((transient-mark-mode t))
        (set-mark beg)
        (activate-mark)
        ;; 12-14, not 12-15: the region ends at column 0 of line 15, so
        ;; it covers up to the previous line -- selecting three whole
        ;; lines should not claim a fourth.
        (check "ref-region-is-project-relative"
               (agent-backend-selection-reference)
               "@elisp/agent-backend.el:12-14")
        (deactivate-mark))
      ;; No region: the single line at point.
      (goto-char (point-min))
      (forward-line 4)
      (check "ref-no-region-is-one-line"
             (agent-backend-selection-reference)
             "@elisp/agent-backend.el:5")))
  (kill-buffer buf))

;; With no file to point at there is no path, so the text itself is the
;; only useful reference.
(with-temp-buffer
  (insert "alpha\nbeta\n")
  (goto-char (point-min))
  (check "ref-nonfile-no-region" (agent-backend-selection-reference) "alpha"))

;; Resolution finds any buffer holding an instance -- no registry, so a
;; new client is found for free.
(let ((conv (get-buffer-create "*fake-conversation*")))
  (unwind-protect
      (progn
        (with-current-buffer conv
          (setq-local agent-backend--instance (make-instance 'agent-backend)))
        (check "conversation-found"
               (memq conv (agent-backend--conversation-buffers))
               (list conv))
        (check "resolves-the-only-one"
               (agent-backend--resolve-conversation) conv))
    (kill-buffer conv)))

;; A buffer without an instance is not a conversation.
(let ((plain (get-buffer-create "*not-a-conversation*")))
  (unwind-protect
      (check "plain-buffer-ignored"
             (memq plain (agent-backend--conversation-buffers)) nil)
    (kill-buffer plain)))

;; Refuses rather than silently doing nothing when nothing is live.
(check "no-conversation-errors"
       (condition-case nil
           (progn (agent-backend--resolve-conversation) 'no-error)
         (user-error 'user-error))
       'user-error)

;; Same project beats another project, and visible beats hidden -- the
;; selection is about the project you are in, and an on-screen
;; conversation is the one being worked with.
(let* ((here (expand-file-name default-directory))
       (mine (get-buffer-create "*conv-same-project*"))
       (other (get-buffer-create "*conv-other-project*")))
  (unwind-protect
      (progn
        (with-current-buffer mine
          (setq-local default-directory here)
          (setq-local agent-backend--instance (make-instance 'agent-backend)))
        (with-current-buffer other
          (setq-local default-directory "/tmp/somewhere-else/")
          (setq-local agent-backend--instance (make-instance 'agent-backend)))
        (check "same-project-wins"
               (agent-backend--resolve-conversation) mine))
    (kill-buffer mine)
    (kill-buffer other)))

;; The default mention routes through add-note, so a backend that
;; implements only the required verbs still gets a working mention.
(let ((noted nil))
  (cl-letf (((symbol-function 'agent-backend-add-note)
             (lambda (_backend text) (setq noted text))))
    (agent-backend-mention (make-instance 'agent-backend) "@foo.el:1")
    (check "default-mention-uses-add-note" noted "@foo.el:1")))

;;;; Explaining a selection (issue #56)

;; Not every backend can answer without a session, so the base class
;; refuses rather than pretending.
(check "default-query-refuses"
       (condition-case nil
           (progn (agent-backend-query (make-instance 'agent-backend) "hi" #'ignore)
                  'no-error)
         (user-error 'user-error))
       'user-error)

;; The default route prefers a visible conversation: "explain this" is
;; usually part of the work already in that context.
(check "default-explain-route" agent-backend-explain-route 'session-first)

;; `--visible-conversation' answers the question the fallback needs --
;; "is one on screen?" -- without signalling the way
;; `--resolve-conversation' does, since a nil answer is actionable here.
(check "no-visible-conversation-is-nil" (agent-backend--visible-conversation) nil)

(let ((conv (get-buffer-create "*conv-visible*")))
  (unwind-protect
      (progn
        (with-current-buffer conv
          (setq-local agent-backend--instance (make-instance 'agent-backend)))
        ;; Live but not displayed: still nil, which is what routes an
        ;; explain to the one-shot path.
        (check "hidden-conversation-is-not-visible"
               (agent-backend--visible-conversation) nil)
        (set-window-buffer (selected-window) conv)
        (check "shown-conversation-is-visible"
               (agent-backend--visible-conversation) conv))
    (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
    (kill-buffer conv)))

;; Routing.  Each mode is checked for what it does *and* what it must not
;; do: the point of `one-shot' is that it skips a session even when one
;; is right there, so asserting only "it queried" would pass a
;; still-broken implementation.
(let ((conv (get-buffer-create "*conv-route*"))
      queried sent)
  (unwind-protect
      (cl-letf (((symbol-function 'agent-backend-send)
                 (lambda (_b prompt) (setq sent prompt)))
                ((symbol-function 'agent-backend-query)
                 (lambda (_b prompt _cb) (setq queried prompt)))
                ((symbol-function 'agent-backend--query-backend)
                 (lambda () (make-instance 'agent-backend)))
                ;; The popup needs markdown-mode, absent in batch.  The
                ;; command requires mcp-emacs-run, which would reinstate
                ;; the real definitions over a stub set before it loads --
                ;; so load it here first, then stub both the renderer and
                ;; the guard that refuses without markdown-mode.
                ((symbol-function 'mcp-emacs-popup-show)
                 (progn (require 'mcp-emacs-run)
                        (lambda (content &optional _kind) content)))
                ((symbol-function 'mcp-emacs-run--ensure-markdown) #'ignore))
        (with-current-buffer conv
          (setq-local agent-backend--instance (make-instance 'agent-backend)))

        ;; Nothing visible: session-first falls back to a one-shot query.
        (setq queried nil sent nil)
        (let ((agent-backend-explain-route 'session-first))
          (with-temp-buffer
            (insert "some code\n")
            (goto-char (point-min))
            (agent-backend-explain-selection)))
        (check "session-first-without-session-queries" (and queried t) t)
        (check "session-first-without-session-sends-no-turn" sent nil)

        ;; Visible: session-first sends a real turn instead.
        (set-window-buffer (selected-window) conv)
        (setq queried nil sent nil)
        (let ((agent-backend-explain-route 'session-first))
          (with-temp-buffer
            (insert "some code\n")
            (goto-char (point-min))
            (agent-backend-explain-selection)))
        (check "session-first-with-session-sends-turn" (and sent t) t)
        (check "session-first-with-session-does-not-query" queried nil)

        ;; one-shot ignores the visible conversation entirely.
        (setq queried nil sent nil)
        (let ((agent-backend-explain-route 'one-shot))
          (with-temp-buffer
            (insert "some code\n")
            (goto-char (point-min))
            (agent-backend-explain-selection)))
        (check "one-shot-queries-despite-session" (and queried t) t)
        (check "one-shot-sends-no-turn" sent nil)

        ;; The prompt is the template applied to the reference.
        (check "explain-prompt-uses-template" queried "explain some code")

        ;; session-only refuses instead of spending a separate call.
        (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
        (setq queried nil sent nil)
        (check "session-only-without-session-refuses"
               (let ((agent-backend-explain-route 'session-only))
                 (with-temp-buffer
                   (insert "some code\n")
                   (goto-char (point-min))
                   (condition-case nil
                       (progn (agent-backend-explain-selection) 'no-error)
                     (user-error 'user-error))))
               'user-error)
        (check "session-only-refusal-queries-nothing" queried nil))
    (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
    (kill-buffer conv)))
