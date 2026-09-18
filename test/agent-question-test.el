;;; agent-question-test.el --- Tests for the agent question answer menu -*- lexical-binding: t; -*-

;; Batch tests for `agent-question.el'.  No HTTP: questions are raised
;; and resolved directly, which is the same path the opencode SSE handler
;; takes (its own wiring is covered in `opencode-client-sse-test.el').

(require 'cl-lib)
(require 'agent-question)
(require 'test-helper)

(defun agent-question-test--reset ()
  "Drop any question left pending by an earlier expectation."
  (dolist (id (agent-question-pending-ids))
    (agent-question--resolve id "test cleanup"))
  (setq agent-question--pending nil))

;;;; Raising and answering

(describe "raising a question"
  (agent-question-test--reset)
  (let ((answers nil))
    (agent-question-request
     "req-q1" "Which command?" '("ls" "cat" "custom")
     :resolve (lambda (a) (push a answers)))
    (it "registers the question as pending"
      (check (agent-question-pending-ids) '("req-q1")))
    (it "shows the question and one line per proposed option"
      (check (with-current-buffer "*agent-question: req-q1*"
               (buffer-substring-no-properties (point-min) (point-max)))
             "Which command?\n\n[a] ls\n[b] cat\n[c] custom\n\n"))
    (it "makes the buffer read-only, since an answer is a choice not text"
      (check (with-current-buffer "*agent-question: req-q1*" buffer-read-only) t))
    (agent-question-test--reset)))

(describe "answering a question with a proposed option"
  (agent-question-test--reset)
  (let ((answers nil))
    (agent-question-request
     "req-pick" "Which?" '("alpha" "beta")
     :resolve (lambda (a) (push a answers)))
    (with-current-buffer "*agent-question: req-pick*"
      (agent-question-answer-option "b"))
    (sit-for 0.2)
    (it "delivers the chosen option text"
      (check answers '("beta")))
    (it "kills the buffer once answered"
      (check (get-buffer "*agent-question: req-pick*") nil)))
  (agent-question-test--reset))

(describe "answering a question free-form"
  (agent-question-test--reset)
  (let ((answers nil))
    (agent-question-request
     "req-free" "Anything else?" nil
     :resolve (lambda (a) (push a answers)))
    (with-current-buffer "*agent-question: req-free*"
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "a custom idea")))
        (agent-question-answer-free)))
    (sit-for 0.2)
    (it "delivers the custom text the human typed"
      (check answers '("a custom idea"))))
  (agent-question-test--reset))

(describe "a question is answered exactly once"
  (agent-question-test--reset)
  (let* ((answers nil)
         (_ (agent-question-request
             "req-once" "Once?" '("yes" "no")
             :resolve (lambda (a) (push a answers))))
         (first (agent-question--resolve "req-once" "yes"))
         (second (agent-question--resolve "req-once" "no")))
    (sit-for 0.2)
    (it "reports the first answer as the one that resolved it"
      (check first t))
    (it "reports a second answer as having resolved nothing"
      (check second nil))
    (it "delivers only the first answer"
      (check answers '("yes"))))
  (agent-question-test--reset))

(describe "raising the same id twice"
  (agent-question-test--reset)
  (agent-question-request "req-dup" "Dup?" '("a"))
  (it "signals rather than leaving two callers waiting on one answer"
    (check-that (condition-case nil
                    (progn (agent-question-request "req-dup" "Dup?" '("a")) nil)
                  (error t))))
  (agent-question-test--reset))

;;;; Option keys

(describe "assigning option keys"
  (it "assigns a..z before 0..9, skipping the free-form key"
    (check (agent-question--option-keys 4) '("a" "b" "c" "d")))
  (it "hands the free-form key to every question, not to an option"
    (let ((agent-question-free-key "c"))
      (check (agent-question--option-keys 6)
             '("a" "b" "d" "e" "f" "g")))))

;;;; End-to-end resolve through the buffer-local keys

(describe "answering through a position, not a label"
  (agent-question-test--reset)
  (let ((answers nil))
    (agent-question-request
     "req-k" "K?" '("one" "two" "three")
     :resolve (lambda (a) (push a answers)))
    (with-current-buffer "*agent-question: req-k*"
      (agent-question-answer-option "c"))
    (sit-for 0.2)
    (it "resolves through the option key bound for that position"
      (check answers '("three")))
    (it "clears the pending registry once answered"
      (check (agent-question-pending-ids) nil)))
  (agent-question-test--reset))

(test-helper-summary)
;;; agent-question-test.el ends here