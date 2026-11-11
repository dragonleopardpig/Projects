;;; ai-agent.el --- Antigravity editing of live Org and LaTeX buffers -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'json)
(require 'org)
(require 'org-table)
(require 'server)
(require 'subr-x)

(defconst my/agent-directory
  (file-name-directory (or load-file-name buffer-file-name)))
(defvar my/agent-contexts (make-hash-table :test #'equal))
(defvar my/agent-current-context-id nil)
(defvar my/agent-map)
(defvar agent-shell-antigravity-acp-command)
(defvar agent-shell-antigravity-authentication)
(defvar agent-shell-preferred-agent-config)
(defvar agent-shell-permission-responder-function)
(defvar agent-shell-session-strategy)
(defvar agent-shell-mcp-servers)
(defvar agent-shell-display-action)
(autoload 'agent-shell "agent-shell" nil t)
(declare-function agent-shell--shell-buffer "agent-shell")
(declare-function agent-shell-insert "agent-shell")
(declare-function agent-shell-permission-allow-always "agent-shell")
(declare-function agent-shell-antigravity-make-authentication "agent-shell-antigravity")
(declare-function agent-shell-antigravity-make-agent-config "agent-shell-antigravity")

(defun my/agent-capture-context ()
  "Remember the source buffer and point before opening an agent window."
  (let ((id (substring (secure-hash 'sha256
                                   (format "%s:%s:%s" (buffer-name) (float-time) (random)))
                       0 24)))
    (maphash (lambda (key value)
               (unless (marker-buffer (plist-get value :point))
                 (remhash key my/agent-contexts)))
             my/agent-contexts)
    (puthash id (list :point (copy-marker (point) t)
                      :region (when (use-region-p)
                                (cons (copy-marker (region-beginning))
                                      (copy-marker (region-end) t))))
             my/agent-contexts)
    (setq my/agent-current-context-id id)))

(defmacro my/agent--with-context (id &rest body)
  (declare (indent 1) (debug t))
  `(let* ((entry (gethash (or ,id my/agent-current-context-id) my/agent-contexts))
          (marker (plist-get entry :point)))
     (unless (and (markerp marker) (marker-buffer marker))
       (user-error "Source buffer is unavailable; ask again from that buffer"))
     (with-current-buffer (marker-buffer marker)
       (let ((source-point (point))
             (captured-point (marker-position marker))
             (point-after-edit nil))
         (prog1
             (save-restriction
               (widen)
               (save-excursion
                 (goto-char marker)
                 ,@body))
           ;; Advance the source cursor after inserting, provided the user
           ;; has not moved it elsewhere while the agent was thinking.
           (when (and point-after-edit (= source-point captured-point))
             (goto-char point-after-edit)))))))

(defun my/agent--latex-bounds (region)
  "Find selected REGION, an Org math element, or the current line."
  (let ((element (and (derived-mode-p 'org-mode) (org-element-context))))
    (cond
     (region (cons (marker-position (car region)) (marker-position (cdr region))))
     ((memq (org-element-type element) '(latex-fragment latex-environment))
      (cons (org-element-property :begin element)
            (- (org-element-property :end element)
               (or (org-element-property :post-blank element) 0))))
     (t (cons (line-beginning-position) (line-end-position))))))

(defun my/agent-context (id)
  "Return live context for ID without reading an entire long document."
  (my/agent--with-context id
    (let* ((bounds (my/agent--latex-bounds (plist-get entry :region)))
           (table (when (org-at-table-p)
                    (buffer-substring-no-properties (org-table-begin) (org-table-end)))))
      `((context_id . ,(or id my/agent-current-context-id))
        (buffer . ,(buffer-name)) (file . ,(or buffer-file-name :null))
        (mode . ,(symbol-name major-mode)) (point . ,(point))
        (tick . ,(buffer-chars-modified-tick))
        (size . ,(buffer-size)) (table . ,(or table :null))
        (fragment_start . ,(car bounds)) (fragment_end . ,(cdr bounds))
        (fragment . ,(buffer-substring-no-properties
                      (car bounds) (min (cdr bounds) (+ (car bounds) 16000))))))))

(defun my/agent--check-edit (tick)
  (barf-if-buffer-read-only)
  (unless (and (integerp tick) (= tick (buffer-chars-modified-tick)))
    (user-error "Buffer changed; read fresh context and retry the edit")))

(defun my/agent-org-sum (id column tick)
  "Sum COLUMN at context ID with an Org formula, checking expected TICK."
  (my/agent--with-context id
    (my/agent--check-edit tick)
    (unless (and (derived-mode-p 'org-mode) (org-at-table-p))
      (user-error "Point is not inside an Org table"))
    (unless (and (integerp column) (> column 0))
      (user-error "Column must be a positive integer"))
    (let* ((begin (org-table-begin)) (end (org-table-end))
           (rows (org-table-to-lisp))
           (data (seq-filter #'listp rows))
           (width (apply #'max (mapcar #'length data)))
           (target (format "@>$%d" column))
           (formulas (org-table-get-stored-formulas))
           (existing (cdr (assoc target formulas)))
           (footer (or existing
                       (seq-some (lambda (cell)
                                   (string-match-p "\\`\\(?:total\\|sum\\)\\'"
                                                   (downcase (string-trim cell))))
                                 (car (last data)))))
           (before-separator 0)
           (first-data 1))
      (unless (<= column width) (user-error "Column must be between 1 and %d" width))
      (if (and existing (string-match "\\`vsum(@\\([0-9]+\\)\\$" existing))
          (setq first-data (string-to-number (match-string 1 existing)))
        (catch 'separator
          (dolist (row rows)
            (if (eq row 'hline)
                (progn (setq first-data (1+ before-separator)) (throw 'separator t))
              (cl-incf before-separator)))))
      (unless footer
        (unless (eq (car (last rows)) 'hline)
          (setq rows (append rows '(hline))))
        (let ((total (make-list width "")))
          (when (> width 1) (setf (nth (if (= column 1) 1 0) total) "Total"))
          (setq rows (append rows (list total)))))
      (let* ((footer-row (length (seq-filter #'listp rows)))
             (formula (format "vsum(@%d$%d..@-1$%d)" first-data column column)))
        (when (> first-data (1- footer-row)) (user-error "No data rows to sum"))
        (undo-boundary)
        (atomic-change-group
          (delete-region begin end)
          (goto-char begin)
          (dolist (row rows)
            (insert (if (eq row 'hline) "|-|\n"
                      (concat "| " (mapconcat #'identity row " | ") " |\n"))))
          (goto-char begin)
          (org-table-align)
          (org-table-store-formulas
           (cons (cons target formula)
                 (assoc-delete-all (format "@%d$%d" footer-row column)
                                   (assoc-delete-all target formulas))))
          (org-table-recalculate t)
          ;; Replacing the table moves insertion-type markers past its end.
          ;; Keep this conversation anchored inside the updated table.
          (set-marker marker begin))
        (undo-boundary)
        `((formula . ,(concat target "=" formula))
          (tick . ,(buffer-chars-modified-tick))
          (table . ,(buffer-substring-no-properties (org-table-begin) (org-table-end))))))))

(defun my/agent-check-latex (id)
  "Compile the math fragment at ID and return actual LaTeX diagnostics."
  (my/agent--with-context id
    (let* ((bounds (my/agent--latex-bounds (plist-get entry :region)))
           (fragment (string-trim (buffer-substring-no-properties (car bounds) (cdr bounds))))
           (directory (make-temp-file "emacs-agent-latex-" t))
           (default-directory directory)
           (program (or (executable-find "latex") (user-error "latex is not on PATH")))
           (output (generate-new-buffer " *agent-latex-log*")))
      (unwind-protect
          (progn
            (with-temp-file (expand-file-name "fragment.tex" directory)
              (insert "\\documentclass{article}\n\\usepackage{amsmath,amssymb}\n\\pagestyle{empty}\n\\begin{document}\n")
              (if (string-match-p "\\`\\(?:\\$\\|\\\\(\\|\\\\\\[\\|\\\\begin{\\)" fragment)
                  (insert fragment)
                (insert "\\[\n" fragment "\n\\]"))
              (insert "\n\\end{document}\n"))
            (let ((status (call-process program nil output nil "-interaction=nonstopmode"
                                        "-halt-on-error" "-no-shell-escape" "fragment.tex")))
              `((valid . ,(if (equal status 0) t :false))
                (exit_code . ,status)
                (fragment_start . ,(car bounds)) (fragment_end . ,(cdr bounds))
                (diagnostics . ,(with-current-buffer output
                                  (buffer-substring-no-properties
                                   (max (point-min) (- (point-max) 6000)) (point-max)))))))
        (kill-buffer output)
        (delete-directory directory t)))))

(defun my/agent-dispatch (encoded)
  "Handle a base64 JSON MCP tool request, returning base64 JSON."
  (let ((result
         (condition-case error-data
             (let* ((request (json-parse-string
                              (decode-coding-string (base64-decode-string encoded) 'utf-8)
                              :object-type 'alist :array-type 'list))
                    (action (alist-get 'action request))
                    (id (alist-get 'context_id request)))
               (pcase action
                 ("context" (my/agent-context id))
                 ("sum_column" (my/agent-org-sum id (alist-get 'column request)
                                                (alist-get 'expected_tick request)))
                 ("check_latex" (my/agent-check-latex id))
                 (_ (my/agent--with-context id
                      (pcase action
                        ("read_buffer"
                         (let ((start (max (point-min) (or (alist-get 'start request) (point-min))))
                               (end (min (point-max) (or (alist-get 'end request) (point-max)))))
                           (when (> (- end start) 40000) (setq end (+ start 40000)))
                           `((start . ,start) (end . ,end) (tick . ,(buffer-chars-modified-tick))
                             (text . ,(buffer-substring-no-properties start end)))))
                        ((or "insert" "replace")
                         (my/agent--check-edit (alist-get 'expected_tick request))
                         (undo-boundary)
                         (atomic-change-group
                           (when (equal action "replace")
                             (let ((start (alist-get 'start request)) (end (alist-get 'end request)))
                               (unless (equal (buffer-substring-no-properties start end)
                                              (alist-get 'expected_text request))
                                 (user-error "Original text differs; read fresh context"))
                               (delete-region start end) (goto-char start)))
                           (insert (alist-get 'text request))
                           (setq point-after-edit (point)))
                         (undo-boundary)
                         `((tick . ,(buffer-chars-modified-tick)) (point . ,(point))))
                        ("preview_latex"
                         (unless (derived-mode-p 'org-mode) (user-error "Preview requires Org mode"))
                         (unless (display-graphic-p)
                           (user-error "Open a graphical Emacs frame to display the preview; check_latex still checks compilation"))
                         (let ((bounds (my/agent--latex-bounds (plist-get entry :region))))
                           (org-clear-latex-preview (car bounds) (cdr bounds))
                           (goto-char (min (point-max) (1+ (car bounds))))
                           (org-latex-preview))
                         '((preview_requested . t)))
                        (_ (error "Unknown action: %s" action)))))))
           (error `((error . ,(error-message-string error-data)))))))
    (base64-encode-string (encode-coding-string
                          (json-serialize result :false-object :false :null-object :null) 'utf-8) t)))

(defun my/agent--mcp-server ()
  "Configure the stdio MCP bridge for this running Emacs instance."
  (unless (server-running-p server-name) (server-start))
  `((name . "emacs-buffer")
    (command . ,(or (executable-find "python3") (user-error "python3 is not on PATH")))
    (args . (,(expand-file-name "emacs-agent-mcp.py" my/agent-directory)
             "--socket" ,(expand-file-name server-name server-socket-dir)
             "--emacsclient" ,(expand-file-name "emacsclient" invocation-directory)))
    (env . ())))

(with-eval-after-load 'agent-shell
  (require 'agent-shell-antigravity)
  (setq agent-shell-antigravity-acp-command
        (list (expand-file-name "~/.local/bin/agy") "acp" "--dangerously-skip-permissions")
        agent-shell-antigravity-authentication
        (agent-shell-antigravity-make-authentication :none t)
        agent-shell-preferred-agent-config (agent-shell-antigravity-make-agent-config)
        agent-shell-session-strategy 'new
        agent-shell-display-action
        '((display-buffer-reuse-window display-buffer-in-direction)
          (direction . below)
          (window . root)
          (window-height . 0.5)
          (inhibit-same-window . t)
          (reusable-frames . nil))
        agent-shell-permission-responder-function #'agent-shell-permission-allow-always)
  (add-to-list 'agent-shell-mcp-servers (lambda () (my/agent--mcp-server))))

(defun my/agent-ask (prompt)
  "Ask Antigravity to edit the current buffer using live Emacs tools."
  (interactive "sAsk Antigravity: ")
  (require 'agent-shell)
  (let* ((id (my/agent-capture-context))
         (context (json-serialize (my/agent-context id) :null-object :null))
         (shell-buffer (agent-shell--shell-buffer)))
    (agent-shell-insert
     :shell-buffer shell-buffer
     :text (concat "Work in the live Emacs buffer using the emacs-buffer MCP tools. "
                   "Read emacs_context first. Apply requested edits directly with Emacs tools; "
                   "retain undo history and leave saving to me. Use sum_column for Org totals "
                   "so the result has a recalculating TBLFM formula. For LaTeX repairs, use "
                   "check_latex before and after editing, then preview_latex. Insert symbol "
                   "requests at the captured point. If the buffer changes, re-read context.\n"
                   "Context: " context "\n\nRequest: " prompt)
     :submit t)))

(defun my/agent-insert-symbol (description)
  (interactive "sDescribe the LaTeX symbol: ")
  (my/agent-ask (concat "Insert the LaTeX for this symbol at my captured cursor: " description)))

(defun my/agent-repair-latex ()
  (interactive)
  (my/agent-ask "Diagnose and fix the current/selected LaTeX equation so it compiles and previews. Preserve its mathematical meaning."))

(defun my/agent-sum-column (column)
  (interactive (list (progn (unless (org-at-table-p) (user-error "Move into an Org table"))
                            (read-number "Column to sum: " (org-table-current-column)))))
  (let ((result (my/agent-org-sum (my/agent-capture-context) column (buffer-chars-modified-tick))))
    (message "%s" (alist-get 'formula result))))

(define-prefix-command 'my/agent-map)
(global-set-key (kbd "C-c e") 'my/agent-map)
(define-key my/agent-map (kbd "a") #'my/agent-ask)
(define-key my/agent-map (kbd "i") #'my/agent-insert-symbol)
(define-key my/agent-map (kbd "l") #'my/agent-repair-latex)
(define-key my/agent-map (kbd "s") #'my/agent-sum-column)
(define-key my/agent-map (kbd "e") #'agent-shell)

(provide 'ai-agent)
;;; ai-agent.el ends here
