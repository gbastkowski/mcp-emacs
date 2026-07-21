;;; opencode-client.el --- Native Emacs client for the opencode HTTP API -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.0.0
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

;; A native Emacs client for opencode's local HTTP API (`opencode serve').
;; It drives opencode over HTTP for requests and consumes its Server-Sent
;; Events stream to render the conversation incrementally in an ordinary
;; Emacs buffer, rather than embedding the opencode TUI in a terminal.
;;
;; Editor-tool integration is provided to opencode via the mcp-emacs MCP
;; server (wired through opencode.json); this client does not reimplement
;; editor tools.
;;
;; `plz' is an optional dependency: it is loaded only when present and is
;; required only when a client command is actually invoked, so installing
;; mcp-emacs never hard-requires plz.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'plz nil t)

(declare-function plz "plz"
                  (method url &rest rest))

;;;; Customization

(defgroup opencode-client nil
  "Native Emacs client for the opencode HTTP API."
  :group 'tools
  :prefix "opencode-client-")

(defcustom opencode-client-executable "opencode"
  "Path to the opencode executable (used by `opencode-client-serve')."
  :type 'string
  :group 'opencode-client)

(defcustom opencode-client-host "127.0.0.1"
  "Host where the opencode server listens."
  :type 'string
  :group 'opencode-client)

(defcustom opencode-client-port 4096
  "Port where the opencode server listens."
  :type 'integer
  :group 'opencode-client)

(defcustom opencode-client-password nil
  "Optional password for the opencode server (HTTP basic auth).
The basic-auth username opencode expects is `opencode'.  When nil,
`opencode-client-password-command' is consulted."
  :type '(choice (const :tag "None" nil) string)
  :group 'opencode-client)

(defcustom opencode-client-password-command nil
  "Shell command whose trimmed stdout is the server password.
Used only when `opencode-client-password' is nil, so the password can
come from a secret store (for example \"pass show private/opencode\")."
  :type '(choice (const :tag "None" nil) string)
  :group 'opencode-client)

(defcustom opencode-client-launchd-label nil
  "launchd label of an `opencode serve' agent to start on demand.
When non-nil, `opencode-client-serve' kickstarts this agent (so the
server is owned by launchd and outlives Emacs) instead of spawning a
child process.  When nil, the server is started as a child process."
  :type '(choice (const :tag "None" nil) string)
  :group 'opencode-client)

;;;; State

(defvar opencode-client--active-session nil
  "ID of the currently active opencode session, or nil.")

(defvar-local opencode-client--session-id nil
  "The opencode session ID a chat buffer is bound to.")

(defvar-local opencode-client--messages nil
  "Ordered list of message IDs seen in this chat buffer.")

(defvar-local opencode-client--parts nil
  "Hash table mapping part ID -> part alist, for this chat buffer.")

(defvar-local opencode-client--message-parts nil
  "Hash table mapping message ID -> ordered list of part IDs.")

(defvar-local opencode-client--seq 0
  "Highest sync-event `seq' applied in this chat buffer.")

(defvar-local opencode-client--stream-process nil
  "The SSE stream process for this chat buffer, or nil.")

(defvar-local opencode-client--stream-buffer ""
  "Accumulated, not-yet-framed SSE bytes for this chat buffer.")

;;;; Low-level HTTP

(defun opencode-client--ensure-plz ()
  "Signal a clear error unless `plz' is available."
  (unless (featurep 'plz)
    (user-error "opencode-client requires the `plz' package; please install it")))

(defun opencode-client--base-url ()
  "Return the base URL of the configured opencode server."
  (format "http://%s:%d" opencode-client-host opencode-client-port))

(defun opencode-client--password ()
  "Return the server password, or nil.
Prefer `opencode-client-password'; otherwise run
`opencode-client-password-command' and use its trimmed stdout."
  (cond
   (opencode-client-password opencode-client-password)
   (opencode-client-password-command
    (let ((out (string-trim
                (shell-command-to-string opencode-client-password-command))))
      (unless (string-empty-p out) out)))
   (t nil)))

(defun opencode-client--headers ()
  "Return request headers, including basic auth when a password resolves."
  (append
   '(("Content-Type" . "application/json"))
   (when-let ((pw (opencode-client--password)))
     (list (cons "Authorization"
                 (concat "Basic "
                         (base64-encode-string
                          (concat "opencode:" pw) t)))))))

(defun opencode-client--request (method path &optional body)
  "Perform a synchronous HTTP METHOD on PATH, returning parsed JSON.
BODY, when non-nil, is encoded as a JSON request body.  Errors are
surfaced as user errors rather than raw signals."
  (opencode-client--ensure-plz)
  (condition-case err
      (let* ((url (concat (opencode-client--base-url) path))
             (json-object-type 'alist)
             (json-array-type 'list)
             (res (apply #'plz method url
                         (append
                          (list :headers (opencode-client--headers)
                                :as (lambda () (ignore-errors (json-read))))
                          (when body
                            (list :body (json-encode body)))))))
        (opencode-client--unwrap res))
    (error (user-error "opencode request failed (%s %s): %s"
                       method path (error-message-string err)))))

(defun opencode-client--unwrap (res)
  "Unwrap the server's `data' envelope from RES.
opencode wraps most responses as `((data . PAYLOAD) ...)'; return PAYLOAD
in that case.  Flat responses (for example the health check, which has
no `data' key) are returned unchanged."
  (if (and (consp res) (consp (car res)) (assq 'data res))
      (alist-get 'data res)
    res))

;;;; Connection

(defun opencode-client-health ()
  "Return non-nil when the opencode server is reachable and healthy."
  (ignore-errors
    (let ((res (opencode-client--request 'get "/api/health")))
      (and res (alist-get 'healthy res)))))

;;;###autoload
(defun opencode-client-connect ()
  "Verify the configured opencode server is reachable."
  (interactive)
  (if (opencode-client-health)
      (message "opencode: connected to %s" (opencode-client--base-url))
    (user-error "opencode: cannot reach a healthy server at %s"
                (opencode-client--base-url))))

;;;###autoload
(defun opencode-client-serve ()
  "Start an `opencode serve' on demand and wait until it is healthy.
Attaching to an already-running server is the primary path; this is a
convenience for starting one.  When `opencode-client-launchd-label' is
set, the server is started by kickstarting that launchd agent, so it is
owned by launchd and outlives Emacs; otherwise it is started as a child
process."
  (interactive)
  (when (opencode-client-health)
    (user-error "opencode: a server is already running at %s"
                (opencode-client--base-url)))
  (if opencode-client-launchd-label
      (unless (zerop (call-process
                      "launchctl" nil nil nil "kickstart"
                      (format "gui/%d/%s"
                              (user-uid) opencode-client-launchd-label)))
        (user-error "opencode: failed to kickstart launchd agent %s"
                    opencode-client-launchd-label))
    (start-process "opencode-serve" " *opencode-serve*"
                   opencode-client-executable "serve"
                   "--hostname" opencode-client-host
                   "--port" (number-to-string opencode-client-port)))
  (let ((deadline (+ (float-time) 20)))
    (while (and (not (opencode-client-health))
                (< (float-time) deadline))
      (accept-process-output nil 0.3))
    (if (opencode-client-health)
        (message "opencode: server started at %s" (opencode-client--base-url))
      (user-error "opencode: server did not become healthy in time"))))

;;;; Sessions

(defun opencode-client--sessions ()
  "Return the list of sessions from the server."
  (opencode-client--request 'get "/api/session"))

;;;###autoload
(defun opencode-client-list-sessions ()
  "Message the available opencode sessions."
  (interactive)
  (let ((sessions (opencode-client--sessions)))
    (if sessions
        (message "opencode sessions:\n%s"
                 (mapconcat
                  (lambda (s) (format "  %s  %s"
                                      (alist-get 'id s)
                                      (or (alist-get 'title s) "")))
                  sessions "\n"))
      (message "opencode: no sessions"))))

;;;###autoload
(defun opencode-client-create-session (&optional title)
  "Create a new opencode session with optional TITLE and make it active."
  (interactive (list (read-string "Session title: ")))
  (let* ((body (when (and title (not (string-empty-p title))) `((title . ,title))))
         (session (opencode-client--request 'post "/api/session" body))
         (id (alist-get 'id session)))
    (setq opencode-client--active-session id)
    (opencode-client--open-buffer id (or title id))
    (message "opencode: created session %s" id)
    id))

;;;###autoload
(defun opencode-client-switch-session ()
  "Choose an opencode session and make it active, opening its chat buffer."
  (interactive)
  (let* ((sessions (opencode-client--sessions))
         (choices (mapcar (lambda (s)
                            (cons (format "%s  %s"
                                          (or (alist-get 'title s) "")
                                          (alist-get 'id s))
                                  (alist-get 'id s)))
                          sessions))
         (pick (completing-read "Session: " choices nil t))
         (id (cdr (assoc pick choices))))
    (setq opencode-client--active-session id)
    (opencode-client--open-buffer id pick)))

;;;###autoload
(defun opencode-client-delete-session (id)
  "Delete the opencode session ID."
  (interactive (list (or opencode-client--session-id
                         opencode-client--active-session
                         (read-string "Session id: "))))
  (opencode-client--request 'delete (format "/api/session/%s" id))
  (when (equal id opencode-client--active-session)
    (setq opencode-client--active-session nil))
  (message "opencode: deleted session %s" id))

;;;; Conversation model

(defun opencode-client--buffer-name (title)
  "Return the chat buffer name for session TITLE."
  (format "*opencode:%s*" title))

(defun opencode-client--open-buffer (id title)
  "Open (creating if needed) the chat buffer for session ID/TITLE, and stream.
Loads and renders the session's existing message history before starting
the live event stream, so reconnecting shows the prior conversation."
  (let ((buf (get-buffer-create (opencode-client--buffer-name title))))
    (with-current-buffer buf
      (unless (derived-mode-p 'opencode-client-mode)
        (opencode-client-mode))
      (setq opencode-client--session-id id)
      (unless opencode-client--parts
        (setq opencode-client--parts (make-hash-table :test 'equal)))
      (unless opencode-client--message-parts
        (setq opencode-client--message-parts (make-hash-table :test 'equal)))
      (opencode-client--seed-history id)
      (opencode-client--render)
      (opencode-client--start-stream))
    (pop-to-buffer buf)
    buf))

(defun opencode-client--seed-history (id)
  "Seed the conversation model from session ID's message history.
Populates `opencode-client--messages', `--message-parts', and `--parts'
from `GET /api/session/ID/message', adapting each history message into
the same part model the live stream uses.  A user message becomes a
single text part; an assistant message contributes its `content' items
\(text, reasoning, tool), with the tool item's `name' copied to the
`tool' key the renderer reads."
  (let ((messages (opencode-client--request
                   'get (format "/api/session/%s/message" id))))
    (dolist (msg messages)
      (let* ((mid (alist-get 'id msg))
             (mtype (alist-get 'type msg))
             (parts (opencode-client--history-parts mid mtype msg)))
        (when mid
          (unless (member mid opencode-client--messages)
            (setq opencode-client--messages
                  (append opencode-client--messages (list mid))))
          (dolist (part parts)
            (let ((pid (alist-get 'id part)))
              (puthash pid part opencode-client--parts)
              (let ((order (gethash mid opencode-client--message-parts)))
                (unless (member pid order)
                  (puthash mid (append order (list pid))
                           opencode-client--message-parts))))))))))

(defun opencode-client--history-parts (mid mtype msg)
  "Return render-model parts for history message MSG with id MID, type MTYPE."
  (if (equal mtype "user")
      (list `((id . ,(format "%s:text" mid))
              (type . "text")
              (text . ,(or (alist-get 'text msg) ""))))
    ;; assistant (and other content-bearing) messages carry a `content' array
    (mapcar
     (lambda (item)
       (if (equal (alist-get 'type item) "tool")
           ;; renderer reads the `tool' key; history uses `name'.
           (cons (cons 'tool (alist-get 'name item)) item)
         item))
     (alist-get 'content msg))))

(defun opencode-client--apply-sync-event (buffer event)
  "Apply a parsed sync EVENT to the conversation model in BUFFER.
Ignores stale/duplicate `seq' and unknown event types."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((sync (alist-get 'syncEvent event))
             (etype (alist-get 'type sync))
             (seq (or (alist-get 'seq sync) 0))
             (data (alist-get 'data sync)))
        ;; Ignore stale/duplicate events; the stream `seq' is monotonic.
        (when (> seq opencode-client--seq)
          (setq opencode-client--seq seq)
          (pcase etype
          ("message.updated.1"
           (let* ((info (alist-get 'info data))
                  (mid (alist-get 'id info)))
             (when (and mid (not (member mid opencode-client--messages)))
               (setq opencode-client--messages
                     (append opencode-client--messages (list mid))))))
          ("message.part.updated.1"
           (let* ((part (alist-get 'part data))
                  (pid (alist-get 'id part))
                  (mid (alist-get 'messageID part)))
             (when pid
               (puthash pid part opencode-client--parts)
               (when (and mid (not (member mid opencode-client--messages)))
                 (setq opencode-client--messages
                       (append opencode-client--messages (list mid))))
               (let ((order (gethash mid opencode-client--message-parts)))
                 (unless (member pid order)
                   (puthash mid (append order (list pid))
                            opencode-client--message-parts)))
               (opencode-client--render))))
          ("message.part.removed.1"
           (let* ((part (alist-get 'part data))
                  (pid (alist-get 'id part)))
             (when pid
               (remhash pid opencode-client--parts)
               (opencode-client--render))))
          (_ nil)))))))

(defun opencode-client--render-part (pid)
  "Return a rendered string for part PID, or nil to skip it."
  (let* ((part (gethash pid opencode-client--parts))
         (type (alist-get 'type part)))
    (pcase type
      ("text" (alist-get 'text part))
      ("reasoning" (concat "  · " (or (alist-get 'text part) "")))
      ("tool" (format "  [tool: %s %s]"
                      (alist-get 'tool part)
                      (let ((st (alist-get 'state part)))
                        (if (listp st) (alist-get 'status st) st))))
      ((or "step-start" "step-finish") nil)
      (_ nil))))

(defun opencode-client--render ()
  "Re-render the conversation into the current chat buffer."
  (let ((at-end (eobp))
        (inhibit-read-only t))
    (erase-buffer)
    (dolist (mid opencode-client--messages)
      (dolist (pid (gethash mid opencode-client--message-parts))
        (when-let ((s (opencode-client--render-part pid)))
          (insert s)
          (unless (string-suffix-p "\n" s) (insert "\n")))))
    (when at-end (goto-char (point-max)))))

;;;; Streaming (SSE)

(defun opencode-client--start-stream ()
  "Open the per-session SSE stream for the current chat buffer."
  (opencode-client--ensure-plz)
  (opencode-client--stop-stream)
  (let* ((buffer (current-buffer))
         (id opencode-client--session-id)
         (url (format "%s/api/session/%s/event"
                      (opencode-client--base-url) id)))
    (setq opencode-client--stream-buffer "")
    (setq opencode-client--stream-process
          (plz 'get url
            :headers (opencode-client--headers)
            :as 'response
            :filter (lambda (proc chunk)
                      (opencode-client--stream-filter buffer proc chunk))
            :then #'ignore
            :else (lambda (_err)
                    (when (buffer-live-p buffer)
                      (with-current-buffer buffer
                        (message "opencode: event stream disconnected"))))))))

(defun opencode-client--stop-stream ()
  "Stop the SSE stream process for the current chat buffer, if any."
  (when (and opencode-client--stream-process
             (process-live-p opencode-client--stream-process))
    (ignore-errors (delete-process opencode-client--stream-process)))
  (setq opencode-client--stream-process nil))

(defun opencode-client--stream-filter (buffer _proc chunk)
  "Frame SSE CHUNK for BUFFER: split on blank lines, parse data payloads."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq opencode-client--stream-buffer
            (concat opencode-client--stream-buffer chunk))
      ;; SSE frames are separated by a blank line.  Capture the split
      ;; positions before dispatching, since parsing/rendering a frame can
      ;; clobber the global match data.
      (let ((sep "\n\n") (pos nil))
        (while (setq pos (string-search sep opencode-client--stream-buffer))
          (let ((frame (substring opencode-client--stream-buffer 0 pos)))
            (setq opencode-client--stream-buffer
                  (substring opencode-client--stream-buffer (+ pos (length sep))))
            (opencode-client--handle-frame buffer frame)))))))

(defun opencode-client--handle-frame (buffer frame)
  "Parse one SSE FRAME (its `data:' lines) and apply the event to BUFFER."
  (let ((data (mapconcat
               (lambda (line)
                 (cond
                  ((string-prefix-p "data:" line)
                   (string-trim (substring line 5)))
                  (t "")))
               (split-string frame "\n") "")))
    (unless (string-empty-p data)
      (let ((event (ignore-errors
                     (json-parse-string data
                                        :object-type 'alist
                                        :array-type 'list
                                        :null-object nil
                                        :false-object nil))))
        (when event
          (opencode-client--apply-sync-event buffer event))))))

;;;; Prompting and interaction

;;;###autoload
(defun opencode-client-send-prompt (text &optional steer)
  "Send TEXT as a prompt to the active session.
With prefix arg STEER, deliver it as a steering message mid-turn."
  (interactive (list (read-string "Prompt: ") current-prefix-arg))
  (let ((id (or opencode-client--session-id opencode-client--active-session)))
    (unless id (user-error "opencode: no active session"))
    (opencode-client--request
     'post (format "/api/session/%s/prompt" id)
     `((prompt . ((text . ,text)))
       (delivery . ,(if steer "steer" "queue"))))
    (message "opencode: prompt sent")))

;;;###autoload
(defun opencode-client-interrupt ()
  "Interrupt the running turn in the active session."
  (interactive)
  (let ((id (or opencode-client--session-id opencode-client--active-session)))
    (unless id (user-error "opencode: no active session"))
    (opencode-client--request 'post (format "/api/session/%s/interrupt" id))
    (message "opencode: interrupted")))

(defun opencode-client--reply-permission (id request-id decision)
  "Reply DECISION to permission REQUEST-ID of session ID."
  (opencode-client--request
   'post (format "/api/session/%s/permission/%s/reply" id request-id)
   `((decision . ,decision))))

(defun opencode-client-answer-permission (request-id)
  "Prompt the user to allow or deny permission REQUEST-ID in the active session."
  (interactive (list (read-string "Permission request id: ")))
  (let ((id (or opencode-client--session-id opencode-client--active-session)))
    (unless id (user-error "opencode: no active session"))
    (opencode-client--reply-permission
     id request-id
     (if (y-or-n-p "opencode: allow this request? ") "allow" "deny"))))

(defun opencode-client--reply-question (id request-id answer)
  "Reply ANSWER to question REQUEST-ID of session ID."
  (opencode-client--request
   'post (format "/api/session/%s/question/%s/reply" id request-id)
   `((answer . ,answer))))

(defun opencode-client-answer-question (request-id)
  "Prompt the user to answer question REQUEST-ID in the active session."
  (interactive (list (read-string "Question request id: ")))
  (let ((id (or opencode-client--session-id opencode-client--active-session)))
    (unless id (user-error "opencode: no active session"))
    (opencode-client--reply-question
     id request-id (read-string "Answer: "))))

;;;; Major mode

(defvar opencode-client-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'opencode-client-send-prompt)
    (define-key map (kbd "C-c C-k") #'opencode-client-interrupt)
    (define-key map (kbd "g")       #'opencode-client-send-prompt)
    map)
  "Keymap for `opencode-client-mode'.")

(define-derived-mode opencode-client-mode special-mode "opencode"
  "Major mode for an opencode chat buffer."
  (setq-local truncate-lines nil)
  (add-hook 'kill-buffer-hook #'opencode-client--stop-stream nil t))

(provide 'opencode-client)

;;; opencode-client.el ends here
