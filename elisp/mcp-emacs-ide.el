;;; mcp-emacs-ide.el --- Claude Code IDE integration for mcp-emacs -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 1.6.0
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

;; An IDE-protocol integration surface for Claude Code, distinct from the
;; HTTP MCP server in `mcp-emacs-server'.  Claude Code only routes its
;; *native* Edit/Write operations through an in-editor diff review when it
;; connects to an "IDE": a WebSocket server that the CLI is told about via
;; the `CLAUDE_CODE_SSE_PORT' / `ENABLE_IDE_INTEGRATION' environment
;; variables at launch (see `mcp-emacs-run').  This module implements that
;; IDE side.
;;
;; The protocol was verified live against Claude Code 2.1.212 (see
;; openspec/changes/native-edit-diff-review/spike-findings.md).  Notable
;; points that shape this code:
;;
;; - protocolVersion is "2025-11-25"; `initialize' echoes it back.
;; - Before every native edit the CLI calls `closeAllDiffTabs' then
;;   `getDiagnostics' then `openDiff', and BLOCKS until each is answered.
;;   So all four tools must be served, not only `openDiff'.
;; - `openDiff' is deferred: no immediate response.  When the human
;;   resolves the ediff review we complete the stored request id with
;;   `FILE_SAVED' + final content (accept) or `DIFF_REJECTED' + tab name
;;   (reject).  Claude Code writes the file itself on `FILE_SAVED'.
;;
;; The ediff review reuses `mcp-emacs--ediff-review' from `mcp-emacs', the
;; same accept/reject flow the synchronous `apply_diff' tool uses.
;;
;; This surface is opt-in (`mcp-emacs-ide-enabled') and does not touch the
;; HTTP MCP server.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'project nil t)
(require 'mcp-emacs)

;; websocket is a soft dependency: load it lazily and fail with a clear
;; hint only when the IDE surface is actually started.
(declare-function websocket-server "websocket" (port &rest plist))
(declare-function websocket-server-close "websocket" (server))
(declare-function websocket-send-text "websocket" (ws text))
(declare-function websocket-frame-text "websocket" (frame))
(declare-function mcp-emacs--ediff-review "mcp-emacs"
                  (buffer-a buffer-b entry-content result
                            &optional on-resolve tab-name))
(declare-function project-current "project" (&optional maybe-prompt directory))
(declare-function project-root "project" (project))

;;;; Constants

(defconst mcp-emacs-ide-protocol-version "2025-11-25"
  "MCP protocol version advertised to Claude Code.
Verified against Claude Code 2.1.212; echo whatever the client offers
if this ever drifts again.")

(defconst mcp-emacs-ide--port-range '(10000 . 65535)
  "Inclusive port range to search for a free WebSocket port.")

(defconst mcp-emacs-ide--max-port-attempts 100
  "Maximum random port bind attempts before giving up.")

;;;; Customization

(defgroup mcp-emacs-ide nil
  "Claude Code IDE integration for mcp-emacs."
  :group 'tools
  :prefix "mcp-emacs-ide-")

(defcustom mcp-emacs-ide-enabled nil
  "When non-nil, allow the IDE integration surface to start.
Off by default: the Claude Code IDE protocol is unofficial and
version-fragile, so it is opt-in and isolated from the HTTP MCP server."
  :type 'boolean
  :group 'mcp-emacs-ide)

(defcustom mcp-emacs-ide-lockfile-directory "~/.claude/ide/"
  "Directory in which the discovery lockfile is written."
  :type 'directory
  :group 'mcp-emacs-ide)

;;;; State

(cl-defstruct (mcp-emacs-ide-session (:constructor mcp-emacs-ide--make-session))
  "State for one IDE WebSocket server and its connected client."
  server           ; websocket server process
  client           ; connected websocket client (or nil)
  port             ; server port
  project-dir      ; workspace root
  lockfile         ; path to the discovery lockfile
  (diffs (make-hash-table :test 'equal))     ; tab-name -> diff plist
  (deferred (make-hash-table :test 'equal))) ; tab-name -> pending request id

(defvar mcp-emacs-ide--session nil
  "The single active IDE session, or nil.
One workspace at a time is supported; starting again stops the old one.")

;;;; JSON helpers

(defun mcp-emacs-ide--obj (&rest kv)
  "Build an alist suitable for `json-encode' from KV pairs.
KV is a flat list of \"key\" value \"key\" value ...; keys are interned."
  (let (al)
    (while kv (push (cons (intern (pop kv)) (pop kv)) al))
    (nreverse al)))

(defun mcp-emacs-ide--empty-object ()
  "Return a value that `json-encode' serialises as an empty object {}."
  (make-hash-table :test 'equal))

(defun mcp-emacs-ide--send (client obj)
  "Encode OBJ as JSON and send it to CLIENT over the WebSocket."
  (when client
    (condition-case err
        (websocket-send-text client (json-encode obj))
      (error (message "mcp-emacs-ide: send failed: %s"
                      (error-message-string err))))))

(defun mcp-emacs-ide--result (id result)
  "Return a JSON-RPC result object for request ID carrying RESULT."
  (mcp-emacs-ide--obj "jsonrpc" "2.0" "id" id "result" result))

(defun mcp-emacs-ide--text-content (&rest strings)
  "Wrap STRINGS as an MCP text-content result value."
  (mcp-emacs-ide--obj
   "content"
   (vconcat (mapcar (lambda (s) (mcp-emacs-ide--obj "type" "text" "text" s))
                    strings))))

;;;; Tool schemas

(defun mcp-emacs-ide--tool (name description &optional properties required)
  "Describe a tool NAME with DESCRIPTION for tools/list.
PROPERTIES is an inputSchema properties alist (or nil for none);
REQUIRED is a list of required property-name strings."
  (mcp-emacs-ide--obj
   "name" name
   "description" description
   "inputSchema"
   (mcp-emacs-ide--obj
    "type" "object"
    "properties" (or properties (mcp-emacs-ide--empty-object))
    "required" (vconcat (or required '())))))

(defun mcp-emacs-ide--tool-list ()
  "Return the vector of tools advertised to Claude Code."
  (let ((str (mcp-emacs-ide--obj "type" "string")))
    (vector
     (mcp-emacs-ide--tool
      "openDiff" "Open an interactive diff review of a proposed edit."
      (mcp-emacs-ide--obj "old_file_path" str
                          "new_file_path" str
                          "new_file_contents" str
                          "tab_name" str)
      '("old_file_path" "new_file_path" "new_file_contents" "tab_name"))
     (mcp-emacs-ide--tool
      "close_tab" "Close a diff tab by name."
      (mcp-emacs-ide--obj "tab_name" str)
      '("tab_name"))
     (mcp-emacs-ide--tool
      "closeAllDiffTabs" "Close all open diff tabs.")
     (mcp-emacs-ide--tool
      "getDiagnostics" "Return diagnostics for a file (or all files)."
      (mcp-emacs-ide--obj "uri" str)))))

;;;; Lockfile

(defun mcp-emacs-ide--lockfile-path (port)
  "Return the lockfile path for PORT."
  (expand-file-name (format "%d.lock" port) mcp-emacs-ide-lockfile-directory))

(defun mcp-emacs-ide--write-lockfile (port project-dir)
  "Write the discovery lockfile for PORT and PROJECT-DIR; return its path."
  (let ((path (mcp-emacs-ide--lockfile-path port)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path
      (insert (json-encode
               (mcp-emacs-ide--obj
                "pid" (emacs-pid)
                "workspaceFolders" (vector (expand-file-name project-dir))
                "ideName" "Emacs"
                "transport" "ws"))))
    path))

(defun mcp-emacs-ide--remove-lockfile (path)
  "Delete the lockfile at PATH if it exists."
  (when (and path (file-exists-p path))
    (ignore-errors (delete-file path))))

;;;; Diff sessions

(defun mcp-emacs-ide--cleanup-diff (session tab-name)
  "Tear down the diff for TAB-NAME in SESSION and free its buffers."
  (let* ((diffs (mcp-emacs-ide-session-diffs session))
         (info (gethash tab-name diffs)))
    (when info
      (let ((control (plist-get info :control))
            (buffer-b (plist-get info :buffer-b)))
        (when (and control (buffer-live-p control))
          (with-current-buffer control
            (ignore-errors (ediff-really-quit nil))))
        (when (and buffer-b (buffer-live-p buffer-b))
          (kill-buffer buffer-b)))
      (remhash tab-name diffs)
      (remhash tab-name (mcp-emacs-ide-session-deferred session)))))

(defun mcp-emacs-ide--complete-open-diff (session tab-name status &rest extra)
  "Complete the deferred openDiff for TAB-NAME with STATUS and EXTRA text.
Send the stored request id's response over the client socket, then drop
the deferred entry.  Does nothing if there is no pending id (e.g. the
diff was already resolved or closed)."
  (let* ((deferred (mcp-emacs-ide-session-deferred session))
         (id (gethash tab-name deferred)))
    (when id
      (remhash tab-name deferred)
      (mcp-emacs-ide--send
       (mcp-emacs-ide-session-client session)
       (mcp-emacs-ide--result
        id (apply #'mcp-emacs-ide--text-content status extra))))))

(defun mcp-emacs-ide--open-diff (session args id)
  "Handle an openDiff call in SESSION with ARGS and request ID.
Open the ediff review and store ID as deferred, keyed by tab name.  When
the human resolves, complete the request with FILE_SAVED + content
\(accept) or DIFF_REJECTED + tab name (reject)."
  (let* ((old-path (alist-get 'old_file_path args))
         (new-contents (alist-get 'new_file_contents args))
         (tab-name (alist-get 'tab_name args)))
    (unless (and old-path new-contents tab-name)
      (error "openDiff: missing required arguments"))
    ;; Replace any existing diff for this tab.
    (mcp-emacs-ide--cleanup-diff session tab-name)
    (let* ((file (expand-file-name old-path))
           (buffer-a (find-file-noselect file))
           (entry-content (with-current-buffer buffer-a
                            (buffer-substring-no-properties
                             (point-min) (point-max))))
           (buffer-b (generate-new-buffer
                      (format "*mcp-ide-diff: %s*"
                              (file-name-nondirectory file))))
           (result (list nil)))
      (with-current-buffer buffer-b
        (insert new-contents)
        (let ((mode (assoc-default file auto-mode-alist 'string-match)))
          (when (functionp mode) (ignore-errors (funcall mode)))))
      ;; Register the deferred id before opening ediff so a very fast
      ;; resolve still finds it.
      (puthash tab-name id (mcp-emacs-ide-session-deferred session))
      (let ((control
             (mcp-emacs--ediff-review
              buffer-a buffer-b entry-content result
              (lambda ()
                (if (eq (car result) 'applied)
                    (mcp-emacs-ide--complete-open-diff
                     session tab-name "FILE_SAVED"
                     (with-current-buffer buffer-a
                       (buffer-substring-no-properties
                        (point-min) (point-max))))
                  (mcp-emacs-ide--complete-open-diff
                   session tab-name "DIFF_REJECTED" tab-name))
                (mcp-emacs-ide--cleanup-diff session tab-name))
              tab-name)))
        (puthash tab-name
                 (list :buffer-a buffer-a :buffer-b buffer-b
                       :control control :result result)
                 (mcp-emacs-ide-session-diffs session)))
      ;; Deferred: no immediate response.
      'deferred)))

;;;; Tool dispatch

(defun mcp-emacs-ide--call-tool (session name args id)
  "Handle tools/call for NAME with ARGS and request ID in SESSION.
Return the JSON-RPC result object to send, or the symbol `deferred' when
the response is sent later (openDiff)."
  (cond
   ((string= name "openDiff")
    (mcp-emacs-ide--open-diff session args id)
    'deferred)
   ((string= name "close_tab")
    (mcp-emacs-ide--cleanup-diff session (alist-get 'tab_name args))
    (mcp-emacs-ide--result id (mcp-emacs-ide--text-content "TAB_CLOSED")))
   ((string= name "closeAllDiffTabs")
    (let ((tabs '()))
      (maphash (lambda (tab _v) (push tab tabs))
               (mcp-emacs-ide-session-diffs session))
      (dolist (tab tabs) (mcp-emacs-ide--cleanup-diff session tab))
      (mcp-emacs-ide--result
       id (mcp-emacs-ide--text-content
           (format "CLOSED_%d_DIFF_TABS" (length tabs))))))
   ((string= name "getDiagnostics")
    ;; Stubbed: Claude Code blocks until this is answered, but an empty
    ;; result is acceptable.  A future version can wire Flycheck/Flymake.
    (mcp-emacs-ide--result id (mcp-emacs-ide--text-content "[]")))
   (t
    (mcp-emacs-ide--result id (mcp-emacs-ide--text-content
                               (format "Unknown tool: %s" name))))))

(defun mcp-emacs-ide--handle-message (session client text)
  "Dispatch one JSON-RPC message TEXT from CLIENT belonging to SESSION."
  (let* ((msg (ignore-errors (json-parse-string text :object-type 'alist)))
         (method (and msg (alist-get 'method msg)))
         (id (and msg (alist-get 'id msg)))
         (params (and msg (alist-get 'params msg))))
    (cond
     ((null msg) nil)
     ((string= method "initialize")
      (mcp-emacs-ide--send
       client
       (mcp-emacs-ide--result
        id (mcp-emacs-ide--obj
            "protocolVersion" mcp-emacs-ide-protocol-version
            "capabilities" (mcp-emacs-ide--obj
                            "tools" (mcp-emacs-ide--obj "listChanged" t))
            "serverInfo" (mcp-emacs-ide--obj
                          "name" "mcp-emacs-ide" "version" "1.0.0")))))
     ((string= method "tools/list")
      (mcp-emacs-ide--send
       client (mcp-emacs-ide--result
               id (mcp-emacs-ide--obj "tools" (mcp-emacs-ide--tool-list)))))
     ((string= method "tools/call")
      (let* ((name (alist-get 'name params))
             (args (alist-get 'arguments params))
             (res (condition-case err
                      (mcp-emacs-ide--call-tool session name args id)
                    (error
                     (mcp-emacs-ide--result
                      id (mcp-emacs-ide--text-content
                          (format "Error: %s" (error-message-string err))))))))
        ;; `deferred' means the response is sent asynchronously later.
        (unless (eq res 'deferred)
          (mcp-emacs-ide--send client res))))
     ((null id)
      ;; Notification (initialized, ide_connected, ...): no response.
      nil)
     (t
      (mcp-emacs-ide--send
       client (mcp-emacs-ide--obj
               "jsonrpc" "2.0" "id" id
               "error" (mcp-emacs-ide--obj
                        "code" -32601
                        "message" (format "Method not found: %s" method))))))))

;;;; WebSocket server lifecycle

(defun mcp-emacs-ide--require-websocket ()
  "Ensure the websocket package is available, or signal a clear error."
  (unless (require 'websocket nil t)
    (user-error
     "mcp-emacs-ide requires the `websocket' package; please install it")))

(defun mcp-emacs-ide--start-server ()
  "Bind a WebSocket server on a free local port and return (SERVER . PORT)."
  (let ((min (car mcp-emacs-ide--port-range))
        (max (cdr mcp-emacs-ide--port-range))
        (attempts 0)
        found)
    (while (and (null found) (< attempts mcp-emacs-ide--max-port-attempts))
      (let ((port (+ min (random (- max min)))))
        (condition-case nil
            (let ((server
                   (websocket-server
                    port
                    :host "127.0.0.1"
                    :protocol '("mcp")
                    :on-open
                    (lambda (ws)
                      (when mcp-emacs-ide--session
                        (setf (mcp-emacs-ide-session-client
                               mcp-emacs-ide--session)
                              ws)))
                    :on-message
                    (lambda (ws frame)
                      (when mcp-emacs-ide--session
                        (mcp-emacs-ide--handle-message
                         mcp-emacs-ide--session ws
                         (websocket-frame-text frame))))
                    :on-close
                    (lambda (_ws)
                      (when mcp-emacs-ide--session
                        (setf (mcp-emacs-ide-session-client
                               mcp-emacs-ide--session)
                              nil))))))
              (setq found (cons server port)))
          (error (setq attempts (1+ attempts))))))
    (or found (error "mcp-emacs-ide: no free port in range %d-%d" min max))))

;;;###autoload
(defun mcp-emacs-ide-start ()
  "Start the Claude Code IDE integration surface for the current project.
Bind a WebSocket server, publish the discovery lockfile, and store the
port so `mcp-emacs-run' can launch Claude Code against it.  Requires
`mcp-emacs-ide-enabled'."
  (interactive)
  (unless mcp-emacs-ide-enabled
    (user-error "mcp-emacs-ide is disabled; set `mcp-emacs-ide-enabled' first"))
  (mcp-emacs-ide--require-websocket)
  (when mcp-emacs-ide--session
    (mcp-emacs-ide-stop))
  (let* ((project-dir (or (when (and (featurep 'project)
                                     (fboundp 'project-current)
                                     (project-current))
                            (expand-file-name
                             (project-root (project-current))))
                          default-directory))
         (sp (mcp-emacs-ide--start-server))
         (server (car sp))
         (port (cdr sp))
         (lockfile (mcp-emacs-ide--write-lockfile port project-dir)))
    (setq mcp-emacs-ide--session
          (mcp-emacs-ide--make-session
           :server server :port port :project-dir project-dir
           :lockfile lockfile))
    (add-hook 'kill-emacs-hook #'mcp-emacs-ide--kill-emacs-cleanup)
    (message "mcp-emacs-ide: IDE server on ws://127.0.0.1:%d for %s"
             port project-dir)
    port))

;;;###autoload
(defun mcp-emacs-ide-stop ()
  "Stop the IDE integration surface: close diffs, socket, and lockfile."
  (interactive)
  (when mcp-emacs-ide--session
    (let ((session mcp-emacs-ide--session))
      (let (tabs)
        (maphash (lambda (tab _v) (push tab tabs))
                 (mcp-emacs-ide-session-diffs session))
        (dolist (tab tabs) (mcp-emacs-ide--cleanup-diff session tab)))
      (ignore-errors
        (websocket-server-close (mcp-emacs-ide-session-server session)))
      (mcp-emacs-ide--remove-lockfile (mcp-emacs-ide-session-lockfile session))
      (setq mcp-emacs-ide--session nil)
      (message "mcp-emacs-ide: stopped"))))

(defun mcp-emacs-ide--kill-emacs-cleanup ()
  "Best-effort lockfile removal when Emacs exits."
  (when mcp-emacs-ide--session
    (mcp-emacs-ide--remove-lockfile
     (mcp-emacs-ide-session-lockfile mcp-emacs-ide--session))))

(defun mcp-emacs-ide-port ()
  "Return the active IDE server port, or nil when not running."
  (and mcp-emacs-ide--session
       (mcp-emacs-ide-session-port mcp-emacs-ide--session)))

(provide 'mcp-emacs-ide)
;;; mcp-emacs-ide.el ends here
