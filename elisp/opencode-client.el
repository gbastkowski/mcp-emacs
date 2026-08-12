;;; opencode-client.el --- Native Emacs client for the opencode HTTP API -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.7.0
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
;; along with this program.  If not, see <https://www.gnu.org/licenses/\>.

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
;;
;; The client is an `agent-backend' subclass (`opencode-client-backend'):
;; the conversation lifecycle (send, interrupt, add-note, replies,
;; sessions) dispatches through the shared generic methods and publishes
;; the shared event vocabulary on `agent-backend-event-functions', so the
;; backend is interchangeable with claude-client behind one UI (issue #41).

;;; Code:

(require 'json)
(require 'subr-x)
(require 'plz nil t)
(require 'agent-backend)

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

;;;; The backend class

(defclass opencode-client-backend (agent-backend)
  ((host :initarg :host :initform nil
         :documentation "Host of this backend's own server, or nil for the default.")
   (port :initarg :port :initform nil
         :documentation "Port of this backend's own server, or nil for the default.")
   (messages :initarg :messages :initform nil
             :documentation "Ordered list of message IDs seen in this chat buffer.")
   (parts :initarg :parts
          :initform (make-hash-table :test 'equal)
          :documentation "Hash table mapping part ID -> part alist.")
   (message-parts :initarg :message-parts
                  :initform (make-hash-table :test 'equal)
                  :documentation "Hash table mapping message ID -> ordered part IDs.")
   (seq :initarg :seq :initform 0
        :documentation "Highest sync-event `seq' applied in this chat buffer.")
   (stream-process :initarg :stream-process :initform nil
                   :documentation "The SSE stream process for this chat buffer, or nil.")
   (stream-buffer :initarg :stream-buffer :initform ""
                  :documentation "Accumulated, not-yet-framed SSE bytes."))
  "An opencode chat backend (an `agent-backend' subclass).
Holds the per-buffer conversation state -- session id, part model, and
SSE stream -- and implements the shared lifecycle generics.")

(defun opencode-client--instance ()
  "Return the opencode backend instance for the current buffer."
  agent-backend--instance)

;;;; Low-level HTTP

