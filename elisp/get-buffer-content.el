(with-current-buffer (window-buffer (frame-selected-window (selected-frame)))
  (buffer-substring-no-properties (point-min) (point-max)))
