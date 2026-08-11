;;; agent-backend-test.el --- Tests for the shared agent-backend -*- lexical-binding: t; -*-

;; Batch tests for the shared core.  The preference dispatcher is the
;; load-bearing new logic: which backend agent-backend-start picks is a
;; per-machine decision, since a CLI can be installed yet unusable (no
;; subscription), so the signal is the defcustom, not a runtime probe.

(add-to-list 'load-path (expand-file-name "elisp"))
(require 'cl-lib)
(require 'agent-backend)
(defun check (l g w) (princ (format "%s %s: got=%S want=%S
" (if (equal g w) "PASS" "FAIL") l g w)))

;; Explicit preference wins regardless of server state.
(cl-letf (((symbol-function 'opencode-client--health) (lambda () t)))
  (let ((agent-backend-preference 'opencode))
    (check "forced-opencode" (agent-backend-prefer-opencode-p) t)))

(cl-letf (((symbol-function 'opencode-client--health) (lambda () nil)))
  (let ((agent-backend-preference 'opencode))
    (check "forced-opencode-despite-unhealthy" (agent-backend-prefer-opencode-p) t)))

(let ((agent-backend-preference 'claude))
  (check "forced-claude" (agent-backend-prefer-opencode-p) nil))

;; auto consults the server only for opencode.  Provide a stub
;; opencode-client feature first so the require inside
;; prefer-opencode-p finds it and cannot clobber the stub with the
;; real (server-probing) function.
(defun agent-backend-test--health (healthy)
  (lambda () healthy))
(unless (featurep 'opencode-client)
  (fset 'opencode-client--health (lambda () nil))
  (provide 'opencode-client))
(cl-letf (((symbol-function 'opencode-client--health) (lambda () t)))
  (let ((agent-backend-preference 'auto))
    (check "auto-healthy-opencode" (agent-backend-prefer-opencode-p) t)))
(cl-letf (((symbol-function 'opencode-client--health) (lambda () nil)))
  (let ((agent-backend-preference 'auto))
    (check "auto-unhealthy-falls-to-claude" (agent-backend-prefer-opencode-p) nil)))

;; Default is auto.
(check "default-preference" agent-backend-preference 'auto)

;; The class dispatches note-policy from the slot.
(let ((b (make-instance 'agent-backend)))
  (check "default-note-policy" (agent-backend-note-policy b) :steer)
  (oset b note-policy :queue)
  (check "oset-note-policy" (agent-backend-note-policy b) :queue))
