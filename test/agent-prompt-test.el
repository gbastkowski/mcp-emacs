;;; agent-prompt-test.el --- Suite for the prompt composition buffer -*- lexical-binding: t; -*-

;; The composition buffer replaced `read-string' for prompts, so what needs
;; pinning is the part a minibuffer never had: that the text survives
;; multiline intact, that the callback runs on send and never on abort, and
;; that the window it takes is a split of the conversation's own window --
;; given back when the prompt closes.

;;; Code:

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'agent-prompt)

(defun agent-prompt-test--drain ()
  "Run the timers `agent-prompt-send' defers its callback to.
Batch Emacs does not run timers from `sit-for', so the queue is drained
by hand -- the callback is deliberately deferred (see
`agent-prompt-send'), and a test that skipped the timer would be
checking a code path the human never takes."
  (dolist (timer (append timer-list timer-idle-list))
    (timer-event-handler timer)))

(defmacro agent-prompt-test--with-window (&rest body)
  "Run BODY with a single window over a scratch conversation buffer.
Batch Emacs has one frame with one window; that is enough to check which
direction a split takes and whether the lines come back."
  (declare (indent 0))
  `(let ((conversation (get-buffer-create "*agent-prompt-test-conversation*"))
         (agent-prompt-history nil))
     (unwind-protect
         (progn
           (delete-other-windows)
           (set-window-buffer (selected-window) conversation)
           ,@body)
       (let ((kill-buffer-query-functions nil))
         (dolist (b (buffer-list))
           (when (string-prefix-p "*agent-prompt" (buffer-name b))
             (kill-buffer b)))
         (when (buffer-live-p conversation) (kill-buffer conversation))))))

;;;; Collecting the text

(describe "agent-prompt-read on send"
  (agent-prompt-test--with-window
    (let* ((got :unset)
           (buffer (agent-prompt-read (lambda (text) (setq got text))
                                      nil "conv" (selected-window))))
      (it "names the buffer after the conversation it belongs to"
        (check (buffer-name buffer) "*agent-prompt: conv*"))
      (it "turns on the minor mode that carries the send binding"
        (check-that (buffer-local-value 'agent-prompt-mode buffer)))
      (with-current-buffer buffer
        (insert "first line\n\nthird line")
        (agent-prompt-send))
      (agent-prompt-test--drain)
      (it "hands the callback the text with its line structure intact"
        (check got "first line\n\nthird line"))
      (it "kills the composition buffer, so a stale draft cannot be resent"
        (check-that (not (buffer-live-p buffer))))
      (it "records what was sent in the history"
        (check agent-prompt-history '("first line\n\nthird line"))))))

(describe "agent-prompt-read text handling"
  (agent-prompt-test--with-window
    (let* ((got :unset)
           (buffer (agent-prompt-read (lambda (text) (setq got text))
                                      nil "conv" (selected-window))))
      (with-current-buffer buffer
        (insert "\n\n  padded  \n\n")
        (agent-prompt-send))
      (agent-prompt-test--drain)
      (it "trims the blank space around the prompt rather than sending it"
        (check got "padded"))))
  (agent-prompt-test--with-window
    (let ((buffer (agent-prompt-read #'ignore "seeded text" "conv"
                                     (selected-window))))
      (it "seeds the buffer with the initial text a caller supplied"
        (check (with-current-buffer buffer (agent-prompt--text)) "seeded text"))
      (it "leaves point after the seed, ready to keep typing"
        (check (with-current-buffer buffer (point)) (with-current-buffer buffer (point-max))))
      (with-current-buffer buffer (agent-prompt-abort)))))

(describe "agent-prompt-send with nothing written"
  (agent-prompt-test--with-window
    (let* ((fired nil)
           (buffer (agent-prompt-read (lambda (_) (setq fired t))
                                      nil "conv" (selected-window))))
      (it "refuses rather than starting a turn that says nothing"
        (check (with-current-buffer buffer
                 (condition-case _ (progn (agent-prompt-send) nil)
                   (user-error t)))
               t))
      (agent-prompt-test--drain)
      (it "does not call the callback"
        (check fired nil))
      (it "leaves the buffer open so the prompt can still be written"
        (check-that (buffer-live-p buffer)))
      (with-current-buffer buffer (agent-prompt-abort)))))

;;;; Aborting

(describe "agent-prompt-abort"
  (agent-prompt-test--with-window
    (let* ((fired nil)
           (buffer (agent-prompt-read (lambda (_) (setq fired t))
                                      nil "conv" (selected-window))))
      (with-current-buffer buffer
        (insert "never sent")
        (agent-prompt-abort))
      (agent-prompt-test--drain)
      (it "never calls the callback, so nothing reaches the model"
        (check fired nil))
      (it "kills the composition buffer"
        (check-that (not (buffer-live-p buffer))))
      (it "keeps the discarded draft out of the history"
        (check agent-prompt-history nil)))))

;;;; Windows

(describe "agent-prompt--split direction"
  (agent-prompt-test--with-window
    (let* ((window (selected-window))
           (agent-prompt-split-height-threshold 1)
           (new (agent-prompt--split window)))
      (it "splits below when the conversation window can spare the lines"
        (check-that (and (= (window-left-column new) (window-left-column window))
                         (> (window-top-line new) (window-top-line window)))))
      (it "gives the prompt the smaller share, leaving the conversation readable"
        ;; `split-window' counts the mode line in the size it is given, so
        ;; the body is one row short of the configured height.
        (check (window-body-height new) (1- agent-prompt-window-height)))
      (delete-window new)))
  (agent-prompt-test--with-window
    (let* ((window (selected-window))
           (agent-prompt-split-height-threshold 1000)
           (new (agent-prompt--split window)))
      (it "splits sideways when the window is too short to divide horizontally"
        (check-that (> (window-left-column new) (window-left-column window))))
      (delete-window new))))

