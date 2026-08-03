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
    (orgspec-mcp--new '((id . "add-auth")))
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
