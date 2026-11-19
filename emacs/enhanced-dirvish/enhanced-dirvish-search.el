;;; enhanced-dirvish-search.el --- Search, pane filters, history, frecency & letter marks -*- lexical-binding: t; -*-

;;; Commentary:
;; Implements Enhanced Dirvish search, live pane filtering (with subfolder depth &
;; Compact-mode preservation), global recursive `fd' search (C-k) with
;; exclusions and time/entry limits, per-pane back/forward history, frecency
;; jumps (z / Z / C-S-k), persistent letter bookmarks (m / '), and C-l URI
;; location prompt.

;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'dirvish-narrow nil t)
(require 'subr-x)
(require 'enhanced-dirvish-prefs)
(require 'enhanced-dirvish-devices)
(require 'enhanced-dirvish-views)
(require 'enhanced-dirvish-panes)

(defvar enhanced-dirvish-history-file
  (expand-file-name "history.eld" enhanced-dirvish-state-dir)
  "Persistence file for Enhanced Dirvish visited-folder frecency.")

(defvar enhanced-dirvish-visited-folders nil
  "Alist of ((DIR . COUNT) ...) ordered most-recently-visited first.")

(defvar enhanced-dirvish-last-find-query nil)
(defvar enhanced-dirvish-last-find-backward nil)

;;;; Frecency & Per-Pane Back/Forward History

(defun enhanced-dirvish-history-load ()
  "Load saved visited folders frecency list."
  (when (and (null enhanced-dirvish-visited-folders) (file-readable-p enhanced-dirvish-history-file))
    (ignore-errors
      (with-temp-buffer
        (insert-file-contents enhanced-dirvish-history-file)
        (let ((v (read (current-buffer))))
          (when (listp v) (setq enhanced-dirvish-visited-folders v)))))))

(defun enhanced-dirvish-history-save ()
  "Save visited folders frecency list."
  (make-directory (file-name-directory enhanced-dirvish-history-file) t)
  (with-temp-file enhanced-dirvish-history-file
    (prin1 (seq-take enhanced-dirvish-visited-folders 250) (current-buffer))
    (insert "\n")))

(defun enhanced-dirvish-record-history (pane dir)
  "Push DIR onto PANE's back stack and update visited-folder frecency."
  (when (and dir (not (string-empty-p dir)))
    (setf (enhanced-dirvish-pane-state-history-back pane)
          (cons dir (seq-take (enhanced-dirvish-pane-state-history-back pane) 64)))
    (setf (enhanced-dirvish-pane-state-history-fwd pane) nil)
    (unless (enhanced-dirvish-location-virtual-p dir)
      (enhanced-dirvish-history-load)
      (let* ((canon (directory-file-name (expand-file-name dir)))
             (old (or (cdr (assoc canon enhanced-dirvish-visited-folders)) 0)))
        (setq enhanced-dirvish-visited-folders
              (cons (cons canon (1+ old))
                    (assoc-delete-all canon enhanced-dirvish-visited-folders)))
        (enhanced-dirvish-history-save)))))

(defun enhanced-dirvish-history-back ()
  "Navigate active pane backward in history (`H' / `M-<left>')."
  (interactive)
  (let* ((pane (enhanced-dirvish-active-pane))
         (back (enhanced-dirvish-pane-state-history-back pane)))
    (unless back (user-error "No earlier folder in pane history"))
    (let ((cur (enhanced-dirvish-pane-state-dir pane))
          (target (pop back)))
      (setf (enhanced-dirvish-pane-state-history-back pane) back)
      (when cur (push cur (enhanced-dirvish-pane-state-history-fwd pane)))
      (let ((cur-old (enhanced-dirvish-pane-state-dir pane)))
        (setf (enhanced-dirvish-pane-state-dir pane) nil) ; prevent duplicate push
        (ignore cur-old)
        (enhanced-dirvish-open-location target nil)))))

