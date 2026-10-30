;;; opencode-client-test.el --- Tests for the opencode client -*- lexical-binding: t; -*-

;; Batch tests for `opencode-client.el' that need no live server: URL
;; parsing and the service-file discovery path (with the health probe
;; stubbed out, since it talks HTTP).

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'cl-lib)
(require 'opencode-client)

(describe "opencode-client--url-host-port"
  (it "parses host and port from a service url"
    (check (opencode-client--url-host-port "http://127.0.0.1:49374")
           '("127.0.0.1" . 49374)))
  (it "returns nil for something that is not a url"
    (check (opencode-client--url-host-port "not a url") nil)))

(describe "opencode-client--service-file"
  (it "defaults to ~/.local/state/opencode/service.json"
    (cl-letf (((getenv "XDG_STATE_HOME") nil))
      (check (opencode-client--service-file)
             (expand-file-name "opencode/service.json" "~/.local/state")))))

(describe "opencode-client--discover"
  (let ((file (make-temp-file "opencode-service" nil ".json"
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
      (it "sends an empty object body, not nil, when no title is given"
        (check (json-encode captured) "{}"))
      (opencode-client-create-session "My title")
      (it "sends the title when one is given"
        (check (alist-get 'title captured) "My title")))))

(test-helper-summary)

;;; opencode-client-test.el ends here
