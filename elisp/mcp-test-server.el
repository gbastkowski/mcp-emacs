;;; mcp-test-server.el --- Minimal test MCP server -*- lexical-binding: t; -*-

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

(defun mcp-test--handle-initialize (id)
  "Handle initialize request."
  (mcp-test--send-response
   `((jsonrpc . "2.0")
     (id . ,id)
     (result . ((capabilities . ((tools . t) (resources . t)))
               (serverInfo . ((name . "mcp-emacs") (version . "1.0.0"))))))))

(defun mcp-test--main-loop ()
  "Main server loop."
  (while (setq line (mcp-test--read-line))
    (let ((message (with-temp-buffer
                     (insert line)
                     (goto-char (point-min))
                     (json-read))))
      (when (and (alist-get 'method message) 
                 (string= (alist-get 'method message) "initialize"))
        (mcp-test--handle-initialize (alist-get 'id message))))))

;; Start the server
(mcp-test--main-loop)