(defun enhanced-dirvish-history-forward ()
  "Navigate active pane forward in history (`L' / `M-<right>')."
  (interactive)
  (let* ((pane (enhanced-dirvish-active-pane))
         (fwd (enhanced-dirvish-pane-state-history-fwd pane)))
    (unless fwd (user-error "No next folder in pane history"))
    (let ((cur (enhanced-dirvish-pane-state-dir pane))
          (target (pop fwd)))
      (setf (enhanced-dirvish-pane-state-history-fwd pane) fwd)
      (when cur (push cur (enhanced-dirvish-pane-state-history-back pane)))
      (setf (enhanced-dirvish-pane-state-dir pane) nil)
      (enhanced-dirvish-open-location target nil))))

(defun enhanced-dirvish-jump-visited-folder ()
  "Jump quickly to any previously visited folder (`z' / `C-S-k')."
  (interactive)
  (enhanced-dirvish-history-load)
  (let* ((cands (mapcar #'car enhanced-dirvish-visited-folders))
         (picked (enhanced-dirvish-ui-completing-read "Jump to folder: " (or cands (list "~/")) nil nil)))
    (when (and picked (not (string-empty-p picked)))
      (enhanced-dirvish-open-location picked t))))

(defun enhanced-dirvish-jump-recent-file ()
  "Jump to or open a recently used file (`Z')."
  (interactive)
  (let* ((cands (enhanced-dirvish-recent-files))
         (picked (enhanced-dirvish-ui-completing-read "Recent file: " cands nil t)))
    (when picked
      (if (enhanced-dirvish-prefs-search-open-files-directly (enhanced-dirvish-prefs))
          (find-file picked)
        (enhanced-dirvish-open-location (file-name-directory picked))
        (enhanced-dirvish-goto-file picked)))))

;;;; Persistent Cross-Session Letter Bookmarks (`m' / `\'')

(defun enhanced-dirvish-letter-bookmark-set (letter &optional dir)
  "Save persistent bookmark LETTER (a-z) for DIR (defaults to current folder)."
  (interactive (list (read-char "Set bookmark letter (a-z): ")))
  (let* ((p (enhanced-dirvish-prefs))
         (d (or dir (enhanced-dirvish-pane-state-dir (enhanced-dirvish-active-pane)) default-directory))
         (tbl (assoc-delete-all letter (enhanced-dirvish-prefs-marks p))))
    (push (cons letter d) tbl)
    (setf (enhanced-dirvish-prefs-marks p) tbl)
    (enhanced-dirvish-prefs-save)
    (message "Bookmark '%c -> %s" letter d)))

(defun enhanced-dirvish-letter-bookmark-go (letter)
  "Jump to persistent bookmark LETTER (a-z)."
  (interactive (list (read-char "Jump to bookmark letter: ")))
  (let ((target (cdr (assoc letter (enhanced-dirvish-prefs-marks (enhanced-dirvish-prefs))))))
    (unless target
      (user-error "No bookmark set for '%c" letter))
    (enhanced-dirvish-open-location target t)))

;;;; Editable Location Prompt (`C-l' / `g SPC')

(defun enhanced-dirvish-location-prompt ()
  "Open Enhanced Dirvish location prompt for active pane (`C-l')."
  (interactive)
  (when (fboundp 'enhanced-dirvish-panes--sync-active-pane-from-window)
    (enhanced-dirvish-panes--sync-active-pane-from-window (selected-window)))
  (let* ((cur (or (ignore-errors (enhanced-dirvish-pane-state-dir (enhanced-dirvish-active-pane)))
                  default-directory))
         (cands (append enhanced-dirvish-virtual-locations
                        (list "admin:///etc/" "sftp://" "smb://")))
         (input (minibuffer-with-setup-hook
                    (lambda () nil)
                  (enhanced-dirvish-ui-completing-read "Go to location (path or computer:///trash:///recent:///network:///sftp://): "
                                   (completion-table-in-turn cands #'completion-file-name-table)
                                   nil nil (if (enhanced-dirvish-location-virtual-p cur) cur (abbreviate-file-name cur))))))
    (when (and input (not (string-empty-p (string-trim input))))
      (enhanced-dirvish-open-location input t))))

;;;; Incremental Find Within Current Folder (`/' / `?' / `n' / `N')

(defun enhanced-dirvish-find-in-folder (&optional backward query)
  "Jump to matching filename in current browser buffer."
  (interactive "P")
  (let* ((q (or query (enhanced-dirvish-ui-read-string (if backward "Find backward: " "Find: ")
                                   enhanced-dirvish-last-find-query)))
         (entries (enhanced-dirvish-list-directory-entries default-directory))
         (names (mapcar (lambda (e) (cons (plist-get e :name) (plist-get e :path))) entries)))
    (when (and q (not (string-empty-p q)))
      (setq enhanced-dirvish-last-find-query q
            enhanced-dirvish-last-find-backward backward)
      (let* ((ordered (if backward (reverse names) names))
             (cur (enhanced-dirvish-current-file))
             (cur-pos (cl-position cur ordered :key #'cdr :test #'equal))
             (tail (if cur-pos
                       (append (nthcdr (1+ cur-pos) ordered)
                               (seq-take ordered (1+ cur-pos)))
                     ordered))
             (hit (cl-find-if (lambda (np) (string-match-p (regexp-quote q) (car np))) tail)))
        (if hit
            (progn (enhanced-dirvish-goto-file (cdr hit))
                   (message "Found: %s" (car hit)))
          (message "No match for '%s'" q))))))

(defun enhanced-dirvish-find-repeat (&optional reversed)
  "Repeat last in-folder find query (`n' / `N')."
  (interactive)
  (if (not enhanced-dirvish-last-find-query)
      (call-interactively #'enhanced-dirvish-find-in-folder)
    (enhanced-dirvish-find-in-folder (if reversed (not enhanced-dirvish-last-find-backward) enhanced-dirvish-last-find-backward)
                           enhanced-dirvish-last-find-query)))

;;;; Folder-Scoped Filter (`f' / `C-f' / `s' Subfolders)

(defun enhanced-dirvish-clear-filter ()
  "Clear active folder filter in current pane."
  (interactive)
  (setq-local enhanced-dirvish-local-filter nil)
  (cond
   ((derived-mode-p 'dired-mode)
    (when (fboundp 'dirvish-narrow) (revert-buffer)))
   ((derived-mode-p 'enhanced-dirvish-compact-mode) (enhanced-dirvish-compact-refresh))
   ((derived-mode-p 'enhanced-dirvish-icons-mode) (enhanced-dirvish-icons-refresh)))
  (force-mode-line-update)
  (message "Filter cleared"))

(defun enhanced-dirvish-filter-pane (&optional include-subfolders)
  "Filter current folder (via `dirvish-narrow' or live match; optional subfolders with `s')."
  (interactive "P")
  (if (and (not include-subfolders)
           (not (enhanced-dirvish-ui-mouse-p))
           (derived-mode-p 'dired-mode)
           (fboundp 'dirvish-narrow))
      (call-interactively #'dirvish-narrow)
    (let* ((dir default-directory)
           (q (enhanced-dirvish-ui-read-string (if include-subfolders "Filter incl. subfolders: " "Filter folder: ")))
           (subp (or include-subfolders (enhanced-dirvish-prefs-filter-include-subfolders (enhanced-dirvish-prefs)))))
      (if (string-empty-p (string-trim q))
          (enhanced-dirvish-clear-filter)
        (setq-local enhanced-dirvish-local-filter q)
        (cond
         ((or (derived-mode-p 'enhanced-dirvish-compact-mode)
              (derived-mode-p 'enhanced-dirvish-icons-mode))
          (if (derived-mode-p 'enhanced-dirvish-compact-mode)
              (enhanced-dirvish-compact-refresh)
            (enhanced-dirvish-icons-refresh))
          (force-mode-line-update t)
          (message "Filter active: %s (press ESC or empty filter to clear)" q))
         ((and subp (executable-find "fd"))
          (let* ((lines (process-lines "fd" "--max-depth" "4" "--color=never" "--" q dir))
                 (picked (enhanced-dirvish-ui-completing-read (format "Matched (%d): " (length lines)) lines nil t)))
            (when picked
              (let ((clean (directory-file-name (expand-file-name picked dir))))
                (if (file-directory-p clean)
                    (enhanced-dirvish-open-location clean)
                  (enhanced-dirvish-open-location (or (file-name-directory clean) dir))
                  (enhanced-dirvish-goto-file clean))))))
         (t
          (let* ((entries (enhanced-dirvish-list-directory-entries dir))
                 (cands (cl-remove-if-not
                         (lambda (e) (string-match-p (regexp-quote q) (plist-get e :name)))
                         entries)))
            (if (= (length cands) 1)
                (let ((one (plist-get (car cands) :path)))
                  (if (file-directory-p one)
                      (enhanced-dirvish-open-location one)
                    (enhanced-dirvish-goto-file one)))
              (when-let ((picked (enhanced-dirvish-ui-completing-read "Filtered matches: "
                                                  (mapcar (lambda (e) (plist-get e :path)) cands)
                                                  nil t)))
                (if (file-directory-p picked)
                    (enhanced-dirvish-open-location picked)
                  (enhanced-dirvish-goto-file picked)))))))))))

;;;; Global Recursive Search (`C-k`)

(defvar enhanced-dirvish-global-search-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    (define-key map (kbd "RET") #'enhanced-dirvish-search-activate-at-point)
    (define-key map (kbd "M-RET") #'enhanced-dirvish-search-open-folder-at-point)
    (define-key map (kbd "o") #'enhanced-dirvish-search-open-folder-at-point)
    (define-key map (kbd "/") #'enhanced-dirvish-global-search)
    (define-key map (kbd "s") #'enhanced-dirvish-global-search)
    (define-key map (kbd "<mouse-1>") #'enhanced-dirvish-search-mouse-click)
    (define-key map (kbd "<mouse-2>") #'enhanced-dirvish-search-mouse-activate)
    (define-key map (kbd "<double-mouse-1>") #'enhanced-dirvish-search-mouse-activate)
    map)
  "Keymap for `*Enhanced Dirvish Search*' global results buffer.")

(defun enhanced-dirvish-search-mouse-click (event)
  "Handle `<mouse-1>' in `*Enhanced Dirvish Search*': open dirs, select files."
  (interactive "e")
  (mouse-set-point event)
  (when-let ((p (get-text-property (line-beginning-position) 'enhanced-dirvish-search-path)))
    (when (file-directory-p p)
      (enhanced-dirvish-open-location p))))

(defun enhanced-dirvish-search-mouse-activate (event)
  "Open clicked search result at EVENT."
  (interactive "e")
  (mouse-set-point event)
  (when (get-text-property (line-beginning-position) 'enhanced-dirvish-search-path)
    (enhanced-dirvish-search-activate-at-point)))

(define-derived-mode enhanced-dirvish-global-search-mode special-mode "Enhanced-Dirvish-Search"
  "Global Enhanced Dirvish async `fd' search results buffer."
  (setq-local truncate-lines t)
  (hl-line-mode 1))

(defun enhanced-dirvish-search--roots ()
  "Return search root directories (~ plus local mounted removable drives)."
  (let ((roots (list (expand-file-name "~/"))))
    (dolist (d (or enhanced-dirvish-devices-cache (enhanced-dirvish-devices-list)))
      (let ((mp (enhanced-dirvish-device-mountpoint d)))
        (when (and mp (memq (enhanced-dirvish-device-placement d) '(fixed removable))
                   (not (string= mp "/"))
                   (not (string-prefix-p "/home" mp)))
          (push mp roots))))
    (delete-dups roots)))

(defun enhanced-dirvish-search-activate-at-point ()
  "Open searched file/folder at point (or containing folder per `search-open-files-directly')."
  (interactive)
  (let ((p (or (get-text-property (line-beginning-position) 'enhanced-dirvish-search-path)
               (user-error "No search result on this line"))))
    (cond
     ((file-directory-p p) (enhanced-dirvish-open-location p))
     ((enhanced-dirvish-prefs-search-open-files-directly (enhanced-dirvish-prefs)) (find-file p))
     (t
      (enhanced-dirvish-open-location (file-name-directory p))
      (enhanced-dirvish-goto-file p)))))

(defun enhanced-dirvish-search-open-folder-at-point ()
  "Open containing folder in active pane & jump cursor to the result (`M-RET')."
  (interactive)
  (let* ((p (or (get-text-property (line-beginning-position) 'enhanced-dirvish-search-path)
                (user-error "No search result on this line")))
         (clean (directory-file-name p)))
    (enhanced-dirvish-open-location (or (file-name-directory clean) "/"))
    (enhanced-dirvish-goto-file clean)))

(defun enhanced-dirvish-global-search (&optional query)
  "Run asynchronous global `fd' search across Home + local drives (`C-k')."
  (interactive)
  (let* ((q (or query (enhanced-dirvish-ui-read-string "Global search (Home & mounted local drives): ")))
         (p (enhanced-dirvish-prefs))
         (limit (max 100 (or (enhanced-dirvish-prefs-search-entry-limit p) 5000)))
         (timeout-sec (max 1 (or (enhanced-dirvish-prefs-search-time-limit p) 5)))
         (exclusions (enhanced-dirvish-prefs-search-exclusions p))
         (fd (or (executable-find "fd") (executable-find "fdfind"))))
    (unless fd (user-error "`fd' executable not found on PATH"))
    (unless (and q (not (string-empty-p (string-trim q))))
      (user-error "Empty search query"))
    (let* ((buf (get-buffer-create "*Enhanced Dirvish Search*"))
           (args (append (list "timeout" (number-to-string timeout-sec)
                               fd "--color=never" "--max-results" (number-to-string limit))
                         (cl-loop for ex in exclusions append (list "--exclude" ex))
                         (list "--" q)
                         (enhanced-dirvish-search--roots))))
      (with-current-buffer buf
        (enhanced-dirvish-global-search-mode)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (setq-local header-line-format
                      (concat "  "
                              (enhanced-dirvish-icon-glyph 'search 'enhanced-dirvish-header-accent)
                              (propertize (format " Searching '%s'… (Click/RET: Open · M-RET: Reveal Folder · /: New Search)" q)
                                          'face 'enhanced-dirvish-header-accent)))
          (insert (propertize (format "  Searching across %s…\n\n"
                                      (string-join (enhanced-dirvish-search--roots) ", "))
                              'face 'shadow))))
      (pop-to-buffer buf)
      (make-process
       :name "enhanced-dirvish-global-fd"
       :buffer (generate-new-buffer " *enhanced-dirvish-fd-out*")
       :noquery t
       :command args
       :sentinel
       (lambda (proc _ev)
         (when (memq (process-status proc) '(exit signal))
           (unwind-protect
               (let* ((raw (if (buffer-live-p (process-buffer proc))
                               (with-current-buffer (process-buffer proc) (buffer-string))
                             ""))
                      (lines (split-string raw "\n" t))
                      (timed-out (= (process-exit-status proc) 124)))
                 (when (buffer-live-p buf)
                   (with-current-buffer buf
                     (let ((inhibit-read-only t))
                       (erase-buffer)
                       (insert (propertize
                                (format "  %d results for \"%s\"%s\n\n"
                                        (length lines) q
                                        (cond (timed-out "  [Time limit reached (partial)]")
                                              ((>= (length lines) limit) "  [Entry limit reached (partial)]")
                                              (t "")))
                                'face 'enhanced-dirvish-section-heading))
                       (dolist (path lines)
                         (let* ((clean (directory-file-name path))
                                (dirp (file-directory-p clean))
                                (line (format "   %s  %-38s  %s\n"
                                              (enhanced-dirvish-icon-glyph (if dirp 'folder 'file))
                                              (truncate-string-to-width (file-name-nondirectory clean) 38 nil nil "…")
                                              (propertize (abbreviate-file-name (or (file-name-directory clean) "/"))
                                                          'face 'shadow))))
                           (insert (enhanced-dirvish-add-row-properties
                                    line (append (list 'enhanced-dirvish-search-path clean
                                                       'mouse-face 'highlight)
                                                 (when dirp (list 'pointer 'hand 'help-echo clean)))))))
                       (goto-char (point-min))))))
             (when (buffer-live-p (process-buffer proc))
               (kill-buffer (process-buffer proc))))))))))

(provide 'enhanced-dirvish-search)
;;; enhanced-dirvish-search.el ends here
