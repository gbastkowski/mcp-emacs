(add-to-list 'load-path (expand-file-name "elisp"))
(require 'orgspec-lifecycle)

(defun check (l g w) (princ (format "%s %s\n" (if (equal g w) "PASS" "FAIL") l)))

(defconst life-test--change "* Delta
** Notify on lockout                                 :ADDED:
:PROPERTIES:
:AREA: auth
:END:
The system SHALL notify.
*** Lockout triggered
- GIVEN a
** Second requirement                                :MODIFIED:
:PROPERTIES:
:AREA: auth
:END:
The system MUST also do b.
")

(defun life-test--in-buffer (fn)
  (with-temp-buffer
    (let ((org-inhibit-startup t)
          (org-todo-keywords '((sequence "TODO" "STRT" "WAIT" "|" "DONE" "KILL"))))
      (org-mode)
      (insert life-test--change)
      (goto-char (point-min))
      (funcall fn))))

;; goto finds an untagged-keyword requirement by name.
(life-test--in-buffer
 (lambda ()
   (check "goto-found" (and (orgspec-lifecycle-goto-requirement "Notify on lockout") t) t)
   (check "goto-on-heading" (org-get-heading t t t t) "Notify on lockout")))

;; goto returns nil and does not move for an absent name.
(life-test--in-buffer
 (lambda ()
   (goto-char (point-max))
   (let ((before (point)))
     (check "goto-absent" (orgspec-lifecycle-goto-requirement "Nope") nil)
     (check "goto-absent-nomove" (point) before))))

;; advance-at-point sets the active keyword.
(life-test--in-buffer
 (lambda ()
   (orgspec-lifecycle-goto-requirement "Notify on lockout")
   (orgspec-lifecycle-advance-at-point 'active)
   (check "advance-active" (org-get-todo-state) orgspec-todo-active)))

;; advance-at-point 'done reaches a done state.
(life-test--in-buffer
 (lambda ()
   (orgspec-lifecycle-goto-requirement "Second requirement")
   (orgspec-lifecycle-advance-at-point 'done)
   (check "advance-done"
          (and (member (substring-no-properties (org-get-todo-state))
                       org-done-keywords)
               t)
          t)))

;; role->keyword map.
(check "role-active" (orgspec-lifecycle--keyword-for-role 'active) orgspec-todo-active)
(check "role-blocked" (orgspec-lifecycle--keyword-for-role 'blocked) orgspec-todo-blocked)
(check "role-removed" (orgspec-lifecycle--keyword-for-role 'removed) orgspec-todo-removed)
(check "role-done" (orgspec-lifecycle--keyword-for-role 'done) 'done)
