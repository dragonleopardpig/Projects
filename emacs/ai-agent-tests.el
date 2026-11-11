;;; ai-agent-tests.el --- Live buffer agent regression checks -*- lexical-binding: t; -*-
(require 'ert)
(load (expand-file-name "ai-agent.el" (file-name-directory (or load-file-name buffer-file-name))))

(defun my/agent-test-request (request)
  (json-parse-string
   (decode-coding-string
    (base64-decode-string
     (my/agent-dispatch (base64-encode-string (encode-coding-string (json-serialize request) 'utf-8) t)))
    'utf-8)
   :object-type 'alist :array-type 'list))

(ert-deftest my/agent-sum-retains-recalculating-formula ()
  (with-temp-buffer
    (org-mode)
    (insert "Long document\n\n| Item | Cost |\n|------+------|\n| A | 1.5 |\n| B | 2.5 |\n")
    (goto-char (point-min)) (search-forward "| A")
    (let* ((id (my/agent-capture-context))
           (result (my/agent-org-sum id 2 (buffer-chars-modified-tick))))
      (should (equal (alist-get 'formula result) "@>$2=vsum(@2$2..@-1$2)"))
      (should (= (string-to-number (cadr (car (last (org-table-to-lisp))))) 4))
      (goto-char (org-table-end)) (forward-line -1) (beginning-of-line)
      (insert "| C | 3 |\n")
      (goto-char (org-table-begin)) (org-table-align) (org-table-recalculate t)
      (should (= (string-to-number (cadr (car (last (org-table-to-lisp))))) 7)))))

(ert-deftest my/agent-sum-no-header-and-repeat ()
  (with-temp-buffer
    (org-mode) (insert "| A | 1 |\n| B | 2 |\n") (goto-char (point-min))
    (let ((id (my/agent-capture-context)))
      (my/agent-org-sum id 2 (buffer-chars-modified-tick))
      (goto-char (point-min))
      (my/agent-org-sum id 2 (buffer-chars-modified-tick))
      (should (equal (cadr (car (last (org-table-to-lisp)))) "3"))
      (should (= (length (seq-filter #'listp (org-table-to-lisp))) 3)))))

(ert-deftest my/agent-sum-preserves-other-formulas ()
  (with-temp-buffer
    (org-mode)
    (insert "| A | B | C |\n|---+---+---|\n| x | 2 | 3 |\n| y | 4 | 5 |\n#+TBLFM: @2$3=$2+1\n")
    (goto-char (point-min))
    (my/agent-org-sum (my/agent-capture-context) 2 (buffer-chars-modified-tick))
    (should (equal (cdr (assoc "@2$3" (org-table-get-stored-formulas))) "$2+1"))))

(ert-deftest my/agent-edits-captured-buffer-not-agent-window ()
  (let ((source (generate-new-buffer " *agent-source-test*")))
    (unwind-protect
        (let ((id (with-current-buffer source (insert "x = ") (my/agent-capture-context)))
              (tick (with-current-buffer source (buffer-chars-modified-tick))))
          (with-temp-buffer
            (insert "Agent chat")
            (my/agent-test-request `((action . "insert") (context_id . ,id)
                                      (expected_tick . ,tick) (text . "\\alpha")))
            (should (equal (buffer-string) "Agent chat")))
          (with-current-buffer source
            (should (equal (buffer-string) "x = \\alpha"))
            (should (= (point) (point-max)))))
      (kill-buffer source))))

(ert-deftest my/agent-concurrent-edit-is-protected ()
  (with-temp-buffer
    (insert "equation")
    (let ((id (my/agent-capture-context)) (tick (buffer-chars-modified-tick)))
      (insert " typed meanwhile")
      (let ((result (my/agent-test-request `((action . "insert") (context_id . ,id)
                                            (expected_tick . ,tick) (text . "wrong")))))
        (should (string-match-p "Buffer changed" (alist-get 'error result)))
        (should (equal (buffer-string) "equation typed meanwhile"))))))

(ert-deftest my/agent-replacement-checks-original-text ()
  (with-temp-buffer
    (insert "abc")
    (let* ((id (my/agent-capture-context))
           (result (my/agent-test-request `((action . "replace") (context_id . ,id)
                                           (expected_tick . ,(buffer-chars-modified-tick))
                                           (start . 1) (end . 4) (expected_text . "different") (text . "xyz")))))
      (should (alist-get 'error result))
      (should (equal (buffer-string) "abc")))))

(ert-deftest my/agent-unicode-round-trip ()
  (with-temp-buffer
    (insert "π and 中文")
    (let ((result (my/agent-test-request `((action . "read_buffer")
                                          (context_id . ,(my/agent-capture-context))))))
      (should (equal (alist-get 'text result) "π and 中文")))))

(ert-deftest my/agent-latex-reports-real-errors ()
  (skip-unless (executable-find "latex"))
  (with-temp-buffer
    (org-mode) (insert "$\\thiscommanddoesnotexist{x}$") (goto-char 5)
    (let* ((id (my/agent-capture-context)) (bad (my/agent-check-latex id)))
      (should (eq (alist-get 'valid bad) :false))
      (should (string-match-p "Undefined control sequence" (alist-get 'diagnostics bad)))
      (erase-buffer) (insert "$\\alpha + \\beta$") (goto-char 5)
      (should (eq (alist-get 'valid (my/agent-check-latex (my/agent-capture-context))) t)))))

(ert-deftest my/agent-killed-buffer-gives-actionable-error ()
  (let* ((buffer (generate-new-buffer " *agent-killed-test*"))
         (id (with-current-buffer buffer (my/agent-capture-context))))
    (kill-buffer buffer)
    (should (string-match-p "Source buffer is unavailable"
                            (alist-get 'error (my/agent-test-request `((action . "context") (context_id . ,id))))))))

(ert-deftest my/agent-insertion-is-one-undoable-change ()
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "E = ")
    (setq buffer-undo-list nil)
    (my/agent-test-request `((action . "insert") (context_id . ,(my/agent-capture-context))
                             (expected_tick . ,(buffer-chars-modified-tick)) (text . "\\alpha")))
    (undo-only 1)
    (should (equal (buffer-string) "E = "))))

(ert-deftest my/agent-sum-is-one-undoable-change ()
  (with-temp-buffer
    (org-mode)
    (buffer-enable-undo)
    (insert "| A | 1 |\n| B | 2 |\n")
    (goto-char (point-min))
    (setq buffer-undo-list nil)
    (let ((original (buffer-string)))
      (my/agent-org-sum (my/agent-capture-context) 2 (buffer-chars-modified-tick))
      (undo-only 1)
      (should (equal (buffer-string) original)))))

(ert-deftest my/agent-headless-preview-does-not-report-false-success ()
  (skip-unless (not (display-graphic-p)))
  (with-temp-buffer
    (org-mode) (insert "$x$") (goto-char 2)
    (let ((response (my/agent-test-request `((action . "preview_latex")
                                            (context_id . ,(my/agent-capture-context))))))
      (should (string-match-p "graphical Emacs frame" (alist-get 'error response))))))
