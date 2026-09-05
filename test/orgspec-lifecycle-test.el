;;; orgspec-lifecycle-test.el --- Tests for the orgspec requirement lifecycle -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'orgspec-lifecycle)

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

(describe "orgspec-lifecycle-goto-requirement"
  (life-test--in-buffer
   (lambda ()
     (it "finds an untagged-keyword requirement by name"
       (check (and (orgspec-lifecycle-goto-requirement "Notify on lockout") t) t))
     (it "leaves point on the matched heading"
       (check (org-get-heading t t t t) "Notify on lockout"))))

  (life-test--in-buffer
   (lambda ()
     (goto-char (point-max))
     (let ((before (point)))
       (it "returns nil for an absent name"
         (check (orgspec-lifecycle-goto-requirement "Nope") nil))
       (it "does not move point when the name is absent"
         (check (point) before))))))

(describe "orgspec-lifecycle-advance-at-point"
  (life-test--in-buffer
   (lambda ()
     (orgspec-lifecycle-goto-requirement "Notify on lockout")
     (orgspec-lifecycle-advance-at-point 'active)
     (it "sets the active keyword"
       (check (org-get-todo-state) orgspec-todo-active))))

  (life-test--in-buffer
   (lambda ()
     (orgspec-lifecycle-goto-requirement "Second requirement")
     (orgspec-lifecycle-advance-at-point 'done)
     (it "reaches a done state for the done role"
       (check-that (member (substring-no-properties (org-get-todo-state))
                           org-done-keywords))))))

(describe "orgspec-lifecycle--keyword-for-role"
  (it "maps active to the active keyword"
    (check (orgspec-lifecycle--keyword-for-role 'active) orgspec-todo-active))
  (it "maps blocked to the blocked keyword"
    (check (orgspec-lifecycle--keyword-for-role 'blocked) orgspec-todo-blocked))
  (it "maps removed to the removed keyword"
    (check (orgspec-lifecycle--keyword-for-role 'removed) orgspec-todo-removed))
  (it "maps done to the `done' marker rather than a keyword"
    (check (orgspec-lifecycle--keyword-for-role 'done) 'done)))

(test-helper-summary)

;;; orgspec-lifecycle-test.el ends here
