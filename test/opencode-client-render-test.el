;;; opencode-client-render-test.el --- Tool detail rendering -*- lexical-binding: t; -*-

(require 'test-helper)
(require 'cl-lib)
(load "opencode-client.el" nil t)

(defmacro with-tool-view (&rest body)
  "Evaluate BODY in an isolated conversation with one completed shell call."
  (declare (indent 0))
  `(with-temp-buffer
     (opencode-client-mode)
     (let* ((backend (make-instance 'opencode-client-backend :buffer (current-buffer)
                                    :session-id "ses_render"))
            (part '((id . "m:call") (type . "tool") (tool . "shell")
                    (time . ((created . 1000) (ran . 1100) (completed . 2600)))
                    (state . ((status . "completed")
                              (input . ((command . "git status --short") (cwd . "/project")))
                              (content . (((type . "text")
                                           (text . "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n"))))))))
            (opencode-client-tool-input-lines 4)
            (opencode-client-tool-result-lines 3)
            (opencode-client-tool-preview-chars 2000))
       (setq-local agent-backend--instance backend)
       (opencode-client--put-part backend "m" "m:call" (copy-tree part))
       (unwind-protect (progn ,@body)
         (agent-backend-quit backend)))))

(with-tool-view
  (describe "tool call previews"
    (it "shows the command and working directory without needing expansion"
      (opencode-client--render)
      (check-that (string-match-p "command: git status --short" (buffer-string)))
      (check-that (string-match-p "cwd: /project" (buffer-string))))
    (it "shows bounded result lines and an explicit expansion hint"
      (check-that (string-match-p "one\n      two\n      three" (buffer-string)))
      (check (string-match-p "      four" (buffer-string)) nil)
      (check-that (string-match-p "5 more lines" (buffer-string)))
      (check-that (string-match-p "TAB to expand" (buffer-string))))
    (it "shows an observed completed duration"
      (check-that (string-match-p "1.5s" (buffer-string))))
    (it "retains the complete result in the model"
      (check (opencode-client--tool-result-text (gethash "m:call" (oref backend parts)))
             "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n"))
    (it "bounds a very long single line by characters too"
      (let ((opencode-client-tool-preview-chars 12))
        (check-that (string-match-p "characters hidden"
                                   (opencode-client--tool-detail
                                    "Result" (make-string 1000 ?x) 3 nil)))
        (check-that (< (length (opencode-client--tool-detail
                               "Result" (make-string 1000 ?x) 3 nil)) 200))))))

(with-tool-view
  (describe "tool detail expansion"
    (it "expands a tool from its input or result, not only its heading"
      (opencode-client--render)
      (goto-char (point-min))
      (search-forward "two")
      (opencode-client-toggle-tool-details)
      (check-that (string-match-p "      eight" (buffer-string)))
      (check (string-match-p "characters hidden" (buffer-string)) nil)
      (check (get-text-property (point) 'opencode-client-tool-id) "m:call"))
    (it "stays expanded across repeated stream renders"
      (opencode-client--render)
      (check-that (string-match-p "      eight" (buffer-string))))
    (it "collapses again without losing its place"
      (opencode-client-toggle-tool-details)
      (check (string-match-p "      eight" (buffer-string)) nil)
      (check (point) (point-min)))
    (it "does not share expansion state with another conversation"
      (push "m:call" opencode-client--expanded-tools)
      (with-temp-buffer
        (opencode-client-mode)
        (check opencode-client--expanded-tools nil)))
    (it "refuses expansion outside a tool call"
      (goto-char (point-max))
      (check-that (condition-case nil (progn (opencode-client-toggle-tool-details) nil)
                    (user-error t))))))

(describe "tool value formatting"
  (it "keeps nested JSON arguments readable"
    (check-that (string-match-p "settings:"
                 (opencode-client--tool-input-text
                  '((state . ((input . ((settings . ((enabled . t))))))))))))
  (it "shows a structured failure reason separately from output"
    (with-tool-view
      (let ((failed (gethash "m:call" (oref backend parts))))
        (setf (alist-get 'status (alist-get 'state failed)) "error"
              (alist-get 'error (alist-get 'state failed))
              '((type . "ProcessError") (message . "Command exited with code 2")))
        (opencode-client--render)
        (check-that (string-match-p "Error:" (buffer-string)))
        (check-that (string-match-p "Command exited with code 2" (buffer-string))))))
  (it "labels file results without inserting embedded binary payloads"
    (let ((text (opencode-client--tool-output-text
                 '((state . ((content . (((type . "file") (name . "plot.png")
                                          (mime . "image/png") (uri . "data:image/png;base64,abcdef"))))))))))
      (check-that (string-match-p "plot.png" text))
      (check (string-match-p "abcdef" text) nil)))
  (it "does not invent a duration for missing timestamps"
    (check (opencode-client--tool-duration '((type . "tool"))) nil)))

(with-tool-view
  (describe "tool stream detail retention"
    (it "retains tool arguments after its terminal result event"
      (oset backend synchronized t)
      (opencode-client--apply-event
       (current-buffer)
       '((id . "result-event") (type . "session.tool.success") (created . 3000)
         (data . ((sessionID . "ses_render") (assistantMessageID . "m") (id . "call")
                  (content . (((type . "text") (text . "done"))))))))
      (let ((stored (gethash "m:call" (oref backend parts))))
        (check (alist-get 'command (alist-get 'input (alist-get 'state stored)))
               "git status --short")
        (check (alist-get 'completed (alist-get 'time stored)) 3000)))))

(with-tool-view
  (describe "rendered view stability"
    (it "keeps point on the same part when earlier tools grow"
      (opencode-client--put-part backend "later" "later:text"
                                 '((type . "text") (text . "Later answer")))
      (opencode-client--render)
      (goto-char (point-min))
      (search-forward "Later")
      (setq opencode-client--expanded-tools '("m:call"))
      (opencode-client--render)
      (check (buffer-substring-no-properties (- (point) 5) (point)) "Later"))
    (it "resolves anchors when history recreates equal but nonidentical IDs"
      (let ((anchor (opencode-client--view-anchor (point))))
        (oset backend messages '("later"))
        (clrhash (oref backend message-parts))
        (puthash "later" (list (copy-sequence "later:text")) (oref backend message-parts))
        (opencode-client--render)
        (check (car (opencode-client--view-anchor (opencode-client--anchor-position anchor)))
               "later:text")))))

(describe "tool detail keybindings"
  (it "binds both terminal and graphical TAB events"
    (check (lookup-key opencode-client-mode-map (kbd "TAB")) #'opencode-client-toggle-tool-details)
    (check (lookup-key opencode-client-mode-map (kbd "<tab>")) #'opencode-client-toggle-tool-details))
  (it "registers expansion for Evil normal and motion states when available"
    (let (bindings)
      (cl-letf (((symbol-function 'evil-define-key*)
                 (lambda (states _map _key command) (push (list states command) bindings))))
        (opencode-client--install-tool-keys))
      (check (length bindings) 2)
      (check (caar bindings) '(normal motion)))))

(test-helper-summary)
;;; opencode-client-render-test.el ends here
