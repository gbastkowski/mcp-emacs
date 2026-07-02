;;; mcp-emacs-server.el --- HTTP MCP server running inside Emacs -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 0.5.0
;; Package-Requires: ((emacs "28.1") (web-server "0.1.2"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs

;;; Commentary:

;; A Model Context Protocol server that runs inside the live Emacs
;; session and speaks the MCP streamable-HTTP transport.  Unlike the
;; Node.js server it does not shell out via emacsclient; tool calls are
;; dispatched directly to the `mcp-emacs-*' helpers, so they observe the
;; real buffers, windows, and Org state of the running session.
;;
;; Usage:
;;   (require 'mcp-emacs-server)
;;   (mcp-emacs-server-start)        ; default port 8765
;;
;; Then point an MCP client at it:
;;   { "type": "http", "url": "http://localhost:8765/mcp" }

;;; Code:

(require 'mcp-emacs)
(require 'web-server)
(require 'json)
(require 'cl-lib)

(defgroup mcp-emacs-server nil
  "MCP server hosted inside Emacs."
  :group 'tools)

(defcustom mcp-emacs-server-port 8765
  "TCP port the MCP HTTP server listens on."
  :type 'integer
  :group 'mcp-emacs-server)

(defconst mcp-emacs-server-protocol-version "2025-06-18"
  "MCP protocol version advertised in the initialize result.")

(defvar mcp-emacs-server--process nil
  "The running `web-server' process, or nil when stopped.")

;;;; Tool registry

(defun mcp-emacs-server--obj (&rest pairs)
  "Build a JSON object value from PAIRS preserving key order.
With no PAIRS, return an empty hash table so it encodes as `{}'
rather than `null' (an empty alist would)."
  (if (null pairs)
      (make-hash-table :test 'equal)
    (let (acc)
      (while pairs
        (push (cons (pop pairs) (pop pairs)) acc))
      (nreverse acc))))

(defun mcp-emacs-server--no-args ()
  "Schema for a tool that takes no arguments."
  (mcp-emacs-server--obj "type" "object" "properties" (mcp-emacs-server--obj)))

(defun mcp-emacs-server--prop (type description)
  "Build a JSON schema property of TYPE with DESCRIPTION."
  (mcp-emacs-server--obj "type" type "description" description))

(defun mcp-emacs-server--position-prop (which)
  "Build the schema for a WHICH (\"start\"/\"end\") line/column position object."
  (mcp-emacs-server--obj
   "type" "object"
   "description" (format "%s of the replacement region" (capitalize which))
   "properties" (mcp-emacs-server--obj
                 "line" (mcp-emacs-server--prop "integer" "1-based line number")
                 "column" (mcp-emacs-server--prop "integer" "1-based column number"))
   "required" (vector "line" "column")))

(defconst mcp-emacs-server--tools
  (list
   (list :name "get_buffer_content"
         :description "Get the content of the current Emacs buffer"
         :schema (mcp-emacs-server--no-args)
         :handler (lambda (_args) (mcp-emacs-get-buffer-content)))
   (list :name "get_buffer_filename"
         :description "Get the filename associated with the current Emacs buffer"
         :schema (mcp-emacs-server--no-args)
         :handler (lambda (_args)
                    (or (mcp-emacs-get-buffer-filename)
                        "Current buffer is not visiting a file")))
   (list :name "get_selection"
         :description "Get the current selection (region) in Emacs"
         :schema (mcp-emacs-server--no-args)
         :handler (lambda (_args)
                    (or (mcp-emacs-get-selection) "No active selection")))
   (list :name "open_file"
         :description "Open a file in the current Emacs window"
         :schema (mcp-emacs-server--obj
                  "type" "object"
                  "properties" (mcp-emacs-server--obj
                                "path" (mcp-emacs-server--prop "string" "Absolute path to the file to open"))
                  "required" (vector "path"))
         :handler (lambda (args)
                    (let ((path (alist-get 'path args)))
                      (mcp-emacs-open-file path)
                      (format "Opened file: %s" path))))
   (list :name "get_current_clocked_task"
         :description "Get the Org task currently clocked in"
         :schema (mcp-emacs-server--no-args)
         :handler (lambda (_args)
                    (or (mcp-emacs-get-current-clocked-task)
                        "No task is currently clocked in")))
   (list :name "get_current_task_at_point"
         :description "Get the current Org task at point"
         :schema (mcp-emacs-server--no-args)
         :handler (lambda (_args)
                    (or (mcp-emacs-get-current-task-at-point)
                        "No current task at point")))
   (list :name "edit_file_region"
         :description "Edit a specific region in an Emacs buffer using line/column coordinates"
         :schema (mcp-emacs-server--obj
                  "type" "object"
                  "properties" (mcp-emacs-server--obj
                                "path" (mcp-emacs-server--prop "string" "Absolute path to the file being edited")
                                "start" (mcp-emacs-server--position-prop "start")
                                "end" (mcp-emacs-server--position-prop "end")
                                "text" (mcp-emacs-server--prop "string" "Replacement text to insert within the range")
                                "save" (mcp-emacs-server--prop "boolean" "Save the buffer after applying the edit"))
                  "required" (vector "path" "start" "end" "text"))
         :handler (lambda (args)
                    (let ((start (alist-get 'start args))
                          (end (alist-get 'end args)))
                      (mcp-emacs-edit-file-region
                       (alist-get 'path args)
                       (alist-get 'line start) (alist-get 'column start)
                       (alist-get 'line end) (alist-get 'column end)
                       (alist-get 'text args)
                       (eq (alist-get 'save args) t)))))
   (list :name "insert_at_point"
         :description "Insert text at point or replace the current selection in Emacs"
         :schema (mcp-emacs-server--obj
                  "type" "object"
                  "properties" (mcp-emacs-server--obj
                                "text" (mcp-emacs-server--prop "string" "Text to insert at the current point")
                                "replaceSelection" (mcp-emacs-server--prop "boolean" "Replace the active selection if one exists"))
                  "required" (vector "text"))
         :handler (lambda (args)
                    (mcp-emacs-insert-at-point
                     (alist-get 'text args)
                     (eq (alist-get 'replaceSelection args) t))))
   (list :name "goto_line"
         :description "Jump to a specific line/column or function name in the current buffer"
         :schema (mcp-emacs-server--obj
                  "type" "object"
                  "properties" (mcp-emacs-server--obj
                                "line" (mcp-emacs-server--prop "integer" "1-based line number to jump to")
                                "column" (mcp-emacs-server--prop "integer" "1-based column to position the cursor at")
                                "functionName" (mcp-emacs-server--prop "string" "Function or symbol name to jump to (via imenu)")))
         :handler (lambda (args)
                    (mcp-emacs-goto-location
                     (alist-get 'line args)
                     (alist-get 'column args)
                     (alist-get 'functionName args))))
   (list :name "toggle_org_todo"
         :description "Toggle or set the TODO keyword at point in the current org heading"
         :schema (mcp-emacs-server--obj
                  "type" "object"
                  "properties" (mcp-emacs-server--obj
                                "state" (mcp-emacs-server--prop "string" "Explicit TODO keyword to set")))
         :handler (lambda (args)
                    (mcp-emacs-toggle-org-todo (alist-get 'state args))))
   (list :name "describe_flycheck_info_at_point"
         :description "Get flycheck error/warning/info messages at the current cursor position"
         :schema (mcp-emacs-server--no-args)
         :handler (lambda (_args) (mcp-emacs-get-flycheck-info)))
   (list :name "get_error_context"
         :description "Summarize recent error-related buffers such as *Messages*, *Warnings*, or compilation logs"
         :schema (mcp-emacs-server--no-args)
         :handler (lambda (_args) (mcp-emacs-get-error-context)))
   (list :name "save_buffer"
         :description "Save the current buffer if it is visiting a file"
         :schema (mcp-emacs-server--no-args)
         :handler (lambda (_args) (mcp-emacs-save-buffer)))
   (list :name "close_buffer"
         :description "Close the current buffer, optionally saving it first"
         :schema (mcp-emacs-server--obj
                  "type" "object"
                  "properties" (mcp-emacs-server--obj
                                "save" (mcp-emacs-server--prop "boolean" "Save the buffer before closing")))
         :handler (lambda (args)
                    (mcp-emacs-close-buffer (eq (alist-get 'save args) t))))
   (list :name "switch_buffer"
         :description "Switch to a named buffer in the current Emacs session"
         :schema (mcp-emacs-server--obj
                  "type" "object"
                  "properties" (mcp-emacs-server--obj
                                "name" (mcp-emacs-server--prop "string" "Name of the buffer to switch to"))
                  "required" (vector "name"))
         :handler (lambda (args)
                    (mcp-emacs-switch-buffer (alist-get 'name args))))
   (list :name "diagnose_emacs"
         :description "Collect diagnostic information about the running Emacs, including exec-path and LSP clients"
         :schema (mcp-emacs-server--no-args)
         :handler (lambda (_args) (mcp-emacs-diagnose)))
   (list :name "get_env_vars"
         :description "List the environment variables currently visible to Emacs"
         :schema (mcp-emacs-server--no-args)
         :handler (lambda (_args) (mcp-emacs-get-env-vars)))
   (list :name "eval"
         :description "Evaluate an arbitrary Elisp expression in the current buffer context"
         :schema (mcp-emacs-server--obj
                  "type" "object"
                  "properties" (mcp-emacs-server--obj
                                "expression" (mcp-emacs-server--prop "string" "Elisp expression to evaluate"))
                  "required" (vector "expression"))
         :handler (lambda (args)
                    (let* ((expr (alist-get 'expression args))
                           (form (car (read-from-string
                                       (format "(with-current-buffer (mcp-emacs--current-buffer) (progn %s))" expr)))))
                      (format "%s" (eval form t)))))
   (list :name "get_diagnostics"
         :description "Get all diagnostics for the current buffer (Flycheck or Flymake)"
         :schema (mcp-emacs-server--no-args)
         :handler (lambda (_args) (mcp-emacs-get-diagnostics)))
   (list :name "imenu_list_symbols"
         :description "List the current buffer's symbols (functions, classes, variables) with line numbers"
         :schema (mcp-emacs-server--no-args)
         :handler (lambda (_args) (mcp-emacs-imenu-list-symbols)))
   (list :name "project_info"
         :description "Overview of the current project: root, active file, and tracked file count"
         :schema (mcp-emacs-server--no-args)
         :handler (lambda (_args) (mcp-emacs-project-info)))
   (list :name "xref_find_references"
         :description "Find references to an identifier (or the symbol at point) via xref"
         :schema (mcp-emacs-server--obj
                  "type" "object"
                  "properties" (mcp-emacs-server--obj
                                "identifier" (mcp-emacs-server--prop "string" "Identifier to search for; defaults to the symbol at point")))
         :handler (lambda (args)
                    (mcp-emacs-xref-find-references (alist-get 'identifier args))))
   (list :name "xref_find_apropos"
         :description "Find symbols matching a pattern across the project via xref apropos"
         :schema (mcp-emacs-server--obj
                  "type" "object"
                  "properties" (mcp-emacs-server--obj
                                "pattern" (mcp-emacs-server--prop "string" "Name pattern to match symbols against"))
                  "required" (vector "pattern"))
         :handler (lambda (args)
                    (mcp-emacs-xref-find-apropos (alist-get 'pattern args))))
   (list :name "treesit_info"
         :description "Tree-sitter node info at point: node type, range, and ancestor chain"
         :schema (mcp-emacs-server--no-args)
         :handler (lambda (_args) (mcp-emacs-treesit-info)))
   (list :name "org_task_session"
         :description "Read a session task Org file: task heading, session id, status, and TODO checklist"
         :schema (mcp-emacs-server--obj
                  "type" "object"
                  "properties" (mcp-emacs-server--obj
                                "path" (mcp-emacs-server--prop "string" "Absolute path to the session task Org file"))
                  "required" (vector "path"))
         :handler (lambda (args)
                    (mcp-emacs-org-task-read (alist-get 'path args))))
   (list :name "org_task_set_session_status"
         :description "Set the session status (Org keyword) of a session task file"
         :schema (mcp-emacs-server--obj
                  "type" "object"
                  "properties" (mcp-emacs-server--obj
                                "path" (mcp-emacs-server--prop "string" "Absolute path to the session task Org file")
                                "status" (mcp-emacs-server--prop "string" "Org TODO keyword to set as the session status"))
                  "required" (vector "path" "status"))
         :handler (lambda (args)
                    (mcp-emacs-org-task-set-session-status
                     (alist-get 'path args)
                     (alist-get 'status args))))
   (list :name "org_task_set_item_status"
         :description "Set the Org keyword of a TODO item, identified by id property or heading text"
         :schema (mcp-emacs-server--obj
                  "type" "object"
                  "properties" (mcp-emacs-server--obj
                                "path" (mcp-emacs-server--prop "string" "Absolute path to the session task Org file")
                                "item" (mcp-emacs-server--prop "string" "Item reference: its ID/CUSTOM_ID property, else its heading text")
                                "status" (mcp-emacs-server--prop "string" "Org TODO keyword to set on the item"))
                  "required" (vector "path" "item" "status"))
         :handler (lambda (args)
                    (mcp-emacs-org-task-set-item-status
                     (alist-get 'path args)
                     (alist-get 'item args)
                     (alist-get 'status args))))
   (list :name "org_task_append_note"
         :description "Append a progress note to the task body without altering existing content"
         :schema (mcp-emacs-server--obj
                  "type" "object"
                  "properties" (mcp-emacs-server--obj
                                "path" (mcp-emacs-server--prop "string" "Absolute path to the session task Org file")
                                "note" (mcp-emacs-server--prop "string" "Progress note text to append"))
                  "required" (vector "path" "note"))
         :handler (lambda (args)
                    (mcp-emacs-org-task-append-note
                     (alist-get 'path args)
                     (alist-get 'note args))))
   (list :name "org_task_append_item"
         :description "Append a new TODO item as a child under the task heading"
         :schema (mcp-emacs-server--obj
                  "type" "object"
                  "properties" (mcp-emacs-server--obj
                                "path" (mcp-emacs-server--prop "string" "Absolute path to the session task Org file")
                                "text" (mcp-emacs-server--prop "string" "Heading text for the new TODO item")
                                "keyword" (mcp-emacs-server--prop "string" "Optional Org TODO keyword; defaults to the first configured keyword"))
                  "required" (vector "path" "text"))
         :handler (lambda (args)
                    (mcp-emacs-org-task-append-item
                     (alist-get 'path args)
                     (alist-get 'text args)
                     (alist-get 'keyword args)))))
  "List of tool descriptors.  Each is a plist with :name :description :schema :handler.")

(defun mcp-emacs-server--find-tool (name)
  "Return the tool descriptor whose :name equals NAME, or nil."
  (seq-find (lambda (tool) (string= (plist-get tool :name) name))
            mcp-emacs-server--tools))

;;;; Resource registry

(defconst mcp-emacs-server--resources
  (list
   (list :uri "org-tasks://all"
         :name "org-tasks"
         :description "All TODO items from org-mode agenda files"
         :mime "text/plain"
         :reader (lambda () (mcp-emacs-get-org-tasks)))
   (list :uri "buffer://messages"
         :name "messages-buffer"
         :description "Live contents of the *Messages* buffer"
         :mime "text/plain"
         :reader (lambda () (mcp-emacs-get-buffer-text "*Messages*")))
   (list :uri "buffer://warnings"
         :name "warnings-buffer"
         :description "Live contents of the *Warnings* buffer"
         :mime "text/plain"
         :reader (lambda () (mcp-emacs-get-buffer-text "*Warnings*"))))
  "List of resource descriptors.  Each is a plist with :uri :name :description :mime :reader.")

(defun mcp-emacs-server--find-resource (uri)
  "Return the resource descriptor whose :uri equals URI, or nil."
  (seq-find (lambda (res) (string= (plist-get res :uri) uri))
            mcp-emacs-server--resources))

;;;; JSON-RPC dispatch

(defun mcp-emacs-server--tools-list ()
  "Return the JSON value for a tools/list result."
  (mcp-emacs-server--obj
   "tools"
   (apply #'vector
          (mapcar (lambda (tool)
                    (mcp-emacs-server--obj
                     "name" (plist-get tool :name)
                     "description" (plist-get tool :description)
                     "inputSchema" (plist-get tool :schema)))
                  mcp-emacs-server--tools))))

(defun mcp-emacs-server--tools-call (params)
  "Execute a tools/call request described by PARAMS, return the result value."
  (let* ((name (alist-get 'name params))
         (args (alist-get 'arguments params))
         (tool (mcp-emacs-server--find-tool name)))
    (unless tool
      (error "Unknown tool: %s" name))
    (let ((text (funcall (plist-get tool :handler) args)))
      (mcp-emacs-server--obj
       "content" (vector (mcp-emacs-server--obj
                          "type" "text"
                          "text" (format "%s" (or text ""))))))))

(defun mcp-emacs-server--resources-list ()
  "Return the JSON value for a resources/list result."
  (mcp-emacs-server--obj
   "resources"
   (apply #'vector
          (mapcar (lambda (res)
                    (mcp-emacs-server--obj
                     "uri" (plist-get res :uri)
                     "name" (plist-get res :name)
                     "description" (plist-get res :description)
                     "mimeType" (plist-get res :mime)))
                  mcp-emacs-server--resources))))

(defun mcp-emacs-server--resources-read (params)
  "Execute a resources/read request described by PARAMS, return the result value."
  (let* ((uri (alist-get 'uri params))
         (res (mcp-emacs-server--find-resource uri)))
    (unless res
      (error "Unknown resource: %s" uri))
    (let ((text (funcall (plist-get res :reader))))
      (mcp-emacs-server--obj
       "contents" (vector (mcp-emacs-server--obj
                           "uri" uri
                           "mimeType" (plist-get res :mime)
                           "text" (format "%s" (or text ""))))))))

(defun mcp-emacs-server--dispatch (request)
  "Dispatch a parsed JSON-RPC REQUEST alist, returning a response alist or nil.
Returns nil for notifications, which require no response."
  (let ((id (alist-get 'id request))
        (method (alist-get 'method request))
        (params (alist-get 'params request)))
    (cond
     ((null method) nil)
     ((string= method "initialize")
      (mcp-emacs-server--result
       id (mcp-emacs-server--obj
           "protocolVersion" mcp-emacs-server-protocol-version
           "capabilities" (mcp-emacs-server--obj
                           "tools" (mcp-emacs-server--obj)
                           "resources" (mcp-emacs-server--obj))
           "serverInfo" (mcp-emacs-server--obj
                         "name" "mcp-emacs" "version" "0.5.0"))))
     ((string= method "tools/list")
      (mcp-emacs-server--result id (mcp-emacs-server--tools-list)))
     ((string= method "tools/call")
      (condition-case err
          (mcp-emacs-server--result id (mcp-emacs-server--tools-call params))
        (error (mcp-emacs-server--error id -32603 (error-message-string err)))))
     ((string= method "resources/list")
      (mcp-emacs-server--result id (mcp-emacs-server--resources-list)))
     ((string= method "resources/read")
      (condition-case err
          (mcp-emacs-server--result id (mcp-emacs-server--resources-read params))
        (error (mcp-emacs-server--error id -32603 (error-message-string err)))))
     ;; Notifications (id absent) need no reply.
     ((null id) nil)
     (t (mcp-emacs-server--error id -32601 (format "Method not found: %s" method))))))

(defun mcp-emacs-server--result (id result)
  "Build a JSON-RPC success response for ID carrying RESULT."
  (mcp-emacs-server--obj "jsonrpc" "2.0" "id" id "result" result))

(defun mcp-emacs-server--error (id code message)
  "Build a JSON-RPC error response for ID with CODE and MESSAGE."
  (mcp-emacs-server--obj
   "jsonrpc" "2.0" "id" id
   "error" (mcp-emacs-server--obj "code" code "message" message)))

;;;; HTTP handling

(defun mcp-emacs-server--parse-body (request)
  "Parse the JSON body of web-server REQUEST into an alist, or nil."
  (let ((body (and (slot-boundp request 'body) (oref request body))))
    (when (and body (not (string-empty-p body)))
      (let ((json-object-type 'alist)
            (json-array-type 'vector)
            (json-key-type 'symbol))
        (json-read-from-string body)))))

(defun mcp-emacs-server--handler (request)
  "Top-level `web-server' handler for an MCP REQUEST."
  (with-slots (process headers) request
    (let* ((is-post (assoc :POST headers))
           (rpc (ignore-errors (mcp-emacs-server--parse-body request))))
      (cond
       ;; POST with a JSON-RPC body: the normal MCP request path.
       ((and is-post rpc)
        (let* ((response (mcp-emacs-server--dispatch rpc)))
          (if response
              (let ((json (json-encode response)))
                (ws-response-header process 200
                                    '("Content-Type" . "application/json"))
                (process-send-string process json))
            ;; Notification: 202 Accepted, empty body.
            (ws-response-header process 202 '("Content-Type" . "application/json")))))
       ;; Anything else: minimal health response.
       (t
        (ws-response-header process 200 '("Content-Type" . "text/plain"))
        (process-send-string process "mcp-emacs server\n"))))))

;;;; Lifecycle

;;;###autoload
(defun mcp-emacs-server-running-p ()
  "Return non-nil when the MCP HTTP server is running."
  (and mcp-emacs-server--process t))

;;;###autoload
(defun mcp-emacs-server-start ()
  "Start the MCP HTTP server on `mcp-emacs-server-port'."
  (interactive)
  (when (mcp-emacs-server-running-p)
    (mcp-emacs-server-stop))
  (setq mcp-emacs-server--process
        (ws-start
         '(((:GET . ".*") . mcp-emacs-server--handler)
           ((:POST . ".*") . mcp-emacs-server--handler))
         mcp-emacs-server-port))
  ;; The listening socket is a normal process; without this Emacs asks
  ;; "Active processes exist; kill them?" on quit.
  (let ((proc (ws-process mcp-emacs-server--process)))
    (when (processp proc)
      (set-process-query-on-exit-flag proc nil)))
  (message "mcp-emacs server listening on http://localhost:%d" mcp-emacs-server-port)
  mcp-emacs-server--process)

;;;###autoload
(defun mcp-emacs-server-ensure ()
  "Start the MCP server if it is not already running; return its URL.
Idempotent: safe to call repeatedly, e.g. from `config.el' on startup
or from a launcher script via `emacsclient --eval'."
  (interactive)
  (unless (mcp-emacs-server-running-p)
    (mcp-emacs-server-start))
  (format "http://localhost:%d/mcp" mcp-emacs-server-port))

;;;###autoload
(defun mcp-emacs-server-stop ()
  "Stop the MCP HTTP server if running."
  (interactive)
  (when (mcp-emacs-server-running-p)
    (ws-stop mcp-emacs-server--process)
    (setq mcp-emacs-server--process nil)
    (message "mcp-emacs server stopped")))

(provide 'mcp-emacs-server)

;;; mcp-emacs-server.el ends here