(defun opencode-client--ensure-plz ()
  "Signal a clear error unless `plz' is available."
  (unless (featurep 'plz)
    (user-error "opencode-client requires the `plz' package; please install it")))

(defun opencode-client--base-url (&optional backend)
  "Return the base URL for BACKEND, or the configured default.
When BACKEND carries its own host/port (a per-project server started by
`opencode-client-serve'), that wins; otherwise the defcustoms apply."
  (format "http://%s:%d"
          (or (and backend (oref backend host)) opencode-client-host)
          (or (and backend (oref backend port)) opencode-client-port)))

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

(defun opencode-client--request (method path &optional body backend)
  "Perform a synchronous HTTP METHOD on PATH, returning parsed JSON.
BODY, when non-nil, is encoded as a JSON request body.  BACKEND selects
the server when non-nil (its own host/port); nil uses the defaults.
Errors are surfaced as user errors rather than raw signals."
  (opencode-client--ensure-plz)
  (condition-case err
      (let* ((url (concat (opencode-client--base-url backend) path))
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

(defun opencode-client--health (&optional backend)
  "Return non-nil when BACKEND's server is reachable and healthy.
nil BACKEND probes the default server."
  (ignore-errors
    (let ((res (opencode-client--request 'get "/api/health" nil backend)))
      (and res (alist-get 'healthy res)))))

;;;###autoload
(defun opencode-client-connect ()
  "Verify the configured opencode server is reachable."
  (interactive)
  (agent-backend-connect (opencode-client--transient-backend)))

;;;###autoload
;;;; Server registry (one server per project, parallel ports)

(defvar opencode-client--servers nil
  "Alist mapping project directory -> `opencode-client-backend' instance.
Lets several opencode servers run in parallel, each on its own port,
one per project -- so sessions stay project-scoped and do not collide
on a single fixed port.")

(defun opencode-client--free-port ()
  "Return a free TCP port, probing upward from `opencode-client-port'.
The probe binds and releases a socket, so a parallel server starting
concurrently could race -- acceptable for an interactive tool."
  (let ((port opencode-client-port))
    (while (condition-case nil
               (progn
                 (make-network-process
                  :name "opencode-client--port-probe"
                  :server t :host "127.0.0.1" :service port
                  :noquery t)
                 (delete-process (get-process "opencode-client--port-probe"))
                 nil)                ; bind succeeded: port is free
             (error t))              ; bind failed: port is taken
      (setq port (1+ port)))
    port))

(defun opencode-client--ensure-server ()
  "Return the backend for the current project, starting one if needed.
The server is registered under `default-directory' so switching
projects uses that project's server and its sessions."
  (or (cdr (assoc (expand-file-name default-directory)
                  opencode-client--servers))
      (opencode-client-serve)))

;;;###autoload
(defun opencode-client-serve ()
  "Start an `opencode serve' for the current project on a free port.
Each project gets its own server on its own port, so several can run
in parallel with project-scoped sessions.  Registers the backend under
`default-directory' and returns it.  When `opencode-client-launchd-label'
is set *and* this is macOS (launchd exists only there), the server is
started by kickstarting that launchd agent; otherwise it is started as
a child process."
  (interactive)
  (let* ((port (opencode-client--free-port))
         (backend (make-instance 'opencode-client-backend
                                 :host opencode-client-host
                                 :port port))
         (dir (expand-file-name default-directory)))
    (if (and opencode-client-launchd-label (eq system-type 'darwin))
        (unless (zerop (call-process
                        "launchctl" nil nil nil "kickstart"
                        (format "gui/%d/%s"
                                (user-uid) opencode-client-launchd-label)))
          (user-error "opencode: failed to kickstart launchd agent %s"
                      opencode-client-launchd-label))
      (start-process "opencode-serve" " *opencode-serve*"
                     opencode-client-executable "serve"
                     "--hostname" opencode-client-host
                     "--port" (number-to-string port)))
    (let ((deadline (+ (float-time) 20)))
      (while (and (not (opencode-client--health backend))
                  (< (float-time) deadline))
        (accept-process-output nil 0.3))
      (if (opencode-client--health backend)
          (progn
            (setq opencode-client--servers
                  (assoc-delete-all dir opencode-client--servers))
            (push (cons dir backend) opencode-client--servers)
            (message "opencode: server started at %s (project %s)"
                     (opencode-client--base-url backend) dir)
            backend)
        (user-error "opencode: server did not become healthy in time")))))

;;;; Sessions

(defun opencode-client--sessions (&optional backend)
  "Return the list of sessions from BACKEND's server."
  (opencode-client--request 'get "/api/session" nil backend))

;;;###autoload
(defun opencode-client-list-sessions ()
  "Message the available opencode sessions."
  (interactive)
  (let ((sessions (agent-backend-list-sessions
                   (opencode-client--ensure-server))))
    (if sessions
        (message "opencode sessions:n%s"
                 (mapconcat
                  (lambda (s) (format "  %s  %s"
                                      (plist-get s :id)
                                      (plist-get s :label)))
                  sessions "\n"))
      (message "opencode: no sessions"))))

;;;###autoload
(defun opencode-client-create-session (&optional title)
  "Create a new opencode session on the current project's server.
The server is started on demand if none exists for this project, so
several projects can run their own opencode server in parallel."
  (interactive (list (read-string "Session title: ")))
  (let* ((backend (opencode-client--ensure-server))
         (body (when (and title (not (string-empty-p title))) `((title . ,title))))
         (session (opencode-client--request 'post "/api/session" body backend))
         (id (alist-get 'id session)))
    (setq opencode-client--active-session id)
    (opencode-client--open-buffer id (or title id) nil backend)
    (message "opencode: created session %s" id)
    id))

;;;###autoload
(defun opencode-client-switch-session ()
  "Choose an opencode session on the current project's server.
Lists sessions from this project's server (starting it on demand), so
each project keeps its own session list."
  (interactive)
  (let* ((backend (opencode-client--ensure-server))
         (sessions (opencode-client--sessions backend))
         (choices (mapcar (lambda (s)
                            (cons (format "%s  %s"
                                          (or (alist-get 'title s) "")
                                          (alist-get 'id s))
                                  (alist-get 'id s)))
                          sessions))
         (pick (completing-read "Session: " choices nil t))
         (id (cdr (assoc pick choices))))
    (setq opencode-client--active-session id)
    (opencode-client--open-buffer id pick t backend)))

;;;###autoload
(defun opencode-client-delete-session (id)
  "Delete the opencode session ID from the current buffer's server."
  (interactive (list (or (and (opencode-client--instance)
                              (oref (opencode-client--instance) session-id))
                         opencode-client--active-session
                         (read-string "Session id: "))))
  (let ((backend (or (opencode-client--instance)
                     (opencode-client--ensure-server))))
    (opencode-client--request 'delete (format "/api/session/%s" id) nil backend))
  (when (equal id opencode-client--active-session)
    (setq opencode-client--active-session nil))
  (message "opencode: deleted session %s" id))

;;;; Conversation model

(defun opencode-client--buffer-name (title)
  "Return the chat buffer name for session TITLE."
  (format "*opencode:%s*" title))

(defun opencode-client--open-buffer (id title &optional resumed server)
  "Open (creating if needed) the chat buffer for session ID/TITLE, and stream.
Creates a fresh backend instance bound to the buffer, carrying SERVER's
host/port (so the buffer talks to the right project server), loads and
renders the session's existing message history, then starts the live
stream.  Publishes `started' or, when RESUMED, `resumed' on the shared
hook."
  (let ((buf (get-buffer-create (opencode-client--buffer-name title))))
    (with-current-buffer buf
      (unless (derived-mode-p 'opencode-client-mode)
        (opencode-client-mode))
      (let ((backend (make-instance 'opencode-client-backend
                                    :session-id id
                                    :buffer buf
                                    :host (and server (oref server host))
                                    :port (and server (oref server port)))))
        (setq-local agent-backend--instance backend)
        (agent-backend-seed-history backend)
        (agent-backend-render backend)
        (opencode-client--start-stream)
        (agent-backend--publish
         buf (list :kind (if resumed 'resumed 'started) :session id))))
    (pop-to-buffer buf)
    buf))

(defun opencode-client--seed-history (backend)
  "Seed BACKEND's conversation model from its session's message history.
Populates `messages', `message-parts', and `parts' from
`GET /api/session/ID/message', adapting each history message into the
same part model the live stream uses.  A user message becomes a single
text part; an assistant message contributes its `content' items
(text, reasoning, tool), with the tool item's `name' copied to the
`tool' key the renderer reads."
  (let ((id (oref backend session-id)))
    (dolist (msg (opencode-client--request
                  'get (format "/api/session/%s/message" id) nil backend))
      (let* ((mid (alist-get 'id msg))
             (mtype (alist-get 'type msg))
             (parts (opencode-client--history-parts mid mtype msg)))
        (when mid
          (unless (member mid (oref backend messages))
            (oset backend messages
                  (append (oref backend messages) (list mid))))
          (dolist (part parts)
            (let ((pid (alist-get 'id part)))
              (puthash pid part (oref backend parts))
              (let ((order (gethash mid (oref backend message-parts))))
                (unless (member pid order)
                  (puthash mid (append order (list pid))
                           (oref backend message-parts)))))))))))

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
Ignores stale/duplicate `seq' and unknown event types, and publishes
translated events on `agent-backend-event-functions'."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let ((backend (opencode-client--instance)))
        (let* ((sync (alist-get 'syncEvent event))
               (etype (alist-get 'type sync))
               (seq (or (alist-get 'seq sync) 0))
               (data (alist-get 'data sync)))
          ;; Ignore stale/duplicate events; the stream `seq' is monotonic.
          (when (> seq (oref backend seq))
            (oset backend seq seq)
            (pcase etype
              ("message.updated.1"
               (let* ((info (alist-get 'info data))
                      (mid (alist-get 'id info)))
                 (when (and mid (not (member mid (oref backend messages))))
                   (oset backend messages
                         (append (oref backend messages) (list mid))))))
              ("message.part.updated.1"
               (let* ((part (alist-get 'part data))
                      (pid (alist-get 'id part))
                      (mid (alist-get 'messageID part)))
                 (when pid
                   (puthash pid part (oref backend parts))
                   (when (and mid (not (member mid (oref backend messages))))
                     (oset backend messages
                           (append (oref backend messages) (list mid))))
                   (let ((order (gethash mid (oref backend message-parts))))
                     (unless (member pid order)
                       (puthash mid (append order (list pid))
                                (oref backend message-parts))))
                   (opencode-client--render)
                   (opencode-client--publish-part buffer part))))
              ("message.part.removed.1"
               (let* ((part (alist-get 'part data))
                      (pid (alist-get 'id part)))
                 (when pid
                   (remhash pid (oref backend parts))
                   (opencode-client--render))))
              (_ nil))))))))

(defun opencode-client--publish-part (buffer part)
  "Publish PART from BUFFER as a shared `:kind' event, when renderable.
Maps opencode part types onto the shared vocabulary: a text part becomes
`:text', a tool part becomes `:tool-use'."
  (pcase (alist-get 'type part)
    ("text"
     (let ((text (alist-get 'text part)))
       (when (and text (not (string-empty-p (string-trim text))))
         (agent-backend--publish buffer (list :kind 'text :text text)))))
    ("tool"
     (agent-backend--publish
      buffer (list :kind 'tool-use
                   :name (or (alist-get 'tool part)
                             (alist-get 'name part)))))
    (_ nil)))

(defun opencode-client--render-part (pid)
  "Return a rendered string for part PID, or nil to skip it."
  (when-let ((backend (opencode-client--instance)))
    (let* ((part (gethash pid (oref backend parts)))
           (type (alist-get 'type part)))
      (pcase type
        ("text" (alist-get 'text part))
        ("reasoning" (concat "  · " (or (alist-get 'text part) "")))
        ("tool" (format "  [tool: %s %s]"
                          (alist-get 'tool part)
                          (let ((st (alist-get 'state part)))
                            (if (listp st) (alist-get 'status st) st))))
        ((or "step-start" "step-finish") nil)
        (_ nil)))))

(defun opencode-client--render ()
  "Re-render the conversation into the current chat buffer."
  (when-let ((backend (opencode-client--instance)))
    (let ((at-end (eobp))
          (inhibit-read-only t))
      (erase-buffer)
      (dolist (mid (oref backend messages))
        (dolist (pid (gethash mid (oref backend message-parts)))
          (when-let ((s (opencode-client--render-part pid)))
            (insert s)
            (unless (string-suffix-p "\n" s) (insert "\n")))))
      (when at-end (goto-char (point-max))))))

;;;; Streaming (SSE)

(defun opencode-client--start-stream ()
  "Open the per-session SSE stream for the current chat buffer."
  (opencode-client--ensure-plz)
  (opencode-client--stop-stream)
  (when-let ((backend (opencode-client--instance)))
    (let* ((buffer (current-buffer))
           (id (oref backend session-id))
           (url (format "%s/api/session/%s/event"
                        (opencode-client--base-url backend) id)))
      (oset backend stream-buffer "")
      (oset backend stream-process
            (plz 'get url
              :headers (opencode-client--headers)
              :as 'response
              :filter (lambda (proc chunk)
                        (opencode-client--stream-filter buffer proc chunk))
              :then #'ignore
              :else (lambda (_err)
                      (when (buffer-live-p buffer)
                        (with-current-buffer buffer
                          (message "opencode: event stream disconnected")))))))))

(defun opencode-client--stop-stream ()
  "Stop the SSE stream process for the current chat buffer, if any."
  (when-let ((backend (opencode-client--instance)))
    (let ((proc (oref backend stream-process)))
      (when (and proc (process-live-p proc))
        (ignore-errors (delete-process proc)))
      (oset backend stream-process nil))))

(defun opencode-client--stream-filter (buffer _proc chunk)
  "Frame SSE CHUNK for BUFFER: split on blank lines, parse data payloads."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let ((backend (opencode-client--instance)))
        (oset backend stream-buffer
              (concat (oref backend stream-buffer) chunk))
        ;; SSE frames are separated by a blank line.  Capture the split
        ;; positions before dispatching, since parsing/rendering a frame can
        ;; clobber the global match data.
        (let ((sep "\n\n") (pos nil))
          (while (setq pos (string-search sep (oref backend stream-buffer)))
            (let ((frame (substring (oref backend stream-buffer) 0 pos)))
              (oset backend stream-buffer
                    (substring (oref backend stream-buffer) (+ pos (length sep))))
              (opencode-client--handle-frame buffer frame))))))))

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

;;;; agent-backend methods

(cl-defmethod agent-backend-connect ((backend opencode-client-backend))
  "Verify BACKEND's server is reachable."
  (if (opencode-client--health backend)
      (message "opencode: connected to %s" (opencode-client--base-url backend))
    (user-error "opencode: cannot reach a healthy server at %s"
                (opencode-client--base-url backend))))

(cl-defmethod agent-backend-quit ((backend opencode-client-backend))
  "Stop the SSE stream for BACKEND's chat buffer, if any."
  (let ((buffer (oref backend buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (opencode-client--stop-stream)))))

(cl-defmethod agent-backend-send ((backend opencode-client-backend) prompt)
  "Send PROMPT to BACKEND's session as the next turn."
  (let ((id (oref backend session-id)))
    (unless id (user-error "opencode: no active session"))
    (opencode-client--request
     'post (format "/api/session/%s/prompt" id)
     `((prompt . ((text . ,prompt)))
       (delivery . "queue"))
     backend)
    (when-let ((buffer (oref backend buffer)))
      (agent-backend--publish buffer (list :kind 'prompt :text prompt)))
    (message "opencode: prompt sent")))

(cl-defmethod agent-backend-interrupt ((backend opencode-client-backend))
  "Interrupt the running turn in BACKEND's session."
  (let ((id (oref backend session-id)))
    (unless id (user-error "opencode: no active session"))
    (opencode-client--request 'post (format "/api/session/%s/interrupt" id) nil backend)
    (when-let ((buffer (oref backend buffer)))
      (agent-backend--publish buffer (list :kind 'interrupted)))
    (message "opencode: interrupted")))

(cl-defmethod agent-backend-add-note ((backend opencode-client-backend) text)
  "Deliver TEXT to BACKEND's session as a steering prompt.
opencode notes ARE steering prompts: the note is posted with delivery
`steer' so the model incorporates it mid-turn."
  (let ((id (oref backend session-id))
        (note (string-trim text)))
    (unless id (user-error "opencode: no active session"))
    (when (string-empty-p note) (user-error "Empty note"))
    (opencode-client--request
     'post (format "/api/session/%s/prompt" id)
     `((prompt . ((text . ,note)))
       (delivery . "steer"))
     backend)
    (when-let ((buffer (oref backend buffer)))
      (agent-backend--publish buffer (list :kind 'note :text note)))
    (message "opencode: note sent")))

(cl-defmethod agent-backend-reply-permission
  ((backend opencode-client-backend) request-id decision)
  "Reply DECISION to BACKEND's permission REQUEST-ID."
  (opencode-client--reply-permission backend (oref backend session-id)
                                     request-id decision))

(cl-defmethod agent-backend-reply-question
  ((backend opencode-client-backend) request-id answer)
  "Reply ANSWER to BACKEND's question REQUEST-ID."
  (opencode-client--reply-question backend (oref backend session-id) request-id answer))

(cl-defmethod agent-backend-list-sessions ((backend opencode-client-backend))
  "Return opencode sessions as (:id :label :time) plists."
  (mapcar (lambda (s)
            (list :id (alist-get 'id s)
                  :label (or (alist-get 'title s) (alist-get 'id s))
                  :time (or (alist-get 'time s) "")))
          (opencode-client--sessions backend)))

(cl-defmethod agent-backend-resume ((_backend opencode-client-backend) _session)
  "Refuse to resume: opencode has no native resume picker.
Use `opencode-client-switch-session' to pick a past session instead."
  (user-error "opencode: no native resume picker; use `opencode-client-switch-session'"))

(cl-defmethod agent-backend-seed-history ((backend opencode-client-backend))
  "Seed BACKEND's conversation model from its session's history."
  (opencode-client--seed-history backend))

(cl-defmethod agent-backend-project-root ((_backend opencode-client-backend))
  "Return nil: opencode sessions carry no project scoping."
  nil)

(cl-defmethod agent-backend-render ((backend opencode-client-backend))
  "Re-render BACKEND's conversation buffer."
  (let ((buffer (oref backend buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (opencode-client--render)))))

;;;; Prompting and interaction

(defun opencode-client--transient-backend ()
  "Return a transient backend instance for server-level operations.
Used by commands that need a backend object but are not bound to a
conversation buffer (connect, list-sessions)."
  (make-instance 'opencode-client-backend))

(defun opencode-client--active-backend ()
  "Return the backend instance for the active session.
Uses the current buffer's instance when bound to a session; otherwise a
transient instance around `opencode-client--active-session' carrying the
current project's server host/port."
  (let ((instance (opencode-client--instance)))
    (if (and instance (oref instance session-id))
        instance
      (let ((server (opencode-client--ensure-server)))
        (make-instance 'opencode-client-backend
                       :session-id opencode-client--active-session
                       :host (oref server host)
                       :port (oref server port))))))

;;;###autoload
(defun opencode-client-send-prompt (text &optional steer)
  "Send TEXT as a prompt to the active session.
With prefix arg STEER, deliver it as a steering message mid-turn --
the shared note path (`agent-backend-add-note')."
  (interactive (list (read-string "Prompt: ") current-prefix-arg))
  (let ((backend (opencode-client--active-backend)))
    (if steer
        (agent-backend-add-note backend text)
      (agent-backend-send backend text))))

;;;###autoload
(defun opencode-client-interrupt ()
  "Interrupt the running turn in the active session."
  (interactive)
  (agent-backend-interrupt (opencode-client--active-backend)))

(defun opencode-client--reply-permission (backend id request-id decision)
  "Reply DECISION to permission REQUEST-ID of session ID on BACKEND's server."
  (opencode-client--request
   'post (format "/api/session/%s/permission/%s/reply" id request-id)
   `((decision . ,decision)) backend))

;;;###autoload
(defun opencode-client-answer-permission (request-id)
  "Prompt the user to allow or deny permission REQUEST-ID in the active session."
  (interactive (list (read-string "Permission request id: ")))
  (agent-backend-reply-permission
   (opencode-client--active-backend) request-id
   (if (y-or-n-p "opencode: allow this request? ") "allow" "deny")))

(defun opencode-client--reply-question (backend id request-id answer)
  "Reply ANSWER to question REQUEST-ID of session ID on BACKEND's server."
  (opencode-client--request
   'post (format "/api/session/%s/question/%s/reply" id request-id)
   `((answer . ,answer)) backend))

;;;###autoload
(defun opencode-client-answer-question (request-id)
  "Prompt the user to answer question REQUEST-ID in the active session."
  (interactive (list (read-string "Question request id: ")))
  (agent-backend-reply-question
   (opencode-client--active-backend) request-id (read-string "Answer: ")))

;;;; Major mode

(defvar opencode-client-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'opencode-client-send-prompt)
    (define-key map (kbd "C-c C-k") #'opencode-client-interrupt)
    (define-key map (kbd "g")       #'opencode-client-send-prompt)
    map)
  "Keymap for `opencode-client-mode'.")

(define-derived-mode opencode-client-mode agent-backend-mode "opencode"
  "Major mode for an opencode chat buffer."
  (setq-local truncate-lines nil)
  (add-hook 'kill-buffer-hook #'opencode-client--stop-stream nil t))

(provide 'opencode-client)

;;; opencode-client.el ends here
