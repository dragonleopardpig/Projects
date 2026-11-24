;;; init-study.el --- Personal note-taking workbench: Sioyek + AI + Org -*- lexical-binding: t; -*-

;;; Commentary:
;; Emacs side of the Study AI workbench.  Sioyek keeps showing the PDF; pressing
;; `E' (selected text) or `S' (dragged rectangle -> vector SVG) there sends the
;; context to the right-hand `xwidget-webkit' chat pane started here.  The pane
;; asks Antigravity, Codex or Claude Code, renders the Markdown answer (KaTeX
;; math, sanitised vector SVG) and its "Save to Org" button converts the answer
;; with Pandoc and files it into your Org notes.  Sioyek's own SQLite databases
;; are read directly to browse and import highlights and notes.
;;
;; Keys (prefix `C-c n'): o open, s send region, a ask, t target Org file,
;; g agent, h browse Sioyek highlights, b import a book's highlights,
;; r sync theme, q stop.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(declare-function xwidget-webkit-browse-url "xwidget" (url &optional new-session))
(declare-function xwidget-webkit-last-session "xwidget" ())
(declare-function xwidget-webkit-edit-mode "xwidget" (&optional arg))
(declare-function xwidget-webkit-pass-command-event "xwidget" ())
(declare-function xwidget-buffer "xwidget.c" (xwidget))
(declare-function org-before-first-heading-p "org" ())
(declare-function org-current-level "org" ())
(declare-function org-end-of-subtree "org" (&optional invisible-ok to-heading))
(declare-function org-latex-preview "org" (&optional arg))
(declare-function org-redisplay-inline-images "org" ())
(declare-function org-link-set-parameters "ol" (type &rest parameters))
(declare-function pdf-view-current-page "pdf-view" (&optional window))
(declare-function pdf-view-active-region-p "pdf-view" ())
(declare-function pdf-view-active-region-text "pdf-view" ())
(declare-function color-rgb-to-hex "color" (red green blue &optional digits-per-component))
(declare-function server-running-p "server" (&optional name))
(declare-function server-start "server" (&optional leave-dead inhibit-prompt))

(defgroup my/study nil
  "Sioyek + AI + Org note-taking workbench."
  :group 'applications
  :prefix "my/study-")

(defconst my/study-directory
  (expand-file-name "../study/" (file-name-directory
                                 (or load-file-name buffer-file-name
                                     default-directory)))
  "Directory holding the Study AI Python backend and web UI.")

