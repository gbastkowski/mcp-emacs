(with-current-buffer (window-buffer (frame-selected-window (selected-frame)))
  (if (use-region-p)
      (buffer-substring-no-properties (region-beginning) (region-end))
    nil))
