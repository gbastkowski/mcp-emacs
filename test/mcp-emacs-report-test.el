(add-to-list 'load-path (expand-file-name "elisp"))
(require 'mcp-emacs-report)
(require 'cl-lib)

(defun check (l g w) (princ (format "%s %s\n" (if (equal g w) "PASS" "FAIL") l)))

;; --- 4.1 Handler validation --------------------------------------------------

;; Missing title -> user-error, no filing attempted.
(check "missing-title-errors"
       (condition-case _ (progn (mcp-emacs-report-tooling-issue "") nil)
         (user-error t))
       t)

(check "whitespace-title-errors"
       (condition-case _ (progn (mcp-emacs-report-tooling-issue "   ") nil)
         (user-error t))
       t)

;; Invalid kind -> user-error naming the accepted values.
(check "invalid-kind-errors"
       (condition-case e
           (progn (mcp-emacs-report-tooling-issue "t" "b" "nonsense") nil)
         (user-error (and (string-match-p "bug" (error-message-string e)) t)))
       t)

;; A valid kind passes validation (still no real filing -- gh stubbed absent).
(cl-letf (((symbol-function 'mcp-emacs-report--gh-available-p) (lambda () nil)))
  (check "valid-kind-accepted"
         (condition-case _
             (progn (mcp-emacs-report-tooling-issue "t" "b" "feature") t)
           (user-error nil))
         t))

;; --- 4.2 Fallback chain ------------------------------------------------------

;; gh present + CLI succeeds -> CLI URL used, api-create never called.
(let ((api-called nil))
  (cl-letf (((symbol-function 'mcp-emacs-report--gh-available-p) (lambda () t))
            ((symbol-function 'mcp-emacs-report--create-via-cli)
             (lambda (_title _body) "https://github.com/gbastkowski/mcp-emacs/issues/1"))
            ((symbol-function 'mcp-emacs-report--api-create)
             (lambda (_title _body) (setq api-called t) nil))
            ((symbol-function 'mcp-emacs-report--apply-label) (lambda (&rest _) nil)))
    (check "cli-success-uses-cli"
           (mcp-emacs-report-tooling-issue "t" "b")
           "Created issue: https://github.com/gbastkowski/mcp-emacs/issues/1")
    (check "cli-success-skips-api" api-called nil)))

;; gh present + CLI fails -> falls to api-create.
(cl-letf (((symbol-function 'mcp-emacs-report--gh-available-p) (lambda () t))
          ((symbol-function 'mcp-emacs-report--create-via-cli) (lambda (_t _b) nil))
          ((symbol-function 'mcp-emacs-report--api-create)
           (lambda (_t _b) "https://github.com/gbastkowski/mcp-emacs/issues/2"))
          ((symbol-function 'mcp-emacs-report--apply-label) (lambda (&rest _) nil)))
  (check "cli-fail-falls-to-api"
         (mcp-emacs-report-tooling-issue "t" "b")
         "Created issue: https://github.com/gbastkowski/mcp-emacs/issues/2"))

;; gh absent -> manual fallback text, neither create path called.
(let ((cli-called nil) (api-called nil))
  (cl-letf (((symbol-function 'mcp-emacs-report--gh-available-p) (lambda () nil))
            ((symbol-function 'mcp-emacs-report--create-via-cli)
             (lambda (_t _b) (setq cli-called t) nil))
            ((symbol-function 'mcp-emacs-report--api-create)
             (lambda (_t _b) (setq api-called t) nil)))
    (let ((out (mcp-emacs-report-tooling-issue "My title" "Body here")))
      (check "no-gh-manual-fallback"
             (and (string-match-p "manually" out)
                  (string-match-p "My title" out)
                  (string-match-p "Body here" out) t)
             t)
      (check "no-gh-skips-cli" cli-called nil)
      (check "no-gh-skips-api" api-called nil))))

;; --- 4.3 Best-effort label ---------------------------------------------------

;; A failing label call still yields a created-issue result (not an error).
;; Stub the low-level runner so the real `--apply-label' ignore-errors path
;; is exercised, not bypassed.
(cl-letf (((symbol-function 'mcp-emacs-report--gh-available-p) (lambda () t))
          ((symbol-function 'mcp-emacs-report--create-via-cli)
           (lambda (_t _b) "https://github.com/gbastkowski/mcp-emacs/issues/3"))
          ((symbol-function 'mcp-emacs-report--run)
           (lambda (&rest _) (error "label does not exist"))))
  (check "missing-label-still-creates"
         (condition-case _
             (mcp-emacs-report-tooling-issue "t" "b" "server")
           (error "ERRORED"))
         "Created issue: https://github.com/gbastkowski/mcp-emacs/issues/3"))
