;;; opencode-client.el --- Native Emacs client for the opencode HTTP API -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.13.0
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

;; A native Emacs client for OpenCode V2's HTTP API (`opencode serve').
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
(require 'url-util)
(require 'plz nil t)
(require 'agent-backend)
(require 'agent-prompt)
(require 'agent-question)
(require 'agent-permission)

;; Soft dependency: prose is fontified as markdown when `markdown-mode' is
;; installed, and rendered plain when it is not.
(require 'markdown-mode nil t)
(declare-function gfm-view-mode "markdown-mode" ())

(declare-function plz "plz"
                   (method url &rest rest))
(declare-function evil-local-set-key "evil-core" (state key definition))
(defvar plz-curl-default-args)

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

(defcustom opencode-client-reconnect-delay 2
  "Seconds before retrying a disconnected V2 event stream."
  :type 'number
  :group 'opencode-client)

(defcustom opencode-client-request-timeout 30
  "Seconds allowed for a V2 control request, excluding the event stream."
  :type 'number
  :group 'opencode-client)

(defcustom opencode-client-discover-service t
  "Reuse OpenCode's registered shared service when available.
Set nil to use only the explicitly configured host, port and credentials."
  :type 'boolean
  :group 'opencode-client)

(defcustom opencode-client-tool-input-lines 4
  "Legacy input line limit, no longer used.
Collapsed details are single-line previews; use
`opencode-client-tool-preview-chars' to control their length."
  :type '(choice (const :tag "All" nil) (integer :tag "Lines"))
  :group 'opencode-client)

(defcustom opencode-client-tool-result-lines 6
  "Legacy result line limit, no longer used.
Collapsed details are single-line previews; use
`opencode-client-tool-preview-chars' to control their length."
  :type '(choice (const :tag "All" nil) (integer :tag "Lines"))
  :group 'opencode-client)

(make-obsolete-variable 'opencode-client-tool-input-lines
                        'opencode-client-tool-preview-chars "2026-11-25")
(make-obsolete-variable 'opencode-client-tool-result-lines
                        'opencode-client-tool-preview-chars "2026-11-25")

(defcustom opencode-client-tool-preview-chars 80
  "Maximum characters per collapsed input or result preview.
Includes the trailing `…' when truncated, but excludes indentation and
the section label.  Values below 1 are treated as 1.  Whitespace is folded
onto one line.  TAB reveals the full original multiline details without
changing the underlying conversation."
  :type 'integer
  :group 'opencode-client)

(defvar-local opencode-client--expanded-tools nil
  "Stable part IDs of tool calls expanded in this conversation.")

;;;; State

(defvar opencode-client--active-session nil
  "Last selected session ID, for compatibility with existing callers.")

(defvar opencode-client--active-sessions nil
  "Alist of project directories and their last selected session IDs.")

(defvar opencode-client--generated-password nil
  "In-memory password for a standalone server started by this client.")

;;;; The backend class

(defclass opencode-client-backend (agent-backend)
  ((host :initarg :host :initform nil
         :documentation "Host of this backend's own server, or nil for the default.")
   (port :initarg :port :initform nil
         :documentation "Port of this backend's own server, or nil for the default.")
   (password :initarg :password :initform nil
             :documentation "Basic-auth password for this backend's server, or nil to resolve from the defcustoms.")
   (messages :initarg :messages :initform nil
             :documentation "Ordered list of message IDs seen in this chat buffer.")
   (parts :initarg :parts
          :initform (make-hash-table :test 'equal)
          :documentation "Hash table mapping part ID -> part alist.")
   (message-parts :initarg :message-parts
                  :initform (make-hash-table :test 'equal)
                  :documentation "Hash table mapping message ID -> ordered part IDs.")
    (directory :initarg :directory :initform nil
               :documentation "Absolute V2 session location directory.")
    (turn-state :initform 'finished
                :documentation "Observed execution state, never inferred from output.")
    (turn-started :initform nil
                  :documentation "Execution start time in seconds, or nil.")
    (seen-events :initform (make-hash-table :test 'equal)
                 :documentation "Recent event IDs, for duplicate suppression.")
    (forms :initform (make-hash-table :test 'equal)
           :documentation "Pending V2 forms, indexed by form ID.")
    (permissions :initform (make-hash-table :test 'equal)
                 :documentation "Pending permission IDs owned by this backend.")
    (stopped :initform t :documentation "Non-nil after an explicit disconnect.")
    (generation :initform 0 :documentation "Stream generation rejecting old callbacks.")
    (reconnect-timer :initform nil :documentation "Pending reconnect timer.")
    (refresh-timer :initform nil :documentation "Pending reconciliation timer.")
    (refresh-needed :initform nil :documentation "Events arrived during reconciliation.")
    (syncing :initform nil :documentation "Non-nil while fetching authoritative state.")
    (synchronized :initform nil :documentation "History has been loaded for this stream.")
    (connected :initform nil :documentation "The event stream sent its connection marker.")
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
  (let ((host (or (and backend (oref backend host)) opencode-client-host)))
    (format "http://%s:%d"
            (if (and (string-search ":" host) (not (string-prefix-p "[" host)))
                (concat "[" host "]") host)
            (or (and backend (oref backend port)) opencode-client-port))))

(defun opencode-client--password (&optional backend)
  "Return BACKEND's password, then configured or generated credentials.
A discovered endpoint owns its credential; never replace it with another
server's global password."
  (or (and backend (oref backend password))
      opencode-client-password
      (and opencode-client-password-command
           (let ((out (string-trim
                       (shell-command-to-string opencode-client-password-command))))
             (unless (string-empty-p out) out)))
      opencode-client--generated-password))

(defun opencode-client--headers (&optional backend)
  "Return BACKEND's request headers, adding basic auth when a password
resolves."
  (append
   '(("Content-Type" . "application/json"))
    (when-let* ((pw (opencode-client--password backend)))
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
                           (list :headers (opencode-client--headers backend)
                                 :timeout opencode-client-request-timeout
                                 :as (lambda ()
                                       (unless (eobp) (json-read))))
                           (when (or body (memq method '(post put patch)))
                             (list :body (json-encode
                                          (or body (make-hash-table)))))))))
        res)
    (error (user-error "opencode request failed (%s %s): %s"
                       method path (error-message-string err)))))

(defun opencode-client--unwrap (res)
  "Return RES's V2 data payload, or RES when it has no envelope."
  (if (and (consp res) (consp (car res)) (assq 'data res))
      (alist-get 'data res)
     res))

(defun opencode-client--data (method path &optional body backend)
  "Request METHOD PATH with BODY on BACKEND and unwrap its data envelope."
  (opencode-client--unwrap
   (opencode-client--request method path body backend)))

(defun opencode-client--pages (path backend)
  "Read all V2 pages at PATH on BACKEND without discarding cursors.
PATH selects ascending order; following pages must omit the order argument."
  (let ((next path) (seen nil) (items nil))
    (while next
      (let* ((page (opencode-client--request 'get next nil backend))
             (cursor (alist-get 'next (alist-get 'cursor page))))
        (setq items (nconc items (opencode-client--unwrap page)))
        (when (member cursor seen)
          (user-error "opencode: repeated pagination cursor"))
        (push cursor seen)
        (setq next
              (when cursor
                (concat (replace-regexp-in-string
                         "[?&]order=[^&]*" "" path)
                        (if (string-match-p "?" (replace-regexp-in-string
                                                 "[?&]order=[^&]*" "" path))
                            "&" "?")
                        "cursor=" (url-hexify-string cursor))))))
    items))

(defun opencode-client--directory (&optional backend)
  "Return BACKEND's location, or the current project's directory."
  (directory-file-name
   (expand-file-name
    (or (and backend (oref backend directory))
        (opencode-client--project-root)))))

(defun opencode-client--session-path (backend &optional suffix)
  "Return BACKEND's session route, followed by optional SUFFIX."
  (unless (oref backend session-id) (user-error "opencode: no active session"))
  (concat "/api/session/" (url-hexify-string (oref backend session-id)) suffix))

;;;; Connection

(defun opencode-client--health (&optional backend)
  "Return non-nil when BACKEND's server answers its liveness probe.
nil BACKEND probes the default server.  opencode 2.x removed `/api/health';
`/api/info' (which reports version and pid) is the probe for a live server."
  (ignore-errors
    (let ((version (alist-get 'version
                             (opencode-client--request 'get "/api/info" nil backend))))
      (and (stringp version) (string-prefix-p "2." version)))))

;;;; Shared background service discovery

(defun opencode-client--service-file ()
  "Return the shared service registration path, respecting XDG_STATE_HOME."
  (expand-file-name "opencode/service.json"
                    (or (getenv "XDG_STATE_HOME")
                        (expand-file-name "~/.local/state"))))

(defun opencode-client--url-host-port (url)
  "Return (HOST . PORT) for a local HTTP service URL, or nil.
Only HTTP is supported by this transport; do not silently downgrade HTTPS."
  (when (and (stringp url)
             (string-match
              "\\`http://\\(\\[[^]]+\\]\\|[^/:]+\\):\\([0-9]+\\)/?\\'" url))
    (let ((host (match-string 1 url))
          (port (string-to-number (match-string 2 url))))
      (when (<= 1 port 65535)
        (cons (string-remove-suffix "]" (string-remove-prefix "[" host)) port)))))

(defun opencode-client--discover ()
  "Return a healthy V2 backend from the shared service registration, or nil.
Discovery never starts, restarts or changes the managed service."
  (when opencode-client-discover-service
    (let ((json-object-type 'alist)
          (json-array-type 'list)
          (file (opencode-client--service-file)))
      (when (file-readable-p file)
        (let* ((registration
                (ignore-errors
                  (with-temp-buffer
                    (insert-file-contents file)
                    (goto-char (point-min))
                    (json-read))))
               (host-port (opencode-client--url-host-port
                           (and (listp registration) (alist-get 'url registration)))))
          (when host-port
            (let ((backend (make-instance 'opencode-client-backend
                                          :host (car host-port) :port (cdr host-port)
                                          :password (alist-get 'password registration))))
              (and (opencode-client--health backend) backend))))))))

;;;###autoload
(defun opencode-client-connect ()
  "Verify the configured opencode server is reachable."
  (interactive)
  (agent-backend-connect (opencode-client--transient-backend)))

;;;###autoload
;;;; One explicit V2 service, with project-scoped session locations

(defvar opencode-client--servers nil
  "Project directory to backend mapping, all using the configured V2 service.")

(defvar opencode-client--server-process nil
  "Standalone server started by this client, if any.")

(defun opencode-client--ensure-server ()
  "Return a project-scoped connection, preferring a registered V2 service.
Reuse healthy project connections first; otherwise discover the shared
service before falling back to a configured standalone endpoint."
  (let* ((dir (opencode-client--directory))
          (backend (cdr (assoc dir opencode-client--servers))))
    (cond
     ((and backend (opencode-client--health backend)) backend)
     ((setq backend (opencode-client--discover))
      (oset backend directory dir)
      (setf (alist-get dir opencode-client--servers nil nil #'equal) backend)
      backend)
     (t (opencode-client-serve)))))

;;;###autoload
(defun opencode-client-serve ()
  "Connect to, or start, the configured OpenCode V2 service.
Projects share this endpoint but sessions have explicit locations.
Never replace an occupied port or modify the user's managed service."
  (interactive)
  (let* ((dir (opencode-client--directory))
         (backend (make-instance 'opencode-client-backend
                                 :host opencode-client-host
                                 :port opencode-client-port :directory dir)))
    (unless (opencode-client--health backend)
      (unless (member opencode-client-host '("127.0.0.1" "localhost" "::1"))
        (user-error "opencode: start the remote V2 service separately"))
      (if (and opencode-client-launchd-label (eq system-type 'darwin))
        (unless (zerop (call-process
                        "launchctl" nil nil nil "kickstart"
                        (format "gui/%d/%s"
                                (user-uid) opencode-client-launchd-label)))
          (user-error "opencode: failed to kickstart launchd agent %s"
                      opencode-client-launchd-label))
        (when (process-live-p opencode-client--server-process)
          (user-error "opencode: existing server is unavailable; check its log"))
        (let* ((process-environment (copy-sequence process-environment))
               (password (or (opencode-client--password)
                             (setq opencode-client--generated-password
                                   (secure-hash 'sha256
                                                (format "%s:%s:%s" (random) (float-time)
                                                        (emacs-pid)))))))
          (setenv "OPENCODE_PASSWORD" password)
          (oset backend password password)
          (setq opencode-client--server-process
                (make-process
                 :name "opencode-serve" :buffer " *opencode-serve*" :noquery t
                 :command (list opencode-client-executable "serve"
                                "--hostname" opencode-client-host
                                "--port" (number-to-string opencode-client-port)))))))
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
        (user-error "opencode: expected a V2 server at %s; check version/authentication and *opencode-serve*"
                    (opencode-client--base-url backend))))))

;;;; Sessions

(defun opencode-client--sessions (&optional backend)
  "Return the list of sessions from BACKEND's server."
  (opencode-client--pages
   (concat "/api/session?directory="
           (url-hexify-string (opencode-client--directory backend)) "&order=asc")
   backend))

;;;###autoload
(defun opencode-client-list-sessions ()
  "Message the available opencode sessions."
  (interactive)
  (let ((sessions (agent-backend-list-sessions
                   (opencode-client--ensure-server))))
    (if sessions
        (message "opencode sessions:\n%s"
                 (mapconcat
                  (lambda (s) (format "  %s  %s"
                                      (plist-get s :id)
                                      (plist-get s :label)))
                  sessions "\n"))
      (message "opencode: no sessions"))))

(defun opencode-client--project-root ()
  "Return the project root to scope a session to, or `default-directory'."
  (require 'project nil t)
  (agent-backend--current-project-root))

;;;###autoload
(defun opencode-client-create-session (&optional title)
  "Create a new opencode session on the current project's server.
The server is started on demand if none exists for this project, so
several projects can run their own opencode server in parallel."
  (interactive (list (read-string "Session title: ")))
  (let* ((backend (opencode-client--ensure-server))
         (body `((location . ((directory . ,(opencode-client--directory backend))))
                 ,@(when (and title (not (string-empty-p title))) `((title . ,title)))))
         (session (opencode-client--data 'post "/api/session" body backend))
         (id (alist-get 'id session)))
    (unless id (user-error "opencode: server returned no session ID"))
    (opencode-client--open-buffer id (or (alist-get 'title session) title id) nil backend)
    (message "opencode: created session %s" id)
    id))

;;;###autoload
(defun opencode-client-open ()
  "Create a session and open a prompt composition for it.
Mirrors `claude-client-open': a bare `opencode-client-create-session'
lands you in an empty, read-only conversation buffer with no obvious way
to type.  This shows the conversation and opens its prompt buffer right
away, so you start typing instead of facing a dead buffer."
  (interactive)
  (opencode-client-create-session)
  (let ((buffer (window-buffer (selected-window))))
    (when (with-current-buffer buffer (derived-mode-p 'opencode-client-mode))
      (agent-prompt-read
       (lambda (text)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (opencode-client-send-prompt text))))
       nil (buffer-name buffer) (selected-window)))))

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
    (opencode-client--open-buffer id pick t backend)))

;;;###autoload
(defun opencode-client-delete-session (id)
  "Delete the opencode session ID from the current buffer's server."
  (interactive (list (or (and (opencode-client--instance)
                              (oref (opencode-client--instance) session-id))
                         (oref (opencode-client--active-backend) session-id))))
  (let ((backend (or (opencode-client--instance)
                      (opencode-client--ensure-server))))
    (opencode-client--request 'delete (format "/api/session/%s" id) nil backend)
    (when-let* ((buffer (opencode-client--conversation id backend)))
      (agent-backend-quit (buffer-local-value 'agent-backend--instance buffer))))
  (setq opencode-client--active-sessions
        (seq-remove (lambda (entry) (equal (cdr entry) id))
                    opencode-client--active-sessions))
  (when (equal id opencode-client--active-session)
    (setq opencode-client--active-session nil))
  (message "opencode: deleted session %s" id))

;;;; Conversation model

(defun opencode-client--buffer-name (title)
  "Return the chat buffer name for session TITLE."
  (format "*opencode:%s*" title))

(defun opencode-client--conversation (id server)
  "Find the conversation for session ID on SERVER by identity, not title."
  (seq-find
   (lambda (buffer)
     (let ((instance (buffer-local-value 'agent-backend--instance buffer)))
       (and (eieio-object-p instance)
            (object-of-class-p instance 'opencode-client-backend)
            (equal id (oref instance session-id))
            (equal (opencode-client--base-url instance)
                   (opencode-client--base-url server)))))
   (buffer-list)))

(defun opencode-client--open-buffer (id title &optional resumed server)
  "Open (creating if needed) the chat buffer for session ID/TITLE, and stream.
Carry SERVER's endpoint and explicit directory, subscribe, then recover
history from the connection marker.  Publish `started' or `resumed'."
  (let* ((directory (opencode-client--directory server))
         (buf (or (opencode-client--conversation id server)
                  (generate-new-buffer (opencode-client--buffer-name title)))))
    (setq opencode-client--active-session id)
    (setf (alist-get directory opencode-client--active-sessions nil nil #'equal) id)
    (with-current-buffer buf
      (when (opencode-client--instance)
        (agent-backend-quit (opencode-client--instance)))
      (unless (derived-mode-p 'opencode-client-mode)
        (opencode-client-mode))
      (setq default-directory (file-name-as-directory directory))
      (let ((backend (make-instance 'opencode-client-backend
                                    :session-id id
                                    :buffer buf
                                    :host (and server (oref server host))
                                    :port (and server (oref server port))
                                    :password (and server (oref server password))
                                    :directory directory)))
        (setq-local agent-backend--instance backend)
        ;; Subscribe first.  server.connected triggers history/state recovery;
        ;; history-before-subscribe would lose events in between the two.
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
  (opencode-client--load-history
   backend (opencode-client--pages
            (concat (opencode-client--session-path backend "/message") "?order=asc") backend)))

(defun opencode-client--load-history (backend history)
  "Replace BACKEND's projection with already fetched chronological HISTORY."
  (oset backend messages nil)
  (clrhash (oref backend parts))
  (clrhash (oref backend message-parts))
  (dolist (msg history)
    (when-let* ((mid (alist-get 'id msg)))
      (dolist (part (opencode-client--history-parts mid (alist-get 'type msg) msg))
        (opencode-client--put-part backend mid (alist-get 'id part) part)))))

(defun opencode-client--history-parts (mid mtype msg)
  "Return render-model parts for history message MSG with id MID, type MTYPE."
  (if (equal mtype "user")
      (list `((id . ,(format "%s:text" mid))
               (type . "text")
              (role . "user")
              (text . ,(or (alist-get 'text msg) ""))))
    ;; assistant (and other content-bearing) messages carry a `content' array
    (cl-loop for item in (alist-get 'content msg)
             for ordinal from 0 collect
       (let ((item (copy-tree item)))
         (setf (alist-get 'id item)
               (opencode-client--part-id mid ordinal (alist-get 'id item)))
         (if (equal (alist-get 'type item) "tool")
           ;; renderer reads the `tool' key; history uses `name'.
           (cons (cons 'tool (alist-get 'name item)) item)
           item)))))

(defun opencode-client--part-id (message ordinal &optional tool-id)
  "Return a stable render ID for MESSAGE's ORDINAL or TOOL-ID."
  (format "%s:%s" message (or tool-id ordinal)))

(defun opencode-client--put-part (backend message id part)
  "Upsert PART at ID in BACKEND's MESSAGE without duplicating ordering."
  (puthash id part (oref backend parts))
  (unless (member message (oref backend messages))
    (oset backend messages (append (oref backend messages) (list message))))
  (unless (member id (gethash message (oref backend message-parts)))
    (puthash message (append (gethash message (oref backend message-parts)) (list id))
             (oref backend message-parts))))

(defun opencode-client--apply-event (buffer event)
  "Apply a V2 EVENT for BUFFER's session only.
Durable and transient events have IDs, but only durable events have sequence
numbers.  Never use one global sequence to discard transient deltas."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* ((backend (opencode-client--instance)))
        (let* ((type (alist-get 'type event))
               (data (alist-get 'data event))
               (form (alist-get 'form data))
               (id (alist-get 'id event)))
          (cond
           ((equal type "server.connected")
            (oset backend connected t)
            (oset backend synchronized nil)
            (opencode-client--schedule-refresh backend))
           ((not (equal (oref backend session-id)
                        (or (alist-get 'sessionID data) (alist-get 'sessionID form)))) nil)
           ((and id (gethash id (oref backend seen-events))) nil)
           (t
            (when (> (hash-table-count (oref backend seen-events)) 4096)
              (clrhash (oref backend seen-events)))
            (when id (puthash id t (oref backend seen-events)))
            (let ((racing (or (oref backend syncing)
                              (not (oref backend synchronized)))))
              (when racing (oset backend refresh-needed t))
              (if (and racing (string-suffix-p ".delta" type))
                  ;; A snapshot may already contain these bytes.  Suppress
                  ;; ambiguous render deltas, not the actual live transcript.
                  (when (equal type "session.text.delta")
                    (agent-backend--publish
                     buffer (list :kind 'text :text (alist-get 'delta data))))
                ;; Lifecycle, tool completions and approvals must still reach
                ;; subscribers even while the display is reconciling history.
                (opencode-client--dispatch-event backend buffer type data event))))))))))

(defun opencode-client--dispatch-event (backend buffer type data event)
  "Translate TYPE/DATA from V2 EVENT into BACKEND state and shared events."
  (pcase type
    ("session.execution.started"
     (oset backend turn-state 'working)
     (oset backend turn-started (/ (or (alist-get 'created event) (* 1000 (float-time))) 1000.0))
     (agent-backend--publish buffer (list :kind 'working)))
    ((or "session.execution.succeeded" "session.execution.failed" "session.execution.interrupted")
     (oset backend turn-state 'idle)
     (oset backend turn-started nil)
     (when (equal type "session.execution.failed")
       (agent-backend--publish buffer (list :kind 'error :text (opencode-client--error-text data))))
     (agent-backend--publish
      buffer (list :kind (if (equal type "session.execution.interrupted") 'interrupted 'finished)
                   :subtype type))
     (opencode-client--schedule-refresh backend))
    ("session.inbox.enqueued"
     (let* ((item (alist-get 'item data))
            (mid (alist-get 'inboxID data))
            (text (alist-get 'text (alist-get 'payload item))))
       (when (and mid (equal (alist-get 'type item) "user") (stringp text))
         (let ((pid (format "%s:text" mid)))
           (opencode-client--put-part
            backend mid pid `((id . ,pid) (type . "text") (role . "user") (text . ,text)))
           ;; Local sends already publish prompt.  The inbox event updates
           ;; the display without duplicating the transcript entry.
           (agent-backend-render backend)))))
    ((or "session.text.started" "session.text.delta" "session.text.ended"
         "session.reasoning.started" "session.reasoning.delta" "session.reasoning.ended")
     (let* ((mid (alist-get 'assistantMessageID data))
            (pid (opencode-client--part-id mid (alist-get 'ordinal data)))
            (part (or (gethash pid (oref backend parts))
                      `((id . ,pid) (type . ,(if (string-prefix-p "session.text." type)
                                                "text" "reasoning")) (text . "")))))
       (setf (alist-get 'text part)
             (if (string-suffix-p ".delta" type)
                 (concat (alist-get 'text part) (alist-get 'delta data))
               (or (alist-get 'text data) (alist-get 'text part))))
       (opencode-client--put-part backend mid pid part)
       (when (and (equal (alist-get 'type part) "text") (string-suffix-p ".delta" type))
         (agent-backend--publish buffer (list :kind 'text :text (alist-get 'delta data))))
       (agent-backend-render backend)))
    ((or "session.tool.input.started" "session.tool.called" "session.tool.success" "session.tool.failed")
     (let* ((mid (alist-get 'assistantMessageID data))
            (pid (opencode-client--part-id mid nil (alist-get 'id data)))
            (part (or (gethash pid (oref backend parts)) `((id . ,pid) (type . "tool"))))
            (time (copy-tree (alist-get 'time part)))
            (created (alist-get 'created event)))
       (when (numberp created)
         (setf (alist-get (pcase type
                           ("session.tool.input.started" 'created)
                           ("session.tool.called" 'ran)
                           (_ 'completed)) time) created)
         (setf (alist-get 'time part) time))
       (when (alist-get 'name data) (setf (alist-get 'tool part) (alist-get 'name data)))
       (pcase type
         ("session.tool.input.started" (setf (alist-get 'state part) '((status . "streaming"))))
         ("session.tool.called"
          (setf (alist-get 'state part) `((status . "running") (input . ,(alist-get 'input data))))
          (agent-backend--publish buffer (list :kind 'tool-use :name (alist-get 'tool part)
                                               :id (alist-get 'id data) :input (alist-get 'input data))))
         (_
          (setf (alist-get 'state part)
                `((status . ,(if (equal type "session.tool.failed") "error" "completed"))
                  ,@(when-let* ((input (assq 'input (alist-get 'state part))))
                      (list (copy-tree input)))
                  (content . ,(alist-get 'content data)) (error . ,(alist-get 'error data))))
          (agent-backend--publish
           buffer (list :kind 'tool-result :name (alist-get 'tool part) :id (alist-get 'id data)
                        :status (if (equal type "session.tool.failed") 'failed 'done)
                        :text (or (opencode-client--tool-result-text part)
                                  (opencode-client--error-text data))))))
       (opencode-client--put-part backend mid pid part)
       (agent-backend-render backend)))
    ("permission.asked" (opencode-client--ask-permission backend buffer data))
    ("session.deleted" (agent-backend-quit backend))
    ("permission.replied"
     (opencode-client--dismiss-permission backend (alist-get 'requestID data)))
    ("form.created" (opencode-client--ask-question backend buffer (alist-get 'form data)))
    ((or "form.replied" "form.cancelled")
     (opencode-client--dismiss-form backend (alist-get 'id data)))
    ((or "session.inbox.delivered" "session.message.content.updated" "session.moved")
     (opencode-client--schedule-refresh backend))
    (_ nil)))

(defun opencode-client--error-text (data)
  "Return a readable V2 structured error from DATA."
  (let ((err (alist-get 'error data)))
    (and err (or (alist-get 'message err) (format "%s" err)))))

(defun opencode-client--permission-input (data)
  "Return the tool input to show for permission event DATA.
`resources' is the list of things the call would touch, which is the
part a human actually judges; the older shape carries the same under
`permission'."
  (let ((resources (append (alist-get 'resources data) nil))
        (legacy (alist-get 'permission data)))
    (cond
     (resources `((command . ,(mapconcat (lambda (r) (format "%s" r))
                                         resources "\n"))))
     (legacy (if (consp legacy) legacy `((command . ,(format "%s" legacy)))))
     (t nil))))

(defun opencode-client--ask-permission (backend buffer data)
  "Raise permission event DATA from BACKEND as a decision in BUFFER.
Answers through the shared `agent-permission' menu rather than a
`y-or-n-p', so opencode's gate and Claude's hook look the same to the
human.  Nothing here waits: the reply is posted from the menu's
continuation, and opencode holds the call open until it arrives."
  (when-let* ((request-id (alist-get 'id data)))
    (puthash request-id t (oref backend permissions))
    (agent-backend--publish
     buffer (list :kind 'permission-request :id request-id))
    (let ((ui-id (opencode-client--ui-id backend request-id)))
      (unless (member ui-id (agent-permission-pending-ids))
        (let ((menu
               (agent-permission-request
                ui-id (or (alist-get 'action data) "opencode")
                (opencode-client--permission-input data)
                :cwd (agent-backend-project-root backend)
                :window (get-buffer-window buffer)
                ;; V2 waits for the human, so do not invent a UI deadline.
                :resolve
                (lambda (decision _reason)
                  (agent-backend-reply-permission
                   backend request-id
                   (pcase decision
                     ('allow "once") ('always "always") (_ "reject")))))))
          (when (bufferp menu)
            (with-current-buffer menu
              ;; The shared UI's A writes Claude rules.  V2 persists its own
              ;; permissions; never write .claude settings from this backend.
              (use-local-map (copy-keymap agent-permission-mode-map))
              (local-set-key (kbd "A")
                             (lambda ()
                               (interactive)
                               (when (yes-or-no-p
                                      (format "Save OpenCode %s permissions for %S? "
                                              (alist-get 'action data)
                                              (or (alist-get 'save data)
                                                  (alist-get 'resources data))))
                                 (agent-permission--resolve ui-id 'always))))
              (local-set-key (kbd "z") #'undefined)
              ;; Evil's state maps outrank the ordinary local map.  Without
              ;; these, its A could still call the Claude settings writer.
              (when (fboundp 'evil-local-set-key)
                (dolist (state '(normal motion))
                  (evil-local-set-key state (kbd "A")
                                      (lookup-key (current-local-map) (kbd "A")))
                  (evil-local-set-key state (kbd "z") #'undefined)))
              (setq-local header-line-format "a allow once   d deny   A save in OpenCode"))))))))

(defun opencode-client--ui-id (backend request-id)
  "Namespace REQUEST-ID by BACKEND's endpoint and session."
  (format "opencode:%s:%s:%s" (opencode-client--base-url backend)
          (oref backend session-id) request-id))

(defun opencode-client--dismiss-permission (backend id)
  "Close BACKEND's permission ID without sending a second decision."
  (remhash id (oref backend permissions))
  (when-let* ((entry (agent-permission--take (opencode-client--ui-id backend id)))
              (buffer (plist-get entry :buffer)))
    (agent-permission--close buffer)))

(defun opencode-client--tool-result-text (part)
  "Return the result text of a completed tool PART, or nil.
V2 carries output blocks in state.content, not the V1 output string."
  (let ((state (alist-get 'state part)))
    (when (listp state)
      (let ((output (mapconcat
                     (lambda (content) (or (alist-get 'text content) ""))
                     (alist-get 'content state) "\n")))
        (and (stringp output)
             (not (string-empty-p (string-trim output)))
             output)))))

(defun opencode-client--ask-question (backend buffer data)
  "Present every field of V2 form DATA through BUFFER's question UI."
  (let ((id (alist-get 'id data)))
    (unless (gethash id (oref backend forms))
      (puthash id data (oref backend forms))
      (agent-backend--publish buffer (list :kind 'question-request :id id))
      (opencode-client--form-next backend data (alist-get 'fields data)
                                  (make-hash-table :test 'equal)))))

(defun opencode-client--form-visible-p (field answers)
  "Whether FIELD is visible given previously collected ANSWERS."
  (and (not (eq (alist-get 'hidden field) t))
       (cl-every
        (lambda (condition)
          (let ((equal-p (equal (gethash (alist-get 'key condition) answers)
                                (alist-get 'value condition))))
            (if (equal (alist-get 'op condition) "neq") (not equal-p) equal-p)))
        (alist-get 'when field))))

(defun opencode-client--form-value (field text)
  "Convert answer TEXT to FIELD's V2 value, preserving option values."
  (let* ((options (alist-get 'options field))
         (option (seq-find (lambda (o) (equal text (alist-get 'label o))) options)))
    (pcase (alist-get 'type field)
      ("boolean" (cond ((member (downcase text) '("yes" "true")) t)
                        ((member (downcase text) '("no" "false")) :json-false)
                        (t (user-error "Answer Yes or No"))))
      ((or "number" "integer")
       (let ((value (json-parse-string text)))
         (unless (and (numberp value)
                      (or (equal (alist-get 'type field) "number") (integerp value)))
           (user-error "A %s is required" (alist-get 'type field)))
         value))
      ("multiselect"
       (vconcat
        (mapcar (lambda (label)
                  (or (alist-get 'value
                                 (seq-find (lambda (o) (equal label (alist-get 'label o))) options))
                      label))
                (split-string text "," t "[ \t\n]+"))))
      ("external" (user-error "Answer URL forms in OpenCode's web or terminal interface"))
      (_ (or (alist-get 'value option) text)))))

(defun opencode-client--form-next (backend form fields answers)
  "Collect FIELDS of FORM into ANSWERS, then reply once through BACKEND."
  (let* ((id (alist-get 'id form))
         (field (car fields))
         (ui-id (opencode-client--ui-id backend id)))
    (when (gethash id (oref backend forms))
      (cond
       ((null fields) (agent-backend-reply-question backend id answers))
       ((not (opencode-client--form-visible-p field answers))
        (opencode-client--form-next backend form (cdr fields) answers))
       (t
        (agent-question-request
         ui-id
         (string-join
          (delq nil (list (alist-get 'title form)
                          (or (alist-get 'title field) (alist-get 'key field))
                          (alist-get 'description field)
                          (when (equal (alist-get 'type field) "external")
                            (concat "OpenCode URL form: " (alist-get 'url field)
                                    "\nAnswer in OpenCode, or cancel this form with C-c C-k."))
                          (when (equal (alist-get 'type field) "multiselect")
                            (concat "Comma-separated choices: "
                                    (mapconcat (lambda (o) (alist-get 'label o))
                                               (alist-get 'options field) ", "))))) "\n")
         (pcase (alist-get 'type field)
           ("boolean" '("Yes" "No"))
           ("string" (mapcar (lambda (o) (alist-get 'label o)) (alist-get 'options field))))
         :window (get-buffer-window (oref backend buffer))
         :resolve
         (lambda (answer)
           (when (gethash id (oref backend forms))
             (condition-case err
                 (progn
                   (puthash (alist-get 'key field)
                            (opencode-client--form-value field answer) answers)
                   (opencode-client--form-next backend form (cdr fields) answers))
               (error
                (message "opencode form: %s" (error-message-string err))
                (opencode-client--form-next backend form fields answers))))))
        (when-let* ((entry (assoc ui-id agent-question--pending)))
          (with-current-buffer (plist-get (cdr entry) :buffer)
            (use-local-map (copy-keymap agent-question-mode-map))
            (local-set-key (kbd "C-c C-k")
                           (lambda ()
                             (interactive)
                             (opencode-client--data 'delete
                              (concat (opencode-client--session-path backend "/form/")
                                      (url-hexify-string id)) nil backend)
                             (opencode-client--dismiss-form backend id))))))))))

(defun opencode-client--dismiss-form (backend id)
  "Close BACKEND's form ID without sending a stale reply."
  (remhash id (oref backend forms))
  (when-let* ((entry (agent-question--take (opencode-client--ui-id backend id)))
              (buffer (plist-get entry :buffer)))
    (agent-question--close buffer)))

;;;; Faces

(defface opencode-client-prompt-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for a prompt the human sent."
  :group 'opencode-client)

(defface opencode-client-reasoning-face
  '((t :inherit shadow :slant italic))
  "Face for the model's reasoning."
  :group 'opencode-client)

(defface opencode-client-tool-face
  '((t :inherit font-lock-function-name-face))
  "Face for a tool call's name."
  :group 'opencode-client)

(defface opencode-client-tool-running-face
  '((t :inherit warning))
  "Face for a tool call still running."
  :group 'opencode-client)

(defface opencode-client-tool-ok-face
  '((t :inherit success))
  "Face for a tool call that succeeded."
  :group 'opencode-client)

(defface opencode-client-tool-error-face
  '((t :inherit error))
  "Face for a tool call that failed."
  :group 'opencode-client)

;;;; Rendering

(defvar opencode-client--fontify-buffer nil
  "Scratch buffer used to fontify markdown, or nil before first use.")

(defun opencode-client--fontify-markdown (text)
  "Return TEXT with markdown text properties applied.
Fontification happens in a scratch buffer whose properties are copied
out, so no markdown mode is active in the conversation buffer.  When
`markdown-mode' is absent TEXT is returned unchanged, so prose reads
plain rather than not at all."
  (if (or (string-empty-p text) (not (fboundp 'gfm-view-mode)))
      text
    (unless (buffer-live-p opencode-client--fontify-buffer)
      (setq opencode-client--fontify-buffer
            (get-buffer-create " *opencode-client-fontify*")))
    (with-current-buffer opencode-client--fontify-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        (setq-local markdown-fontify-code-blocks-natively t)
        (delay-mode-hooks (gfm-view-mode))
        (setq-local markdown-fontify-code-blocks-natively t)
        (font-lock-flush)
        (font-lock-ensure)
        (buffer-string)))))

(defun opencode-client--faced (text face)
  "Return TEXT propertized with FACE.
Uses the `face' property: the conversation buffer is `special-mode' with
font-lock off, where `font-lock-face' would have no effect."
  (propertize text 'face face))

(defun opencode-client--tool-status-face (part)
  "Return the face for PART's tool status."
  (pcase (opencode-client--tool-status part)
    ("completed" 'opencode-client-tool-ok-face)
    ("error" 'opencode-client-tool-error-face)
    (_ 'opencode-client-tool-running-face)))

(defun opencode-client--tool-status (part)
  "Return the lifecycle status of tool PART."
  (let ((state (alist-get 'state part)))
    (if (listp state) (alist-get 'status state) state)))

(defun opencode-client--tool-input-text (part)
  "Return readable arguments for tool PART, or nil before input arrives."
  (let* ((state (alist-get 'state part))
         (input (and (listp state) (assq 'input state))))
    (when input
      (let ((value (cdr input)) (json-encoding-pretty-print t))
        (cond
         ((null value) "(no arguments)")
         ((stringp value) value)
         ((and (listp value) (cl-every #'consp value))
          (mapconcat
           (lambda (entry)
             (format "%s: %s" (car entry)
                     (if (stringp (cdr entry)) (cdr entry) (json-encode (cdr entry)))))
           value "\n"))
         (t (json-encode value)))))))

(defun opencode-client--tool-output-text (part)
  "Return PART's result text, including readable file-attachment labels."
  (let ((state (alist-get 'state part)))
    (when (listp state)
      (mapconcat
       (lambda (content)
         (if (equal (alist-get 'type content) "file")
             (let ((uri (or (alist-get 'uri content) "")))
               (format "[file: %s, %s] %s"
                       (or (alist-get 'name content) "attachment")
                       (or (alist-get 'mime content) "unknown type")
                       (if (string-prefix-p "data:" uri) "(embedded file)" uri)))
           (or (alist-get 'text content) "")))
       (alist-get 'content state) "\n"))))

(defun opencode-client--tool-detail (label text _lines expanded &optional face)
  "Render LABEL and TEXT as a compact preview or full details when EXPANDED.
The legacy _LINES argument is ignored.  FACE styles the section label."
  (when (and (stringp text) (not (string-empty-p text)))
    (if expanded
        (concat
         (opencode-client--faced (concat "    " label ":\n") (or face 'shadow))
         (mapconcat (lambda (line) (concat "      " line))
                    (split-string (string-remove-suffix "\n" text) "\n") "\n")
         "\n")
      (let* ((preview (string-trim (replace-regexp-in-string "[ \t\r\n]+" " " text)))
             (limit (max 1 opencode-client-tool-preview-chars)))
        (when (> (length preview) limit)
          (setq preview (concat (substring preview 0 (1- limit)) "…")))
        (concat
         (opencode-client--faced (concat "    " label ": ") (or face 'shadow))
         preview "\n")))))

(defun opencode-client--tool-duration (part)
  "Return a completed duration for PART, or nil when timestamps are absent."
  (let* ((time (alist-get 'time part))
         (start (or (alist-get 'ran time) (alist-get 'created time)))
         (end (alist-get 'completed time)))
    (when (and (numberp start) (numberp end) (>= end start))
      (let ((seconds (/ (- end start) 1000.0)))
        (if (< seconds 1) (format "%.0fms" (* seconds 1000))
          (format "%.1fs" seconds))))))

(defun opencode-client--render-tool (pid part)
  "Render tool PART at PID with arguments, bounded results and expandable details."
  (let* ((expanded (member pid opencode-client--expanded-tools))
         (state (alist-get 'state part))
         (input (opencode-client--tool-input-text part))
         (output (opencode-client--tool-output-text part))
         (error-text (and (listp state) (opencode-client--error-text state)))
         (duration (opencode-client--tool-duration part)))
    (propertize
     (concat
      "  "
      (opencode-client--faced
       (format "[tool: %s]" (or (alist-get 'name part) (alist-get 'tool part) "unknown"))
       'opencode-client-tool-face)
      " " (opencode-client--faced (or (opencode-client--tool-status part) "")
                                   (opencode-client--tool-status-face part))
      (when duration (opencode-client--faced (concat " · " duration) 'shadow))
      (when (or input (and output (not (string-empty-p output))) error-text)
        (opencode-client--faced (if expanded "  [TAB: collapse]" "  [TAB: expand]") 'shadow))
      "\n"
      (opencode-client--tool-detail "Input" input nil expanded)
      (opencode-client--tool-detail "Result" output nil expanded)
      (opencode-client--tool-detail "Error" error-text nil expanded
                                    'opencode-client-tool-error-face))
     'opencode-client-tool-id pid
     'help-echo "TAB: expand or collapse this tool's input and result")))

(defun opencode-client-toggle-tool-details ()
  "Expand or collapse the tool call at point, without changing remote state."
  (interactive)
  (let ((pid (get-text-property (point) 'opencode-client-tool-id)))
    (unless pid (user-error "No tool call at point"))
    (if (member pid opencode-client--expanded-tools)
        (setq opencode-client--expanded-tools (delete pid opencode-client--expanded-tools))
      (push pid opencode-client--expanded-tools))
    (goto-char (text-property-any (point-min) (point-max) 'opencode-client-tool-id pid))
    (opencode-client--render)))

(defun opencode-client--view-anchor (position)
  "Describe POSITION by stable part identity and offset, or its numeric position."
  (let* ((id (get-text-property position 'opencode-client-part-id))
         (start (and id (text-property-any (point-min) (point-max)
                                          'opencode-client-part-id id))))
    (list id (if start (- position start) position))))

(defun opencode-client--anchor-position (anchor)
  "Resolve a saved view ANCHOR after rendering, clamped to the same part."
  (let* ((id (car anchor))
         (start (and id (opencode-client--part-position id))))
    (if start
        (min (+ start (cadr anchor))
             (1- (next-single-property-change start 'opencode-client-part-id nil (point-max))))
      (min (point-max) (max (point-min) (cadr anchor))))))

(defun opencode-client--part-position (id)
  "Find rendered part ID by value, even after history creates new ID strings."
  (let ((position (point-min)) found)
    (while (and (< position (point-max)) (not found))
      (if (equal id (get-text-property position 'opencode-client-part-id))
          (setq found position)
        (setq position (next-single-property-change
                        position 'opencode-client-part-id nil (point-max)))))
    found))

(defun opencode-client--render-part (pid)
  "Return a rendered string for part PID, or nil to skip it."
  (when-let* ((backend (opencode-client--instance)))
    (let* ((part (gethash pid (oref backend parts)))
           (type (alist-get 'type part)))
      (pcase type
        ("text"
         (if (equal (alist-get 'role part) "user")
             (opencode-client--faced
              (concat "\n>>> " (or (alist-get 'text part) ""))
              'opencode-client-prompt-face)
           (opencode-client--fontify-markdown (or (alist-get 'text part) ""))))
        ("reasoning"
         (opencode-client--faced
          (concat "  · " (or (alist-get 'text part) ""))
          'opencode-client-reasoning-face))
        ("tool" (opencode-client--render-tool pid part))
        (_ nil)))))

(defun opencode-client--render ()
  "Re-render the conversation into the current chat buffer."
  (when-let* ((backend (opencode-client--instance)))
    (let ((at-end (eobp))
          (anchor (opencode-client--view-anchor (point)))
          (views (mapcar
                  (lambda (window)
                    (list window (= (window-point window) (point-max))
                          (opencode-client--view-anchor (window-start window))
                          (opencode-client--view-anchor (window-point window))))
                  (get-buffer-window-list (current-buffer) nil t)))
          (inhibit-read-only t))
      (erase-buffer)
      (dolist (mid (oref backend messages))
        (dolist (pid (gethash mid (oref backend message-parts)))
          (when-let* ((s (opencode-client--render-part pid)))
            (let ((start (point)))
              (insert s)
              (unless (string-suffix-p "\n" s) (insert "\n"))
              (add-text-properties start (point) (list 'opencode-client-part-id pid))))))
      (goto-char (if at-end (point-max) (opencode-client--anchor-position anchor)))
      (dolist (view views)
        (when (window-live-p (car view))
          (set-window-point (car view) (if (cadr view) (point-max)
                                        (opencode-client--anchor-position (nth 3 view))))
          (unless (cadr view)
            (set-window-start (car view) (opencode-client--anchor-position (nth 2 view)) t)))))))

;;;; Streaming (SSE)

(defun opencode-client--start-stream ()
  "Subscribe to V2's shared event endpoint for the current chat buffer.
Each subscriber filters session IDs; unrelated sessions never reach its UI."
  (opencode-client--ensure-plz)
  (opencode-client--stop-stream)
  (when-let* ((backend (opencode-client--instance)))
    (let* ((buffer (current-buffer))
           (generation (cl-incf (oref backend generation)))
           (url (concat (opencode-client--base-url backend) "/api/event"))
           (plz-curl-default-args (cons "--no-buffer" plz-curl-default-args)))
      (oset backend stopped nil)
      (oset backend connected nil)
      (oset backend synchronized nil)
      (oset backend stream-buffer "")
      (oset backend stream-process
            (plz 'get url
               :headers (opencode-client--headers backend)
               :timeout nil
               :as 'response
               :filter (lambda (proc chunk)
                         (when (= generation (oref backend generation))
                           (opencode-client--stream-filter buffer proc chunk)))
               :then (lambda (_response)
                       (opencode-client--disconnected backend generation))
               :else (lambda (_err)
                       (opencode-client--disconnected backend generation))))
      (let* ((process (oref backend stream-process))
             (sentinel (process-sentinel process)))
        ;; plz 0.9 does not recognize Emacs's "deleted" event.  Preserve its
        ;; cleanup, but cover every terminal status ourselves as well as EOF.
        (set-process-sentinel
         process
         (lambda (proc status)
           (unwind-protect
               (when sentinel
                 (funcall sentinel proc (if (equal status "deleted\n") "killed\n" status)))
             (unless (process-live-p proc)
               (opencode-client--disconnected backend generation)))))))))

(defun opencode-client--disconnected (backend generation)
  "Reconnect BACKEND after GENERATION's EOF or error, unless explicitly stopped."
  (when (and (= generation (oref backend generation))
             (not (oref backend stopped)) (buffer-live-p (oref backend buffer)))
    (oset backend synchronized nil)
    (oset backend connected nil)
    (oset backend turn-state 'finished)
    (oset backend turn-started nil)
    (when (timerp (oref backend refresh-timer))
      (cancel-timer (oref backend refresh-timer))
      (oset backend refresh-timer nil))
    (unless (timerp (oref backend reconnect-timer))
      (agent-backend--publish (oref backend buffer)
                             (list :kind 'error :text "OpenCode disconnected; reconnecting"))
      (oset backend reconnect-timer
            (run-at-time opencode-client-reconnect-delay nil
                         (lambda ()
                           (oset backend reconnect-timer nil)
                           (when (and (not (oref backend stopped))
                                      (buffer-live-p (oref backend buffer)))
                             (with-current-buffer (oref backend buffer)
                               (condition-case nil
                                   (opencode-client--start-stream)
                                 (error (opencode-client--disconnected
                                         backend (oref backend generation))))))))))))

(defun opencode-client--schedule-refresh (backend &optional delay)
  "Schedule BACKEND's history recovery outside its filter, after optional DELAY."
  (unless (or (oref backend stopped) (not (oref backend connected))
              (timerp (oref backend refresh-timer)))
    (oset backend refresh-timer
          (run-at-time (or delay 0.1) nil
                       (lambda ()
                         (oset backend refresh-timer nil)
                         (when (and (not (oref backend stopped)) (oref backend connected)
                                    (buffer-live-p (oref backend buffer)))
                           (if (oref backend syncing)
                               (opencode-client--schedule-refresh
                                backend opencode-client-reconnect-delay)
                             (condition-case err
                                 (opencode-client--refresh backend)
                               (error
                                (message "opencode recovery: %s" (error-message-string err))
                                (opencode-client--schedule-refresh
                                 backend opencode-client-reconnect-delay))))))))))

(defun opencode-client--refresh (backend)
  "Reconcile BACKEND with V2 history, execution, permissions and forms.
Never resend a prompt or replay approvals during recovery.  Events arriving
inside a snapshot request trigger another snapshot, not duplicate deltas."
  (oset backend syncing t)
  (oset backend refresh-needed nil)
  (unwind-protect
      (let* ((buffer (oref backend buffer))
             (generation (oref backend generation))
             (info (opencode-client--data
                    'get (opencode-client--session-path backend) nil backend))
             (active (opencode-client--data 'get "/api/session/active" nil backend))
             (permissions (opencode-client--data
                           'get (opencode-client--session-path backend "/permission") nil backend))
             (forms (opencode-client--data
                     'get (opencode-client--session-path backend "/form") nil backend))
             (history (opencode-client--pages
                       (concat (opencode-client--session-path backend "/message") "?order=asc") backend)))
        (when (and (= generation (oref backend generation))
                   (oref backend connected) (not (oref backend stopped)))
          (opencode-client--load-history backend history)
          (when-let* ((directory (alist-get 'directory (alist-get 'location info))))
            (setq directory (directory-file-name (expand-file-name directory)))
            (let ((old (oref backend directory)) (id (oref backend session-id)))
              (when (and old (not (equal old directory))
                         (equal (cdr (assoc old opencode-client--active-sessions)) id))
                (setq opencode-client--active-sessions
                      (assoc-delete-all old opencode-client--active-sessions))
                (unless (assoc directory opencode-client--active-sessions)
                  (push (cons directory id) opencode-client--active-sessions))))
            (oset backend directory directory)
            (with-current-buffer buffer
              (setq default-directory (file-name-as-directory directory))))
          (unless (oref backend refresh-needed)
            ;; Do not overwrite a newer live event with an older inventory.
            (oset backend turn-state
                  (if (alist-get (intern (oref backend session-id)) active)
                      'working 'idle))
            (oset backend turn-started
                  (when (eq (oref backend turn-state) 'working)
                    (let ((busy (alist-get 'busy (alist-get 'time info))))
                      (if busy (/ busy 1000.0) (float-time)))))
            (let (stale)
              (maphash
               (lambda (id _)
                 (unless (seq-find (lambda (p) (equal id (alist-get 'id p))) permissions)
                   (push id stale)))
               (oref backend permissions))
              (dolist (id stale) (opencode-client--dismiss-permission backend id)))
            (let (stale)
              (maphash
               (lambda (id _)
                 (unless (seq-find (lambda (f) (equal id (alist-get 'id f))) forms)
                   (push id stale)))
               (oref backend forms))
              (dolist (id stale) (opencode-client--dismiss-form backend id)))
            (dolist (p permissions) (opencode-client--ask-permission backend buffer p))
            (dolist (f forms) (opencode-client--ask-question backend buffer f)))
          (oset backend synchronized (not (oref backend refresh-needed)))
          (agent-backend-render backend)
          (agent-backend--publish buffer (list :kind 'state-changed))))
    (oset backend syncing nil))
  (when (oref backend refresh-needed) (opencode-client--schedule-refresh backend)))

(defun opencode-client--stop-stream ()
  "Stop the SSE stream process for the current chat buffer, if any."
  (when-let* ((backend (opencode-client--instance)))
    (oset backend stopped t)
    (oset backend connected nil)
    (oset backend synchronized nil)
    (cl-incf (oref backend generation))
    (dolist (timer (list (oref backend reconnect-timer) (oref backend refresh-timer)))
      (when (timerp timer) (cancel-timer timer)))
    (oset backend reconnect-timer nil)
    (oset backend refresh-timer nil)
    (oset backend turn-state 'finished)
    (oset backend turn-started nil)
    (let ((proc (oref backend stream-process)))
      (when (and proc (process-live-p proc))
        (ignore-errors (delete-process proc)))
      (oset backend stream-process nil))))

(defun opencode-client--stream-filter (buffer proc chunk)
  "Frame SSE CHUNK for BUFFER: split on blank lines, parse data payloads."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* ((backend (opencode-client--instance)))
        (oset backend stream-buffer
              (concat (oref backend stream-buffer) chunk))
        ;; SSE frames are separated by a blank line.  Capture the split
        ;; positions before dispatching, since parsing/rendering a frame can
        ;; clobber the global match data.
        (let (start end)
          (while (string-match "\r?\n\r?\n" (oref backend stream-buffer))
            (setq start (match-beginning 0) end (match-end 0))
            (let ((frame (substring (oref backend stream-buffer) 0 start)))
              (oset backend stream-buffer
                    (substring (oref backend stream-buffer) end))
              (if (string-prefix-p "HTTP/" frame)
                  ;; plz needs headers in its process buffer to finish/error
                  ;; correctly, but retaining the whole stream grows forever.
                  (when (and (processp proc) (buffer-live-p (process-buffer proc)))
                    (with-current-buffer (process-buffer proc)
                      (goto-char (point-max))
                      (insert frame "\r\n\r\n")))
                (opencode-client--handle-frame buffer frame)))))))))

(defun opencode-client--handle-frame (buffer frame)
  "Parse one SSE FRAME (its `data:' lines) and apply the event to BUFFER."
  (let ((data (mapconcat
               (lambda (line)
                 (cond
                   ((string-prefix-p "data:" line)
                    (string-remove-prefix " " (substring line 5)))))
                (seq-filter (lambda (line) (string-prefix-p "data:" line))
                            (split-string frame "\r?\n")) "\n")))
    (unless (string-empty-p data)
       (let ((event (ignore-errors
                      (json-parse-string (if (multibyte-string-p data) data
                                           (decode-coding-string data 'utf-8))
                                        :object-type 'alist
                                        :array-type 'list
                                        :null-object nil
                                         :false-object :json-false))))
        (when event
          (condition-case err
              (opencode-client--apply-event buffer event)
            (error
             (message "opencode event: %s" (error-message-string err))
             (when (buffer-live-p buffer)
               (opencode-client--schedule-refresh
                (buffer-local-value 'agent-backend--instance buffer))))))))))

;;;; agent-backend methods

(cl-defmethod agent-backend-connect ((backend opencode-client-backend))
  "Verify BACKEND's server is reachable."
  (if (opencode-client--health backend)
      (message "opencode: connected to %s" (opencode-client--base-url backend))
    (user-error "opencode: cannot reach an authenticated V2 server at %s"
                (opencode-client--base-url backend))))

(cl-defmethod agent-backend-quit ((backend opencode-client-backend))
  "Stop the SSE stream for BACKEND's chat buffer, if any."
  (let ((buffer (oref backend buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (opencode-client--stop-stream)
        (let (ids)
          (maphash (lambda (id _) (push id ids)) (oref backend permissions))
          (dolist (id ids) (opencode-client--dismiss-permission backend id)))
        (let (ids)
          (maphash (lambda (id _) (push id ids)) (oref backend forms))
          (dolist (id ids) (opencode-client--dismiss-form backend id)))
        (agent-backend--publish buffer (list :kind 'state-changed))))))

(cl-defmethod agent-backend-send ((backend opencode-client-backend) prompt)
  "Send PROMPT to BACKEND's session as the next turn.
Posted with `queue' delivery, so text arriving mid-turn is run as the
next turn rather than refused.  That is already what the input verb
promises, so opencode needs no `agent-backend-input' method of its own
-- the base default routes here (issue #69)."
  (let ((id (oref backend session-id)))
    (unless id (user-error "opencode: no active session"))
    (opencode-client--request
     'post (format "/api/session/%s/prompt" id)
     `((text . ,prompt)
       (delivery . "queue"))
     backend)
    (when-let* ((buffer (oref backend buffer)))
      (agent-backend--publish buffer (list :kind 'prompt :text prompt)))
    (message "opencode: prompt sent")))

(cl-defmethod agent-backend-interrupt ((backend opencode-client-backend))
  "Interrupt the running turn in BACKEND's session."
  (let ((id (oref backend session-id)))
    (unless id (user-error "opencode: no active session"))
    (opencode-client--request 'post (format "/api/session/%s/interrupt" id) nil backend)
    ;; Wait for execution.interrupted, rather than claiming an HTTP
    ;; acknowledgement has already stopped execution.
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
     `((text . ,note)
       (delivery . "steer"))
     backend)
    (when-let* ((buffer (oref backend buffer)))
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

(cl-defmethod agent-backend-resume ((backend opencode-client-backend) session)
  "Reattach BACKEND to SESSION and recover its existing conversation."
  (let* ((id (if (stringp session) session (plist-get session :id)))
         (info (opencode-client--data 'get (concat "/api/session/" (url-hexify-string id)) nil backend)))
    (oset backend directory (alist-get 'directory (alist-get 'location info)))
    (opencode-client--open-buffer id (or (alist-get 'title info) id) t backend)))

(cl-defmethod agent-backend-seed-history ((backend opencode-client-backend))
  "Seed BACKEND's conversation model from its session's history."
  (opencode-client--seed-history backend))

(cl-defmethod agent-backend-project-root ((backend opencode-client-backend))
  "Return BACKEND's explicit V2 location directory."
  (and (oref backend directory) (file-name-as-directory (oref backend directory))))

(cl-defmethod agent-backend-turn-state ((backend opencode-client-backend))
  "Return BACKEND's observed execution state."
  (oref backend turn-state))

(cl-defmethod agent-backend-turn-elapsed ((backend opencode-client-backend))
  "Return elapsed seconds only while BACKEND is working."
  (when (and (eq (oref backend turn-state) 'working) (oref backend turn-started))
    (max 0 (- (float-time) (oref backend turn-started)))))

(cl-defmethod agent-backend-render ((backend opencode-client-backend))
  "Re-render BACKEND's conversation buffer."
  (let ((buffer (oref backend buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (opencode-client--render)))))

(defcustom opencode-client-query-timeout 120
  "Seconds to wait for a one-shot `agent-backend-query' answer.
Polling stops after this and the user is told, so a wedged or very slow
model cannot leave the caller waiting forever."
  :type 'integer
  :group 'opencode-client)

(defcustom opencode-client-query-poll-interval 1.0
  "Seconds between polls while waiting for a one-shot query's answer.
opencode's prompt endpoint only acknowledges the request -- the answer
arrives later -- so the reply has to be collected by asking again."
  :type 'number
  :group 'opencode-client)

(defun opencode-client--completed-answer (session backend)
  "Return the assistant answer for SESSION on BACKEND, or nil if not ready.
nil means \"not finished yet\", so a caller can keep polling; a finished
turn that failed signals instead, since waiting longer will not help.

Shape verified against a live server: `GET /api/session/ID/message'
returns messages newest-first, each with a `type' (\"assistant\" or
\"user\"), a `content' list of parts, and -- once the turn is over -- a
`finish' field, which is \"error\" plus an `error' object on failure."
  (let* ((active (opencode-client--data 'get "/api/session/active" nil backend))
         (info (opencode-client--data 'get (format "/api/session/%s" session) nil backend))
         (messages (opencode-client--data
                    'get (format "/api/session/%s/message?type=assistant&order=desc" session) nil backend))
         (reply (seq-find (lambda (m) (equal (alist-get 'type m) "assistant"))
                          (if (listp messages) messages nil))))
    ;; An assistant tool-calls step is not the end of an execution.
    (when (equal (alist-get 'outcome info) "failed")
      (user-error "opencode query failed"))
    (when-let* ((finish (and (not (alist-get (intern session) active))
                            (equal (alist-get 'outcome info) "succeeded")
                            reply (alist-get 'finish reply))))
      (when (equal finish "error")
        (user-error "opencode query failed: %s"
                    (or (alist-get 'message (alist-get 'error reply))
                        "unknown error")))
      ;; Finished cleanly: join the text parts, skipping tool calls and
      ;; other non-prose content.
      (mapconcat (lambda (part) (or (alist-get 'text part) ""))
                 (seq-filter (lambda (part) (equal (alist-get 'type part) "text"))
                             (alist-get 'content reply))
                 ""))))

(cl-defmethod agent-backend-query ((backend opencode-client-backend) prompt callback)
  "Answer PROMPT in a throwaway V2 agent session, passing text to CALLBACK.
Unlike the text-generation API, an agent session can use editor tools to
read selection references.  Wait for execution completion, not an
individual tool-calls step, then interrupt and delete the temporary
session, including on failure or timeout."
  (let* ((backend (or (and (oref backend port) backend)
                      ;; Called with a bare instance -- e.g. from
                      ;; `agent-backend--query-backend', which builds one
                      ;; from the preference with no server attached yet.
                      (opencode-client--ensure-server)))
          (session (alist-get 'id (opencode-client--data
                                  'post "/api/session"
                                  `((location . ((directory . ,(opencode-client--directory backend)))))
                                  backend)))
         (deadline (+ (float-time) opencode-client-query-timeout))
         (done nil))
    (unless session
      (user-error "opencode: could not create a session for the query"))
    (unwind-protect
        (progn
          (opencode-client--request
           'post (format "/api/session/%s/prompt" session)
           `((text . ,prompt) (delivery . "queue"))
           backend)
          (while (and (not done) (< (float-time) deadline))
            ;; `sit-for' rather than `sleep-for': this runs from a
            ;; command, and input should still get through while waiting.
            (sit-for opencode-client-query-poll-interval)
            (setq done (opencode-client--completed-answer session backend)))
          (if done
              (funcall callback done)
            (message "opencode query timed out after %ss"
                     opencode-client-query-timeout)))
      (ignore-errors
        (opencode-client--request
         'post (format "/api/session/%s/interrupt" session) nil backend))
      (ignore-errors
        (opencode-client--request
         'delete (format "/api/session/%s" session) nil backend)))))

;;;; Prompting and interaction

(defun opencode-client--transient-backend ()
  "Return a transient backend instance for server-level operations.
Used by commands that need a backend object but are not bound to a
conversation buffer (connect, list-sessions)."
  (or (opencode-client--discover) (make-instance 'opencode-client-backend)))

(defun opencode-client--active-backend ()
  "Return the backend instance for the active session.
Uses the current buffer's instance when bound to a session; otherwise a
transient instance around the current project's selected session."
  (let ((instance (opencode-client--instance)))
    (if (and instance (oref instance session-id))
        instance
      (let ((server (opencode-client--ensure-server)))
        (let* ((directory (opencode-client--directory))
               (id (cdr (assoc directory opencode-client--active-sessions))))
          (unless id (user-error "opencode: no selected session in this project"))
          (make-instance 'opencode-client-backend
                       :session-id id :directory directory
                        :host (oref server host)
                       :port (oref server port)
                       :password (oref server password)))))))

;;;###autoload
(defun opencode-client-compose (&optional steer)
  "Compose a prompt for the active session from any buffer.
An active region in the source buffer seeds the composition with a quote
or file-and-line reference; see `agent-prompt-region-seed'.  The prompt
splits the conversation's window, displaying it first if necessary.
With prefix arg STEER, deliver it as a steering message mid-turn."
  (interactive "P")
  (let* ((source (current-buffer))
         (backend (opencode-client--active-backend))
         (id (oref backend session-id))
         (conversation (or (opencode-client--conversation id backend)
                           (opencode-client--open-buffer id id t backend)))
         (window (or (get-buffer-window conversation t)
                     (progn (pop-to-buffer conversation) (selected-window)))))
    (agent-prompt-read
     (lambda (text)
       (when (buffer-live-p conversation)
         (with-current-buffer conversation
           (opencode-client-send-prompt text steer))))
     nil (buffer-name conversation) window source)))

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
    `((decision . ,(pcase decision ("allow" "once") ("deny" "reject") (_ decision)))) backend)
  (opencode-client--dismiss-permission backend request-id))

;;;###autoload
(defun opencode-client-answer-permission (request-id)
  "Answer permission REQUEST-ID in the active session.
Kept as the manual escape hatch.  A request that arrived over the stream
has already raised its own menu, so this is for answering one by id --
after a reconnect that missed the event, or when the menu was killed."
  (interactive (list (read-string "Permission request id: ")))
  (let ((backend (opencode-client--active-backend)))
    (if (member (opencode-client--ui-id backend request-id) (agent-permission-pending-ids))
        (message "That request is already open; answer it in its buffer")
      (opencode-client--ask-permission
       backend (current-buffer)
       (opencode-client--data 'get
        (concat (opencode-client--session-path backend "/permission/")
                (url-hexify-string request-id)) nil backend)))))

(defun opencode-client--reply-question (backend id request-id answer)
  "Reply with the complete keyed ANSWER to form REQUEST-ID in session ID."
  (unless (hash-table-p answer)
    (user-error "opencode: form answers must be a keyed object; use the form menu"))
  (opencode-client--request
   'post (format "/api/session/%s/form/%s/reply" id (url-hexify-string request-id))
   `((answer . ,answer)) backend)
  (opencode-client--dismiss-form backend request-id))

;;;###autoload
(defun opencode-client-answer-question (request-id)
  "Recover form REQUEST-ID and present all its fields in the active session.
A form already open is left alone; no unkeyed free-form reply is sent."
  (interactive (list (read-string "Question request id: ")))
  (let ((backend (opencode-client--active-backend)))
    (if (member (opencode-client--ui-id backend request-id) (agent-question-pending-ids))
        (message "That question is already open; answer it in its buffer")
      (opencode-client--ask-question
       backend (current-buffer)
       (opencode-client--data 'get
        (concat (opencode-client--session-path backend "/form/")
                (url-hexify-string request-id)) nil backend)))))

;;;; Session help

(defconst opencode-client--help-buffer-name "*opencode help*"
  "Name of the session keybinding help buffer.")

(defconst opencode-client--help
  '(("C-c C-c" "compose/send a prompt; with a prefix argument, steer")
    ("C-c C-k" "interrupt remote work, keeping the session")
    ("TAB" "expand/collapse the tool's input and result at point")
    ("?" "toggle this help")
    ("C-c C-s" "send input; queue it when a turn is already running")
    ("C-c C-i" "interrupt remote work (shared backend binding)")
    ("C-c C-q" "disconnect this view; remote work keeps running")
    ("C-c C-r" "resume an existing session by ID"))
  "Session bindings as (KEY DESCRIPTION), including inherited backend keys.")

(defun opencode-client--display-help (buffer _alist)
  "Display help BUFFER in an ordinary split, without replacing the conversation.
An ordinary window avoids popup frameworks closing the conversation when
the human dismisses its help.  Reuse an existing help window."
  (or (get-buffer-window buffer)
      (let* ((base (or (get-buffer-window (current-buffer)) (selected-window)))
             (window (split-window base nil 'below)))
        (set-window-buffer window buffer)
        window)))

;;;###autoload
(defun opencode-client-help ()
  "Toggle the available OpenCode session keys in a help window."
  (interactive)
  (if-let* ((window (get-buffer-window opencode-client--help-buffer-name)))
      (progn
        (unless (ignore-errors (delete-window window) t)
          (quit-window nil window))
        (bury-buffer opencode-client--help-buffer-name))
    (let ((display-buffer-alist
           (cons `(,(regexp-quote opencode-client--help-buffer-name)
                   (opencode-client--display-help))
                 display-buffer-alist)))
      (with-help-window opencode-client--help-buffer-name
        (princ "OpenCode conversation — available keys\n\n")
        (dolist (binding opencode-client--help)
          (princ (format "  %-10s %s\n" (car binding) (cadr binding))))
        (princ "\nInput normally queues; steering is explicit.\n")
        (princ "Disconnecting is not an interrupt: stop remote work first if needed.\n")
        (princ "\nPlain Emacs also has g (minibuffer prompt) and q (bury conversation).\n")
        (princ "Evil keeps its usual g/q behaviour in the conversation.\n")
        (princ "\nM-x opencode-client-open starts another conversation.\n")
        (princ "M-x opencode-client-switch-session selects an existing one.\n")
        (princ "\nPress ? or q in this help window to close only the help.\n"))
      (with-current-buffer opencode-client--help-buffer-name
        (use-local-map (copy-keymap (current-local-map)))
        (dolist (key '("?" "q"))
          (local-set-key (kbd key) #'opencode-client-help)
          (when (fboundp 'evil-local-set-key)
            (dolist (state '(normal motion))
              (evil-local-set-key state (kbd key) #'opencode-client-help)))))
      (when-let* ((window (get-buffer-window opencode-client--help-buffer-name)))
        (fit-window-to-buffer window)))))

;;;; Major mode

(defvar opencode-client-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'opencode-client-compose)
    (define-key map (kbd "C-c C-k") #'opencode-client-interrupt)
    (define-key map (kbd "g")       #'opencode-client-send-prompt)
    map)
  "Keymap for `opencode-client-mode'.")

(declare-function evil-define-key* "evil-core" (state keymap key def &rest bindings))

(defun opencode-client--install-help-key ()
  "Bind session help, including Evil states where ? otherwise searches backward."
  (define-key opencode-client-mode-map (kbd "?") #'opencode-client-help)
  (when (fboundp 'evil-define-key*)
    (evil-define-key* '(normal motion) opencode-client-mode-map
                      (kbd "?") #'opencode-client-help)))

(defun opencode-client--install-tool-keys ()
  "Bind tool-detail expansion in both plain Emacs and optional Evil states."
  (dolist (key '("TAB" "<tab>"))
    (define-key opencode-client-mode-map (kbd key) #'opencode-client-toggle-tool-details)
    (when (fboundp 'evil-define-key*)
      (evil-define-key* '(normal motion) opencode-client-mode-map
                        (kbd key) #'opencode-client-toggle-tool-details))))

(opencode-client--install-tool-keys)
(opencode-client--install-help-key)
(with-eval-after-load 'evil
  (opencode-client--install-tool-keys)
  (opencode-client--install-help-key))

(define-derived-mode opencode-client-mode agent-backend-mode "opencode"
  "Major mode for an opencode chat buffer."
  (setq-local truncate-lines nil)
  (add-hook 'kill-buffer-hook
            (lambda ()
              (when agent-backend--instance
                (agent-backend-quit agent-backend--instance))) nil t))

(provide 'opencode-client)

;;; opencode-client.el ends here
