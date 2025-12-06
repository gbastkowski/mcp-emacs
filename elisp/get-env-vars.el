(let* ((entries (copy-sequence process-environment))
       (sorted (sort entries #'string-lessp)))
  (if sorted
      (mapconcat #'identity sorted "\n")
    "Environment is empty"))
