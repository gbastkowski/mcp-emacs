;;; agent-permission.el --- Answer agent permission decisions in a buffer -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.11.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A tool call the agent is not allowed to make should be a question, not a
;; dead end.  This is the surface that asks it: a small buffer naming the
;; tool and the exact call, answered with one key -- allow once, or deny.
;;
;; The shape is `agent-prompt''s, for the same reasons, with one difference:
;; a prompt collects text and a decision collects a choice, so this is a
;; read-only buffer of single keys rather than something to type into.
;;
;; Backend-agnostic on purpose.  A pending decision is a plist and a
;; continuation; who asked and how the answer travels back is the caller's
;; business.  Claude reaches this through a `PreToolUse' hook (the CLI
;; blocks on it, which is what makes a real gate possible at all), opencode
;; through its own permission API and `agent-backend-reply-permission'.
;; Neither is mentioned here.
;;
;; Two invariants the callers depend on:
;;
;; - Every pending decision is answered exactly once.  Whoever is waiting is
;;   blocked until then, so a decision that resolves twice would answer a
;;   call that already happened.
;; - Not answering is a denial.  These requests arrive while nobody may be
;;   looking, so the timeout has to fall closed; `agent-permission-request'
;;   takes the deadline and reports it as `timeout' rather than leaving the
;;   caller to invent a default.

;;; Code:

(require 'subr-x)
(require 'json)

(declare-function project-current "project" (&optional maybe-prompt directory))
(declare-function project-root "project" (project))

(defgroup agent-permission nil
  "Answering agent permission decisions."
  :group 'tools
  :prefix "agent-permission-")

(defcustom agent-permission-window-height 12
  "Lines given to the decision window when splitting below."
  :type 'integer
  :group 'agent-permission)

(defcustom agent-permission-split-height-threshold 20
  "Window height below which the decision buffer splits sideways.
Mirrors `agent-prompt-split-height-threshold': below this many lines a
horizontal split leaves both halves useless."
  :type 'integer
  :group 'agent-permission)

