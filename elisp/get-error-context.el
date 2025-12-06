(require 'subr-x)

(let* ((max-chars 2000)
       (known-buffers '("*Backtrace*" "*Compile-Log*" "*compilation*" "*Messages*" "*Warnings*" "*Async-native-compile-log*"))
       (dynamic (let (matches)
                  (dolist (buf (buffer-list) matches)
                    (let ((name (buffer-name buf)))
                      (when (and name
                                 (string-match-p "\\(error\\|warning\\|backtrace\\|compile\\|log\\)" (downcase name)))
                        (push name matches))))))
       (targets (delete-dups (append known-buffers dynamic)))
       (results '()))
  (dolist (name targets)
    (when-let ((buf (get-buffer name)))
      (with-current-buffer buf
        (let* ((raw (buffer-substring-no-properties (point-min) (point-max)))
               (snippet (if (> (length raw) max-chars)
                            (concat (substring raw 0 max-chars) "\n... [truncated]")
                          raw))
               (trimmed (string-trim snippet)))
          (push (format "Buffer: %s\n%s"
                        name
                        (if (string-empty-p trimmed)
                            "[Buffer is empty]"
                          trimmed))
                results)))))
  (if results
      (mapconcat #'identity (nreverse results) "\n\n---\n\n")
    "No error-related buffers were found."))