(describe "the prompt window's lifetime"
  (agent-prompt-test--with-window
    (let ((before (length (window-list)))
          (buffer nil))
      (setq buffer (agent-prompt-read #'ignore nil "conv" (selected-window)))
      (it "takes a window of its own from the conversation's"
        (check (length (window-list)) (1+ before)))
      (it "selects it, since it exists to be typed into"
        (check (window-buffer (selected-window)) buffer))
      (with-current-buffer buffer (insert "x") (agent-prompt-send))
      (agent-prompt-test--drain)
      (it "hands the lines back to the conversation when the prompt closes"
        (check (length (window-list)) before)))))

;;;; History

(describe "walking back through agent-prompt-history"
  (agent-prompt-test--with-window
    (let ((agent-prompt-history '("newest" "middle" "oldest"))
          (buffer nil))
      (setq buffer (agent-prompt-read #'ignore nil "conv" (selected-window)))
      (with-current-buffer buffer
        (insert "draft")
        (agent-prompt-history-prev)
        (it "reaches the most recent prompt first"
          (check (agent-prompt--text) "newest"))
        (agent-prompt-history-prev)
        (agent-prompt-history-prev)
        (it "keeps walking back in order"
          (check (agent-prompt--text) "oldest"))
        (it "stops at the oldest rather than wrapping round"
          (check (condition-case _ (progn (agent-prompt-history-prev) nil)
                   (user-error t))
                 t))
        (agent-prompt-history-next)
        (it "walks forward again"
          (check (agent-prompt--text) "middle"))
        (agent-prompt-history-next)
        (agent-prompt-history-next)
        (it "restores the draft the history walk displaced"
          (check (agent-prompt--text) "draft"))
        (it "stops once the draft is back"
          (check (condition-case _ (progn (agent-prompt-history-next) nil)
                   (user-error t))
                 t))
        (agent-prompt-abort)))))

(describe "agent-prompt-history-prev with no history"
  (agent-prompt-test--with-window
    (let ((buffer (agent-prompt-read #'ignore nil "conv" (selected-window))))
      (it "says so rather than emptying the buffer"
        (check (with-current-buffer buffer
                 (condition-case _ (progn (agent-prompt-history-prev) nil)
                   (user-error t)))
               t))
      (with-current-buffer buffer (agent-prompt-abort)))))

(describe "agent-prompt--remember"
  (let ((agent-prompt-history nil)
        (agent-prompt-history-limit 3))
    (agent-prompt--remember "a")
    (agent-prompt--remember "b")
    (it "keeps the most recent prompt at the front"
      (check agent-prompt-history '("b" "a")))
    (agent-prompt--remember "a")
    (it "moves a repeated prompt to the front instead of duplicating it"
      (check agent-prompt-history '("a" "b")))
    (agent-prompt--remember "c")
    (agent-prompt--remember "d")
    (it "drops the oldest past the limit, so history cannot grow without bound"
      (check agent-prompt-history '("d" "c" "a")))))

;;;; The minibuffer escape hatch

(describe "agent-prompt-use-minibuffer"
  (let ((agent-prompt-history nil)
        (agent-prompt-use-minibuffer t)
        (got :unset))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "  typed  ")))
      (agent-prompt-read (lambda (text) (setq got text))))
    (it "reads from the minibuffer instead of opening a buffer"
      (check got "typed"))
    (it "calls the callback synchronously, without waiting for a timer"
      (check-that (not (equal got :unset))))
    (it "still records what was sent"
      (check agent-prompt-history '("typed")))
    (it "opens no composition buffer"
      (check (get-buffer "*agent-prompt*") nil)))
  (let ((agent-prompt-use-minibuffer t))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "   ")))
      (it "refuses a whitespace-only prompt the same way the buffer does"
        (check (condition-case _ (progn (agent-prompt-read #'ignore) nil)
                 (user-error t))
               t)))))

;;;; Keys

(describe "agent-prompt-mode-map"
  (it "binds C-c C-c to send, the git-commit spelling"
    (check (lookup-key agent-prompt-mode-map (kbd "C-c C-c")) 'agent-prompt-send))
  (it "binds C-c C-k to abort"
    (check (lookup-key agent-prompt-mode-map (kbd "C-c C-k")) 'agent-prompt-abort))
  (it "binds M-p to the previous prompt"
    (check (lookup-key agent-prompt-mode-map (kbd "M-p")) 'agent-prompt-history-prev))
  (it "binds M-n to the next prompt"
    (check (lookup-key agent-prompt-mode-map (kbd "M-n")) 'agent-prompt-history-next)))

(test-helper-summary)

;;; agent-prompt-test.el ends here
