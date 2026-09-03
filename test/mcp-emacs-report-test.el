;;; mcp-emacs-report-test.el --- Tests for the tooling-issue reporter -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "elisp"))
(add-to-list 'load-path (expand-file-name "test"))
(require 'test-helper)
(require 'mcp-emacs-report)
(require 'cl-lib)

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

(test-helper-summary)

;;; mcp-emacs-report-test.el ends here
