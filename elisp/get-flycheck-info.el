(with-current-buffer (window-buffer (frame-selected-window (selected-frame)))
  (if (bound-and-true-p flycheck-mode)
      (let ((errors (flycheck-overlay-errors-at (point))))
        (if errors
            (mapconcat
             (lambda (err)
               (format "%s: %s [%s]"
                       (flycheck-error-level err)
                       (flycheck-error-message err)
                       (flycheck-error-checker err)))
             errors
             "\\n")
          "No flycheck messages at point"))
    "Flycheck mode not active"))
