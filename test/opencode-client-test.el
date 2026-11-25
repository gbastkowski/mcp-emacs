;;; opencode-client-test.el --- Tests for the opencode client -*- lexical-binding: t; -*-

;; Batch tests for `opencode-client.el' that need no live server: URL
;; parsing and the service-file discovery path (with the health probe
;; stubbed out, since it talks HTTP).

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'cl-lib)
(load "opencode-client.el" nil t)

(describe "opencode-client--url-host-port"
  (it "parses host and port from a service url"
    (check (opencode-client--url-host-port "http://127.0.0.1:49374")
           '("127.0.0.1" . 49374)))
  (it "returns nil for something that is not a url"
    (check (opencode-client--url-host-port "not a url") nil))
  (it "supports bracketed IPv6 service URLs"
    (check (opencode-client--url-host-port "http://[::1]:49374/") '("::1" . 49374)))
  (it "does not silently downgrade HTTPS to an HTTP connection"
    (check (opencode-client--url-host-port "https://localhost:49374") nil)))

(describe "opencode-client--service-file"
  (it "defaults to ~/.local/state/opencode/service.json"
    (cl-letf (((getenv "XDG_STATE_HOME") nil))
      (check (opencode-client--service-file)
             (expand-file-name "opencode/service.json" "~/.local/state")))))

(describe "opencode-client--discover"
  (let ((opencode-client-discover-service t)
        (file (make-temp-file "opencode-service" nil ".json"
                              "{\"url\":\"http://127.0.0.1:49374\",\"password\":\"s3cret\",\"version\":\"2.2.0\"}")))
    (unwind-protect
        (cl-letf (((symbol-function 'opencode-client--service-file)
                   (lambda () file))
                  ((symbol-function 'opencode-client--health)
                   (lambda (_backend) t)))
          (let ((backend (opencode-client--discover)))
            (it "finds the registered server's host and port"
              (check (list (oref backend host) (oref backend port))
                     '("127.0.0.1" 49374)))
            (it "carries the server's password"
              (check (oref backend password) "s3cret"))))
      (delete-file file)))
  (it "returns nil when no service file is registered"
    (cl-letf (((symbol-function 'opencode-client--service-file)
               (lambda () "/nonexistent/opencode/service.json")))
      (check (opencode-client--discover) nil))))

(describe "shared-service credentials and project connections"
  (let ((opencode-client-password "other-server")
        (backend (make-instance 'opencode-client-backend :password "registered-secret")))
    (it "uses the discovered endpoint's credentials for HTTP requests"
      (check (cdr (assoc "Authorization" (opencode-client--headers backend)))
             (concat "Basic " (base64-encode-string "opencode:registered-secret" t)))))
  (let ((opencode-client-discover-service nil))
    (it "does not inspect service state when discovery is explicitly disabled"
      (cl-letf (((symbol-function 'opencode-client--service-file)
                 (lambda () (error "must not inspect the managed service"))))
        (check (opencode-client--discover) nil))))
  (let ((opencode-client--servers nil)
        (default-directory "/project/one/")
        (discoveries 0))
    (cl-letf (((symbol-function 'opencode-client--discover)
               (lambda ()
                 (cl-incf discoveries)
                 (make-instance 'opencode-client-backend :host "127.0.0.1" :port 49374
                                :password "registered-secret")))
              ((symbol-function 'opencode-client--health) (lambda (&rest _) t))
              ((symbol-function 'opencode-client--project-root) (lambda () default-directory))
              ((symbol-function 'opencode-client-serve)
               (lambda () (error "must not start a duplicate service"))))
      (let ((first (opencode-client--ensure-server)))
        (it "reuses a project's healthy discovered connection"
          (check (eq first (opencode-client--ensure-server)) t)
          (check discoveries 1))
        (setq default-directory "/project/two/")
        (let ((second (opencode-client--ensure-server)))
          (it "keeps distinct project locations on the same discovered service"
            (check (oref first directory) "/project/one")
            (check (oref second directory) "/project/two")
            (check (opencode-client--base-url first) (opencode-client--base-url second))))))))

(describe "opencode-client-create-session"
  (let ((captured nil))
    (cl-letf (((symbol-function 'opencode-client--ensure-server)
               (lambda () (make-instance 'opencode-client-backend :port 4096)))
              ((symbol-function 'opencode-client--request)
               (lambda (_method _path body _backend)
                 (setq captured body)
                 '((id . "ses_1"))))
              ((symbol-function 'opencode-client--open-buffer)
               (lambda (_id _title _resumed _server) nil)))
      (opencode-client-create-session)
      (it "scopes the session to the current project (a location directory)"
        (check (stringp (alist-get 'directory (alist-get 'location captured))) t))
      (opencode-client-create-session "My title")
      (it "sends the title when one is given"
        (check (alist-get 'title captured) "My title")))))

(describe "opencode-client-compose"
  (let ((source (generate-new-buffer " *opencode-compose-source*"))
        (conversation (generate-new-buffer " *opencode-compose-conversation*"))
        (other (generate-new-buffer " *opencode-compose-other*"))
        (agent-prompt-use-minibuffer nil)
        (agent-prompt-region-seed 'auto)
        prompt callback sent expected-source)
    (unwind-protect
        (save-window-excursion
          (let ((backend (make-instance 'opencode-client-backend
                                        :session-id "selected" :buffer conversation))
                (other-backend (make-instance 'opencode-client-backend
                                              :session-id "other" :buffer other)))
            (with-current-buffer conversation
              (opencode-client-mode)
              (setq-local agent-backend--instance backend))
            (with-current-buffer other
              (opencode-client-mode)
              (setq-local agent-backend--instance other-backend))
            (switch-to-buffer source)
            (insert "selected code")
            (setq-local transient-mark-mode t)
            (goto-char (point-min))
            (push-mark (point-max) t t)
            (setq expected-source source)
            (let ((read-prompt (symbol-function 'agent-prompt-read)))
              (cl-letf (((symbol-function 'opencode-client--active-backend)
                         (lambda () backend))
                        ((symbol-function 'opencode-client-send-prompt)
                         (lambda (text &optional steer)
                           (setq sent (list (current-buffer) text steer))))
                        ((symbol-function 'agent-prompt-read)
                         (lambda (fn initial label window origin)
                           (setq callback fn)
                           (check origin expected-source)
                           (check (window-buffer window) conversation)
                           (setq prompt (funcall read-prompt fn initial label window origin)))))
                (it "quotes the selection from a source buffer into the selected conversation"
                  (opencode-client-compose)
                  (check-that (buffer-live-p prompt))
                  (check-that
                   (with-current-buffer prompt
                     (string-match-p "selected code" (buffer-string)))))
                (it "keeps the chosen conversation when the active session changes during composition"
                  (setq backend other-backend)
                  (funcall callback "Explain this")
                  (check sent (list conversation "Explain this" nil)))
                (when (buffer-live-p prompt)
                  (with-current-buffer prompt (agent-prompt-abort)))
                (setq backend (buffer-local-value 'agent-backend--instance conversation))
                (switch-to-buffer conversation)
                (setq expected-source conversation)
                (it "preserves prefix-argument steering when composed in a conversation"
                  (opencode-client-compose t)
                  (funcall callback "Try this instead")
                  (check sent (list conversation "Try this instead" t)))
                (it "does not send a draft after its conversation was killed"
                  (kill-buffer conversation)
                  (setq sent nil)
                  (funcall callback "Do not send")
                  (check sent nil))))))
      (when (buffer-live-p prompt)
        (with-current-buffer prompt (agent-prompt-abort)))
      (dolist (buffer (list source conversation other))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(test-helper-summary)

;;; opencode-client-test.el ends here
