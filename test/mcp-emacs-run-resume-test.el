;;; mcp-emacs-run-resume-test.el --- Tests for resuming a Claude session -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'cl-lib)
;; Avoid loading the full runner (needs eat) -- stub the two helpers the
;; command uses; the unit tests below never call the command itself.
(provide 'mcp-emacs-run)
(defun mcp-emacs-run--project-root () default-directory)
(defun mcp-emacs-run--project-name (root) (file-name-nondirectory (directory-file-name root)))
(defvar mcp-emacs-run--launched nil)
(defun mcp-emacs-run--launch (&rest args) (setq mcp-emacs-run--launched args))
(require 'mcp-emacs-run-resume)

(describe "mcp-emacs-run-resume--slug"
  (it "turns a project path into its store directory name"
    (check (mcp-emacs-run-resume--slug "/Users/x/git/mcp-emacs")
           "-Users-x-git-mcp-emacs"))
  (it "replaces dots as well as slashes"
    (check (mcp-emacs-run-resume--slug "/Users/x/.emacs.d")
           "-Users-x--emacs-d"))
  (it "ignores a trailing slash on the project path"
    (check (mcp-emacs-run-resume--slug "/Users/x/proj/")
           "-Users-x-proj")))

(describe "mcp-emacs-run-resume--content-text"
  (it "passes a plain string content through unchanged"
    (check (mcp-emacs-run-resume--content-text "hi") "hi"))
  (it "extracts the text of an array content block"
    (check (mcp-emacs-run-resume--content-text
            (vector '((type . "text") (text . "hello"))))
           "hello"))
  (it "skips non-text blocks and takes the first text one"
    (check (mcp-emacs-run-resume--content-text
            (vector '((type . "tool_result")) '((type . "text") (text . "real"))))
           "real"))
  (it "returns nil for missing content"
    (check (mcp-emacs-run-resume--content-text nil) nil)))

(describe "mcp-emacs-run-resume--noise-p"
  (it "treats a slash-command message as noise"
    (check-that (mcp-emacs-run-resume--noise-p "<command-message>x</command-message>")))
  (it "treats a local command caveat as noise"
    (check-that (mcp-emacs-run-resume--noise-p "<local-command-caveat>y")))
  (it "treats a bare Caveat line as noise"
    (check-that (mcp-emacs-run-resume--noise-p "Caveat: blah")))
  (it "treats a blank message as noise"
    (check-that (mcp-emacs-run-resume--noise-p "   ")))
  (it "treats a genuine user prompt as signal"
    (check (mcp-emacs-run-resume--noise-p "show open issues") nil)))

;;;; first-prompt over a fixture store
(let* ((store (make-temp-file "resume-store-" t)))
  (describe "mcp-emacs-run-resume--first-prompt"
    (let ((f (expand-file-name "aaa.jsonl" store)))
      (with-temp-file f
        (insert "{\"type\":\"mode\"}\n"
                "{\"type\":\"user\",\"message\":{\"content\":\"show open issues\"}}\n"))
      (it "picks the first user message, ignoring non-user lines"
        (check (mcp-emacs-run-resume--first-prompt f) "show open issues")))
    (let ((f (expand-file-name "bbb.jsonl" store)))
      (with-temp-file f
        (insert "{\"type\":\"user\",\"message\":{\"content\":\"<local-command-caveat>Caveat: x\"}}\n"
                "{\"type\":\"user\",\"message\":{\"content\":\"<command-message>opsx:new</command-message>\"}}\n"
                "{\"type\":\"user\",\"message\":{\"content\":\"the actual prompt\"}}\n"))
      (it "skips leading caveat and command blocks to reach the real prompt"
        (check (mcp-emacs-run-resume--first-prompt f) "the actual prompt")))
    (let ((f (expand-file-name "ccc.jsonl" store)))
      (with-temp-file f
        (insert "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"array prompt\"}]}}\n"))
      (it "reads a prompt stored as array content"
        (check (mcp-emacs-run-resume--first-prompt f) "array prompt")))
    (let ((f (expand-file-name "ddd.jsonl" store)))
      (with-temp-file f
        (insert "{\"type\":\"user\",\"message\":{\"content\":\"line one\\nline two\"}}\n"))
      (it "keeps only the first line of a multi-line prompt"
        (check (mcp-emacs-run-resume--first-prompt f) "line one")))
    (let ((f (expand-file-name "eee.jsonl" store)))
      (with-temp-file f
        (insert "{\"type\":\"user\",\"message\":{\"content\":\"<command-message>only noise</command-message>\"}}\n"))
      (it "returns nil when the head holds no genuine prompt"
        (check (mcp-emacs-run-resume--first-prompt f) nil))
      (it "falls back to the session id for the label"
        (check (string-suffix-p "eee" (mcp-emacs-run-resume--label f)) t)))))

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
      (describe "mcp-emacs-run-resume--session-files"
        (let ((files (mcp-emacs-run-resume--session-files slug-root)))
          (it "lists only .jsonl transcripts, ignoring other files"
            (check (length files) 2))
          (it "orders sessions newest first by mtime"
            (check (mcp-emacs-run-resume--session-id (car files)) "new")))))))

(test-helper-summary)

;;; mcp-emacs-run-resume-test.el ends here
