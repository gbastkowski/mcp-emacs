;;; opencode-client-v2-live.el --- Opt-in V2 server smoke test -*- lexical-binding: t; -*-

;; bin/test-emacs.sh test/opencode-client-v2-live.el
;; Starts only a disposable standalone server, never the user's shared service.
;; No model prompts, provider credentials, or production MCP connections.

(require 'test-helper)
(load "opencode-client.el" nil t)
(require 'mcp-emacs-server)

(defun opencode-v2-live--wait (predicate)
  "Wait up to ten seconds for PREDICATE without blocking process filters."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall predicate)))

(let* ((root (expand-file-name default-directory))
       (sandbox (make-temp-file
                 (expand-file-name "opencode-v2-"
                                  (or (getenv "TMPDIR") temporary-file-directory)) t))
       (default-directory (file-name-as-directory sandbox))
       (process-environment
        (list (concat "PATH=" (getenv "PATH")) (concat "HOME=" sandbox)
              (concat "TMPDIR=" sandbox)
              (concat "XDG_CONFIG_HOME=" sandbox "/config")
              (concat "XDG_DATA_HOME=" sandbox "/data")
              (concat "XDG_STATE_HOME=" sandbox "/state")
              (concat "XDG_CACHE_HOME=" sandbox "/cache")
              (concat "OPENCODE_CONFIG_CONTENT="
                      (json-encode
                       `((mcp . ((servers . ((test_emacs .
                                              ((type . "remote")
                                               (url . ,(format "http://127.0.0.1:%d/mcp"
                                                               mcp-emacs-server-port)))))))))))))
       (probe (make-network-process :name "opencode-v2-test-port" :server t
                                     :host "127.0.0.1" :service t :noquery t))
       (port (process-contact probe :service))
       (opencode-client-host "127.0.0.1")
       (opencode-client-port port)
       (opencode-client-password nil)
       (opencode-client-password-command nil)
       (opencode-client--generated-password nil)
       (opencode-client--servers nil)
       (opencode-client--server-process nil)
       (opencode-client-launchd-label nil)
       (opencode-client-reconnect-delay 0.1)
       (agent-backend-event-functions nil)
       (log (get-buffer-create " *opencode-serve*"))
       server backend conversation session)
  (delete-process probe)
  (unwind-protect
      (progn
        (mcp-emacs-server-ensure)
        (opencode-client-serve)
        (setq server opencode-client--server-process)
        (describe "disposable OpenCode V2 service"
          (it "starts with separate credentials, storage and a non-production port"
            (check-that (opencode-v2-live--wait #'opencode-client--health))
            (check-that (stringp opencode-client--generated-password)))
          (unless (opencode-client--health)
            (error "Disposable OpenCode server failed: %s" (with-current-buffer log (buffer-string))))
          (it "creates and lists a session in its explicit location"
            (let* ((connection (make-instance 'opencode-client-backend :directory sandbox))
                   (info (opencode-client--data 'post "/api/session"
                          `((title . "Emacs V2 smoke") (location . ((directory . ,sandbox)))
                            (permissions . [((action . "shell") (resource . "*") (effect . "ask"))])) connection)))
              (setq session (alist-get 'id info))
              (check-that (stringp session))
              (check (alist-get 'directory (alist-get 'location info)) sandbox)
              (check (mapcar (lambda (s) (alist-get 'id s)) (opencode-client--sessions connection))
                     (list session))))
          (it "connects to the isolated test Emacs over classic MCP HTTP"
            (check-that
             (opencode-v2-live--wait
              (lambda ()
                (let* ((servers (opencode-client--data 'get "/api/mcp" nil backend))
                       (entry (seq-find (lambda (s) (equal (alist-get 'name s) "test_emacs")) servers)))
                  (equal (alist-get 'status (alist-get 'status entry)) "connected"))))))
          (it "discovers sandbox credentials and keeps them through opening and streaming"
            (let ((registration (opencode-client--service-file))
                  (opencode-client-discover-service t))
              (make-directory (file-name-directory registration) t)
              (with-temp-file registration
                (insert (json-encode
                         `((url . ,(format "http://127.0.0.1:%d" port))
                           (password . ,opencode-client--generated-password)))))
              ;; Both recovery requests and the SSE connection must use the
              ;; endpoint's credential, not a password for a different service.
              (let* ((opencode-client-password "deliberately-wrong-global-password")
                     (connection (opencode-client--discover)))
                (check-that (eieio-object-p connection))
                (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
                  (setq conversation (opencode-client--open-buffer
                                      session "V2 live smoke" nil connection)))
                (setq backend (buffer-local-value 'agent-backend--instance conversation))
                (check-that (opencode-v2-live--wait (lambda () (oref backend synchronized))))
                (check (agent-backend-turn-state backend) 'idle))))
          (it "receives and answers a real V2 permission request in Emacs"
            (cl-letf (((symbol-function 'agent-permission--display) #'ignore))
              (let* ((request (opencode-client--data
                               'post (opencode-client--session-path backend "/permission")
                               '((action . "shell") (resources . ["echo smoke"])) backend))
                     (id (alist-get 'id request))
                     (ui-id (opencode-client--ui-id backend id)))
                (check (alist-get 'effect request) "ask")
                (check-that (opencode-v2-live--wait (lambda () (member ui-id (agent-permission-pending-ids)))))
                (agent-permission--resolve ui-id 'deny)
                (check-that (opencode-v2-live--wait
                             (lambda () (not (gethash id (oref backend permissions))))))
                (check (opencode-client--data 'get (opencode-client--session-path backend "/permission") nil backend) nil))))
          (it "receives a live form and sends all typed field values to V2"
            (cl-letf (((symbol-function 'agent-question--display) #'ignore))
              (let* ((form (opencode-client--data
                            'post (opencode-client--session-path backend "/form")
                            '((title . "Smoke form")
                              (fields . [((key . "branch") (type . "string"))
                                         ((key . "confirm") (type . "boolean"))])) backend))
                     (id (alist-get 'id form))
                     (ui-id (opencode-client--ui-id backend id)))
                (check-that (opencode-v2-live--wait (lambda () (member ui-id (agent-question-pending-ids)))))
                (agent-question--resolve ui-id "main")
                (check-that (opencode-v2-live--wait (lambda () (member ui-id (agent-question-pending-ids)))))
                (agent-question--resolve ui-id "No")
                (check-that (opencode-v2-live--wait (lambda () (not (gethash id (oref backend forms))))))
                (let ((answer (alist-get 'answer (alist-get 'state
                               (opencode-client--data 'get
                                (concat (opencode-client--session-path backend "/form/") id) nil backend)))))
                  (check (alist-get 'branch answer) "main")
                  (check (alist-get 'confirm answer) :json-false)))))
          (it "recovers a form missed while its stream was disconnected"
            (with-current-buffer conversation (opencode-client--stop-stream))
            (cl-letf (((symbol-function 'agent-question--display) #'ignore))
              (let* ((form (opencode-client--data 'post (opencode-client--session-path backend "/form")
                            '((title . "Offline form") (fields . [((key . "text") (type . "string"))])) backend))
                     (id (alist-get 'id form))
                     (ui-id (opencode-client--ui-id backend id)))
                (with-current-buffer conversation (opencode-client--start-stream))
                (check-that (opencode-v2-live--wait (lambda () (member ui-id (agent-question-pending-ids)))))
                (opencode-client--data 'delete
                 (concat (opencode-client--session-path backend "/form/") id) nil backend)
                (check-that (opencode-v2-live--wait (lambda () (not (member ui-id (agent-question-pending-ids)))))))))
          (it "reconnects automatically after its curl subscriber exits"
            (oset backend synchronized nil)
            (delete-process (oref backend stream-process))
            (check-that (opencode-v2-live--wait (lambda () (oref backend synchronized)))))
          (it "deletes only its disposable session"
            (agent-backend-quit backend)
            (opencode-client--data 'delete (opencode-client--session-path backend) nil backend)
            (check (opencode-client--sessions backend) nil))))
    (when backend (agent-backend-quit backend))
    (when (buffer-live-p conversation) (kill-buffer conversation))
    (when (process-live-p server) (delete-process server))
    (mcp-emacs-server-stop)
    (with-current-buffer log
      (write-region (point-min) (point-max)
                    (expand-file-name ".test-emacs/opencode-v2-live.log" root) nil 'silent))
    (kill-buffer log)
    (delete-directory sandbox t)))

(test-helper-summary)
;;; opencode-client-v2-live.el ends here
