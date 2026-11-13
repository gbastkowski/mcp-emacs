;;; opencode-client-help-test.el --- Session help UI -*- lexical-binding: t; -*-

(require 'test-helper)
(require 'cl-lib)
(load "opencode-client.el" nil t)

(defmacro with-opencode-help-view (&rest body)
  "Run BODY with a conversation and its windows in the isolated test Emacs."
  (declare (indent 0))
  `(save-window-excursion
     (delete-other-windows)
     (let ((conversation (generate-new-buffer "*opencode:help-test*")))
       (unwind-protect
           (progn
             (switch-to-buffer conversation)
             (opencode-client-mode)
             ,@body)
         (when (get-buffer opencode-client--help-buffer-name)
           (kill-buffer opencode-client--help-buffer-name))
         (when (buffer-live-p conversation) (kill-buffer conversation))))))

(describe "OpenCode session help keys"
  (it "binds ? without changing the existing input and tool expansion keys"
    (check (lookup-key opencode-client-mode-map (kbd "?")) #'opencode-client-help)
    (check (lookup-key opencode-client-mode-map (kbd "C-c C-c")) #'opencode-client-compose)
    (check (lookup-key opencode-client-mode-map (kbd "TAB")) #'opencode-client-toggle-tool-details))
  (it "overrides backward search in Evil normal and motion states"
    (let (binding)
      (cl-letf (((symbol-function 'evil-define-key*)
                 (lambda (states map key command) (setq binding (list states map key command)))))
        (opencode-client--install-help-key))
      (check (car binding) '(normal motion))
      (check (nth 2 binding) (kbd "?"))
      (check (nth 3 binding) #'opencode-client-help))))

(with-opencode-help-view
  (describe "OpenCode help contents"
    (it "opens help in a separate window without hiding the conversation"
      (opencode-client-help)
      (check-that (get-buffer-window opencode-client--help-buffer-name))
      (check-that (get-buffer-window conversation)))
    (it "shows tool expansion, prompt, interrupt, resume and disconnect controls"
      (with-current-buffer opencode-client--help-buffer-name
        (dolist (key '("TAB" "C-c C-c" "C-c C-k" "C-c C-r" "C-c C-q" "?"))
          (check-that (string-match-p (regexp-quote key) (buffer-string)) key))))
    (it "explains that disconnecting does not stop remote work"
      (with-current-buffer opencode-client--help-buffer-name
        (check-that (string-match-p "remote work keeps running" (buffer-string)))))
    (it "can be dismissed by pressing ? again in the conversation"
      (with-current-buffer conversation (opencode-client-help))
      (check (get-buffer-window opencode-client--help-buffer-name) nil)
      (check (length (window-list)) 1)
      (check-that (get-buffer-window conversation)))))

(with-opencode-help-view
  (let ((display-buffer-alist
         `((,(regexp-quote opencode-client--help-buffer-name)
            display-buffer-in-side-window (side . right)))))
    (describe "help placement and dismissal"
      (it "uses an ordinary split even when popup rules request a side window"
        (opencode-client-help)
        (check (window-parameter (get-buffer-window opencode-client--help-buffer-name) 'window-side) nil)
        (check-that (get-buffer-window conversation)))
      (it "closes only the help when q is invoked inside its buffer"
        (with-current-buffer opencode-client--help-buffer-name
          (call-interactively (local-key-binding (kbd "q"))))
        (check (length (window-list)) 1)
        (check-that (get-buffer-window conversation)))
      (it "does not accumulate windows when shown and dismissed repeatedly"
        (dotimes (_ 3)
          (with-current-buffer conversation (opencode-client-help))
          (with-current-buffer conversation (opencode-client-help)))
        (check (length (window-list)) 1)))))

(test-helper-summary)
;;; opencode-client-help-test.el ends here