(defcustom my/study-sioyek-data-dir "~/.local/share/sioyek"
  "Directory with Sioyek's `local.db' and `shared.db'."
  :type 'directory)

(defcustom my/study-default-org-file "~/Projects/org/study-notes.org"
  "Org file receiving saved answers unless another one is chosen."
  :type 'file)

(defcustom my/study-default-agent "antigravity"
  "AI agent used at startup: antigravity, codex or claude."
  :type '(choice (const "antigravity") (const "codex") (const "claude")))

(defcustom my/study-python-command nil
  "Python used for the backend.  Nil means `emacs-study-python' or python3."
  :type '(choice (const nil) file))

(defcustom my/study-sioyek-command nil
  "Sioyek executable.  Nil means ~/.local/bin/sioyek or `sioyek' in PATH."
  :type '(choice (const nil) file))

(defcustom my/study-katex-dir "~/.local/share/emacs-study/katex"
  "Directory with KaTeX's `dist' files, served offline to the pane."
  :type 'directory)

(defcustom my/study-mock-agent nil
  "When non-nil, answer with canned text instead of calling an AI CLI."
  :type 'boolean)

(defcustom my/study-pane-width 0.48
  "Width of the Study AI pane as a fraction of the frame."
  :type 'number)

(defvar my/study--proc nil "The backend server process.")
(defvar my/study--port nil)
(defvar my/study--token nil)
(defvar my/study--partial "" "Unterminated stdout text from the backend.")
(defvar my/study--ready-callbacks nil)
(defvar my/study--webkit-buffer nil)
(defvar my/study--target-org nil "Org file receiving saved answers.")
(defvar my/study--target-explicit nil)

;;;; Helpers

(defun my/study--python ()
  "Return the Python executable for the backend."
  (or my/study-python-command
      (let ((wrapper (expand-file-name "~/.local/bin/emacs-study-python")))
        (and (file-executable-p wrapper) wrapper))
      (executable-find "python3")
      (user-error "No Python found for the Study AI backend")))

(defun my/study--current-target ()
  "Return the Org file that receives saved answers."
  (expand-file-name (or my/study--target-org my/study-default-org-file)))

(defun my/study--adopt-org-target ()
  "Make the visited Org buffer the target unless one was chosen explicitly."
  (when (and (not my/study--target-explicit)
             buffer-file-name
             (derived-mode-p 'org-mode))
    (setq my/study--target-org buffer-file-name)))

(defun my/study--send-cmd (command)
  "Send COMMAND, an alist, to the backend as one NDJSON line."
  (when (process-live-p my/study--proc)
    (process-send-string my/study--proc (concat (json-encode command) "\n"))))

(defun my/study--color (face attribute)
  "Return FACE's ATTRIBUTE as a #RRGGBB string, or nil."
  (let ((value (face-attribute face attribute nil 'default)))
    (when (stringp value)
      (let ((rgb (ignore-errors (color-name-to-rgb value))))
        (when rgb
          (require 'color)
          (apply #'color-rgb-to-hex (append rgb '(2))))))))

(defun my/study--theme ()
  "Return the current Emacs colors as an alist for the pane."
  `((mode . ,(if (eq (frame-parameter nil 'background-mode) 'dark)
                 "dark" "light"))
    (bg . ,(my/study--color 'default :background))
    (fg . ,(my/study--color 'default :foreground))
    (accent . ,(my/study--color 'font-lock-keyword-face :foreground))))

;;;###autoload
(defun my/study-sync-theme ()
  "Send the current Emacs theme colors to the Study AI pane."
  (interactive)
  (my/study--send-cmd `((cmd . "set_theme") (theme . ,(my/study--theme)))))

(defun my/study--on-theme-change (&rest _)
  "Keep the pane colors in sync after a theme change."
  (my/study-sync-theme))

(add-hook 'enable-theme-functions #'my/study--on-theme-change)
(add-hook 'disable-theme-functions #'my/study--on-theme-change)

;;;; Backend process

(defun my/study--url ()
  "Return the authenticated pane URL."
  (format "http://127.0.0.1:%d/?token=%s" my/study--port my/study--token))

(defun my/study--handle-event (event)
  "Act on one backend EVENT (an alist)."
  (pcase (alist-get 'event event)
    ("ready"
     (setq my/study--port (alist-get 'port event)
           my/study--token (alist-get 'token event))
     (my/study-sync-theme)
     (let ((callbacks (nreverse my/study--ready-callbacks)))
       (setq my/study--ready-callbacks nil)
       (dolist (callback callbacks)
         (funcall callback))))
    ("context_received" (my/study--show-pane))
    ("save_to_org" (my/study--on-save event))
    ("choose_org_file"
     (run-at-time 0 nil (lambda ()
                          (call-interactively #'my/study-choose-target-org))))
    ("focus_pane" (my/study--on-focus event))
    ("open_sioyek"
     (when-let* ((file (alist-get 'file event)))
       (my/study-open-in-sioyek file (alist-get 'page event))))
    ("error" (message "Study AI: %s" (alist-get 'message event)))))

(defun my/study--filter (_proc chunk)
  "Collect backend stdout CHUNK and dispatch complete NDJSON lines."
  (setq my/study--partial (concat my/study--partial chunk))
  (let ((lines (split-string my/study--partial "\n")))
    (setq my/study--partial (car (last lines)))
    (dolist (line (butlast lines))
      (let ((event (and (not (string-empty-p (string-trim line)))
                        (ignore-errors
                          (json-parse-string line :object-type 'alist
                                             :array-type 'list
                                             :null-object nil
                                             :false-object nil)))))
        (when event
          (condition-case err
              (my/study--handle-event event)
            (error (message "Study AI: %s" (error-message-string err)))))))))

(defun my/study--sentinel (proc _event)
  "Reset state when the backend PROC exits."
  (when (memq (process-status proc) '(exit signal))
    (when (eq proc my/study--proc)
      (setq my/study--proc nil
            my/study--port nil
            my/study--token nil
            my/study--partial ""
            my/study--ready-callbacks nil))))

(defun my/study--ensure-server (callback)
  "Start the backend if needed and call CALLBACK once it is ready."
  (cond
   ((and (process-live-p my/study--proc) my/study--port)
    (funcall callback))
   ((process-live-p my/study--proc)
    (push callback my/study--ready-callbacks))
   (t
    (let* ((script (expand-file-name "emacs-study-server.py"
                                     my/study-directory))
           (katex (expand-file-name my/study-katex-dir))
           (stderr (get-buffer-create " *emacs-study-stderr*"))
           (args (append
                  (list (my/study--python) script
                        "--target-org" (my/study--current-target)
                        "--agent" my/study-default-agent)
                  (when (file-directory-p katex) (list "--katex-dir" katex))
                  (when my/study-mock-agent (list "--mock-agent")))))
      (unless (file-readable-p script)
        (user-error "Study AI backend not found: %s" script))
      (with-current-buffer stderr (erase-buffer))
      (push callback my/study--ready-callbacks)
      (setq my/study--partial ""
            my/study--proc
            (make-process :name "emacs-study-server"
                          :buffer nil
                          :command args
                          :coding 'utf-8-unix
                          :connection-type 'pipe
                          :noquery t
                          :stderr stderr
                          :filter #'my/study--filter
                          :sentinel #'my/study--sentinel))))))

;;;###autoload
(defun my/study-stop ()
  "Stop the Study AI backend and close its pane."
  (interactive)
  (when (process-live-p my/study--proc)
    (my/study--send-cmd '((cmd . "shutdown")))
    (let ((proc my/study--proc))
      (run-with-timer 1 nil (lambda ()
                              (when (process-live-p proc)
                                (delete-process proc))))))
  (when (buffer-live-p my/study--webkit-buffer)
    (let ((win (get-buffer-window my/study--webkit-buffer t))
          (kill-buffer-query-functions
           (delq 'xwidget-kill-buffer-query-function
                 (copy-sequence kill-buffer-query-functions))))
      (kill-buffer my/study--webkit-buffer)
      (when (and (window-live-p win) (not (one-window-p t)))
        (delete-window win))))
  (setq my/study--webkit-buffer nil))

(add-hook 'kill-emacs-hook
          (lambda ()
            (when (process-live-p my/study--proc)
              (delete-process my/study--proc))))

;;;; The WebKit pane

(defun my/study--count-columns (win)
  "Count horizontal leaf columns spanned by window tree node WIN."
  (let ((left (window-left-child win)))
    (if (not left)
        1
      (let ((total 0))
        (while left
          (setq total (+ total (my/study--count-columns left))
                left (window-next-sibling left)))
        total))))

(defun my/study--root-columns ()
  "Return the number of top-level horizontal window columns on the frame."
  (my/study--count-columns (frame-root-window)))

(defun my/study--open-right-window ()
  "Open a right-hand Study AI pane sized evenly alongside existing panes."
  (let* ((root (frame-root-window))
         (cols (my/study--root-columns))
         (frac (if (> cols 1)
                   (min my/study-pane-width (/ 1.0 (1+ cols)))
                 my/study-pane-width))
         (total (window-total-width root))
         (target (max window-min-width
                      (min (round (* total frac))
                           (- total window-min-width)))))
    (or (ignore-errors (split-window root (- target) 'right))
        (split-window (selected-window) nil 'right))))

(defun my/study--show-pane ()
  "Show the Study AI pane on the right without crushing existing panes."
  (unless (and (fboundp 'xwidget-webkit-browse-url) (display-graphic-p))
    (user-error "The Study AI pane needs a graphical Emacs with xwidgets"))
  (cond
   ((and (buffer-live-p my/study--webkit-buffer)
         (get-buffer-window my/study--webkit-buffer t))
    nil)
   ((buffer-live-p my/study--webkit-buffer)
    (set-window-buffer (my/study--open-right-window) my/study--webkit-buffer))
   (t
    (let ((win (my/study--open-right-window)))
      (with-selected-window win
        (let ((switch-to-buffer-obey-display-actions nil)
              (display-buffer-overriding-action nil))
          (xwidget-webkit-browse-url (my/study--url) t)))
      (let ((xwidget (xwidget-webkit-last-session)))
        (setq my/study--webkit-buffer (and xwidget (xwidget-buffer xwidget))))
      (when (and (buffer-live-p my/study--webkit-buffer)
                 (not (get-buffer-window my/study--webkit-buffer t)))
        (set-window-buffer win my/study--webkit-buffer))))))

(declare-function get-buffer-xwidgets "xwidget.c" (buffer))
(declare-function xwidget-view-lookup "xwidget.c" (xwidget &optional window))
(declare-function delete-xwidget-view "xwidget.c" (xwidget-view))
(declare-function xwidget-webkit-adjust-size-in-frame "xwidget" (frame))

(defvar my/study--drag-suspended nil
  "List of (WINDOW BUFFER POINT) saved while dragging dividers near xwidgets.")

(defconst my/study--resize-placeholder-name " *Study AI (resizing)*"
  "Hidden placeholder buffer name used while dragging window dividers.")

(defun my/study--resize-placeholder-buffer ()
  "Return the placeholder buffer shown during divider drags."
  (let ((buf (get-buffer my/study--resize-placeholder-name)))
    (unless (buffer-live-p buf)
      (setq buf (get-buffer-create my/study--resize-placeholder-name))
      (with-current-buffer buf
        (setq-local buffer-read-only t
                    buffer-undo-list t
                    cursor-type nil
                    mode-line-format '("  Study AI (resizing...)"))
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (propertize "\n  Study AI paused while resizing divider...\n"
                              'face 'shadow)))))
    buf))

(defun my/study--xwidget-windows (frame)
  "Return non-minibuffer `xwidget-webkit-mode' windows on FRAME."
  (let (wins)
    (dolist (w (window-list frame 'no-minibuf))
      (when (eq (buffer-local-value 'major-mode (window-buffer w))
                'xwidget-webkit-mode)
        (push w wins)))
    (nreverse wins)))

(defun my/study--suspend-xwidgets (frame)
  "Detach live xwidget views on FRAME during divider drags."
  (unless my/study--drag-suspended
    (let ((ph (my/study--resize-placeholder-buffer))
          (saved nil))
      (dolist (w (my/study--xwidget-windows frame))
        (let ((buf (window-buffer w))
              (pt (window-point w)))
          (push (list w buf pt) saved)
          (when (and (fboundp 'get-buffer-xwidgets)
                     (fboundp 'xwidget-view-lookup)
                     (fboundp 'delete-xwidget-view))
            (dolist (xw (get-buffer-xwidgets buf))
              (when-let* ((view (xwidget-view-lookup xw w)))
                (ignore-errors (delete-xwidget-view view)))))
          (set-window-buffer w ph)))
      (setq my/study--drag-suspended (nreverse saved)))))

(defun my/study--restore-xwidgets (&optional frame)
  "Restore any `xwidget-webkit-mode' windows suspended for divider dragging."
  (when my/study--drag-suspended
    (let ((entries my/study--drag-suspended)
          (ph (get-buffer my/study--resize-placeholder-name))
          (selected (selected-window))
          (frames nil))
      (setq my/study--drag-suspended nil)
      (dolist (entry entries)
        (pcase-let ((`(,w ,buf ,pt) entry))
          (when (and (window-live-p w)
                     (buffer-live-p buf)
                     (or (null ph) (eq (window-buffer w) ph)))
            (set-window-buffer w buf)
            (let ((pmin (with-current-buffer buf (point-min)))
                  (pmax (with-current-buffer buf (point-max))))
              (set-window-point w (max pmin (min pt pmax)))
              (set-window-start w pmin))
            (cl-pushnew (window-frame w) frames :test #'eq))))
      (when (and (null frames) (frame-live-p frame))
        (setq frames (list frame)))
      (when (fboundp 'xwidget-webkit-adjust-size-in-frame)
        (dolist (f frames)
          (when (frame-live-p f)
            (xwidget-webkit-adjust-size-in-frame f))))
      (when (window-live-p selected)
        (select-window selected t)))))

(defun my/study--around-adjust-size-in-frame (orig-fn frame)
  "Skip xwidget WebKit resizes while a window divider drag is active."
  (unless my/study--drag-suspended
    (funcall orig-fn frame)))

(defun my/study--around-mouse-drag-line (orig-fn start-event line)
  "Keep `mouse-drag-line' smooth when an `xwidget-webkit-mode' pane shows.
Native `WebKitWebView' child widgets absorb GTK pointer motion events as soon
as the cursor crosses into the widget, causing divider drags to move one step
and stall.  Temporarily swap xwidget windows to a lightweight placeholder while
dragging, then restore and resize them once the drag completes."
  (let* ((start (event-start start-event))
         (win (posn-window start))
         (frame (and (window-live-p win) (window-frame win)))
         (area (posn-area start)))
    (if (not (and frame (display-graphic-p frame) (my/study--xwidget-windows frame)))
        (funcall orig-fn start-event line)
      (when my/study--drag-suspended
        (my/study--restore-xwidgets frame))
      (let ((orig-stm (symbol-function 'set-transient-map))
            (handed-off nil))
        (unwind-protect
            (cl-letf (((symbol-function 'set-transient-map)
                       (lambda (map &optional keep-pred on-exit message timeout)
                         (let ((orig-move (lookup-key map [mouse-movement])))
                           (when (and (not my/study--drag-suspended)
                                      (functionp orig-move))
                             (define-key map [mouse-movement]
                               (lambda (ev)
                                 (interactive "e")
                                 (unless my/study--drag-suspended
                                   (my/study--suspend-xwidgets frame))
                                 (funcall orig-move ev))))
                           (let ((wrapped-exit
                                  (lambda ()
                                    (unwind-protect
                                        (when on-exit (funcall on-exit))
                                      (my/study--restore-xwidgets frame)))))
                             (setq handed-off t)
                             (funcall orig-stm map keep-pred wrapped-exit message timeout))))))
              (when (or (eq line 'vertical)
                        (memq area '(right-divider bottom-divider vertical-line)))
                (my/study--suspend-xwidgets frame))
              (funcall orig-fn start-event line))
          (unless handed-off
            (my/study--restore-xwidgets frame)))))))

(defun my/study--on-focus (event)
  "Focus the Study AI window and sync `xwidget-webkit-edit-mode' from EVENT."
  (when (buffer-live-p my/study--webkit-buffer)
    (when (alist-get 'select event)
      (when-let* ((win (get-buffer-window my/study--webkit-buffer t)))
        (select-window win)))
    (when (fboundp 'xwidget-webkit-edit-mode)
      (with-current-buffer my/study--webkit-buffer
        (let ((target (if (alist-get 'editing event) 1 0)))
          (unless (eq (not (zerop target))
                      (bound-and-true-p xwidget-webkit-edit-mode))
            (xwidget-webkit-edit-mode target)))))))

(defvar xwidget-webkit-edit-mode-map)

(defun my/study--configure-webkit-edit-keys ()
  "Pass standard editing navigation keys through during `xwidget-webkit-edit-mode'."
  (when (boundp 'xwidget-webkit-edit-mode-map)
    (dolist (key '([delete] [C-delete] [home] [end] [S-home] [S-end]))
      (define-key xwidget-webkit-edit-mode-map key
                  #'xwidget-webkit-pass-command-event))))

(with-eval-after-load 'xwidget
  (advice-add 'xwidget-webkit-adjust-size-in-frame
              :around #'my/study--around-adjust-size-in-frame)
  (my/study--configure-webkit-edit-keys))
(advice-add 'mouse-drag-line :around #'my/study--around-mouse-drag-line)

;;;###autoload
(defun my/study-open ()
  "Open the Study AI pane beside the current window."
  (interactive)
  (my/study--adopt-org-target)
  (my/study--ensure-server #'my/study--show-pane)
  nil)

;;;; Org insertion

(defun my/study--shift-headings (text delta)
  "Return TEXT with every Org heading pushed DELTA levels deeper."
  (if (<= delta 0)
      text
    (let ((case-fold-search nil))
      (replace-regexp-in-string
       "^\\*+ " (lambda (match) (concat (make-string delta ?*) match)) text))))

(defun my/study--insert-org-note (target org-text)
  "Insert ORG-TEXT into the Org file TARGET and return (FILE BEG END).
When TARGET is visible, the note becomes a child of the heading at its
cursor; otherwise it goes at the end of the file as a top level entry."
  (require 'org)
  (let* ((file (expand-file-name target))
         (_ (make-directory (file-name-directory file) t))
         (buffer (find-file-noselect file))
         (window (get-buffer-window buffer t))
         (was-clean (not (buffer-modified-p buffer)))
         beg end)
    (with-current-buffer buffer
      (unless (derived-mode-p 'org-mode) (org-mode))
      (let ((inhibit-read-only t) (level 1))
        (undo-boundary)
        (atomic-change-group
          (if (and window
                   (progn (goto-char (window-point window))
                          (not (org-before-first-heading-p))))
              (progn (setq level (1+ (org-current-level)))
                     (org-end-of-subtree t))
            (goto-char (point-max)))
          (when (and (not (bobp)) (not (bolp))) (insert "\n"))
          (setq beg (point))
          (insert (my/study--shift-headings org-text (1- level)))
          (unless (bolp) (insert "\n"))
          (setq end (point)))
        (undo-boundary))
      (when (and (display-graphic-p) (not noninteractive))
        (ignore-errors
          (save-restriction
            (narrow-to-region beg end)
            (org-latex-preview '(16))))
        (ignore-errors (org-redisplay-inline-images)))
      (when was-clean (save-buffer)))
    (when window (set-window-point window beg))
    (list file beg end)))

(defun my/study--on-save (event)
  "Insert the Org note described by backend EVENT and acknowledge it."
  (let ((turn-id (alist-get 'turn_id event)))
    (condition-case err
        (let ((result (my/study--insert-org-note (alist-get 'target event)
                                                 (alist-get 'org_text event))))
          (my/study--send-cmd `((cmd . "save_ack") (ok . t)
                                (file . ,(abbreviate-file-name (car result)))
                                (turn_id . ,turn-id)))
          (message "Study AI: saved note to %s"
                   (abbreviate-file-name (car result))))
      (error
       (my/study--send-cmd `((cmd . "save_ack") (ok . :json-false)
                             (error . ,(error-message-string err))
                             (turn_id . ,turn-id)))
       (message "Study AI: could not save note: %s"
                (error-message-string err))))))

;;;; Sioyek: links and database

;;;###autoload
(defun my/study-open-in-sioyek (file &optional page)
  "Show FILE (at 1-based PAGE) in the running Sioyek window."
  (let ((command (or my/study-sioyek-command
                     (let ((local (expand-file-name "~/.local/bin/sioyek")))
                       (and (file-executable-p local) local))
                     (executable-find "sioyek"))))
    (unless command (user-error "Sioyek is not installed"))
    (make-process :name "study-sioyek" :buffer nil :noquery t
                  :connection-type 'pipe
                  :command (append (list command "--reuse-window")
                                   (when page (list "--page" (format "%s" page)))
                                   (list (expand-file-name file))))))

(defun my/study--follow-link (path &optional _arg)
  "Follow a `sioyek:FILE::PAGE' Org link given as PATH."
  (let* ((parts (split-string path "::"))
         (page (and (cadr parts) (string-to-number (cadr parts)))))
    (my/study-open-in-sioyek (car parts) (and page (> page 0) page))))

(with-eval-after-load 'org
  (org-link-set-parameters "sioyek" :follow #'my/study--follow-link))

(defun my/study--db-rows (file sql)
  "Run the read-only query SQL on the SQLite database FILE."
  (when (and (file-readable-p file) (sqlite-available-p))
    (let ((db (sqlite-open file)))
      (unwind-protect (sqlite-select db sql)
        (sqlite-close db)))))

(defun my/study-sioyek-read-entries (&optional data-dir)
  "Return Sioyek highlights and notes as plists, read from DATA-DIR.
Each plist has :kind :hash :file :book :text :note :type :y :created.
Documents are keyed by MD5 in `shared.db'; `local.db' maps them to paths."
  (let* ((dir (expand-file-name (or data-dir my/study-sioyek-data-dir)))
         (paths (make-hash-table :test #'equal))
         entries)
    (dolist (row (my/study--db-rows (expand-file-name "local.db" dir)
                                    "SELECT path, hash FROM document_hash"))
      (let ((old (gethash (cadr row) paths)))
        (when (or (null old)
                  (and (not (file-exists-p old)) (file-exists-p (car row))))
          (puthash (cadr row) (car row) paths))))
    (let ((shared (expand-file-name "shared.db" dir)))
      (dolist (row (my/study--db-rows
                    shared
                    "SELECT document_path, desc, text_annot, type, begin_y,
                            creation_time FROM highlights"))
        (push (list :kind 'highlight :hash (nth 0 row) :text (nth 1 row)
                    :note (nth 2 row) :type (nth 3 row) :y (nth 4 row)
                    :created (nth 5 row))
              entries))
      (dolist (row (my/study--db-rows
                    shared
                    "SELECT document_path, desc, offset_y, creation_time
                       FROM bookmarks"))
        (push (list :kind 'note :hash (nth 0 row) :text (nth 1 row)
                    :y (nth 2 row) :created (nth 3 row))
              entries)))
    (let (result)
      (dolist (entry entries)
        (let ((file (gethash (plist-get entry :hash) paths)))
          (when (and file (stringp (plist-get entry :text)))
            (push (append (list :file file
                                :book (file-name-nondirectory file))
                          entry)
                  result))))
      (sort result
            (lambda (a b)
              (let ((fa (plist-get a :file)) (fb (plist-get b :file)))
                (if (string= fa fb)
                    (< (or (plist-get a :y) 0) (or (plist-get b :y) 0))
                  (string< fa fb))))))))

(defun my/study--resolve-pages (file ys)
  "Return the 1-based page of each absolute Sioyek Y in YS for FILE."
  (let ((script (expand-file-name "study_assets.py" my/study-directory)))
    (with-temp-buffer
      (when (zerop (apply #'call-process (my/study--python) nil '(t nil) nil
                          script "resolve-pages" file
                          (mapcar (lambda (y) (format "%s" (or y 0))) ys)))
        (mapcar #'string-to-number
                (split-string (buffer-string) "\n" t))))))

(defun my/study--flatten (text)
  "Collapse whitespace in TEXT to single spaces."
  (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " (or text ""))))

(defun my/study--entry-line (entry page)
  "Return an Org list item for ENTRY located on PAGE."
  (let ((file (plist-get entry :file)))
    (format "- [[sioyek:%s%s][%s%s]] %s%s\n" file
            (if page (format "::%d" page) "")
            (plist-get entry :book) (if page (format " · p.%d" page) "")
            (my/study--flatten (plist-get entry :text))
            (let ((note (my/study--flatten (plist-get entry :note))))
              (if (string-empty-p note) "" (format " — %s" note))))))

(defun my/study--entry-label (entry)
  "Return a completion label for ENTRY."
  (format "%s · %s %d · %s" (plist-get entry :book) (plist-get entry :kind)
          (round (or (plist-get entry :y) 0))
          (truncate-string-to-width (my/study--flatten (plist-get entry :text))
                                    90 nil nil "…")))

;;;###autoload
(defun my/study-browse-sioyek-highlights ()
  "Pick a Sioyek highlight or note, then open, ask about, or insert it."
  (interactive)
  (let ((entries (my/study-sioyek-read-entries)))
    (unless entries (user-error "No Sioyek highlights found"))
    (let* ((candidates (mapcar (lambda (e) (cons (my/study--entry-label e) e))
                               entries))
           (table (lambda (string predicate action)
                    (if (eq action 'metadata)
                        '(metadata (display-sort-function . identity))
                      (complete-with-action action candidates string predicate))))
           (entry (cdr (assoc (completing-read "Sioyek highlight/note: "
                                               table nil t)
                              candidates)))
           (action (completing-read "Action: "
                                    '("open in Sioyek" "ask Study AI"
                                      "insert into Org")
                                    nil t))
           (page (car (my/study--resolve-pages (plist-get entry :file)
                                               (list (plist-get entry :y))))))
      (pcase action
        ("open in Sioyek" (my/study-open-in-sioyek (plist-get entry :file) page))
        ("ask Study AI"
         (my/study--ensure-server
          (lambda ()
            (my/study--send-cmd `((cmd . "context")
                                  (file . ,(plist-get entry :file))
                                  (page . ,page)
                                  (text . ,(plist-get entry :text))
                                  (replace . t)))
            (my/study--show-pane))))
        (_ (my/study--insert-org-note (my/study--current-target)
                                      (my/study--entry-line entry page)))))))

;;;###autoload
(defun my/study-import-book-highlights ()
  "Insert every highlight and note of one Sioyek book into the target Org."
  (interactive)
  (let* ((entries (my/study-sioyek-read-entries))
         (files (delete-dups (mapcar (lambda (e) (plist-get e :file)) entries))))
    (unless files (user-error "No Sioyek highlights found"))
    (let* ((file (completing-read "Book: " files nil t))
           (mine (cl-remove-if-not
                  (lambda (e) (string= (plist-get e :file) file)) entries))
           (pages (my/study--resolve-pages file (mapcar (lambda (e) (plist-get e :y))
                                                        mine)))
           (body (cl-loop for e in mine
                          for i from 0
                          concat (my/study--entry-line e (nth i pages)))))
      (my/study--insert-org-note
       (my/study--current-target)
       (format "* Highlights: %s\n:PROPERTIES:\n:SOURCE: [[sioyek:%s][%s]]\n:END:\n%s"
               (file-name-nondirectory file) file
               (file-name-nondirectory file) body))
      (message "Imported %d Sioyek entries from %s" (length mine)
               (file-name-nondirectory file)))))

;;;; Commands

;;;###autoload
(defun my/study-send-region ()
  "Send the region (or the `pdf-tools' selection) to the Study AI pane."
  (interactive)
  (let (file page text)
    (cond
     ((derived-mode-p 'pdf-view-mode)
      (setq file buffer-file-name
            page (pdf-view-current-page)
            text (and (pdf-view-active-region-p)
                      (mapconcat #'identity (pdf-view-active-region-text) " "))))
     ((use-region-p)
      (setq file buffer-file-name
            text (buffer-substring-no-properties (region-beginning)
                                                 (region-end))))
     (t (user-error "Select some text first")))
    (my/study--ensure-server
     (lambda ()
       (my/study--send-cmd `((cmd . "context") (file . ,file) (page . ,page)
                             (text . ,text) (replace . t)))
       (my/study--show-pane)))))

;;;###autoload
(defun my/study-ask (question)
  "Ask the selected agent QUESTION about the current reading context."
  (interactive "sAsk Study AI: ")
  (my/study--ensure-server
   (lambda ()
     (my/study--send-cmd `((cmd . "ask") (question . ,question)))
     (my/study--show-pane))))

;;;###autoload
(defun my/study-select-agent (agent)
  "Choose the AI AGENT: antigravity, codex or claude."
  (interactive
   (list (cdr (assoc (completing-read "Agent: "
                                      '("Antigravity" "Codex" "Claude Code") nil t)
                     '(("Antigravity" . "antigravity") ("Codex" . "codex")
                       ("Claude Code" . "claude"))))))
  (setq my/study-default-agent agent)
  (my/study--send-cmd `((cmd . "select_agent") (agent . ,agent))))

;;;###autoload
(defun my/study-choose-target-org (&optional file)
  "Choose the Org FILE that receives saved answers."
  (interactive)
  (let* ((default (my/study--current-target))
         (chosen (or file
                     (read-file-name "Study notes Org file: "
                                     (file-name-directory default) nil nil
                                     (file-name-nondirectory default)))))
    (setq my/study--target-org (expand-file-name chosen)
          my/study--target-explicit t)
    (my/study--send-cmd `((cmd . "set_target_org") (path . ,my/study--target-org)))
    (message "Study AI notes go to %s" (abbreviate-file-name my/study--target-org))))

(defvar my/study-map)
(define-prefix-command 'my/study-map)
(global-set-key (kbd "C-c n") 'my/study-map)
(define-key my/study-map (kbd "o") #'my/study-open)
(define-key my/study-map (kbd "s") #'my/study-send-region)
(define-key my/study-map (kbd "a") #'my/study-ask)
(define-key my/study-map (kbd "t") #'my/study-choose-target-org)
(define-key my/study-map (kbd "g") #'my/study-select-agent)
(define-key my/study-map (kbd "h") #'my/study-browse-sioyek-highlights)
(define-key my/study-map (kbd "b") #'my/study-import-book-highlights)
(define-key my/study-map (kbd "r") #'my/study-sync-theme)
(define-key my/study-map (kbd "q") #'my/study-stop)

;; Let Sioyek (via emacsclient) wake the pane in a running graphical Emacs.
(defun my/study--ensure-emacs-server ()
  "Start the Emacs server so Sioyek can reach this session."
  (require 'server)
  (unless (server-running-p)
    (ignore-errors (server-start))))

(unless noninteractive
  (add-hook 'emacs-startup-hook #'my/study--ensure-emacs-server))

(provide 'init-study)
;;; init-study.el ends here
