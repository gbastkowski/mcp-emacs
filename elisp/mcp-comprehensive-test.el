;;; mcp-comprehensive-test.el --- Comprehensive MCP server test -*- lexical-binding: t; -*-

(require 'json)

(defun mcp-test--read-line ()
  "Read a line from stdin, return nil on EOF."
  (condition-case nil
      (read-from-minibuffer "")
    (end-of-file nil)))

(defun mcp-test--send-response (response)
  "Send JSON-RPC response to stdout."
  (let ((json (json-serialize response)))
    (princ (concat json "\n"))))

(defun mcp-test--send-error (id code message)
  "Send JSON-RPC error response."
  (mcp-test--send-response
   `((jsonrpc . "2.0")
     (id . ,id)
     (error . ((code . ,code)
              (message . ,message))))))

(defun mcp-test--handle-initialize (id params)
  "Handle initialize request."
  (mcp-test--send-response
   `((jsonrpc . "2.0")
     (id . ,id)
     (result . ((capabilities . ((tools . t) (resources . t)))
               (serverInfo . ((name . "mcp-emacs") (version . "1.0.0"))))))))

(defun mcp-test--handle-unknown (id method)
  "Handle unknown method."
  (mcp-test--send-error id -32601 (format "Method not found: %s" method)))

(defun mcp-test--main-loop ()
  "Main server loop."
  (while (setq line (mcp-test--read-line))
    (let ((message (with-temp-buffer
                     (insert line)
                     (goto-char (point-min))
                     (json-read))))
      (let ((method (alist-get 'method message))
            (id (alist-get 'id message)))
        (cond
         ((string= method "initialize")
          (mcp-test--handle-initialize id (alist-get 'params message)))
         (method
          (mcp-test--handle-unknown id method))
         (t
          ;; Notification - no response needed
          ))))))

;; Start the server
(mcp-test--main-loop)