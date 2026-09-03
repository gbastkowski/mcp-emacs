;;; agent-backend-test.el --- Tests for the shared agent-backend -*- lexical-binding: t; -*-

;; Batch tests for the shared core.  The preference dispatcher is the
;; load-bearing new logic: which backend agent-backend-start picks is a
;; per-machine decision, since a CLI can be installed yet unusable (no
;; subscription), so the signal is the defcustom, not a runtime probe.

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'cl-lib)
(require 'agent-backend)

(describe "agent-backend-prefer-opencode-p with an explicit preference"
  (cl-letf (((symbol-function 'opencode-client--health) (lambda () t)))
    (let ((agent-backend-preference 'opencode))
      (it "prefers opencode when it is forced"
        (check (agent-backend-prefer-opencode-p) t))))

  (cl-letf (((symbol-function 'opencode-client--health) (lambda () nil)))
    (let ((agent-backend-preference 'opencode))
      (it "prefers opencode even when the server is unhealthy"
        (check (agent-backend-prefer-opencode-p) t))))

  (let ((agent-backend-preference 'claude))
    (it "declines opencode when claude is forced"
      (check (agent-backend-prefer-opencode-p) nil))))

;; auto consults the server only for opencode.  Provide a stub
;; opencode-client feature first so the require inside
;; prefer-opencode-p finds it and cannot clobber the stub with the
;; real (server-probing) function.
(defun agent-backend-test--health (healthy)
  (lambda () healthy))
(unless (featurep 'opencode-client)
  (fset 'opencode-client--health (lambda () nil))
  (provide 'opencode-client))

(describe "agent-backend-prefer-opencode-p on auto"
  (cl-letf (((symbol-function 'opencode-client--health) (lambda () t)))
    (let ((agent-backend-preference 'auto))
      (it "picks opencode when the server is healthy"
        (check (agent-backend-prefer-opencode-p) t))))
  (cl-letf (((symbol-function 'opencode-client--health) (lambda () nil)))
    (let ((agent-backend-preference 'auto))
      (it "falls back to claude when the server is unhealthy"
        (check (agent-backend-prefer-opencode-p) nil)))))

(describe "agent-backend-preference"
  (it "defaults to auto"
    (check agent-backend-preference 'auto)))

(describe "agent-backend note-policy"
  (let ((b (make-instance 'agent-backend)))
    (it "reads :steer from the class default"
      (check (agent-backend-note-policy b) :steer))
    (oset b note-policy :queue)
    (it "dispatches the value set on the slot"
      (check (agent-backend-note-policy b) :queue))))

;;;; Sharing a selection (issue #56)

(require 'project)

(describe "agent-backend-selection-reference"
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
          (it "points at the project-relative path and the selected lines only"
            (check (agent-backend-selection-reference)
                   "@elisp/agent-backend.el:12-14"))
          (deactivate-mark))
        (goto-char (point-min))
        (forward-line 4)
        (it "points at the single line at point when there is no region"
          (check (agent-backend-selection-reference)
                 "@elisp/agent-backend.el:5"))))
    (kill-buffer buf))

  ;; With no file to point at there is no path, so the text itself is the
  ;; only useful reference.
  (with-temp-buffer
    (insert "alpha\nbeta\n")
    (goto-char (point-min))
    (it "falls back to the line's text in a buffer with no file"
      (check (agent-backend-selection-reference) "alpha"))))

(describe "agent-backend--conversation-buffers"
  ;; Resolution finds any buffer holding an instance -- no registry, so a
  ;; new client is found for free.
  (let ((conv (get-buffer-create "*fake-conversation*")))
    (unwind-protect
        (progn
          (with-current-buffer conv
            (setq-local agent-backend--instance (make-instance 'agent-backend)))
          (it "finds any buffer holding an instance, with no registry to enrol in"
            (check (memq conv (agent-backend--conversation-buffers))
                   (list conv)))
          (it "resolves the only conversation there is"
            (check (agent-backend--resolve-conversation) conv)))
      (kill-buffer conv)))

  (let ((plain (get-buffer-create "*not-a-conversation*")))
    (unwind-protect
        (it "ignores a buffer without an instance"
          (check (memq plain (agent-backend--conversation-buffers)) nil))
      (kill-buffer plain))))

(describe "agent-backend--resolve-conversation"
  (it "refuses rather than silently doing nothing when nothing is live"
    (check (condition-case nil
               (progn (agent-backend--resolve-conversation) 'no-error)
             (user-error 'user-error))
           'user-error))

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
          (it "prefers the conversation in the current project"
            (check (agent-backend--resolve-conversation) mine)))
      (kill-buffer mine)
      (kill-buffer other))))

(describe "agent-backend-mention"
  ;; The default mention routes through add-note, so a backend that
  ;; implements only the required verbs still gets a working mention.
  (let ((noted nil))
    (cl-letf (((symbol-function 'agent-backend-add-note)
               (lambda (_backend text) (setq noted text))))
      (agent-backend-mention (make-instance 'agent-backend) "@foo.el:1")
      (it "routes through add-note so a minimal backend still gets a mention"
        (check noted "@foo.el:1")))))

;;;; Explaining a selection (issue #56)

(describe "agent-backend-query"
  (it "refuses on the base class rather than pretending it can answer without a session"
    (check (condition-case nil
               (progn (agent-backend-query (make-instance 'agent-backend) "hi" #'ignore)
                      'no-error)
             (user-error 'user-error))
           'user-error)))

(describe "agent-backend-explain-route"
  (it "defaults to session-first, since explaining is usually part of the work in context"
    (check agent-backend-explain-route 'session-first)))

;; `--visible-conversation' answers the question the fallback needs --
;; "is one on screen?" -- without signalling the way
;; `--resolve-conversation' does, since a nil answer is actionable here.
(describe "agent-backend--visible-conversation"
  (it "returns nil rather than signalling when there is no conversation at all"
    (check (agent-backend--visible-conversation) nil))

  (let ((conv (get-buffer-create "*conv-visible*")))
    (unwind-protect
        (progn
          (with-current-buffer conv
            (setq-local agent-backend--instance (make-instance 'agent-backend)))
          (it "returns nil for a live conversation that is not displayed"
            (check (agent-backend--visible-conversation) nil))
          (set-window-buffer (selected-window) conv)
          (it "returns the conversation once it is shown in a window"
            (check (agent-backend--visible-conversation) conv)))
      (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
      (kill-buffer conv))))

;; Routing.  Each mode is checked for what it does *and* what it must not
;; do: the point of `one-shot' is that it skips a session even when one
;; is right there, so asserting only "it queried" would pass a
;; still-broken implementation.
(describe "agent-backend-explain-selection"
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

          (setq queried nil sent nil)
          (let ((agent-backend-explain-route 'session-first))
            (with-temp-buffer
              (insert "some code\n")
              (goto-char (point-min))
              (agent-backend-explain-selection)))
          (it "falls back to a one-shot query under session-first when nothing is visible"
            (check-that queried))
          (it "sends no turn under session-first when nothing is visible"
            (check sent nil))

          (set-window-buffer (selected-window) conv)
          (setq queried nil sent nil)
          (let ((agent-backend-explain-route 'session-first))
            (with-temp-buffer
              (insert "some code\n")
              (goto-char (point-min))
              (agent-backend-explain-selection)))
          (it "sends a real turn under session-first when a conversation is visible"
            (check-that sent))
          (it "does not spend a separate query when it sent a turn"
            (check queried nil))

          (setq queried nil sent nil)
          (let ((agent-backend-explain-route 'one-shot))
            (with-temp-buffer
              (insert "some code\n")
              (goto-char (point-min))
              (agent-backend-explain-selection)))
          (it "queries under one-shot even though a conversation is right there"
            (check-that queried))
          (it "sends no turn under one-shot"
            (check sent nil))

          (it "builds the prompt by applying the template to the reference"
            (check queried "explain some code"))

          (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
          (setq queried nil sent nil)
          (it "refuses under session-only when there is no session, instead of spending a separate call"
            (check (let ((agent-backend-explain-route 'session-only))
                     (with-temp-buffer
                       (insert "some code\n")
                       (goto-char (point-min))
                       (condition-case nil
                           (progn (agent-backend-explain-selection) 'no-error)
                         (user-error 'user-error))))
                   'user-error))
          (it "queries nothing when session-only refuses"
            (check queried nil)))
      (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
      (kill-buffer conv))))

(test-helper-summary)

;;; agent-backend-test.el ends here
