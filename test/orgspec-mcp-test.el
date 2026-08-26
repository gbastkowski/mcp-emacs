(add-to-list 'load-path (expand-file-name "elisp"))
(require 'cl-lib)
(require 'orgspec-mcp)

(defun check (l g w) (princ (format "%s %s\n" (if (equal g w) "PASS" "FAIL") l)))

;; Registration: the six orgspec tools land on the server extra-tools var.
(check "reg-count" (length mcp-emacs-server-extra-tools) 8)
(check "reg-names"
       (sort (mapcar (lambda (tl) (plist-get tl :name)) mcp-emacs-server-extra-tools)
             #'string<)
       '("orgspec_advance" "orgspec_agenda" "orgspec_archive"
         "orgspec_new" "orgspec_parse" "orgspec_review"
         "orgspec_status" "orgspec_validate"))
;; Idempotent re-register keeps the count at eight.
(orgspec-mcp-register)
(check "reg-idempotent" (length mcp-emacs-server-extra-tools) 8)
;; Every descriptor has the required plist keys.
(check "reg-well-formed"
       (seq-every-p (lambda (tl) (and (plist-get tl :name)
                                      (plist-get tl :description)
                                      (plist-get tl :schema)
                                      (functionp (plist-get tl :handler))))
                    mcp-emacs-server-extra-tools)
       t)

;; Drive the new -> status -> parse -> advance handlers on a temp project.
(let* ((root (make-temp-file "orgspec-mcp-" t))
       (default-directory (file-name-as-directory root))
       (orgspec-root "orgspec")
       (org-todo-keywords '((sequence "TODO" "STRT" "WAIT" "|" "DONE" "KILL"))))
  (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
    ;; No ambient project here, so the tool is told which one to act on --
    ;; the routing an agent over HTTP has to use anyway.
    (orgspec-mcp-call "orgspec_new" `((id . "add-auth") (root . ,root)))
    (let ((f (orgspec-commands--change-file "add-auth")))
      (check "new-created" (file-exists-p f) t)
      (with-temp-file f
        (insert "* Tasks\n- [ ] a\n- [x] b\n* Delta\n"
                "** Login required :ADDED:\n:PROPERTIES:\n:AREA: auth\n:END:\n"
                "The system SHALL require login.\n*** happy\n- GIVEN x\n")))
    (check "status-text" (orgspec-mcp--status '((id . "add-auth")))
           "add-auth: 1/2 tasks done")
    (let ((s (orgspec-mcp--parse '((id . "add-auth")))))
      (check "parse-has-req" (and (string-match-p "Login required" s) t) t)
      (check "parse-has-area" (and (string-match-p "area=auth" s) t) t))
    (check "advance-active"
           (orgspec-mcp--advance
            '((id . "add-auth") (requirement . "Login required") (role . "active")))
           (format "Login required -> %s" orgspec-todo-active))))

;;;; Project routing (issue #57)

;; Every tool advertises the optional `root' argument, so a caller over
;; HTTP can name the project instead of inheriting the session's buffer.
(check "root-in-every-schema"
       (seq-every-p
        (lambda (tl)
          (let ((props (alist-get "properties" (plist-get tl :schema) nil nil #'equal)))
            (and props (assoc "root" props) t)))
        mcp-emacs-server-extra-tools)
       t)

;; `root' wins over the ambient project: the write lands in the stated
;; project, not in the one `default-directory' would have chosen.
(let* ((stated (make-temp-file "orgspec-stated-" t))
       (ambient (make-temp-file "orgspec-ambient-" t))
       (default-directory (file-name-as-directory ambient))
       (orgspec-root "orgspec"))
  (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
    (orgspec-mcp-call "orgspec_new" `((id . "routed") (root . ,stated)))
    (check "root-routes-write"
           (file-exists-p (expand-file-name "orgspec/changes/routed/change.org" stated))
           t)
    (check "root-spares-ambient"
           (file-exists-p (expand-file-name "orgspec/changes/routed/change.org" ambient))
           nil)))

;; With no project stated and none detectable, the root is a guess from
;; `default-directory' -- creating a tree there is the bug, so refuse.
(let* ((elsewhere (make-temp-file "orgspec-guess-" t))
       (default-directory (file-name-as-directory elsewhere))
       (orgspec-root "orgspec")
       (orgspec-project-root nil))
  (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
    (check "guessed-root-refused"
           (condition-case err
               (progn (orgspec-mcp-call "orgspec_new" '((id . "nope"))) :created)
             (user-error (and (string-match-p "guess" (error-message-string err))
                              :refused)))
           :refused)
    (check "guessed-root-writes-nothing"
           (file-directory-p (expand-file-name "orgspec" elsewhere)) nil)))

;; An existing tree is opt-in enough: no root needed to keep working in it.
(let* ((initialised (make-temp-file "orgspec-existing-" t))
       (default-directory (file-name-as-directory initialised))
       (orgspec-root "orgspec")
       (orgspec-project-root nil))
  (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
    (make-directory (expand-file-name "orgspec/changes" initialised) t)
    (check "existing-tree-needs-no-root"
           (progn (orgspec-mcp-call "orgspec_new" '((id . "ok")))
                  (file-exists-p
                   (expand-file-name "orgspec/changes/ok/change.org" initialised)))
           t)))
