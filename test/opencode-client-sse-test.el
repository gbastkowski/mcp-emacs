;;; opencode-client-sse-test.el --- V2 client contracts -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'cl-lib)
(load "opencode-client.el" nil t)
(load "agent-session-overview.el" nil t)

(defmacro with-v2-client (&rest body)
  "Run BODY in a connected, session-scoped V2 client fixture."
  (declare (indent 0))
  `(with-temp-buffer
     (opencode-client-mode)
     (let* ((buffer (current-buffer))
            (backend (make-instance 'opencode-client-backend :session-id "ses_one"
                                    :buffer buffer :directory "/project/one"))
            (events nil)
            (agent-backend-event-functions
             (list (lambda (_buffer event) (push event events)))))
       (setq-local agent-backend--instance backend)
       (oset backend synchronized t)
       (oset backend connected t)
       (oset backend stopped nil)
       (unwind-protect (progn ,@body)
         (agent-backend-quit backend)))))

(defun v2-event (type data &optional id)
  "Build a V2 TYPE event with DATA and optional unique ID."
  `((id . ,(or id (format "%s-%s" type (random)))) (created . 100000)
    (type . ,type) (data . ,(cons (cons 'sessionID "ses_one") data))))

(defun v2-emit (buffer type data &optional id)
  "Dispatch a V2 TYPE/DATA event to BUFFER with optional ID."
  (opencode-client--apply-event buffer (v2-event type data id)))

(describe "V2 HTTP contracts"
  (let (calls)
    (cl-letf (((symbol-function 'opencode-client--request)
               (lambda (&rest args)
                 (push args calls)
                 '((version . "2.2.5")))))
      (it "probes the versioned server info route"
        (check-that (opencode-client--health))
        (check (cadar calls) "/api/info")))
    (cl-letf (((symbol-function 'opencode-client--request)
               (lambda (&rest _) '((version . "1.19.5")))))
      (it "does not accept a V1 server as compatible"
        (check (opencode-client--health) nil))))
  (let ((opencode-client-password "direct")
        (opencode-client-password-command "echo should-not-run")
        (opencode-client--generated-password "generated"))
    (it "keeps configured credentials ahead of generated credentials"
      (check (opencode-client--password) "direct")
      (check (cdr (assoc "Authorization" (opencode-client--headers)))
             (concat "Basic " (base64-encode-string "opencode:direct" t)))))
  (let ((opencode-client-password nil) (opencode-client-password-command nil)
        (opencode-client--generated-password "generated"))
    (it "authenticates a child server with its in-memory password"
      (check (opencode-client--password) "generated")))
  (let ((opencode-client-password nil) (opencode-client-password-command "printf '  secret\n'"))
    (it "trims credentials supplied by a secret-store command"
      (check (opencode-client--password) "secret")))
  (let ((opencode-client-password nil) (opencode-client-password-command nil)
        (opencode-client--generated-password nil) sent)
    (cl-letf (((symbol-function 'plz)
               (lambda (_method _url &rest options)
                 (setq sent options)
                 '((data . ((id . "ses_new")))))))
      (it "sends an empty JSON object for bodyless POSTs and preserves envelopes"
        (check (opencode-client--request 'post "/api/session")
               '((data . ((id . "ses_new")))))
        (check (plist-get sent :body) "{}")))))

(with-v2-client
  (let (calls)
    (cl-letf (((symbol-function 'opencode-client--request)
               (lambda (&rest args) (push args calls))))
      (describe "V2 input and approvals"
        (it "sends ordinary input as top-level text with queue delivery"
          (agent-backend-send backend "hello")
          (check (caddar calls) '((text . "hello") (delivery . "queue"))))
        (it "steers only when explicitly requested"
          (agent-backend-add-note backend "  new direction  ")
          (check (caddar calls) '((text . "new direction") (delivery . "steer"))))
        (it "does not claim an interrupt completed before its event arrives"
          (setq events nil)
          (agent-backend-interrupt backend)
          (check (cadar calls) "/api/session/ses_one/interrupt")
          (check events nil))
        (it "uses V2 permission decision values"
          (agent-backend-reply-permission backend "perm" "allow")
          (check (caddar calls) '((decision . "once")))
          (agent-backend-reply-permission backend "perm" "deny")
          (check (caddar calls) '((decision . "reject"))))
        (it "posts the complete keyed answer to a form, not a legacy question"
          (let ((answer (make-hash-table :test 'equal)))
            (puthash "branch" "main" answer)
            (agent-backend-reply-question backend "form" answer)
            (check (cadar calls) "/api/session/ses_one/form/form/reply")
            (check (gethash "branch" (alist-get 'answer (caddar calls))) "main")))
        (it "reports the explicit session location to shared UI consumers"
          (check (agent-backend-project-root backend) "/project/one/"))))))

(describe "V2 pagination and location scoping"
  (let (paths)
    (cl-letf (((symbol-function 'opencode-client--request)
               (lambda (_method path &rest _)
                 (push path paths)
                 (if (string-match-p "cursor=" path)
                     '((data . (((id . "ses_second")))) (cursor . ((next . nil))))
                   '((data . (((id . "ses_first")))) (cursor . ((next . "opaque +/="))))))))
      (it "retains pagination cursors and follows all project-scoped pages"
        (let* ((backend (make-instance 'opencode-client-backend :directory "/project/one"))
               (sessions (opencode-client--sessions backend)))
          (check (mapcar (lambda (s) (alist-get 'id s)) sessions) '("ses_first" "ses_second"))
          (check-that (string-match-p "directory=%2Fproject%2Fone" (car paths)))
          (check-that (string-match-p "cursor=opaque%20%2B%2F%3D" (car paths)))
          (check (string-match-p "order=" (car paths)) nil)))))
  (let (opened)
    (cl-letf (((symbol-function 'opencode-client--ensure-server)
               (lambda () (make-instance 'opencode-client-backend :directory "/project/two")))
              ((symbol-function 'opencode-client--request)
               (lambda (_method _path body &rest _) (setq opened body) '((data . ((id . "ses_new"))))))
              ((symbol-function 'opencode-client--open-buffer) #'ignore))
      (it "creates sessions with an explicit V2 location"
        (opencode-client-create-session "title")
        (check (alist-get 'directory (alist-get 'location opened)) "/project/two")
        (check (alist-get 'title opened) "title"))))
  (let ((opencode-client--active-sessions '(("/project/one" . "ses_one")))
        (default-directory "/project/two/")
        (agent-backend--instance nil))
    (cl-letf (((symbol-function 'opencode-client--directory) (lambda (&rest _) "/project/two"))
              ((symbol-function 'opencode-client--ensure-server)
               (lambda () (make-instance 'opencode-client-backend))))
      (it "never sends another project's last selected session by fallback"
        (check-that (condition-case nil (progn (opencode-client--active-backend) nil)
                      (user-error t)))))))

(with-v2-client
  (let* ((start (json-encode (v2-event "session.text.started"
                                     '((assistantMessageID . "msg") (ordinal . 0)) "start")))
         (delta (json-encode (v2-event "session.text.delta"
                                     '((assistantMessageID . "msg") (ordinal . 0) (delta . "héllo 🌍")) "delta")))
         (wire (encode-coding-string (concat "data: " start "\r\n\r\ndata: " delta "\r\n\r\n") 'utf-8)))
    (describe "V2 SSE framing"
      (it "handles CRLF and UTF-8 split across arbitrary byte chunks"
        (dotimes (i (length wire))
          (opencode-client--stream-filter buffer nil (substring wire i (1+ i))))
        (check (alist-get 'text (gethash "msg:0" (oref backend parts))) "héllo 🌍"))
      (it "suppresses duplicate event IDs without dropping transient deltas"
        (opencode-client--stream-filter buffer nil (encode-coding-string (concat "data: " delta "\n\n") 'utf-8))
        (check (alist-get 'text (gethash "msg:0" (oref backend parts))) "héllo 🌍"))
      (it "ignores comments and malformed frames without killing the subscriber"
        (opencode-client--stream-filter buffer nil ": heartbeat\n\ndata: invalid\n\n")
        (check (hash-table-count (oref backend parts)) 1))
      (it "ignores another session's output and permission requests"
        (let ((foreign (v2-event "permission.asked" '((id . "foreign")))))
          (setf (alist-get 'sessionID (alist-get 'data foreign)) "ses_other")
          (opencode-client--apply-event buffer foreign)
          (check (hash-table-count (oref backend permissions)) 0)))
      (it "overwrites streamed text with the authoritative ended text"
        (v2-emit buffer "session.text.ended" '((assistantMessageID . "msg") (ordinal . 0) (text . "Final")))
        (check (alist-get 'text (gethash "msg:0" (oref backend parts))) "Final")))))

(with-v2-client
  (describe "V2 execution and tool events"
    (it "tracks working and elapsed time from execution.started"
      (v2-emit buffer "session.execution.started" nil)
      (check (agent-backend-turn-state backend) 'working)
      (check-that (numberp (agent-backend-turn-elapsed backend))))
    (it "does not treat an individual tool-calls step as completion"
      (v2-emit buffer "session.step.ended" '((finish . "tool-calls")))
      (check (agent-backend-turn-state backend) 'working))
    (it "carries tool identity and arguments through to shared consumers"
      (v2-emit buffer "session.tool.input.started" '((assistantMessageID . "msg") (id . "tool1") (name . "subagent")))
      (v2-emit buffer "session.tool.called" '((assistantMessageID . "msg") (id . "tool1") (input . ((task . "review")))))
      (check (plist-get (car events) :name) "subagent")
      (check (plist-get (car events) :input) '((task . "review"))))
    (it "reports tool success content exactly once"
      (v2-emit buffer "session.tool.success"
               '((assistantMessageID . "msg") (id . "tool1") (content . (((type . "text") (text . "done"))))) "success")
      (check (plist-get (car events) :kind) 'tool-result)
      (check (plist-get (car events) :text) "done")
      (v2-emit buffer "session.tool.success" nil "success")
      (check (length (seq-filter (lambda (e) (eq (plist-get e :kind) 'tool-result)) events)) 1))
    (it "finishes on the execution event and updates the overview's state"
      (v2-emit buffer "session.execution.succeeded" nil)
      (check (agent-backend-turn-state backend) 'idle)
      (check (agent-backend-turn-elapsed backend) nil)
      (check (agent-session-overview--backend-state buffer) 'idle)
      (check (plist-get (car events) :kind) 'finished))))

(with-v2-client
  (let ((history '(((id . "user") (type . "user") (text . "Hi"))
                   ((id . "msg") (type . "assistant")
                    (content . (((type . "text") (text . "Hello"))
                                ((type . "reasoning") (text . "Thinking"))
                                ((type . "tool") (id . "tool1") (name . "read")
                                 (state . ((status . "completed"))))))))))
    (cl-letf (((symbol-function 'opencode-client--pages) (lambda (&rest _) (copy-tree history))))
      (describe "V2 history projection"
        (it "assigns stable ordinals to history text parts without IDs"
          (opencode-client--seed-history backend)
          (check (gethash "msg" (oref backend message-parts)) '("msg:0" "msg:1" "msg:tool1")))
        (it "replaces, rather than appends, history on repeated recovery"
          (opencode-client--seed-history backend)
          (check (oref backend messages) '("user" "msg"))
          (check (hash-table-count (oref backend parts)) 4))
        (it "keeps rendering compatible with the shared conversation UI"
          (agent-backend-render backend)
          (check (buffer-string) "Hi\nHello\n  · Thinking\n  [tool: read completed]\n"))))))

(with-v2-client
  (let (replies)
    (cl-letf (((symbol-function 'agent-question-request)
               (lambda (id question options &rest rest)
                 (push (list id question options (plist-get rest :resolve)) replies)))
              ((symbol-function 'opencode-client--request)
               (lambda (&rest args) (push args replies))))
      (describe "V2 multi-field forms"
        (it "collects every field before sending one keyed reply"
          (opencode-client--ask-question
           backend buffer
           '((id . "f1") (sessionID . "ses_one") (title . "Choose")
             (fields . (((key . "branch") (type . "string")
                         (options . (((label . "Main branch") (value . "main")))))
                        ((key . "confirm") (type . "boolean"))))))
          (check (nth 2 (car replies)) '("Main branch"))
          (funcall (nth 3 (car replies)) "Main branch")
          (check (nth 2 (car replies)) '("Yes" "No"))
          (funcall (nth 3 (car replies)) "No")
          (let ((answer (alist-get 'answer (nth 2 (car replies)))))
            (check (gethash "branch" answer) "main")
            (check (gethash "confirm" answer) :json-false))
          (check (hash-table-count (oref backend forms)) 0))
        (it "preserves typed numbers and multiselect option values"
          (check (opencode-client--form-value '((type . "integer")) "42") 42)
          (check (opencode-client--form-value
                  '((type . "multiselect") (options . (((label . "One") (value . "1"))))) "One,two")
                 ["1" "two"]))
        (it "honors conditional fields including boolean false"
          (let ((answers (make-hash-table :test 'equal)))
            (puthash "confirm" :json-false answers)
            (check-that (opencode-client--form-visible-p
                         '((when . (((key . "confirm") (op . "eq") (value . :json-false))))) answers))))))))

(with-v2-client
  (let ((agent-permission--pending nil)
        (agent-permission-session-allow-all-mode nil)
        resolved)
    (cl-letf (((symbol-function 'agent-permission--display) #'ignore)
              ((symbol-function 'opencode-client--request)
               (lambda (&rest args) (setq resolved args))))
      (describe "V2 permission ownership"
        (it "namespaces menus and saves permissions through OpenCode, not Claude files"
          (opencode-client--ask-permission backend buffer
           '((id . "p1") (action . "shell") (resources . ("git status"))))
          (let* ((ui-id (opencode-client--ui-id backend "p1"))
                 (menu (plist-get (cdr (assoc ui-id agent-permission--pending)) :buffer)))
            (check-that (buffer-live-p menu))
            (with-current-buffer menu
              (check (local-key-binding (kbd "z")) #'undefined)
              (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
                (call-interactively (local-key-binding (kbd "A")))))
            (sit-for 0.05)
            (check (alist-get 'decision (nth 2 resolved)) "always")))
        (it "dismisses a decision answered elsewhere without another reply"
          (setq resolved nil)
          (opencode-client--ask-permission backend buffer '((id . "p2") (action . "shell")))
          (v2-emit buffer "permission.replied" '((requestID . "p2") (reply . "once")))
          (check (agent-permission-pending-ids) nil)
          (check resolved nil))))))

(with-v2-client
  (let (requests)
    (cl-letf (((symbol-function 'opencode-client--request)
               (lambda (_method path &rest _)
                 (push path requests)
                 (cond
                  ((equal path "/api/session/ses_one")
                   '((data . ((location . ((directory . "/project/one"))) (time . ((busy . 99000)))))))
                  ((equal path "/api/session/active") '((data . ((ses_one . ((type . "running")))))))
                  (t '((data . nil)))))))
      (describe "V2 reconnect recovery"
        (it "restores history, active execution and pending-request inventories"
          (opencode-client--refresh backend)
          (check (agent-backend-turn-state backend) 'working)
          (check (oref backend turn-started) 99.0)
          (check-that (member "/api/session/ses_one/permission" requests))
          (check-that (member "/api/session/ses_one/form" requests))
          (check-that (member "/api/session/ses_one/message?order=asc" requests)))
        (it "does not append ambiguous deltas arriving during snapshot recovery"
          (oset backend syncing t)
          (v2-emit buffer "session.text.delta"
                   '((assistantMessageID . "msg") (ordinal . 0) (delta . "duplicate?")))
          (check-that (oref backend refresh-needed))
          (check (hash-table-count (oref backend parts)) 0)
          (oset backend syncing nil))
        (it "schedules one retry on EOF and cancels it on explicit quit"
          (opencode-client--disconnected backend (oref backend generation))
          (let ((timer (oref backend reconnect-timer)))
            (check-that (timerp timer))
            (opencode-client--disconnected backend (oref backend generation))
            (check (eq timer (oref backend reconnect-timer)) t)
            (agent-backend-quit backend)
            (check (oref backend reconnect-timer) nil)
            (check (oref backend refresh-timer) nil)
            (check (agent-backend-turn-state backend) 'finished)))
        (it "ignores stale disconnect callbacks after an explicit stop"
          (opencode-client--disconnected backend 0)
          (check (oref backend reconnect-timer) nil))))))

(with-v2-client
  (describe "live events during snapshot recovery"
    (it "keeps semantic tool events and transcript text while suppressing ambiguous display bytes"
      (oset backend syncing t)
      (v2-emit buffer "session.tool.input.started"
               '((assistantMessageID . "m") (id . "t") (name . "read")))
      (v2-emit buffer "session.tool.called"
               '((assistantMessageID . "m") (id . "t") (input . ((path . "file")))))
      (v2-emit buffer "session.text.delta"
               '((assistantMessageID . "m") (ordinal . 1) (delta . "live")))
      (check-that (seq-find (lambda (e) (eq (plist-get e :kind) 'tool-use)) events))
      (check (plist-get (car events) :text) "live")
      (check (gethash "m:1" (oref backend parts)) nil)
      (oset backend syncing nil))))

(describe "session identity and service ownership"
  (let ((opencode-client--active-sessions nil)
        (server (make-instance 'opencode-client-backend :directory "/project/one"))
        first second)
    (cl-letf (((symbol-function 'opencode-client--start-stream) #'ignore)
              ((symbol-function 'pop-to-buffer) #'ignore))
      (unwind-protect
          (progn
            (it "keeps equal titles in distinct buffers but reuses the same session identity"
              (setq first (opencode-client--open-buffer "ses_A" "Same title" nil server))
              (setq second (opencode-client--open-buffer "ses_B" "Same title" nil server))
              (check (eq first second) nil)
              (check (eq first (opencode-client--open-buffer "ses_A" "New title" t server)) t)))
        (when (buffer-live-p first) (kill-buffer first))
        (when (buffer-live-p second) (kill-buffer second)))))
  (let ((opencode-client--servers nil)
        (opencode-client-host "127.0.0.1")
        (opencode-client-port 50401)
        launches)
    (cl-letf (((symbol-function 'opencode-client--health) (lambda (&rest _) t))
              ((symbol-function 'make-process) (lambda (&rest _) (setq launches t))))
      (it "reuses the configured service for different project locations"
        (let ((default-directory "/project/one/")) (opencode-client-serve))
        (let ((default-directory "/project/two/")) (opencode-client-serve))
        (check (length opencode-client--servers) 2)
        (check (mapcar (lambda (s) (oref (cdr s) port)) opencode-client--servers) '(50401 50401))
        (check launches nil))))
  (it "formats an IPv6 service address correctly"
    (check (opencode-client--base-url (make-instance 'opencode-client-backend :host "::1" :port 4096))
           "http://[::1]:4096")))

(with-v2-client
  (let (calls)
    (cl-letf (((symbol-function 'opencode-client--request)
               (lambda (method path &rest _)
                 (push (cons method path) calls)
                 (cond ((equal path "/api/session") '((data . ((id . "ses_temporary")))))
                       ((string-suffix-p "/prompt" path) (error "provider unavailable"))
                       ((string-suffix-p "/interrupt" path) (error "already idle"))))))
      (describe "temporary V2 agent queries"
        (it "deletes temporary sessions even if prompt and interrupt both fail"
          (oset backend port 4096)
          (condition-case nil (agent-backend-query backend "explain" #'ignore) (error nil))
          (check-that (member '(delete . "/api/session/ses_temporary") calls)))))))

(with-v2-client
  (let ((outcome "succeeded") (active '((ses_one . ((type . "running"))))))
    (cl-letf (((symbol-function 'opencode-client--data)
               (lambda (_method path &rest _)
                 (cond ((equal path "/api/session/active") active)
                       ((equal path "/api/session/ses_one") `((outcome . ,outcome)))
                       (t '(((type . "assistant") (finish . "tool-calls")
                             (content . (((type . "text") (text . "answer")))))))))))
      (describe "V2 query completion boundaries"
        (it "does not return an intermediate assistant answer while execution is active"
          (check (opencode-client--completed-answer "ses_one" backend) nil))
        (it "collects text only once execution has succeeded"
          (setq active nil)
          (check (opencode-client--completed-answer "ses_one" backend) "answer"))
        (it "reports execution failures rather than polling them forever"
          (setq outcome "failed")
          (check-that (condition-case nil
                          (progn (opencode-client--completed-answer "ses_one" backend) nil)
                        (user-error t))))))))

(with-v2-client
  (let ((row (list :backend 'opencode :buffer buffer :state 'working)) calls)
    (cl-letf (((symbol-function 'agent-session-overview--entry-at-point) (lambda () row))
              ((symbol-function 'agent-session-overview--live-buffer-at-point) (lambda () buffer))
              ((symbol-function 'agent-session-overview--render) #'ignore)
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'opencode-client--request)
               (lambda (&rest args) (push args calls))))
      (describe "V2 overview controls"
        (it "interrupts through the OpenCode backend rather than the Claude client"
          (agent-session-overview-interrupt-session)
          (check (cadar calls) "/api/session/ses_one/interrupt"))
        (it "quits the local subscriber without deleting its remote session"
          (setq calls nil)
          (agent-session-overview-quit-session)
          (check (oref backend stopped) t)
          (check calls nil))))))

(with-v2-client
  (let ((agent-permission--pending nil)
        (agent-permission-session-allow-all-mode nil)
        bindings)
    (cl-letf (((symbol-function 'agent-permission--display) #'ignore)
              ((symbol-function 'evil-local-set-key)
               (lambda (state key definition) (push (list state key definition) bindings))))
      (describe "V2 permissions under Evil"
        (it "overrides Evil's Claude-specific always-allow and session-allow-all bindings"
          (opencode-client--ask-permission backend buffer
           '((id . "evil-permission") (action . "shell")))
          (check (length bindings) 4)
          (check (mapcar #'car bindings) '(motion motion normal normal))
          (check (nth 2 (car bindings)) #'undefined)
          (check-that (functionp (nth 2 (cadr bindings)))))))))

(test-helper-summary)
;;; opencode-client-sse-test.el ends here
