;;; agent-prompt.el --- Composition buffer for agent prompts -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.12.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Prompts used to be read with `read-string', which is the wrong surface
;; for the thing being typed: no multiline, no editing commands worth the
;; name, no pasting a code block, and a minibuffer that loses its place the
;; moment an `apply_diff' ediff rearranges the windows.
;;
;; `agent-prompt-read' replaces it with an ordinary buffer -- the
;; git-commit / org-capture shape.  Write the prompt, `C-c C-c' to send,
;; `C-c C-k' to abort.  Under evil, `ZZ' and `ZQ' do the same, and the
;; buffer opens in insert state.
;;
;; The buffer is backend-agnostic on purpose: it knows how to collect text
;; and nothing about Claude, opencode, or the remote bridge.  Callers pass
;; a continuation, so this composes with any backend behind
;; `agent-backend-send'.  That does mean commands that used to read a
;; string inline become asynchronous: their `interactive' spec drops the
;; `read-string' and the send moves into the callback.  The non-interactive
;; cores stay directly callable, so MCP tools and tests are unaffected.
;;
;; An active region in the buffer the prompt was invoked from seeds the
;; composition buffer, so quoting the code you are looking at is not a
;; copy-switch-paste round trip -- see `agent-prompt-region-seed'.
;;
;; Placement follows the conversation, not the frame: the prompt window is
;; a split of the agent's own output window, so several conversations can
;; each have their own prompt.  Split below by default; split right only
;; when the output window is too short to give up lines
;; (`agent-prompt-split-height-threshold').

;;; Code:

(require 'subr-x)

(defgroup agent-prompt nil
  "Composition buffer for agent prompts."
  :group 'tools
  :prefix "agent-prompt-")

(defcustom agent-prompt-split-height-threshold 20
  "Output-window height below which the prompt splits sideways.
The prompt is normally a `split-window-below' of the conversation
window, which reads as \"type underneath what you are talking about\".
That only works while there are lines to spare: under this many lines a
horizontal split leaves both halves useless, so split right instead."
  :type 'integer
  :group 'agent-prompt)

(defcustom agent-prompt-window-height 10
  "Lines given to the prompt window when splitting below."
  :type 'integer
  :group 'agent-prompt)

(defcustom agent-prompt-use-minibuffer nil
  "When non-nil, read prompts with `read-string' instead of a buffer.
The escape hatch for contexts where a window cannot be spared, and for
keyboard macros that predate the composition buffer."
  :type 'boolean
  :group 'agent-prompt)

(defcustom agent-prompt-major-mode nil
  "Major mode for the composition buffer, or nil to choose one.
Nil picks `markdown-mode' when it is available -- prompts are markdown
in practice, and code fences want its font-lock -- and `text-mode'
otherwise."
  :type '(choice (const :tag "Automatic" nil) function)
  :group 'agent-prompt)

(defcustom agent-prompt-history-limit 50
  "How many past prompts `M-p' can walk back through."
  :type 'integer
  :group 'agent-prompt)

(defvar agent-prompt-history nil
  "Previously sent prompts, most recent first.
Session-only: a prompt is a working note, not something worth carrying
across restarts, and prompts routinely contain pasted source.")

(defvar-local agent-prompt--callback nil
  "Function to receive this buffer's text when the prompt is sent.")

(defvar-local agent-prompt--history-index nil
  "Position in `agent-prompt-history' reached by history walking.
Nil while the buffer still holds text the human typed.")

(defvar-local agent-prompt--history-stash nil
  "Text displaced by history walking, restored on walking back past the end.")

;;;; Text

(defun agent-prompt--text ()
  "Return the buffer's prompt text with surrounding blank space removed."
  (string-trim (buffer-substring-no-properties (point-min) (point-max))))

(defun agent-prompt--remember (text)
  "Push TEXT onto `agent-prompt-history', most recent first."
  (setq agent-prompt-history
        (cons text (delete text agent-prompt-history)))
  (when (> (length agent-prompt-history) agent-prompt-history-limit)
    (setcdr (nthcdr (1- agent-prompt-history-limit) agent-prompt-history) nil)))

;;;; Region

;; The region is the strongest signal available about what a prompt is
;; about, and it was being dropped: `s' opened an empty buffer, so quoting
;; the lines in front of you meant copy, switch, paste (issue #78).
;;
;; What gets seeded depends on size, because the two useful shapes trade
;; off against each other.  A short selection goes in as a fenced block:
;; the text is right there in the prompt, visible while you write about
;; it.  A long one goes in as an `@path:start-end' pointer instead -- the
;; agent can read the file itself, the reference stays right if the lines
;; move on, and a 400-line paste would bury the prompt in its own window.

(defcustom agent-prompt-region-seed 'auto
  "What an active region contributes to the composition buffer.
`auto' fences a selection small enough to read in the prompt window and
falls back to a path reference for anything bigger -- see
`agent-prompt-region-fence-max-lines'.  `fenced' and `reference' force
one shape regardless of size.  Nil ignores the region, restoring the
behaviour from before the region was ever consulted."
  :type '(choice (const :tag "By size" auto)
                 (const :tag "Always the text, fenced" fenced)
                 (const :tag "Always a path reference" reference)
                 (const :tag "Ignore the region" nil))
  :group 'agent-prompt)

(defcustom agent-prompt-region-fence-max-lines 12
  "Longest region `auto' still seeds as a fenced block.
Sized to the prompt window (`agent-prompt-window-height'): a fence you
have to scroll to read is no longer serving the purpose of putting the
code in front of you."
  :type 'integer
  :group 'agent-prompt)

(defcustom agent-prompt-region-fence-max-chars 800
  "Longest region, in characters, that `auto' still seeds as a fence.
The line count is the measure that matters, but a handful of very long
lines -- minified source, a wide table -- is just as unreadable wrapped
into a ten-line window, and this catches it."
  :type 'integer
  :group 'agent-prompt)

(declare-function agent-backend-selection-reference "agent-backend" ())

(defun agent-prompt--region-bounds ()
  "Return the active region as (BEG END START-LINE END-LINE), or nil.
END-LINE excludes a trailing newline: a region ending at column 0 was
selected up to the end of the previous line, and reporting the line the
point happens to sit on would overstate it by one."
  (when (use-region-p)
    (let* ((beg (region-beginning))
           (end (region-end))
           (last (if (and (> end beg)
                          (save-excursion (goto-char end) (bolp)))
                     (1- end)
                   end)))
      (list beg end
            (line-number-at-pos beg)
            (line-number-at-pos last)))))

(defun agent-prompt--fence-language ()
  "Return a fence language tag for the current buffer's major mode, or nil.
Derived from the mode name rather than a table: `python-mode' and
`python-ts-mode' both want `python', and a mode this does not know about
gets a plain fence rather than a wrong tag."
  (when (symbolp major-mode)
    (let ((name (replace-regexp-in-string
                 "\\(-ts\\)?-mode\\'" "" (symbol-name major-mode))))
      (unless (member name '("fundamental" "text" "special"))
        name))))

(defun agent-prompt--region-label (start-line end-line)
  "Return a human-readable location for lines START-LINE to END-LINE.
The project-relative path when the buffer visits a file, its name when
it does not, so a fence is always attributable to something."
  (let* ((file (buffer-file-name))
         (where (if file
                    (if (and (featurep 'agent-backend)
                             (fboundp 'agent-backend--current-project-root))
                        (file-relative-name
                         file (agent-backend--current-project-root))
                      (file-name-nondirectory file))
                  (buffer-name))))
    (if (= start-line end-line)
        (format "%s:%d" where start-line)
      (format "%s:%d-%d" where start-line end-line))))

(defun agent-prompt--region-fence (beg end start-line end-line)
  "Return the text between BEG and END as a labelled fenced block.
START-LINE and END-LINE name where it came from, so the agent can find
the lines again instead of searching for the snippet."
  (format "%s\n```%s\n%s\n```"
          (agent-prompt--region-label start-line end-line)
          (or (agent-prompt--fence-language) "")
          (string-trim-right
           (buffer-substring-no-properties beg end))))

(defun agent-prompt--region-reference (start-line end-line)
  "Return an at-mention pointing at lines START-LINE to END-LINE.
Delegates to `agent-backend-selection-reference' when the shared core is
loaded, so the two spellings of \"the lines I am looking at\" cannot
drift.  Falls back to building the same shape here, since this file must
not require the backend layer."
  (if (and (featurep 'agent-backend)
           (fboundp 'agent-backend-selection-reference))
      (agent-backend-selection-reference)
    (format "@%s" (agent-prompt--region-label start-line end-line))))

(defun agent-prompt-region-seed (&optional buffer)
  "Return seed text for the active region in BUFFER, or nil when there is none.
BUFFER defaults to the current one.  The shape follows
`agent-prompt-region-seed': a fenced block for a selection small enough
to read in the prompt window, an `@path:lines' reference otherwise.

Called before the composition buffer takes a window, because selecting
another window is one of the things that can deactivate the region."
  (when agent-prompt-region-seed
    (with-current-buffer (or buffer (current-buffer))
      (when-let* ((bounds (agent-prompt--region-bounds)))
        (pcase-let ((`(,beg ,end ,start-line ,end-line) bounds))
          (if (pcase agent-prompt-region-seed
                ('fenced t)
                ('reference nil)
                (_ (and (<= (1+ (- end-line start-line))
                            agent-prompt-region-fence-max-lines)
                        (<= (- end beg) agent-prompt-region-fence-max-chars))))
              (agent-prompt--region-fence beg end start-line end-line)
            (agent-prompt--region-reference start-line end-line)))))))

;;;; Windows

(defun agent-prompt--split (window)
  "Split WINDOW for a prompt and return the new window.
Below when WINDOW is tall enough to spare the lines, right when it is
not.  Returns nil when WINDOW cannot be split at all, so a cramped frame
degrades to whatever `display-buffer' would have done rather than
signalling."
  (condition-case nil
      (if (< (window-body-height window) agent-prompt-split-height-threshold)
          (split-window window nil 'right)
        (split-window window (- (max 3 agent-prompt-window-height)) 'below))
    (error nil)))

(defun agent-prompt--display (buffer output-window)
  "Show BUFFER in a split of OUTPUT-WINDOW, select it, and return the window."
  (let* ((split (and (window-live-p output-window)
                     (agent-prompt--split output-window)))
         (window (if split
                     (progn (set-window-buffer split buffer) split)
                   (display-buffer buffer))))
    (when (window-live-p window)
      (select-window window))
    window))

(defun agent-prompt--close ()
  "Bury the current prompt buffer and remove its window.
The window is deleted rather than restored from a saved configuration:
the split was taken from the conversation window, so removing it hands
those lines straight back to the conversation.  A saved configuration
would also be stale by now if an ediff ran in between."
  (let ((buffer (current-buffer))
        (window (selected-window)))
    (when (and (window-live-p window)
               (eq (window-buffer window) buffer)
               (not (one-window-p t)))
      (delete-window window))
    (kill-buffer buffer)))

;;;; Commands

(defun agent-prompt-send ()
  "Send this buffer's text to whoever asked for the prompt.
Refuses an empty prompt -- sending one would start a turn that says
nothing -- and closes the buffer before invoking the callback so the
callback sees the window layout it will actually run in.  The callback
runs from a timer rather than inline: it typically spawns a process and
displays buffers, and doing that while this command is still unwinding
the window it was invoked from is how conversation windows get lost."
  (interactive)
  (let ((text (agent-prompt--text))
        (callback agent-prompt--callback))
    (when (string-empty-p text)
      (user-error "Empty prompt; `C-c C-k' to abort"))
    (agent-prompt--remember text)
    (agent-prompt--close)
    (when callback
      (run-at-time 0 nil callback text))))

(defun agent-prompt-abort ()
  "Discard this prompt and close the buffer without sending."
  (interactive)
  (agent-prompt--close)
  (message "Prompt aborted"))

(defun agent-prompt--replace (text)
  "Make TEXT the buffer's whole contents and put point after it."
  (erase-buffer)
  (insert text)
  (goto-char (point-max)))

(defun agent-prompt-history-prev ()
  "Replace the buffer with the previous prompt from `agent-prompt-history'."
  (interactive)
  (unless agent-prompt-history
    (user-error "No prompt history"))
  (let ((index (if agent-prompt--history-index
                   (1+ agent-prompt--history-index)
                 0)))
    (when (>= index (length agent-prompt-history))
      (user-error "Beginning of prompt history"))
    (unless agent-prompt--history-index
      (setq agent-prompt--history-stash (agent-prompt--text)))
    (setq agent-prompt--history-index index)
    (agent-prompt--replace (nth index agent-prompt-history))))

(defun agent-prompt-history-next ()
  "Replace the buffer with the next prompt from `agent-prompt-history'.
Walking past the newest entry restores the text that was displaced."
  (interactive)
  (unless agent-prompt--history-index
    (user-error "End of prompt history"))
  (let ((index (1- agent-prompt--history-index)))
    (if (< index 0)
        (progn
          (setq agent-prompt--history-index nil)
          (agent-prompt--replace (or agent-prompt--history-stash "")))
      (setq agent-prompt--history-index index)
      (agent-prompt--replace (nth index agent-prompt-history)))))

;;;; Mode

(defvar agent-prompt-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'agent-prompt-send)
    (define-key map (kbd "C-c C-k") #'agent-prompt-abort)
    (define-key map (kbd "M-p") #'agent-prompt-history-prev)
    (define-key map (kbd "M-n") #'agent-prompt-history-next)
    map)
  "Keymap for `agent-prompt-mode'.")

(defun agent-prompt--base-mode ()
  "Return the major mode the composition buffer should use."
  (or agent-prompt-major-mode
      (if (fboundp 'markdown-mode) 'markdown-mode 'text-mode)))

(define-minor-mode agent-prompt-mode
  "Minor mode for a buffer whose text becomes an agent prompt.
A minor mode rather than a derived major mode so the buffer keeps
whatever editing mode suits the text -- markdown, usually -- and only
gains the send and abort bindings."
  :lighter " Prompt"
  :keymap agent-prompt-mode-map)

(declare-function evil-define-key* "evil-core")
(declare-function evil-set-initial-state "evil-core")

(with-eval-after-load 'evil
  ;; `ZZ' and `ZQ' are what vim hands already do to finish an editor
  ;; buffer, so they mean the same here as in `git-commit'.  Ex commands
  ;; are deliberately not defined: `:w' on a buffer with no file is a
  ;; confusing thing to redefine, and the normal-state pair covers it.
  (evil-define-key* 'normal agent-prompt-mode-map
                    (kbd "ZZ") #'agent-prompt-send
                    (kbd "ZQ") #'agent-prompt-abort)
  ;; The buffer exists because someone is about to type into it.
  (evil-set-initial-state 'agent-prompt-mode 'insert))

;;;; Entry point

(defun agent-prompt--buffer-name (label)
  "Return the composition buffer name for LABEL."
  (if label (format "*agent-prompt: %s*" label) "*agent-prompt*"))

(defun agent-prompt--header (label)
  "Return the header line describing the keys, prefixed by LABEL."
  (substitute-command-keys
   (concat (if label (format "%s   " label) "")
           "\\<agent-prompt-mode-map>\\[agent-prompt-send] send  "
           "\\[agent-prompt-abort] abort  "
           "\\[agent-prompt-history-prev]/\\[agent-prompt-history-next] history")))

(defun agent-prompt-read (callback &optional initial label output-window source)
  "Collect a prompt in a buffer and pass it to CALLBACK.
CALLBACK receives the text as its only argument, from a timer once the
composition buffer is gone, so it is free to spawn processes and
rearrange windows.  It is not called at all when the human aborts.

INITIAL seeds the buffer.  LABEL names it, so concurrent conversations
get distinguishable prompt buffers.  OUTPUT-WINDOW is the conversation
window to split, defaulting to the selected one.

SOURCE is the buffer the command was invoked from; an active region
there seeds the prompt (see `agent-prompt-region-seed') when INITIAL
does not.  Point lands after the seed and a blank line, so typing starts
on the prompt rather than inside the quote.

With `agent-prompt-use-minibuffer' this falls back to `read-string' and
calls CALLBACK synchronously; callers must not rely on either timing."
  (let* ((seed (and (not initial) source (agent-prompt-region-seed source)))
         ;; The seed is context, not the prompt: the human still has to say
         ;; what to do with it, and a minibuffer cannot show a fenced block
         ;; anyway, so the escape hatch stays a bare `read-string'.
         (initial (or initial (and (not agent-prompt-use-minibuffer) seed))))
    (if agent-prompt-use-minibuffer
        (let ((text (string-trim (read-string "Prompt: " initial))))
          (if (string-empty-p text)
              (user-error "Empty prompt")
            (agent-prompt--remember text)
            (funcall callback text)))
      (let ((buffer (get-buffer-create (agent-prompt--buffer-name label)))
            (window (or output-window (selected-window))))
        (with-current-buffer buffer
          (erase-buffer)
          (funcall (agent-prompt--base-mode))
          (agent-prompt-mode 1)
          (when initial
            (insert initial)
            ;; A seed the human did not type needs somewhere to type after
            ;; it; text a caller supplied as INITIAL is the draft itself.
            (when (eq initial seed) (insert "\n\n")))
          (goto-char (point-max))
          (setq agent-prompt--callback callback
                agent-prompt--history-index nil
                agent-prompt--history-stash nil)
          (setq-local header-line-format (agent-prompt--header label))
          ;; A prompt is not a file, and evil's `:w' would otherwise look for
          ;; one; keep the buffer unmistakably scratch.
          (setq buffer-file-name nil))
        (agent-prompt--display buffer window)
        buffer))))

(provide 'agent-prompt)
;;; agent-prompt.el ends here
