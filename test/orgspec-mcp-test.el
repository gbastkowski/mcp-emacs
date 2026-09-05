;;; orgspec-mcp-test.el --- Tests for the orgspec MCP tools -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'cl-lib)
(require 'orgspec-mcp)

(describe "orgspec-mcp-register"
  (it "lands every orgspec tool on the server extra-tools var"
    (check (length mcp-emacs-server-extra-tools) 8))
  (it "registers the orgspec tools under their advertised names"
    (check (sort (mapcar (lambda (tl) (plist-get tl :name)) mcp-emacs-server-extra-tools)
                 #'string<)
           '("orgspec_advance" "orgspec_agenda" "orgspec_archive"
             "orgspec_new" "orgspec_parse" "orgspec_review"
             "orgspec_status" "orgspec_validate")))
  (orgspec-mcp-register)
  (it "keeps the tool count unchanged when registered twice"
    (check (length mcp-emacs-server-extra-tools) 8))
  (it "gives every descriptor a name, description, schema and callable handler"
    (check-that (seq-every-p (lambda (tl) (and (plist-get tl :name)
                                               (plist-get tl :description)
                                               (plist-get tl :schema)
                                               (functionp (plist-get tl :handler))))
                             mcp-emacs-server-extra-tools))))

;; Drive the new -> status -> parse -> advance handlers on a temp project.
(let* ((root (make-temp-file "orgspec-mcp-" t))
       (default-directory (file-name-as-directory root))
       (orgspec-root "orgspec")
       (org-todo-keywords '((sequence "TODO" "STRT" "WAIT" "|" "DONE" "KILL"))))
  (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
    ;; No ambient project here, so the tool is told which one to act on --
    ;; the routing an agent over HTTP has to use anyway.
    (orgspec-mcp-call "orgspec_new" `((id . "add-auth") (root . ,root)))
    (describe "orgspec_new"
      (let ((f (orgspec-commands--change-file "add-auth")))
        (it "writes a change file for the new change"
          (check (file-exists-p f) t))
        (with-temp-file f
          (insert "* Tasks\n- [ ] a\n- [x] b\n* Delta\n"
                  "** Login required :ADDED:\n:PROPERTIES:\n:AREA: auth\n:END:\n"
                  "The system SHALL require login.\n*** happy\n- GIVEN x\n"))))

    (describe "orgspec-mcp--status"
      (it "reports how many of the change's tasks are done"
        (check (orgspec-mcp--status '((id . "add-auth")))
               "add-auth: 1/2 tasks done")))

    (describe "orgspec-mcp--parse"
      (let ((s (orgspec-mcp--parse '((id . "add-auth")))))
        (it "includes each delta requirement's heading"
          (check-that (string-match-p "Login required" s)))
        (it "includes the requirement's area property"
          (check-that (string-match-p "area=auth" s)))))

    (describe "orgspec-mcp--advance"
      (it "moves a requirement to the active todo keyword"
        (check (orgspec-mcp--advance
                '((id . "add-auth") (requirement . "Login required") (role . "active")))
               (format "Login required -> %s" orgspec-todo-active))))))

;;;; Project routing (issue #57)

(describe "orgspec tool schemas"
  ;; Every tool advertises the optional `root' argument, so a caller over
  ;; HTTP can name the project instead of inheriting the session's buffer.
  (it "all advertise an optional `root' so a caller can name the project"
    (check-that
     (seq-every-p
      (lambda (tl)
        (let ((props (alist-get "properties" (plist-get tl :schema) nil nil #'equal)))
          (and props (assoc "root" props) t)))
      mcp-emacs-server-extra-tools))))

;; `root' wins over the ambient project: the write lands in the stated
;; project, not in the one `default-directory' would have chosen.
(let* ((stated (make-temp-file "orgspec-stated-" t))
       (ambient (make-temp-file "orgspec-ambient-" t))
       (default-directory (file-name-as-directory ambient))
       (orgspec-root "orgspec"))
  (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
    (orgspec-mcp-call "orgspec_new" `((id . "routed") (root . ,stated)))
    (describe "a stated `root'"
      (it "wins over the ambient project and takes the write"
        (check (file-exists-p (expand-file-name "orgspec/changes/routed/change.org" stated))
               t))
      (it "leaves the ambient project untouched"
        (check (file-exists-p (expand-file-name "orgspec/changes/routed/change.org" ambient))
               nil)))))

;; With no project stated and none detectable, the root is a guess from
;; `default-directory' -- creating a tree there is the bug, so refuse.
(let* ((elsewhere (make-temp-file "orgspec-guess-" t))
       (default-directory (file-name-as-directory elsewhere))
       (orgspec-root "orgspec")
       (orgspec-project-root nil))
  (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
    (describe "orgspec_new with no project stated and none detectable"
      (it "refuses rather than acting on a guessed root"
        (check (condition-case err
                   (progn (orgspec-mcp-call "orgspec_new" '((id . "nope"))) :created)
                 (user-error (and (string-match-p "guess" (error-message-string err))
                                  :refused)))
               :refused))
      (it "creates nothing where it would have guessed"
        (check (file-directory-p (expand-file-name "orgspec" elsewhere)) nil)))))

;; An existing tree is opt-in enough: no root needed to keep working in it.
(let* ((initialised (make-temp-file "orgspec-existing-" t))
       (default-directory (file-name-as-directory initialised))
       (orgspec-root "orgspec")
       (orgspec-project-root nil))
  (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
    (make-directory (expand-file-name "orgspec/changes" initialised) t)
    (describe "orgspec_new in a directory with an existing orgspec tree"
      (it "needs no stated root to keep working in that tree"
        (check (progn (orgspec-mcp-call "orgspec_new" '((id . "ok")))
                      (file-exists-p
                       (expand-file-name "orgspec/changes/ok/change.org" initialised)))
               t)))))

(test-helper-summary)

;;; orgspec-mcp-test.el ends here
