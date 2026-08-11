;;; orgspec-review.el --- Ediff review of an orgspec fold before it writes  -*- lexical-binding: t; -*-

;; Author: Gunnar Bastkowski
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools
;; URL: https://github.com/gbastkowski/mcp-emacs
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The org-leverage fold review (issue #34, split from #5).  `archive' folds a
;; change's delta into the spec files with validate-all-then-write-all, so the
;; folded result already exists in memory before anything is written.  This
;; surfaces that: `orgspec-review-fold' ediffs the on-disk spec against the
;; folded text for each affected area -- "see the fold", not "trust the fold" --
;; without touching disk.
;;
;; Review-only: it changes no fold rule and writes nothing.  It reuses the
;; window-layout convention from the native diff review (issue #21): the window
;; configuration is captured before ediff opens and restored when the review
;; quits, so side windows come back and the layout is left unchanged.

;;; Code:

(require 'ediff)
(require 'orgspec-commands)

(defun orgspec-review--ediff (title on-disk new-text)
  "Ediff the ON-DISK spec text against the folded NEW-TEXT.
TITLE labels the buffers.  Captures the window configuration before ediff
opens and restores it once on quit (issue #21), so the caller's layout --
side windows included -- comes back.  View-only: nothing is written."
  (let ((winconf (current-window-configuration))
        (buf-a (generate-new-buffer (format "*orgspec on-disk: %s*" title)))
        (buf-b (generate-new-buffer (format "*orgspec folded: %s*" title))))
    (with-current-buffer buf-a
      (insert (or on-disk ""))
      (let ((org-inhibit-startup t)) (org-mode)))
    (with-current-buffer buf-b
      (insert (or new-text ""))
      (let ((org-inhibit-startup t)) (org-mode)))
    ;; Take the whole frame: ediff's plain single-frame layout calls
    ;; `delete-other-windows', but a *dedicated* window (not just a side
    ;; window) survives that and forces the diff into a split that
    ;; overlaps the user's layout.  Clear every other window first so the
    ;; review owns the screen; the captured `winconf' restores them all
    ;; on quit.
    (dolist (window (window-list))
      (unless (eq window (selected-window))
        (when (or (window-parameter window 'window-side)
                  (window-dedicated-p window))
          (ignore-errors (delete-window window)))))
    (delete-other-windows)
    (let ((ediff-window-setup-function 'ediff-setup-windows-plain)
          (ediff-split-window-function 'split-window-horizontally))
      (condition-case err
          (ediff-buffers
           buf-a buf-b
           (list (lambda ()
                   (with-current-buffer ediff-control-buffer
                     (setq-local
                      ediff-quit-hook
                      (list (lambda ()
                              (ignore-errors (set-window-configuration winconf))
                              (when (buffer-live-p buf-a) (kill-buffer buf-a))
                              (when (buffer-live-p buf-b) (kill-buffer buf-b)))))))))
        ;; Ediff setup can abort before the quit hook exists; restore the
        ;; layout here so a failed review never leaves windows deleted.
        (error (ignore-errors (set-window-configuration winconf))
               (signal (car err) (cdr err)))))))

;;;###autoload
(defun orgspec-review-fold (id)
  "Ediff the fold of change ID against the current specs, before writing.
Builds every affected spec in memory with `orgspec-commands-fold-build'
(the same result `archive' would write) and ediffs the on-disk spec
against it, one area at a time.  Writes nothing and moves nothing -- run
`orgspec-archive' to actually apply the fold.  Returns the list of area
spec files reviewed."
  (interactive "sChange id to review: ")
  (let ((built (orgspec-commands-fold-build id)))
    (dolist (cell built)
      (let* ((file (car cell))
             (new-text (cdr cell))
             (on-disk (when (file-exists-p file)
                        (with-temp-buffer (insert-file-contents file)
                                          (buffer-string)))))
        (orgspec-review--ediff (file-name-nondirectory file) on-disk new-text)))
    (mapcar #'car built)))

(provide 'orgspec-review)
;;; orgspec-review.el ends here
