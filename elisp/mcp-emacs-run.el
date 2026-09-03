;;; mcp-emacs-run.el --- Run the Claude Code CLI inside Emacs -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.8.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A terminal runner for the Claude Code CLI, hosted inside Emacs.  The
;; CLI is a full-screen ANSI TUI, so it runs in an eat terminal buffer
;; (eat is a soft dependency, loaded only when present).  The runner is
;; project-aware, keeps one primary session per project, shows its
;; terminal in an ordinary directional window, and supports
;; continue/resume.  Editor-tool integration is provided to the CLI
;; through the mcp-emacs MCP server (via the user's MCP configuration),
;; not by this runner.
;;
;; This file is separate from the MCP server so the server stays pure.

;;; Code:

(require 'project nil t)
(require 'eat nil t)
(require 'markdown-mode nil t)

(declare-function eat-make "eat" (name program &optional startfile &rest switches))
(declare-function eat-term-send-string "eat" (terminal string))
(declare-function project-current "project" (&optional maybe-prompt directory))
(declare-function project-root "project" (project))
(declare-function gfm-view-mode "markdown-mode" ())

(defvar eat-terminal)
(defvar markdown-fontify-code-blocks-natively)

;;;; Customization

(defgroup mcp-emacs-run nil
  "Run the Claude Code CLI inside Emacs."
  :group 'tools
  :prefix "mcp-emacs-run-")

(defcustom mcp-emacs-run-executable "claude"
  "Path to the Claude Code CLI executable."
  :type 'string
  :group 'mcp-emacs-run)

(defcustom mcp-emacs-run-flags nil
  "Extra command-line flags passed to the Claude Code CLI."
  :type '(repeat string)
  :group 'mcp-emacs-run)

(defcustom mcp-emacs-run-ide-integration nil
  "When non-nil, connect launched Claude Code sessions to the Emacs IDE.
Starts the `mcp-emacs-ide' WebSocket server (if not already running) and
launches Claude Code with `CLAUDE_CODE_SSE_PORT' and
`ENABLE_IDE_INTEGRATION' set, so its native Edit/Write operations are
reviewed via ediff in Emacs.  Requires `mcp-emacs-ide-enabled' and the
`websocket' package.  IDE integration only works for interactive
sessions launched by this runner; a Claude Code started by hand will not
connect."
  :type 'boolean
  :group 'mcp-emacs-run)

(declare-function mcp-emacs-ide-start "mcp-emacs-ide" ())
(declare-function mcp-emacs-ide-port "mcp-emacs-ide" ())

(defcustom mcp-emacs-run-focus-on-show t
  "When non-nil, showing the runner window also selects it."
  :type 'boolean
  :group 'mcp-emacs-run)

(defcustom mcp-emacs-run-window-direction 'right
  "Direction in which the runner window is placed.
The runner uses an ordinary window in this direction, so it can be split,
navigated, and closed like any other window.  The window is weakly
dedicated to its buffer (see `set-window-dedicated-p'), so it prefers to
keep showing the runner but `display-buffer' may still reuse it when no
other window is available."
  :type '(choice (const right) (const left) (const above) (const below))
  :group 'mcp-emacs-run)

(defcustom mcp-emacs-run-window-width 0.4
  "Fallback width hint for the runner window, as a fraction of the frame.
Used when `mcp-emacs-run-window-direction' is `left' or `right' and
`mcp-emacs-run-window-width-columns' is nil."
  :type 'number
  :group 'mcp-emacs-run)

(defcustom mcp-emacs-run-window-width-columns 120
  "Desired width of the runner window in columns.
Used when `mcp-emacs-run-window-direction' is `left' or `right'.  The
resolved width is clamped to `mcp-emacs-run-window-max-width-fraction' of
the frame width.  When nil, fall back to `mcp-emacs-run-window-width'."
  :type '(choice (const :tag "Use fraction fallback" nil) integer)
  :group 'mcp-emacs-run)

(defcustom mcp-emacs-run-window-max-width-fraction 0.5
  "Maximum runner window width, as a fraction of the frame width.
Caps `mcp-emacs-run-window-width-columns' so the code pane is not crushed
on narrow frames."
  :type 'number
  :group 'mcp-emacs-run)

(defcustom mcp-emacs-run-window-height 0.4
  "Height hint for the runner window, as a fraction of the frame.
Used when `mcp-emacs-run-window-direction' is `above' or `below'."
  :type 'number
  :group 'mcp-emacs-run)

(defcustom mcp-emacs-run-popup-direction 'below
  "Direction in which the popup output window is placed.
Like the runner window, the popup uses an ordinary (non-dedicated)
window in this direction so it can be split, scrolled, and closed like
any other window."
  :type '(choice (const right) (const left) (const above) (const below))
  :group 'mcp-emacs-run)

(defcustom mcp-emacs-run-popup-size 0.4
  "Size hint for the popup output window, as a fraction of the frame.
Interpreted as a width when `mcp-emacs-run-popup-direction' is `left' or
`right', otherwise as a height."
  :type 'number
  :group 'mcp-emacs-run)

(defcustom mcp-emacs-run-quit-timeout 10
  "Seconds to wait for the CLI to exit after a graceful quit.
`mcp-emacs-run-quit' sends the quit sequence and, if the session process
is still live after this many seconds, force-kills it and removes the
buffer."
  :type 'number
  :group 'mcp-emacs-run)

;;;; Helpers

;; TODO isn't this already covered by require further up?
(defun mcp-emacs-run--ensure-eat ()
  "Signal a clear error unless eat is available."
  (unless (featurep 'eat)
    (user-error "mcp-emacs-run requires the `eat' package; please install it")))

;; TODO maybe replace when-let with if-let as when-let looks almost deprecated?
(defun mcp-emacs-run--project-root ()
  "Return the current project root, or the buffer's directory as a fallback."
  (or (when (and (featurep 'project) (fboundp 'project-current))
        (when-let ((proj (project-current nil)))
          (expand-file-name (project-root proj))))
      (expand-file-name default-directory)))

(defun mcp-emacs-run--project-name (root)
  "Return a short name for the project at ROOT."
  (file-name-nondirectory (directory-file-name root)))

(defconst mcp-emacs-run--buffer-name-regexp
  "\\`\\*claude:\\(.+\\):\\([0-9]+\\)\\*\\'"
  "Regexp matching a runner buffer name `*claude:<project>:<n>*'.
Group 1 is the project name, group 2 the per-project number.")

(defun mcp-emacs-run--buffer-name (root n)
  "Return the runner buffer name for project ROOT and session number N."
  (format "*claude:%s:%d*" (mcp-emacs-run--project-name root) n))

(defun mcp-emacs-run--sessions-list ()
  "Return the list of live runner buffers, newest buffers last.
A runner buffer is any live buffer whose name matches
`mcp-emacs-run--buffer-name-regexp'."
  (seq-filter (lambda (buf)
                (string-match-p mcp-emacs-run--buffer-name-regexp
                                (buffer-name buf)))
              (buffer-list)))

(defun mcp-emacs-run--buffer-project (buf)
  "Return the project root that runner buffer BUF belongs to.
Derived from BUF's own `default-directory' via `mcp-emacs-run--project-root',
so it survives without any registry."
  (with-current-buffer buf
    (mcp-emacs-run--project-root)))

(defun mcp-emacs-run--project-sessions (root)
  "Return the live runner buffers whose project is ROOT."
  (let ((root (expand-file-name root)))
    (seq-filter (lambda (buf)
                  (string= (mcp-emacs-run--buffer-project buf) root))
                (mcp-emacs-run--sessions-list))))

(defun mcp-emacs-run--next-number (root)
  "Return the lowest positive session number not in use for project ROOT.
Killed middle slots are refilled, so numbers stay compact."
  (let ((used (delq nil
                    (mapcar (lambda (buf)
                              (when (string-match mcp-emacs-run--buffer-name-regexp
                                                  (buffer-name buf))
                                (string-to-number (match-string 2 (buffer-name buf)))))
                            (mcp-emacs-run--project-sessions root))))
        (n 1))
    (while (memq n used) (setq n (1+ n)))
    n))

(defun mcp-emacs-run--session-label (buf)
  "Return a `completing-read' label for runner buffer BUF.
Use `*claude:<project>:<n>*' minus the surrounding stars; unambiguous
because the buffer name already carries project and number."
  (let ((name (buffer-name buf)))
    (if (string-match mcp-emacs-run--buffer-name-regexp name)
        (format "%s:%s" (match-string 1 name) (match-string 2 name))
      name)))

(defun mcp-emacs-run--pick-session (candidates &optional prompt)
  "Return one buffer from CANDIDATES.
When CANDIDATES has a single element, return it without prompting.
Otherwise `completing-read' with PROMPT (default \"Runner session: \")."
  (cond
   ((null candidates) nil)
   ((null (cdr candidates)) (car candidates))
   (t (let* ((alist (mapcar (lambda (b) (cons (mcp-emacs-run--session-label b) b))
                            candidates))
             (pick (completing-read (or prompt "Runner session: ") alist nil t)))
        (cdr (assoc pick alist))))))

(defun mcp-emacs-run--resolve-session ()
  "Resolve the runner session to receive input, or signal a `user-error'.
Candidates are ranked into tiers and the first non-empty tier wins:
  1. same project as the current buffer, and visible in a window
  2. same project, hidden
  3. any project, visible
  4. any project, hidden
Visible windows are preferred over hidden.  When the winning tier has more
than one candidate, prompt with `mcp-emacs-run--pick-session'."
  (let* ((all (mcp-emacs-run--sessions-list)))
    (unless all
      (user-error "No live Claude runner session"))
    (let* ((root (mcp-emacs-run--project-root))
           (visible (lambda (buf) (get-buffer-window buf t)))
           (same (seq-filter (lambda (b) (string= (mcp-emacs-run--buffer-project b) root))
                             all))
           (tiers (list (seq-filter visible same)
                        (seq-remove visible same)
                        (seq-filter visible all)
                        (seq-remove visible all)))
           (tier (seq-find #'identity tiers)))
      (mcp-emacs-run--pick-session tier))))

(defun mcp-emacs-run--resolved-width ()
  "Return the runner window width in columns for a horizontal split.
Prefer `mcp-emacs-run-window-width-columns'; otherwise derive columns from
the `mcp-emacs-run-window-width' fraction.  The result is clamped to
`mcp-emacs-run-window-max-width-fraction' of the current frame width."
  (let ((cap (truncate (* mcp-emacs-run-window-max-width-fraction
                          (frame-width))))
        (cols (or mcp-emacs-run-window-width-columns
                  (truncate (* mcp-emacs-run-window-width (frame-width))))))
    (min cols cap)))

(defun mcp-emacs-run--display (buffer)
  "Display BUFFER in an ordinary window, honouring the focus preference.
The window is placed in `mcp-emacs-run-window-direction' via
`display-buffer-in-direction', so it stays splittable and closable rather
than a dedicated side window.  For a horizontal split the width is
`mcp-emacs-run--resolved-width' columns.  The window is weakly dedicated
to BUFFER so it prefers to keep showing the runner."
  (let* ((horizontal (memq mcp-emacs-run-window-direction '(left right)))
         (size (if horizontal
                   `(window-width . ,(mcp-emacs-run--resolved-width))
                 `(window-height . ,mcp-emacs-run-window-height)))
         (window
          (display-buffer
           buffer
           `((display-buffer-in-direction)
             (direction . ,mcp-emacs-run-window-direction)
             ,size))))
    (when window
      (set-window-dedicated-p window t))
    (when (and window mcp-emacs-run-focus-on-show)
      (select-window window))
    window))

(defun mcp-emacs-run--launch (root no-display &rest extra-switches)
  "Launch the CLI for project ROOT in a fresh numbered eat buffer.
Allocates the next per-project session number via
`mcp-emacs-run--next-number'.  Unless NO-DISPLAY is non-nil, the buffer is
shown in the runner window.  EXTRA-SWITCHES are appended to the configured
flags (e.g. continue/resume)."
  (mcp-emacs-run--ensure-eat)
  (let* ((default-directory (file-name-as-directory root))
         (n (mcp-emacs-run--next-number root))
         (name (substring (mcp-emacs-run--buffer-name root n) 1 -1)) ; eat-make wraps in *...*
         (switches (append mcp-emacs-run-flags extra-switches))
         ;; When IDE integration is on, start the IDE server and pass its
         ;; port to the CLI via the environment (verified handshake; see
         ;; mcp-emacs-ide).  `eat' inherits `process-environment', so bind
         ;; it around the launch.
         (ide-port (mcp-emacs-run--ide-port))
         (process-environment
          (if ide-port
              (append (list (format "CLAUDE_CODE_SSE_PORT=%d" ide-port)
                            "ENABLE_IDE_INTEGRATION=true"
                            "TERM_PROGRAM=emacs")
                      process-environment)
            process-environment))
         (buffer (apply #'eat-make name mcp-emacs-run-executable nil switches)))
    (unless no-display
      (mcp-emacs-run--display buffer))
    buffer))

(defun mcp-emacs-run--ide-port ()
  "Return the IDE WebSocket port to hand to Claude Code, or nil.
When `mcp-emacs-run-ide-integration' is enabled, ensure the
`mcp-emacs-ide' server is running and return its port.  Any failure
\(package missing, surface disabled) degrades gracefully to nil so a
session still launches without IDE integration."
  (when mcp-emacs-run-ide-integration
    (condition-case err
        (when (require 'mcp-emacs-ide nil t)
          (or (mcp-emacs-ide-port) (mcp-emacs-ide-start)))
      (error
       (message "mcp-emacs-run: IDE integration unavailable: %s"
                (error-message-string err))
       nil))))

(defun mcp-emacs-run--send-to-buffer (buf string)
  "Send STRING to runner buffer BUF's terminal.
Signal a `user-error' when BUF is not a live eat terminal.
`eat-term-send-string' resolves the input process from the current
buffer's eat state, not from its TERM argument, so this must run with
BUF current or it silently sends nothing when invoked from another
buffer (e.g. via \\[execute-extended-command] from a file buffer)."
  (with-current-buffer buf
    (let ((term (buffer-local-value 'eat-terminal buf)))
      (unless term
        (user-error "Runner session is not a live terminal"))
      (eat-term-send-string term string))))

(defun mcp-emacs-run--send (string)
  "Resolve the target runner session once and send STRING to it.
Signal a `user-error' when there is no live session."
  (mcp-emacs-run--send-to-buffer (mcp-emacs-run--resolve-session) string))

(defun mcp-emacs-run--selection-reference ()
  "Return a reference to the current selection for embedding in a prompt.
Now a thin alias for `agent-backend-selection-reference', which this
function was generalised into when the verb became backend-agnostic
(issue #56).  Kept so the runner's own callers and the reference tests
keep working from one implementation rather than two that can drift."
  (require 'agent-backend)
  (agent-backend-selection-reference))

;;;; Popup output window

(defun mcp-emacs-run--ensure-markdown ()
  "Signal a clear error unless `markdown-mode' is available."
  (unless (fboundp 'gfm-view-mode)
    (user-error "mcp-emacs-run requires the `markdown-mode' package for popup output; please install it")))

(defun mcp-emacs-run--popup-buffer-name (kind)
  "Return the dedicated popup buffer name for KIND."
  (format "*mcp-emacs:%s*" kind))

(defun mcp-emacs-popup-show (content &optional kind)
  "Render markdown CONTENT in the popup output window for KIND.
CONTENT is displayed read-only with `gfm-view-mode' and native code
fontification in a dedicated per-KIND buffer, shown in an ordinary split
window that does not auto-hide.  KIND defaults to \"output\".  A new call
with the same KIND replaces the previous content and reuses its window.
Return the popup buffer."
  (mcp-emacs-run--ensure-markdown)
  (let* ((kind (or kind "output"))
         (buf (get-buffer-create (mcp-emacs-run--popup-buffer-name kind))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert content)
        (goto-char (point-min)))
      (setq-local markdown-fontify-code-blocks-natively t)
      (gfm-view-mode)
      (setq-local markdown-fontify-code-blocks-natively t)
      (font-lock-flush)
      (font-lock-ensure))
    (mcp-emacs-run--display-popup buf)
    buf))

(defun mcp-emacs-run--display-popup (buffer)
  "Display BUFFER as an ordinary directional popup window.
An entry matching the popup buffer name is prepended to a local copy of
`display-buffer-alist' so this placement wins over any user or framework
rule (e.g. Doom's `+popup', which would otherwise force a transient,
auto-hiding side window).  The window is reused if already shown."
  (let* ((horizontal (memq mcp-emacs-run-popup-direction '(left right)))
         (size (if horizontal
                   `(window-width . ,mcp-emacs-run-popup-size)
                 `(window-height . ,mcp-emacs-run-popup-size)))
         (rule `(,(regexp-quote (buffer-name buffer))
                 (display-buffer-reuse-window display-buffer-in-direction)
                 (direction . ,mcp-emacs-run-popup-direction)
                 ,size))
         (display-buffer-alist (cons rule display-buffer-alist)))
    (display-buffer buffer)))

;;;; Headless query

(defun mcp-emacs-run--query-headless (prompt callback)
  "Run PROMPT non-interactively via the CLI and pass stdout to CALLBACK.
Invokes the configured executable with `-p PROMPT --output-format text'
from the current project root, collecting stdout asynchronously.  On a
zero exit, CALLBACK is called with the collected string.  On failure the
user is informed and CALLBACK is not called.

`agent-backend-query' on a Claude backend now does the same thing for
the backend clients (issue #56).  This is deliberately *not* delegated
to it: this one honours `mcp-emacs-run-executable' and
`mcp-emacs-run--project-root', and folding it into the backend method
would silently switch a user who configured only the runner's paths onto
`claude-client-executable'.  Two short call sites beat changing
behaviour under a deprecated surface; both go when the runner does."
  (let* ((default-directory (file-name-as-directory (mcp-emacs-run--project-root)))
         (out (generate-new-buffer " *mcp-emacs-query-out*"))
         (err (generate-new-buffer " *mcp-emacs-query-err*")))
    (make-process
     :name "mcp-emacs-query"
     :buffer out
     :stderr err
     :noquery t
     :command (list mcp-emacs-run-executable "-p" prompt "--output-format" "text")
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (let ((code (process-exit-status proc))
               (output (with-current-buffer out (buffer-string)))
               (errtext (with-current-buffer err (buffer-string))))
           (unwind-protect
               (if (and (eq (process-status proc) 'exit) (zerop code))
                   (funcall callback output)
                 (message "mcp-emacs query failed (exit %s): %s"
                          code (string-trim (if (string-empty-p errtext)
                                                 output
                                               errtext))))
             (when (buffer-live-p out) (kill-buffer out))
             (when (buffer-live-p err) (kill-buffer err)))))))))

;;;; Commands

;;;###autoload
(defun mcp-emacs-run-new (&rest extra-switches)
  "Start a new Claude Code runner session for the current project.
Always launches a fresh numbered session (`*claude:<project>:<n>*') and
displays it, even when the project already has live sessions.  Reach an
existing session with `mcp-emacs-run-switch'.  EXTRA-SWITCHES are passed to
the launch."
  (interactive)
  (apply #'mcp-emacs-run--launch (mcp-emacs-run--project-root) nil extra-switches))

;;;###autoload
(defun mcp-emacs-run-start ()
  "Start a new Claude Code runner session without showing it.
Launches the CLI in a fresh numbered eat buffer without displaying any
window or moving focus.  Reveal it later with `mcp-emacs-run-toggle' or
`mcp-emacs-run-switch'."
  (interactive)
  (let ((root (mcp-emacs-run--project-root)))
    (prog1 (mcp-emacs-run--launch root t)
      (message "Claude runner started (hidden) for %s"
               (mcp-emacs-run--project-name root)))))

;;;###autoload
(defun mcp-emacs-run-continue ()
  "Start a new runner session continuing the most recent conversation."
  (interactive)
  (mcp-emacs-run--launch (mcp-emacs-run--project-root) nil "--continue"))

;;;###autoload
(defun mcp-emacs-run-resume ()
  "Start a new runner session resuming a prior conversation."
  (interactive)
  (mcp-emacs-run--launch (mcp-emacs-run--project-root) nil "--resume"))

;;;###autoload
(defun mcp-emacs-run-list ()
  "Message the live runner sessions."
  (interactive)
  (let ((entries (mapcar (lambda (buf)
                           (format "  %s" (buffer-name buf)))
                         (mcp-emacs-run--sessions-list))))
    (if entries
        (message "Claude runner sessions:\n%s" (string-join entries "\n"))
      (message "No live Claude runner sessions"))))

;;;###autoload
(defun mcp-emacs-run-switch ()
  "Choose a live runner session and display it."
  (interactive)
  (let ((sessions (mcp-emacs-run--sessions-list)))
    (unless sessions (user-error "No live Claude runner sessions"))
    (mcp-emacs-run--display (mcp-emacs-run--pick-session sessions))))

;;;###autoload
(defun mcp-emacs-run-kill ()
  "Kill a runner session for the current project.
When the project has several sessions, prompt for which to kill."
  (interactive)
  (let* ((sessions (mcp-emacs-run--project-sessions (mcp-emacs-run--project-root)))
         (buf (mcp-emacs-run--pick-session sessions "Kill runner session: ")))
    (unless buf (user-error "No live runner session for this project"))
    (when-let ((proc (get-buffer-process buf)))
      (ignore-errors (delete-process proc)))
    (let ((name (buffer-name buf)))
      (kill-buffer buf)
      (message "Killed Claude runner session %s" name))))

(defconst mcp-emacs-run--quit-sequence "\003\003"
  "Sequence that makes the Claude CLI exit: two Ctrl-C characters.")

(defun mcp-emacs-run--force-kill-buffer (buf)
  "Force-kill BUF's process if still live, then kill BUF.
A no-op when BUF has already been killed."
  (when (buffer-live-p buf)
    (when-let ((proc (get-buffer-process buf)))
      (ignore-errors (delete-process proc)))
    (kill-buffer buf)))

;;;###autoload
(defun mcp-emacs-run-quit ()
  "Gracefully quit a resolved runner session, force-killing if it hangs.
Resolves the target session like the send commands (see
`mcp-emacs-run--resolve-session'), sends the CLI quit sequence, then after
`mcp-emacs-run-quit-timeout' seconds — without blocking Emacs — force-kills
the process if it is still live and removes the session buffer.  The end
state has no process and no buffer for that session."
  (interactive)
  (let ((buf (mcp-emacs-run--resolve-session)))
    (mcp-emacs-run--send-to-buffer buf mcp-emacs-run--quit-sequence)
    (run-with-timer mcp-emacs-run-quit-timeout nil
                    #'mcp-emacs-run--force-kill-buffer buf)
    (message "Quitting Claude runner session %s" (buffer-name buf))))

;;;###autoload
(defun mcp-emacs-run-toggle ()
  "Toggle a runner window for the current project.
With no session, start a new one.  With one session, hide it when visible
or show it otherwise.  With several, prompt for which to toggle."
  (interactive)
  (let* ((sessions (mcp-emacs-run--project-sessions (mcp-emacs-run--project-root)))
         (buf (mcp-emacs-run--pick-session sessions "Toggle runner session: ")))
    (cond
     ((null buf) (mcp-emacs-run-new))
     ((get-buffer-window buf)
      (delete-window (get-buffer-window buf)))
     (t (mcp-emacs-run--display buf)))))

;;;###autoload
(defun mcp-emacs-run-send-prompt (text)
  "Send TEXT to a resolved runner session and submit it.
Resolves the target session once (so an ambiguous choice prompts at most
once) and sends TEXT then a carriage return.  Requires a live session;
does not launch a new one."
  (interactive "sPrompt: ")
  (let ((buf (mcp-emacs-run--resolve-session)))
    (mcp-emacs-run--send-to-buffer buf text)
    (mcp-emacs-run--send-to-buffer buf "\r")))

;;;###autoload
(defun mcp-emacs-run-send-escape ()
  "Send an escape/interrupt to the current project's runner session."
  (interactive)
  (mcp-emacs-run--send "\e"))

;;;###autoload
(defun mcp-emacs-run-send-newline ()
  "Insert a newline in the runner prompt without submitting it."
  (interactive)
  (mcp-emacs-run--send "\n"))

;;;###autoload
(defun mcp-emacs-run-send-return ()
  "Send a carriage return to the current project's runner session.
Useful to accept a default or submit without typing a prompt."
  (interactive)
  (mcp-emacs-run--send "\r"))

;;;###autoload
(defun mcp-emacs-run-send-1 ()
  "Send the digit 1 to the current project's runner session."
  (interactive)
  (mcp-emacs-run--send "1"))

;;;###autoload
(defun mcp-emacs-run-send-2 ()
  "Send the digit 2 to the current project's runner session."
  (interactive)
  (mcp-emacs-run--send "2"))

;;;###autoload
(defun mcp-emacs-run-send-3 ()
  "Send the digit 3 to the current project's runner session."
  (interactive)
  (mcp-emacs-run--send "3"))

;;;###autoload
(defun mcp-emacs-run-send-shift-tab ()
  "Send shift-tab to the current project's runner session (cycle mode)."
  (interactive)
  (mcp-emacs-run--send "\e[Z"))

;;;###autoload
(defun mcp-emacs-run-send-up ()
  "Send the up arrow key to the current project's runner session."
  (interactive)
  (mcp-emacs-run--send "\e[A"))

;;;###autoload
(defun mcp-emacs-run-send-down ()
  "Send the down arrow key to the current project's runner session."
  (interactive)
  (mcp-emacs-run--send "\e[B"))

(defun mcp-emacs-run--session-visible-p (root)
  "Return non-nil when any of ROOT's live session buffers is shown in a window."
  (seq-some (lambda (buf) (get-buffer-window buf t))
            (mcp-emacs-run--project-sessions root)))

;;;###autoload
(defun mcp-emacs-run-mention-selection ()
  "Insert an at-mention of the current selection into the runner prompt.
Builds a reference for the active region (or point) with
`mcp-emacs-run--selection-reference' and sends it to the current
project's runner session without submitting, so the user can keep
typing around the reference.  Requires a live session; does not launch
one.  Mirrors claude-code-ide's `insert-at-mentioned'.

Superseded by `agent-backend-mention-selection', which does this for
whichever backend is live rather than for the eat runner only (issue
#56).  This stays while the runner does, since typing into its TUI input
line is a genuinely different mechanism from queueing a mention."
  (interactive)
  (let ((reference (mcp-emacs-run--selection-reference)))
    (mcp-emacs-run--send-to-buffer (mcp-emacs-run--resolve-session)
                                   (concat reference " "))))

;;;###autoload
(defun mcp-emacs-explain-selection-in-current-session ()
  "Explain the current selection, routing output by session visibility.
Builds a reference for the active region (or point).  When the current
project's runner session buffer is visible in a window, the explain
request is sent to and submitted in that live session.  Otherwise —
whether the project has a hidden session or no session at all — the
explanation is fetched with a one-shot headless query and rendered in
the popup output window.  Does not require or launch a TUI session.

Superseded by `agent-backend-explain-selection', which routes the same
way over whichever backend is live and takes
`agent-backend-explain-route' for whether to prefer a session at all
\(issue #56).  This stays while the runner does: its target is an eat
terminal, which is not an `agent-backend' and cannot be resolved as
one."
  (interactive)
  (let* ((root (mcp-emacs-run--project-root))
         (prompt (concat "explain " (mcp-emacs-run--selection-reference))))
    (if (mcp-emacs-run--session-visible-p root)
        (mcp-emacs-run-send-prompt prompt)
      (mcp-emacs-popup-show "Working…" "explain")
      (mcp-emacs-run--query-headless
       prompt
       (lambda (output) (mcp-emacs-popup-show output "explain"))))))

(provide 'mcp-emacs-run)

;;; mcp-emacs-run.el ends here
