(add-to-list 'load-path (expand-file-name "elisp"))
(require 'cl-lib)
;; Avoid loading the full runner (needs eat) -- stub the two helpers the
;; command uses; the unit tests below never call the command itself.
(provide 'mcp-emacs-run)
(defun mcp-emacs-run--project-root () default-directory)
(defun mcp-emacs-run--project-name (root) (file-name-nondirectory (directory-file-name root)))
(defvar mcp-emacs-run--launched nil)
(defun mcp-emacs-run--launch (&rest args) (setq mcp-emacs-run--launched args))
(require 'mcp-emacs-run-resume)

(defun check (l g w) (princ (format "%s %s\n" (if (equal g w) "PASS" "FAIL") l)))

;;;; slug builder
(check "slug-basic"
       (mcp-emacs-run-resume--slug "/Users/x/git/mcp-emacs")
       "-Users-x-git-mcp-emacs")
(check "slug-dots"
       (mcp-emacs-run-resume--slug "/Users/x/.emacs.d")
       "-Users-x--emacs-d")
(check "slug-trailing-slash"
       (mcp-emacs-run-resume--slug "/Users/x/proj/")
       "-Users-x-proj")

;;;; content normalisation
(check "content-string" (mcp-emacs-run-resume--content-text "hi") "hi")
(check "content-array-text"
       (mcp-emacs-run-resume--content-text (vector '((type . "text") (text . "hello"))))
       "hello")
(check "content-array-skip-nontext"
       (mcp-emacs-run-resume--content-text
        (vector '((type . "tool_result")) '((type . "text") (text . "real"))))
       "real")
(check "content-nil" (mcp-emacs-run-resume--content-text nil) nil)

;;;; noise predicate
(check "noise-command" (and (mcp-emacs-run-resume--noise-p "<command-message>x</command-message>") t) t)
(check "noise-local-caveat" (and (mcp-emacs-run-resume--noise-p "<local-command-caveat>y") t) t)
(check "noise-caveat" (and (mcp-emacs-run-resume--noise-p "Caveat: blah") t) t)
(check "noise-empty" (and (mcp-emacs-run-resume--noise-p "   ") t) t)
(check "noise-real" (mcp-emacs-run-resume--noise-p "show open issues") nil)

;;;; first-prompt over a fixture store
(let* ((store (make-temp-file "resume-store-" t)))
  ;; clean string prompt
  (let ((f (expand-file-name "aaa.jsonl" store)))
    (with-temp-file f
      (insert "{\"type\":\"mode\"}\n"
              "{\"type\":\"user\",\"message\":{\"content\":\"show open issues\"}}\n"))
    (check "prompt-clean" (mcp-emacs-run-resume--first-prompt f) "show open issues"))
  ;; caveat/command block precedes the real prompt -> skip to real
  (let ((f (expand-file-name "bbb.jsonl" store)))
    (with-temp-file f
      (insert "{\"type\":\"user\",\"message\":{\"content\":\"<local-command-caveat>Caveat: x\"}}\n"
              "{\"type\":\"user\",\"message\":{\"content\":\"<command-message>opsx:new</command-message>\"}}\n"
              "{\"type\":\"user\",\"message\":{\"content\":\"the actual prompt\"}}\n"))
    (check "prompt-skip-noise" (mcp-emacs-run-resume--first-prompt f) "the actual prompt"))
  ;; array content
  (let ((f (expand-file-name "ccc.jsonl" store)))
    (with-temp-file f
      (insert "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"array prompt\"}]}}\n"))
    (check "prompt-array" (mcp-emacs-run-resume--first-prompt f) "array prompt"))
  ;; multi-line prompt -> first line only
  (let ((f (expand-file-name "ddd.jsonl" store)))
    (with-temp-file f
      (insert "{\"type\":\"user\",\"message\":{\"content\":\"line one\\nline two\"}}\n"))
    (check "prompt-first-line" (mcp-emacs-run-resume--first-prompt f) "line one"))
  ;; no genuine prompt in head -> nil (label falls back to id)
  (let ((f (expand-file-name "eee.jsonl" store)))
    (with-temp-file f
      (insert "{\"type\":\"user\",\"message\":{\"content\":\"<command-message>only noise</command-message>\"}}\n"))
    (check "prompt-none" (mcp-emacs-run-resume--first-prompt f) nil)
    (check "label-id-fallback"
           (string-suffix-p "eee" (mcp-emacs-run-resume--label f)) t)))

;;;; session-files: mtime ordering, newest first, .jsonl only
(let* ((store (make-temp-file "resume-order-" t))
       (slug-root "/tmp/fake-proj"))
  (cl-letf (((symbol-function 'mcp-emacs-run-resume--store-dir) (lambda (_r) store)))
    (let ((old (expand-file-name "old.jsonl" store))
          (new (expand-file-name "new.jsonl" store)))
      (with-temp-file old (insert "{}\n"))
      (with-temp-file new (insert "{}\n"))
      (set-file-times old '(20000 0))
      (set-file-times new '(25000 0))
      (with-temp-file (expand-file-name "notes.txt" store) (insert "ignore"))
      (let ((files (mcp-emacs-run-resume--session-files slug-root)))
        (check "files-count" (length files) 2)
        (check "files-newest-first"
               (mcp-emacs-run-resume--session-id (car files)) "new")))))
