(require 'org)
(require 'org-agenda)

(let ((result '()))
  (org-map-entries
   (lambda ()
     (let* ((heading (org-get-heading t t t t))
            (todo-state (org-get-todo-state))
            (tags (org-get-tags))
            (file (buffer-file-name))
            (priority (org-get-priority (thing-at-point 'line)))
            (scheduled (org-get-scheduled-time (point)))
            (deadline (org-get-deadline-time (point))))
       (when todo-state
         (push (format "* [%s] %s%s%s\n  File: %s%s%s"
                       todo-state
                       (if (> priority 0)
                           (format "[#%c] " (org-priority-to-value priority))
                         "")
                       heading
                       (if tags (format " :%s:" (mapconcat 'identity tags ":")) "")
                       file
                       (if scheduled (format "\n  SCHEDULED: %s" (format-time-string "%Y-%m-%d %a" scheduled)) "")
                       (if deadline (format "\n  DEADLINE: %s" (format-time-string "%Y-%m-%d %a" deadline)) ""))
               result))))
   t
   'agenda)
  (if result
      (mapconcat 'identity (reverse result) "\n\n")
    "No tasks found"))