(defcustom agent-permission-input-max-length 2000
  "Longest tool input rendered in full.
A decision is only meaningful if the human can see what they are
approving, but a pathological input (a whole file passed to a write
tool) would bury the keys below the fold.  Longer inputs are elided in
the middle, where a command's identity is least likely to live."
  :type 'integer
  :group 'agent-permission)

(defvar agent-permission--pending nil
  "Alist of (ID . PLIST) for decisions raised and not yet answered.
PLIST holds `:tool', `:input', `:cwd', `:resolve' and `:buffer'.  The
registry is the single source of truth for \"is this still open\": a
resolved decision is removed from it before its continuation runs, so a
second answer finds nothing and does nothing.")

(defvar-local agent-permission--id nil
  "The pending decision this buffer answers.")

;;;; The registry

(defun agent-permission--take (id)
  "Remove and return the pending decision for ID, or nil when it is gone.
Removal and lookup are one step on purpose: this is what makes
\"answered exactly once\" hold without a separate flag to keep in sync.
Ids are strings, so this compares with `equal' -- an `assq' here would
never match."
  (when-let* ((entry (assoc id agent-permission--pending)))
    (setq agent-permission--pending
          (assoc-delete-all (car entry) agent-permission--pending))
    (cdr entry)))

(defun agent-permission-pending-ids ()
  "Return the ids of decisions still waiting for an answer."
  (mapcar #'car agent-permission--pending))

(defun agent-permission--resolve (id decision &optional reason)
  "Answer the pending decision ID with DECISION and REASON.
DECISION is `allow', `deny' or `timeout'.  Does nothing when ID is no
longer pending, so a race between the human and the deadline resolves
once.  Returns non-nil when this call was the one that answered."
  (when-let* ((entry (agent-permission--take id)))
    (let ((buffer (plist-get entry :buffer))
          (resolve (plist-get entry :resolve)))
      (when (buffer-live-p buffer)
        (agent-permission--close buffer))
      ;; From a timer, not inline: the continuation writes to a process and
      ;; may rearrange windows, and doing that while this command is still
      ;; unwinding the window it was called from is how windows get lost.
      (when resolve
        (run-at-time 0 nil resolve decision reason))
      t)))

;;;; Windows

(defun agent-permission--split (window)
  "Split WINDOW for a decision buffer and return the new window.
Nil when WINDOW cannot be split, so a cramped frame degrades to
`display-buffer' rather than signalling."
  (condition-case nil
      (if (< (window-body-height window) agent-permission-split-height-threshold)
          (split-window window nil 'right)
        (split-window window (- (max 4 agent-permission-window-height)) 'below))
    (error nil)))

(defun agent-permission--display (buffer window)
  "Show BUFFER in a split of WINDOW, select it, and return the window."
  (let* ((split (and (window-live-p window)
                     (agent-permission--split window)))
         (shown (if split
                    (progn (set-window-buffer split buffer) split)
                  (display-buffer buffer))))
    (when (window-live-p shown)
      (select-window shown))
    shown))

(defun agent-permission--close (buffer)
  "Remove BUFFER's window and kill it.
The window is deleted rather than restored from a saved configuration:
the split came from the conversation window, so removing it hands those
lines straight back."
  (when-let* ((window (get-buffer-window buffer)))
    (when (and (window-live-p window) (not (one-window-p t)))
      (ignore-errors (delete-window window))))
  (when (buffer-live-p buffer)
    (kill-buffer buffer)))

;;;; Rendering

(defun agent-permission--elide (text)
  "Return TEXT shortened to `agent-permission-input-max-length'.
Elided in the middle: the head says what the call is and the tail says
what it ends with, and the omission is stated rather than implied."
  (let ((max agent-permission-input-max-length))
    (if (<= (length text) max)
        text
      (let* ((keep (/ (- max 40) 2))
             (dropped (- (length text) (* 2 keep))))
        (concat (substring text 0 keep)
                (format "\n... [%d characters elided] ...\n" dropped)
                (substring text (- keep)))))))

(defun agent-permission--format-input (input)
  "Return INPUT rendered for a human deciding whether to allow it.
A shell command is shown as the command, because that is the thing being
judged; anything else is shown as its key/value pairs.  INPUT may be an
alist, a hash table, a string, or nil."
  (cond
   ((null input) "(no input)")
   ((stringp input) input)
   ((hash-table-p input)
    (let (alist)
      (maphash (lambda (k v) (push (cons (intern (format "%s" k)) v) alist)) input)
      (agent-permission--format-input (nreverse alist))))
   ((and (consp input) (alist-get 'command input))
    (let ((command (alist-get 'command input))
          (description (alist-get 'description input)))
      (if (and description (not (string-empty-p (format "%s" description))))
          (format "%s\n\n(%s)" command description)
        (format "%s" command))))
   ((consp input)
    (mapconcat (lambda (cell)
                 (format "%s: %s" (car cell) (cdr cell)))
               input "\n"))
   (t (format "%s" input))))

(defun agent-permission--render (entry)
  "Return the body text describing pending decision ENTRY."
  (let ((tool (or (plist-get entry :tool) "(unknown tool)"))
        (cwd (plist-get entry :cwd)))
    (concat
     (propertize (format "%s\n" tool) 'face 'bold)
     (when (and cwd (not (string-empty-p cwd)))
       (format "in %s\n" (abbreviate-file-name cwd)))
     "\n"
     (agent-permission--elide
      (agent-permission--format-input (plist-get entry :input)))
     "\n")))

;;;; Turning a decision into a durable rule

;; The rule syntax is Claude Code's, and its globs are looser than they
;; look.  Three behaviours, all measured rather than assumed:
;;
;;   Bash(echo hi)  matches `echo hi'                     -- exact
;;   Bash(echo)     does NOT match `echo hi'              -- a bare prefix
;;                                                           silently misses
;;   Bash(echo *)   matches `echo hi'                     -- as expected
;;   Bash(echo *)   ALSO matches `echo hi && rm -rf ...'  -- the `*' runs
;;                                                           past `&&' into
;;                                                           another command
;;
;; That last one is why the exact command is the default proposal.  "Allow
;; all echo commands" reads harmless and is not: it authorises `echo x &&
;; anything'.  The prefix form stays available, because it is what makes an
;; allowlist worth keeping, but the human has to choose it knowing that.

(defun agent-permission-rule-exact (tool input)
  "Return the rule matching exactly this TOOL call with INPUT.
The narrowest thing that helps: it allows the call that was just asked
about and nothing else."
  (let ((command (and (consp input) (alist-get 'command input))))
    (if command
        (format "%s(%s)" tool command)
      tool)))

(defun agent-permission-rule-prefix (tool input)
  "Return the rule matching TOOL calls sharing INPUT's first word.
Nil when there is no command to take a prefix of, so callers can fall
back to the exact rule rather than offering a broader one that does not
apply."
  (when-let* ((command (and (consp input) (alist-get 'command input)))
              (head (car (split-string (format "%s" command) nil t))))
    (format "%s(%s *)" tool head)))

(defun agent-permission--settings-path (cwd)
  "Return the settings file a rule for a call in CWD should be written to.
`.claude/settings.local.json' under the project root -- the file Claude
Code reads for per-project, per-machine rules, and the one a human would
have edited by hand."
  (let* ((dir (or cwd default-directory))
         (root (or (when (and (featurep 'project) (fboundp 'project-current))
                     (let ((default-directory (file-name-as-directory dir)))
                       (when-let* ((proj (project-current nil)))
                         (expand-file-name (project-root proj)))))
                   (file-name-as-directory (expand-file-name dir)))))
    (expand-file-name ".claude/settings.local.json" root)))

(defun agent-permission--read-settings (path)
  "Return the parsed settings alist at PATH, or nil when there is none.
A malformed file signals: silently starting from scratch would drop
every rule the human already has when this rewrites the file."
  (when (file-exists-p path)
    (with-temp-buffer
      (insert-file-contents path)
      (unless (zerop (buffer-size))
        (let ((json-object-type 'alist)
              ;; Vectors, so arrays this code does not touch are written
              ;; back as arrays rather than collapsing to `null'.
              (json-array-type 'vector)
              (json-key-type 'symbol))
          (json-read-from-string (buffer-string)))))))

(defun agent-permission-add-rule (rule path)
  "Add RULE to the permission allowlist in the settings file at PATH.
Preserves everything else in the file, and adds nothing when RULE is
already there.  Returns non-nil when the file was written.

This file is shared with the terminal CLI, so the write is deliberately
additive: the existing settings are read, one entry is appended to
`permissions.allow', and the rest is written back untouched."
  (let* ((settings (agent-permission--read-settings path))
         (permissions (alist-get 'permissions settings))
         (allow (append (alist-get 'allow permissions) nil)))
    (unless (member rule allow)
      (let* (;; A vector, not a list: an empty JSON array parses to nil,
             ;; and `json-encode' renders nil as `null'.  Writing
             ;; "deny": null back into a file the CLI also reads is how a
             ;; well-meaning rewrite corrupts someone else's settings.
             (allow* (vconcat allow (list rule)))
             (permissions* (cons (cons 'allow allow*)
                                 (assq-delete-all 'allow (copy-alist permissions))))
             (settings* (cons (cons 'permissions permissions*)
                              (assq-delete-all 'permissions (copy-alist settings)))))
        (make-directory (file-name-directory path) t)
        (with-temp-file path
          (insert (json-encode settings*) "\n"))
        t))))

;;;; Commands


(defun agent-permission--answer (decision reason)
  "Answer this buffer's decision with DECISION and REASON."
  (if-let* ((id agent-permission--id))
      (unless (agent-permission--resolve id decision reason)
        (message "That decision was already answered"))
    (user-error "No pending decision in this buffer")))

(defun agent-permission-allow ()
  "Allow the call this buffer is asking about, this once."
  (interactive)
  (agent-permission--answer 'allow "Allowed by the human in Emacs."))

(defun agent-permission-deny ()
  "Deny the call this buffer is asking about."
  (interactive)
  (agent-permission--answer
   'deny "Denied by the human in Emacs. Do not retry; ask before trying again."))

(defun agent-permission-always-allow ()
  "Allow this call and write a rule so the same call stops asking.
Offers the exact command first and the first-word prefix second, shows
the rule that would be written and the file it goes in, and writes
nothing unless the human confirms that exact text.

The confirmation is not ceremony: the settings file is shared with the
terminal CLI, so this changes what other sessions may do, and a prefix
rule's `*' reaches past `&&' into a second command."
  (interactive)
  (let* ((id (or agent-permission--id (user-error "No pending decision in this buffer")))
         (entry (cdr (assoc id agent-permission--pending)))
         (tool (plist-get entry :tool))
         (input (plist-get entry :input))
         (exact (agent-permission-rule-exact tool input))
         (prefix (agent-permission-rule-prefix tool input))
         (choices (delq nil (list exact (unless (equal prefix exact) prefix))))
         (rule (if (cdr choices)
                   (completing-read "Rule to add: " choices nil t (car choices))
                 (car choices)))
         (path (agent-permission--settings-path (plist-get entry :cwd))))
    (when (yes-or-no-p (format "Add %s to %s? " rule (abbreviate-file-name path)))
      (condition-case err
          (progn
            (agent-permission-add-rule rule path)
            (agent-permission--answer
             'allow
             (format "Allowed by the human in Emacs, and %s was added to the allowlist."
                     rule)))
        ;; The call was approved either way; only the durable part failed.
        ;; Allowing anyway is what the human just asked for.
        (error
         (message "Rule not written: %s" (error-message-string err))
         (agent-permission--answer
          'allow "Allowed by the human in Emacs (the allowlist could not be updated)."))))))

(defvar agent-permission-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'agent-permission-allow)
    (define-key map (kbd "y") #'agent-permission-allow)
    (define-key map (kbd "d") #'agent-permission-deny)
    (define-key map (kbd "n") #'agent-permission-deny)
    (define-key map (kbd "q") #'agent-permission-deny)
    (define-key map (kbd "A") #'agent-permission-always-allow)
    map)
  "Keymap for `agent-permission-mode'.
`q' denies rather than dismissing: there is no such thing as closing
this buffer without answering it, because something is blocked waiting.
`A' is capital on purpose: it writes to a settings file shared with the
terminal CLI, so it should not sit under the same finger as `a'.")

(define-derived-mode agent-permission-mode special-mode "Permission"
  "Major mode for answering one agent permission decision.
Derived from `special-mode', so the buffer is read-only and single keys
are commands -- a decision is a choice among a few options, not text to
compose."
  (setq buffer-read-only t)
  (setq-local cursor-type nil))

(declare-function evil-define-key* "evil-core")
(declare-function evil-set-initial-state "evil-core")

(with-eval-after-load 'evil
  ;; Normal state, and the same letters: this buffer is read-only, so
  ;; insert state would have nothing to offer.
  (evil-define-key* 'normal agent-permission-mode-map
                    (kbd "a") #'agent-permission-allow
                    (kbd "y") #'agent-permission-allow
                    (kbd "d") #'agent-permission-deny
                    (kbd "n") #'agent-permission-deny
                    (kbd "q") #'agent-permission-deny
                    (kbd "A") #'agent-permission-always-allow)
  (evil-set-initial-state 'agent-permission-mode 'normal))

;;;; Entry point

(defun agent-permission--buffer-name (id)
  "Return the decision buffer name for ID."
  (format "*agent-permission: %s*" (or id "?")))

(defun agent-permission--header ()
  "Return the header line describing the keys."
  (substitute-command-keys
   (concat "\\<agent-permission-mode-map>"
           "\\[agent-permission-allow] allow once  "
           "\\[agent-permission-deny] deny  "
           "\\[agent-permission-always-allow] always allow")))

(defun agent-permission-request (id tool input &rest options)
  "Raise a permission decision for TOOL with INPUT, identified by ID.
Show a buffer naming the call and wait for the human to answer it with
one key.  Return the decision buffer.

OPTIONS is a plist:

  `:resolve'  called with (DECISION REASON) once, from a timer, where
              DECISION is `allow', `deny' or `timeout'.  Required to be
              useful: without it the answer goes nowhere.
  `:cwd'      the directory the call would run in, shown for context.
  `:timeout'  seconds after which the decision denies itself as
              `timeout'.  Nil waits indefinitely, which is only
              appropriate when the caller has its own deadline.
  `:window'   the conversation window to split; defaults to the
              selected one.

Raising a decision for an ID that is already pending answers nothing and
signals: two callers waiting on one id could not both be told the
answer."
  (when (assoc id agent-permission--pending)
    (error "A decision for %s is already pending" id))
  (let* ((buffer (get-buffer-create (agent-permission--buffer-name id)))
         (entry (list :tool tool
                      :input input
                      :cwd (plist-get options :cwd)
                      :resolve (plist-get options :resolve)
                      :buffer buffer)))
    (push (cons id entry) agent-permission--pending)
    (with-current-buffer buffer
      (agent-permission-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (agent-permission--render entry)))
      (goto-char (point-min))
      (setq agent-permission--id id)
      (setq-local header-line-format (agent-permission--header)))
    (agent-permission--display buffer (or (plist-get options :window)
                                          (selected-window)))
    (when-let* ((seconds (plist-get options :timeout)))
      (run-at-time
       seconds nil
       (lambda ()
         (agent-permission--resolve
          id 'timeout
          (format "No answer within %ss; denied. The human may not have been at the keyboard."
                  seconds)))))
    buffer))

(provide 'agent-permission)
;;; agent-permission.el ends here
