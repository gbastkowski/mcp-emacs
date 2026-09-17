;;; mcp-emacs-report-test.el --- Tests for the tooling-issue reporter -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'mcp-emacs-report)
(require 'cl-lib)
;; Loaded up front so the composition-buffer stubs below rebind a function
;; that already exists: `mcp-emacs-report--compose' requires it lazily, so
;; whichever `cl-letf' runs first would otherwise be binding a void symbol
;; and the real buffer would open during the test.
(require 'agent-prompt)

;; --- 4.1 Handler validation --------------------------------------------------

(describe "mcp-emacs-report-tooling-issue argument validation"
  (it "rejects an empty title without attempting to file"
    (check (condition-case _ (progn (mcp-emacs-report-tooling-issue "") nil)
             (user-error t))
           t))

  (it "rejects a whitespace-only title without attempting to file"
    (check (condition-case _ (progn (mcp-emacs-report-tooling-issue "   ") nil)
             (user-error t))
           t))

  (it "names the accepted values when the kind is unknown"
    (check (condition-case e
               (progn (mcp-emacs-report-tooling-issue "t" "b" "nonsense") nil)
             (user-error (and (string-match-p "bug" (error-message-string e)) t)))
           t))

  ;; A valid kind passes validation (still no real filing -- gh stubbed absent).
  (cl-letf (((symbol-function 'mcp-emacs-report--gh-available-p) (lambda () nil)))
    (it "accepts a known kind"
      (check (condition-case _
                 (progn (mcp-emacs-report-tooling-issue "t" "b" "feature") t)
               (user-error nil))
             t))))

;; --- 4.2 Fallback chain ------------------------------------------------------

(describe "mcp-emacs-report-tooling-issue with gh present and the CLI succeeding"
  (let ((api-called nil))
    (cl-letf (((symbol-function 'mcp-emacs-report--gh-available-p) (lambda () t))
              ((symbol-function 'mcp-emacs-report--create-via-cli)
               (lambda (_title _body) "https://github.com/gbastkowski/mcp-emacs/issues/1"))
              ((symbol-function 'mcp-emacs-report--api-create)
               (lambda (_title _body) (setq api-called t) nil))
              ((symbol-function 'mcp-emacs-report--apply-label) (lambda (&rest _) nil)))
      (it "reports the URL the CLI returned"
        (check (mcp-emacs-report-tooling-issue "t" "b")
               "Created issue: https://github.com/gbastkowski/mcp-emacs/issues/1"))
      (it "never falls through to the API"
        (check api-called nil)))))

(describe "mcp-emacs-report-tooling-issue with gh present and the CLI failing"
  (cl-letf (((symbol-function 'mcp-emacs-report--gh-available-p) (lambda () t))
            ((symbol-function 'mcp-emacs-report--create-via-cli) (lambda (_t _b) nil))
            ((symbol-function 'mcp-emacs-report--api-create)
             (lambda (_t _b) "https://github.com/gbastkowski/mcp-emacs/issues/2"))
            ((symbol-function 'mcp-emacs-report--apply-label) (lambda (&rest _) nil)))
    (it "falls back to creating the issue via the API"
      (check (mcp-emacs-report-tooling-issue "t" "b")
             "Created issue: https://github.com/gbastkowski/mcp-emacs/issues/2"))))

(describe "mcp-emacs-report-tooling-issue with gh absent"
  (let ((cli-called nil) (api-called nil))
    (cl-letf (((symbol-function 'mcp-emacs-report--gh-available-p) (lambda () nil))
              ((symbol-function 'mcp-emacs-report--create-via-cli)
               (lambda (_t _b) (setq cli-called t) nil))
              ((symbol-function 'mcp-emacs-report--api-create)
               (lambda (_t _b) (setq api-called t) nil)))
      (let ((out (mcp-emacs-report-tooling-issue "My title" "Body here")))
        (it "hands back title and body for the user to file manually"
          (check (and (string-match-p "manually" out)
                      (string-match-p "My title" out)
                      (string-match-p "Body here" out) t)
                 t))
        (it "does not try the CLI"
          (check cli-called nil))
        (it "does not try the API"
          (check api-called nil))))))

;; --- 4.3 Best-effort label ---------------------------------------------------

;; Stub the low-level runner so the real `--apply-label' ignore-errors path
;; is exercised, not bypassed.
(describe "mcp-emacs-report-tooling-issue when labelling fails"
  (cl-letf (((symbol-function 'mcp-emacs-report--gh-available-p) (lambda () t))
            ((symbol-function 'mcp-emacs-report--create-via-cli)
             (lambda (_t _b) "https://github.com/gbastkowski/mcp-emacs/issues/3"))
            ((symbol-function 'mcp-emacs-report--run)
             (lambda (&rest _) (error "label does not exist"))))
    (it "still reports the created issue rather than erroring"
      (check (condition-case _
                 (mcp-emacs-report-tooling-issue "t" "b" "server")
               (error "ERRORED"))
             "Created issue: https://github.com/gbastkowski/mcp-emacs/issues/3"))))

;; --- 4.4 Splitting a composed report into title and body ---------------------

(describe "mcp-emacs-report--split"
  (it "treats a single line as the title with no body"
    (check (mcp-emacs-report--split "Something broke") '("Something broke")))

  (it "takes the first line as the title and the rest as the body"
    (check (mcp-emacs-report--split "Title here\n\nBody line one\nand two")
           '("Title here" . "Body line one\nand two")))

  (it "ignores blank space around the composed text"
    (check (mcp-emacs-report--split "\n  Padded title  \n\nBody\n\n")
           '("Padded title" . "Body")))

  (it "reports an empty title for text that is only whitespace"
    (check (car (mcp-emacs-report--split "   \n\n  ")) ""))

  ;; The template is scaffolding, not content: a heading the human never
  ;; answered would make the filed issue look answered when it is not.
  (it "drops template headings that were left unanswered"
    (check (mcp-emacs-report--split
            "Title\n\nWhat happened:\n\nWhat you expected:\n\nHow to reproduce:\n")
           '("Title")))

  (it "keeps the headings that were answered and drops the rest"
    (check (mcp-emacs-report--split
            "Title\n\nWhat happened:\nit crashed\n\nWhat you expected:\n")
           '("Title" . "What happened:\nit crashed")))

  (it "keeps body text that is not a heading at all"
    (check (mcp-emacs-report--split "Title\n\njust a sentence about it")
           '("Title" . "just a sentence about it"))))

;; --- 4.5 Filing what was composed --------------------------------------------

(describe "mcp-emacs-report--file-composed on success"
  (let ((filed nil) (messaged nil))
    (cl-letf (((symbol-function 'mcp-emacs-report-tooling-issue)
               (lambda (title body kind)
                 (setq filed (list title body kind))
                 "Created issue: https://github.com/gbastkowski/mcp-emacs/issues/7"))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (setq messaged (apply #'format fmt args)))))
      (mcp-emacs-report--file-composed "bug" "Title\n\nWhat happened:\nboom")
      (it "files the first line as the title"
        (check (nth 0 filed) "Title"))
      (it "files the remaining lines as the body"
        (check (nth 1 filed) "What happened:\nboom"))
      (it "labels the issue with the kind it was composed for"
        (check (nth 2 filed) "bug"))
      (it "reports the issue URL in the echo area"
        (check messaged
               "Created issue: https://github.com/gbastkowski/mcp-emacs/issues/7")))))

(describe "mcp-emacs-report--file-composed with nothing but blank space"
  (let ((filed nil) (messaged nil))
    (cl-letf (((symbol-function 'mcp-emacs-report-tooling-issue)
               (lambda (&rest args) (setq filed args) "Created issue: x"))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (setq messaged (apply #'format fmt args)))))
      (mcp-emacs-report--file-composed "bug" "   \n\n   ")
      (it "does not attempt to file a titleless report"
        (check filed nil))
      (it "says why nothing was filed"
        (check (and (string-match-p "needs at least a title" messaged) t) t)))))

;; Filing runs after the composition buffer is gone, so a failure that lost
;; the text would lose the report itself.
(describe "mcp-emacs-report--file-composed when filing fails"
  (let ((messaged nil)
        (mcp-emacs-report-last-text nil))
    (cl-letf (((symbol-function 'mcp-emacs-report-tooling-issue)
               (lambda (&rest _) (error "network is down")))
              ((symbol-function 'display-buffer) (lambda (&rest _) nil))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (setq messaged (apply #'format fmt args)))))
      (mcp-emacs-report--file-composed "bug" "Lost title\n\nLost body")
      (it "keeps the composed text recoverable"
        (check mcp-emacs-report-last-text "Lost title\n\nLost body"))
      (it "points the human at the buffer holding it"
        (check (and (string-match-p "mcp-emacs-report" messaged) t) t))
      (it "puts the error and the text in that buffer"
        (check (with-current-buffer "*mcp-emacs-report*"
                 (and (string-match-p "network is down" (buffer-string))
                      (string-match-p "Lost body" (buffer-string)) t))
               t)))))

(describe "mcp-emacs-report--file-composed when no filing mechanism exists"
  (let ((messaged nil))
    (cl-letf (((symbol-function 'mcp-emacs-report--gh-available-p) (lambda () nil))
              ((symbol-function 'display-buffer) (lambda (&rest _) nil))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (setq messaged (apply #'format fmt args)))))
      (mcp-emacs-report--file-composed "feature" "Wishlist item\n\nWhy: reasons")
      (it "does not claim an issue was created"
        (check (string-prefix-p "Created issue: " messaged) nil))
      (it "shows the manual-filing instructions instead"
        (check (with-current-buffer "*mcp-emacs-report*"
                 (and (string-match-p "manually" (buffer-string))
                      (string-match-p "Wishlist item" (buffer-string)) t))
               t)))))

;; --- 4.6 Seeding the composition buffer --------------------------------------

(describe "mcp-emacs-report--initial"
  (let ((mcp-emacs-report-template t))
    (cl-letf (((symbol-function 'agent-prompt-region-seed) (lambda (&rest _) nil)))
      (it "leaves the first line free for the title"
        (check (string-prefix-p "\n\n" (mcp-emacs-report--initial "bug" nil)) t))
      (it "offers the bug template for a bug"
        (check (and (string-match-p "How to reproduce:"
                                    (mcp-emacs-report--initial "bug" nil))
                    t)
               t))
      (it "opens a feature request with an empty body"
        (check (mcp-emacs-report--initial "feature" nil) nil))))

  ;; A source region still seeds a feature request; absent for `feature',
  ;; no template would otherwise follow the seed.
  (let ((mcp-emacs-report-template t))
    (cl-letf (((symbol-function 'agent-prompt-region-seed)
               (lambda (&rest _) "foo.el:12")))
      (it "seeds an active region into a feature request, with no template after it"
        (check (mcp-emacs-report--initial "feature" (current-buffer))
               "\n\nfoo.el:12"))))

  ;; The code in front of you is usually what the report is about.
  (let ((mcp-emacs-report-template nil))
    (cl-letf (((symbol-function 'agent-prompt-region-seed)
               (lambda (&rest _) "foo.el:12")))
      (it "seeds an active region into the body"
        (check (mcp-emacs-report--initial "bug" (current-buffer))
               "\n\nfoo.el:12"))))

  (let ((mcp-emacs-report-template nil))
    (cl-letf (((symbol-function 'agent-prompt-region-seed) (lambda (&rest _) nil)))
      (it "opens an empty buffer when there is nothing to seed"
        (check (mcp-emacs-report--initial "bug" nil) nil)))))

;; --- 4.7 The interactive commands --------------------------------------------

;; Both commands are `agent-prompt-read' plus a kind, so what matters is
;; that the kind reaches the callback and the buffer is named for it.
(describe "mcp-emacs-report-bug"
  (let ((callback nil) (label nil) (kind nil))
    (cl-letf (((symbol-function 'agent-prompt-read)
               (lambda (cb &optional _initial lbl &rest _)
                 (setq callback cb label lbl)
                 nil))
              ((symbol-function 'message) (lambda (&rest _) nil))
              ((symbol-function 'mcp-emacs-report-tooling-issue)
               (lambda (_title _body k) (setq kind k) "Created issue: x")))
      (mcp-emacs-report-bug)
      (it "names the composition buffer for a bug report"
        (check label "bug report"))
      (it "files what the buffer collects as a bug"
        (funcall callback "Title")
        (check kind "bug")))))

(describe "mcp-emacs-report-feature"
  (let ((callback nil) (label nil) (kind nil))
    (cl-letf (((symbol-function 'agent-prompt-read)
               (lambda (cb &optional _initial lbl &rest _)
                 (setq callback cb label lbl)
                 nil))
              ((symbol-function 'message) (lambda (&rest _) nil))
              ((symbol-function 'mcp-emacs-report-tooling-issue)
               (lambda (_title _body k) (setq kind k) "Created issue: x")))
      (mcp-emacs-report-feature)
      (it "names the composition buffer for a feature request"
        (check label "feature request"))
      (it "files what the buffer collects as a feature"
        (funcall callback "Title")
        (check kind "feature")))))

(describe "the report commands"
  (it "are both interactive"
    (check (and (commandp 'mcp-emacs-report-bug)
                (commandp 'mcp-emacs-report-feature) t)
           t)))

(test-helper-summary)

;;; mcp-emacs-report-test.el ends here
