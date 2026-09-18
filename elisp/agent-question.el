;;; agent-question.el --- Answer an agent's question from a menu -*- lexical-binding: t; -*-

;;; Commentary:

;; When an agent asks the human a question, the answer is usually one of a
;; few options the agent proposed -- but the human has had to read the
;; question.  This gives the question flow the same menu the permission
;; flow already has (`agent-permission.el'): a buffer that renders the
;; question, binds one key per proposed option, and resolves the pending
;; question when the human picks one, with a free-form escape for an
;; answer the agent did not anticipate.
;;
;; The design mirrors `agent-permission.el' on purpose -- same pending
;; registry (so a question is answered exactly once), same split-window
;; display, same timer-based resolve -- but general: it is not about
;; allow/deny decisions, so it carries none of the permission semantics.
;; It stays independent of any backend; opencode wraps it (see
;; `opencode-client.el'), and a backend that later emits question
;; requests can do the same.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

;; configurable
(defcustom agent-question-free-key "f"
  "Key that answers a question with free-form text.
One keystroke per proposed option is the menu's core; this key opens
the read-string escape hatch for an answer the agent did not propose.
Letters this equals are skipped when assigning option keys."
  :type 'string
  :group 'agent-question)

(defcustom agent-question-window-height 12
  "Number of lines tall a question answer-menu window splits to."
  :type 'integer
  :group 'agent-question)

(defcustom agent-question-split-height-threshold 20
  "Frame height below which the answer-menu window splits to the side."
  :type 'integer
  :group 'agent-question)

(defvar agent-question--pending nil
  "Alist of (ID . PLIST) for questions raised and not yet answered.
PLIST holds `:question', `:options', `:resolve' and `:buffer'.  The
registry is the single source of truth for \"is this still open\": a
resolved question is removed from it before its continuation runs, so a
second answer finds nothing and does nothing.")

(defvar-local agent-question--id nil
  "The pending question this buffer answers.")

;; The option keys assigned in this buffer, in order, matching
;; `agent-question--options'.  Buffer-local because which options exist
;; differs per pending question.
(defvar-local agent-question--keys nil)

(defvar-local agent-question--options nil
  "The proposed answer strings listed in this buffer, in order.")

;;;; The registry

(defun agent-question--take (id)
  "Remove and return the pending question for ID, or nil when gone.
Removal and lookup are one step so \"answered exactly once\" holds
without a separate flag.  Ids are strings, so this compares with
`equal' -- an `assq' here would never match."
  (when-let* ((entry (assoc id agent-question--pending)))
    (setq agent-question--pending
          (assoc-delete-all (car entry) agent-question--pending))
    (cdr entry)))

(defun agent-question-pending-ids ()
  "Return the ids of questions still waiting for an answer."
  (mapcar #'car agent-question--pending))

(defun agent-question--resolve (id answer)
  "Answer the pending question ID with ANSWER.
Does nothing when ID is no longer pending, so a race between the human
and a second answer resolves once.  Returns non-nil when this call was
the one that answered."
  (when-let* ((entry (agent-question--take id)))
    (let ((buffer (plist-get entry :buffer))
          (resolve (plist-get entry :resolve)))
      (when (buffer-live-p buffer)
        (agent-question--close buffer))
      ;; From a timer, not inline: the continuation posts to a process
      ;; and may rearrange windows, which blocks if still unwinding the
      ;; window the command was called from (same reasoning as
      ;; `agent-permission--resolve').
      (when resolve
        (run-at-time 0 nil resolve answer))
      t)))

;;;; Windows

(defun agent-question--split (window)
  "Split WINDOW for an answer-menu buffer and return the new window.
Nil when WINDOW cannot be split, so a cramped frame degrades to
`display-buffer' rather than signalling."
  (condition-case nil
      (if (< (window-body-height window) agent-question-split-height-threshold)
          (split-window window nil 'right)
        (split-window window (- (max 4 agent-question-window-height)) 'below))
    (error nil)))

(defun agent-question--display (buffer window)
  "Show BUFFER in a split of WINDOW, select it, and return the window."
  (let* ((split (and (window-live-p window)
                     (agent-question--split window)))
         (shown (if split
                    (progn (set-window-buffer split buffer) split)
                  (display-buffer buffer))))
    (when (window-live-p shown)
      (select-window shown))
    shown))

(defun agent-question--close (buffer)
  "Remove BUFFER's window and kill it.
The window is deleted rather than restored from a saved configuration:
the split came from the conversation window, so removing it hands those
lines straight back."
  (when-let* ((window (get-buffer-window buffer)))
    (when (and (window-live-p window) (not (one-window-p t)))
      (ignore-errors (delete-window window))))
  (when (buffer-live-p buffer)
    (kill-buffer buffer)))

;;;; Option keys

(defun agent-question--option-keys (n)
  "Return a list of N key strings for menu options.
`a'-`z' then `0'-`9', skipping `agent-question-free-key' so that key
always means free-form rather than an option.  Fewer than N when the
alphabet runs out -- the menu just offers that many options by key, the
rest only via the free-form escape."
  (let* ((free agent-question-free-key)
         (letters (cl-loop for c from ?a to ?z collect (char-to-string c)))
         (digits (cl-loop for c from ?0 to ?9 collect (char-to-string c)))
         (pool (append letters digits)))
    (cl-loop for k in pool
             when (not (equal k free))
             collect k into keys
             when (= (length keys) n)
             do (cl-return keys)
             finally (return keys))))

;;;; Rendering

(defun agent-question--render (entry)
  "Return the body text describing pending question ENTRY."
  (let ((question (or (plist-get entry :question) "(question)"))
        (options (plist-get entry :options)))
    (concat
     (propertize (format "%s\n" question) 'face 'bold)
     (when options
       (concat
        "\n"
        (mapconcat
         (lambda (pair)
           (format "[%s] %s" (car pair) (cdr pair)))
         (cl-mapcar #'cons
                    agent-question--keys
                    options)
         "\n")
        "\n"))
     "\n")))

;;;; Answering

(defun agent-question--buffer-name (id)
  "Return the question buffer name for ID."
  (format "*agent-question: %s*" (or id "?")))

(defun agent-question--header ()
  "Return the header line describing the keys."
  (substitute-command-keys
   (concat "\\<agent-question-mode-map>"
           "\\[agent-question-answer-option] choose option  "
           "\\[agent-question-answer-free] free-form answer")))

;;;###autoload
(defun agent-question-answer-option (key)
  "Answer this buffer's question with the option bound to KEY.
KEY is a key-description string like \"a\".  Interactive callers reach
it through the per-option bindings in `agent-question-mode-map', which
pass this-command-keys; tests and batch code call it directly with the
key string."
  (interactive (list (key-description (this-command-keys))))
  (if-let* ((id agent-question--id)
            (i (cl-position key agent-question--keys :test #'equal))
            (answer (nth i agent-question--options)))
      (unless (agent-question--resolve id answer)
        (message "That question was already answered"))
    (user-error "No answer menu option bound to %s" key)))

;;;###autoload
(defun agent-question-answer-free ()
  "Answer this buffer's question with free-form text.
The escape hatch for an answer the agent did not propose."
  (interactive)
  (if-let* ((id agent-question--id)
            (answer (read-string "Answer: ")))
      (unless (agent-question--resolve id answer)
        (message "That question was already answered"))
    (user-error "No pending question in this buffer")))

(defvar agent-question-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (k (agent-question--option-keys 100))
      (define-key map (kbd k) #'agent-question-answer-option))
    (define-key map (kbd agent-question-free-key) #'agent-question-answer-free)
    (define-key map (kbd "q") #'agent-question-answer-free)
    map)
  "Keymap for `agent-question-mode'.
Each proposed option is bound to its own key; `agent-question-free-key'
drops into a free-form read-string.  `q' quits by asking for a free-form
answer rather than dismissing, because something is waiting on the
reply.")

(define-derived-mode agent-question-mode special-mode "Question"
  "Major mode for answering one agent question from a menu.
Derived from `special-mode', so the buffer is read-only and single keys
are commands -- an answer is a choice among a few options, not text to
compose (free-form composes inside read-string)."
  (setq buffer-read-only t)
  (setq-local cursor-type nil))

(declare-function evil-define-key* "evil-core")
(declare-function evil-set-initial-state "evil-core")

(with-eval-after-load 'evil
  ;; Normal state, and the same bindings as non-evil: the buffer is
  ;; read-only, so insert state would have nothing to offer.
  (dolist (k (agent-question--option-keys 100))
    (evil-define-key* 'normal agent-question-mode-map
                      (kbd k) #'agent-question-answer-option))
  (evil-define-key* 'normal agent-question-mode-map
                    (kbd agent-question-free-key) #'agent-question-answer-free)
  (evil-set-initial-state 'agent-question-mode 'normal))

;;;; Entry point

;;;###autoload
(defun agent-question-request (id question options &rest opts)
  "Raise question ID with QUESTION text and proposed OPTIONS.
OPTIONS is a list of answer strings the agent proposed.  Show a menu
buffer listing them, one key each, and wait for the human to answer with
one key or the free-form escape.  Return the answer buffer.

OPTS is a plist:

  `:resolve'  called with the ANSWER string once, from a timer.  Without
              it the answer goes nowhere, so the caller must pass it.
  `:options'  alias for OPTIONS (kept for callers that already build a
              plist); when given, it wins.
  `:window'   the conversation window to split; defaults to the
              selected one.

Raising a question for an ID that is already pending answers nothing and
signals: two callers waiting on one id could not both be told the
answer."
  (when (assoc id agent-question--pending)
    (error "A question for %s is already pending" id))
  (setq options (or (plist-get opts :options) options))
  (let* ((keys (agent-question--option-keys (length options)))
         (buffer (get-buffer-create (agent-question--buffer-name id)))
         (entry (list :question question
                      :options options
                      :resolve (plist-get opts :resolve)
                      :buffer buffer)))
    (push (cons id entry) agent-question--pending)
    (with-current-buffer buffer
      (agent-question-mode)
      (setq agent-question--id id)
      (setq agent-question--keys keys)
      (setq agent-question--options options)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (agent-question--render entry)))
      (goto-char (point-min))
      (setq-local header-line-format (agent-question--header)))
    (agent-question--display buffer (or (plist-get opts :window)
                                        (selected-window)))
    buffer))

(provide 'agent-question)
;;; agent-question.el ends here