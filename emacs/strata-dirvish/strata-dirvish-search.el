;;; strata-dirvish-search.el --- Search, pane filters, history, frecency & letter marks -*- lexical-binding: t; -*-

;;; Commentary:
;; Implements Strata search, live pane filtering (with subfolder depth &
;; Compact-mode preservation), global recursive `fd' search (C-k) with
;; exclusions and time/entry limits, per-pane back/forward history, frecency
;; jumps (z / Z / C-S-k), persistent letter bookmarks (m / '), and C-l URI
;; location prompt.

;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'dirvish-narrow nil t)
(require 'subr-x)
(require 'strata-dirvish-prefs)
(require 'strata-dirvish-devices)
(require 'strata-dirvish-views)
(require 'strata-dirvish-panes)

(defvar strata-history-file
  (expand-file-name "history.eld" strata-dirvish-state-dir)
  "Persistence file for Strata visited-folder frecency.")

(defvar strata-visited-folders nil
  "Alist of ((DIR . COUNT) ...) ordered most-recently-visited first.")

(defvar strata-last-find-query nil)
(defvar strata-last-find-backward nil)

;;;; Frecency & Per-Pane Back/Forward History

(defun strata-history-load ()
  "Load saved visited folders frecency list."
  (when (and (null strata-visited-folders) (file-readable-p strata-history-file))
    (ignore-errors
      (with-temp-buffer
        (insert-file-contents strata-history-file)
        (let ((v (read (current-buffer))))
          (when (listp v) (setq strata-visited-folders v)))))))

(defun strata-history-save ()
  "Save visited folders frecency list."
  (make-directory (file-name-directory strata-history-file) t)
  (with-temp-file strata-history-file
    (prin1 (seq-take strata-visited-folders 250) (current-buffer))
    (insert "\n")))

(defun strata-record-history (pane dir)
  "Push DIR onto PANE's back stack and update visited-folder frecency."
  (when (and dir (not (string-empty-p dir)))
    (setf (strata-pane-state-history-back pane)
          (cons dir (seq-take (strata-pane-state-history-back pane) 64)))
    (setf (strata-pane-state-history-fwd pane) nil)
    (unless (strata-location-virtual-p dir)
      (strata-history-load)
      (let* ((canon (directory-file-name (expand-file-name dir)))
             (old (or (cdr (assoc canon strata-visited-folders)) 0)))
        (setq strata-visited-folders
              (cons (cons canon (1+ old))
                    (assoc-delete-all canon strata-visited-folders)))
        (strata-history-save)))))

(defun strata-history-back ()
  "Navigate active pane backward in history (`H' / `M-<left>')."
  (interactive)
  (let* ((pane (strata-active-pane))
         (back (strata-pane-state-history-back pane)))
    (unless back (user-error "No earlier folder in pane history"))
    (let ((cur (strata-pane-state-dir pane))
          (target (pop back)))
      (setf (strata-pane-state-history-back pane) back)
      (when cur (push cur (strata-pane-state-history-fwd pane)))
      (let ((cur-old (strata-pane-state-dir pane)))
        (setf (strata-pane-state-dir pane) nil) ; prevent duplicate push
        (ignore cur-old)
        (strata-open-location target nil)))))

(defun strata-history-forward ()
  "Navigate active pane forward in history (`L' / `M-<right>')."
  (interactive)
  (let* ((pane (strata-active-pane))
         (fwd (strata-pane-state-history-fwd pane)))
    (unless fwd (user-error "No next folder in pane history"))
    (let ((cur (strata-pane-state-dir pane))
          (target (pop fwd)))
      (setf (strata-pane-state-history-fwd pane) fwd)
      (when cur (push cur (strata-pane-state-history-back pane)))
      (setf (strata-pane-state-dir pane) nil)
      (strata-open-location target nil))))

(defun strata-jump-visited-folder ()
  "Jump quickly to any previously visited folder (`z' / `C-S-k')."
  (interactive)
  (strata-history-load)
  (let* ((cands (mapcar #'car strata-visited-folders))
         (picked (completing-read "Jump to folder: " (or cands (list "~/")) nil nil)))
    (when (and picked (not (string-empty-p picked)))
      (strata-open-location picked t))))

(defun strata-jump-recent-file ()
  "Jump to or open a recently used file (`Z')."
  (interactive)
  (let* ((cands (strata-recent-files))
         (picked (completing-read "Recent file: " cands nil t)))
    (when picked
      (if (strata-prefs-search-open-files-directly (strata-prefs))
          (find-file picked)
        (strata-open-location (file-name-directory picked))
        (strata-goto-file picked)))))

;;;; Persistent Cross-Session Letter Bookmarks (`m' / `\'')

(defun strata-letter-bookmark-set (letter &optional dir)
  "Save persistent bookmark LETTER (a-z) for DIR (defaults to current folder)."
  (interactive (list (read-char "Set bookmark letter (a-z): ")))
  (let* ((p (strata-prefs))
         (d (or dir (strata-pane-state-dir (strata-active-pane)) default-directory))
         (tbl (assoc-delete-all letter (strata-prefs-marks p))))
    (push (cons letter d) tbl)
    (setf (strata-prefs-marks p) tbl)
    (strata-prefs-save)
    (message "Bookmark '%c -> %s" letter d)))

(defun strata-letter-bookmark-go (letter)
  "Jump to persistent bookmark LETTER (a-z)."
  (interactive (list (read-char "Jump to bookmark letter: ")))
  (let ((target (cdr (assoc letter (strata-prefs-marks (strata-prefs))))))
    (unless target
      (user-error "No bookmark set for '%c" letter))
    (strata-open-location target t)))

;;;; Editable Location Prompt (`C-l' / `g SPC')

(defun strata-location-prompt ()
  "Open Strata location bar prompt supporting paths, `~', virtual & remote URIs (`C-l')."
  (interactive)
  (let* ((cur (or (ignore-errors (strata-pane-state-dir (strata-active-pane)))
                  default-directory))
         (cands (append strata-virtual-locations
                        (list "admin:///etc/" "sftp://" "smb://")))
         (input (minibuffer-with-setup-hook
                    (lambda () nil)
                  (completing-read "Go to location (path or computer:///trash:///recent:///network:///sftp://): "
                                   (completion-table-in-turn cands #'completion-file-name-table)
                                   nil nil (if (strata-location-virtual-p cur) cur (abbreviate-file-name cur))))))
    (when (and input (not (string-empty-p (string-trim input))))
      (strata-open-location input t))))

;;;; Incremental Find Within Current Folder (`/' / `?' / `n' / `N')

(defun strata-find-in-folder (&optional backward query)
  "Jump to matching filename in current browser buffer."
  (interactive "P")
  (let* ((q (or query (read-string (if backward "Find backward: " "Find: ")
                                   strata-last-find-query)))
         (entries (strata-list-directory-entries default-directory))
         (names (mapcar (lambda (e) (cons (plist-get e :name) (plist-get e :path))) entries)))
    (when (and q (not (string-empty-p q)))
      (setq strata-last-find-query q
            strata-last-find-backward backward)
      (let* ((ordered (if backward (reverse names) names))
             (cur (strata-current-file))
             (cur-pos (cl-position cur ordered :key #'cdr :test #'equal))
             (tail (if cur-pos
                       (append (nthcdr (1+ cur-pos) ordered)
                               (seq-take ordered (1+ cur-pos)))
                     ordered))
             (hit (cl-find-if (lambda (np) (string-match-p (regexp-quote q) (car np))) tail)))
        (if hit
            (progn (strata-goto-file (cdr hit))
                   (message "Found: %s" (car hit)))
          (message "No match for '%s'" q))))))

(defun strata-find-repeat (&optional reversed)
  "Repeat last in-folder find query (`n' / `N')."
  (interactive)
  (if (not strata-last-find-query)
      (call-interactively #'strata-find-in-folder)
    (strata-find-in-folder (if reversed (not strata-last-find-backward) strata-last-find-backward)
                           strata-last-find-query)))

;;;; Folder-Scoped Filter (`f' / `C-f' / `s' Subfolders)

(defun strata-clear-filter ()
  "Clear active folder filter in current pane."
  (interactive)
  (setq-local strata-local-filter nil)
  (cond
   ((derived-mode-p 'dired-mode)
    (when (fboundp 'dirvish-narrow) (revert-buffer)))
   ((derived-mode-p 'strata-compact-mode) (strata-compact-refresh))
   ((derived-mode-p 'strata-icons-mode) (strata-icons-refresh)))
  (force-mode-line-update)
  (message "Filter cleared"))

(defun strata-filter-pane (&optional include-subfolders)
  "Filter current folder (via `dirvish-narrow' or live match; optional subfolders with `s')."
  (interactive "P")
  (if (and (not include-subfolders)
           (derived-mode-p 'dired-mode)
           (fboundp 'dirvish-narrow))
      (call-interactively #'dirvish-narrow)
    (let* ((dir default-directory)
           (q (read-string (if include-subfolders "Filter incl. subfolders: " "Filter folder: ")))
           (subp (or include-subfolders (strata-prefs-filter-include-subfolders (strata-prefs)))))
      (if (string-empty-p (string-trim q))
          (strata-clear-filter)
        (setq-local strata-local-filter q)
        (cond
         ((or (derived-mode-p 'strata-compact-mode)
              (derived-mode-p 'strata-icons-mode))
          (if (derived-mode-p 'strata-compact-mode)
              (strata-compact-refresh)
            (strata-icons-refresh))
          (force-mode-line-update t)
          (message "Filter active: %s (press ESC or empty filter to clear)" q))
         ((and subp (executable-find "fd"))
          (let* ((lines (process-lines "fd" "--max-depth" "4" "--color=never" q dir))
                 (picked (completing-read (format "Matched (%d): " (length lines)) lines nil t)))
            (when picked
              (if (file-directory-p picked)
                  (strata-open-location picked)
                (strata-open-location (file-name-directory picked))
                (strata-goto-file (expand-file-name picked dir))))))
         (t
          (let* ((entries (strata-list-directory-entries dir))
                 (cands (cl-remove-if-not
                         (lambda (e) (string-match-p (regexp-quote q) (plist-get e :name)))
                         entries)))
            (if (= (length cands) 1)
                (let ((one (plist-get (car cands) :path)))
                  (if (file-directory-p one)
                      (strata-open-location one)
                    (strata-goto-file one)))
              (when-let ((picked (completing-read "Filtered matches: "
                                                  (mapcar (lambda (e) (plist-get e :path)) cands)
                                                  nil t)))
                (if (file-directory-p picked)
                    (strata-open-location picked)
                  (strata-goto-file picked)))))))))))

;;;; Global Recursive Search (`C-k`)

(defvar strata-global-search-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    (define-key map (kbd "RET") #'strata-search-activate-at-point)
    (define-key map (kbd "M-RET") #'strata-search-open-folder-at-point)
    (define-key map (kbd "o") #'strata-search-open-folder-at-point)
    (define-key map (kbd "/") #'strata-global-search)
    (define-key map (kbd "s") #'strata-global-search)
    (define-key map (kbd "<mouse-1>") #'strata-search-mouse-click)
    (define-key map (kbd "<mouse-2>") #'strata-search-mouse-activate)
    (define-key map (kbd "<double-mouse-1>") #'strata-search-mouse-activate)
    map)
  "Keymap for `*Strata Search*' global results buffer.")

(defun strata-search-mouse-click (event)
  "Handle `<mouse-1>' in `*Strata Search*': open clicked dir, select files."
  (interactive "e")
  (mouse-set-point event)
  (when-let ((p (get-text-property (line-beginning-position) 'strata-search-path)))
    (when (file-directory-p p)
      (strata-open-location p))))

(defun strata-search-mouse-activate (event)
  "Open clicked search result at EVENT."
  (interactive "e")
  (mouse-set-point event)
  (when (get-text-property (line-beginning-position) 'strata-search-path)
    (strata-search-activate-at-point)))

(define-derived-mode strata-global-search-mode special-mode "Strata-Search"
  "Global Strata async `fd' search results buffer."
  (setq-local truncate-lines t)
  (hl-line-mode 1))

(defun strata-search--roots ()
  "Return search root directories (~ plus local mounted removable drives)."
  (let ((roots (list (expand-file-name "~/"))))
    (dolist (d (strata-devices-list))
      (let ((mp (strata-device-mountpoint d)))
        (when (and mp (memq (strata-device-placement d) '(fixed removable))
                   (not (string= mp "/"))
                   (not (string-prefix-p "/home" mp)))
          (push mp roots))))
    (delete-dups roots)))

(defun strata-search-activate-at-point ()
  "Open searched file/folder at point (or containing folder per `search-open-files-directly')."
  (interactive)
  (let ((p (or (get-text-property (line-beginning-position) 'strata-search-path)
               (user-error "No search result on this line"))))
    (cond
     ((file-directory-p p) (strata-open-location p))
     ((strata-prefs-search-open-files-directly (strata-prefs)) (find-file p))
     (t
      (strata-open-location (file-name-directory p))
      (strata-goto-file p)))))

(defun strata-search-open-folder-at-point ()
  "Open containing folder in active pane & jump cursor to the result (`M-RET')."
  (interactive)
  (let ((p (or (get-text-property (line-beginning-position) 'strata-search-path)
               (user-error "No search result on this line"))))
    (strata-open-location (file-name-directory p))
    (strata-goto-file p)))

(defun strata-global-search (&optional query)
  "Run asynchronous global `fd' search across Home + local drives (`C-k')."
  (interactive)
  (let* ((q (or query (read-string "Global search (Home & mounted local drives): ")))
         (p (strata-prefs))
         (limit (max 100 (or (strata-prefs-search-entry-limit p) 5000)))
         (timeout-sec (max 1 (or (strata-prefs-search-time-limit p) 5)))
         (exclusions (strata-prefs-search-exclusions p))
         (fd (or (executable-find "fd") (executable-find "fdfind"))))
    (unless fd (user-error "`fd' executable not found on PATH"))
    (unless (and q (not (string-empty-p (string-trim q))))
      (user-error "Empty search query"))
    (let* ((buf (get-buffer-create "*Strata Search*"))
           (args (append (list "timeout" (number-to-string timeout-sec)
                               fd "--color=never" "--max-results" (number-to-string limit))
                         (cl-loop for ex in exclusions append (list "--exclude" ex))
                         (list "--" q)
                         (strata-search--roots))))
      (with-current-buffer buf
        (strata-global-search-mode)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (setq-local header-line-format
                      (concat "  "
                              (strata-icon-glyph 'search 'strata-header-accent)
                              (propertize (format " Searching '%s'… (Click/RET: Open · M-RET: Reveal Folder · /: New Search)" q)
                                          'face 'strata-header-accent)))
          (insert (propertize (format "  Searching across %s…\n\n"
                                      (string-join (strata-search--roots) ", "))
                              'face 'shadow))))
      (pop-to-buffer buf)
      (make-process
       :name "strata-global-fd"
       :buffer (generate-new-buffer " *strata-fd-out*")
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
                                'face 'strata-section-heading))
                       (dolist (path lines)
                         (let* ((dirp (file-directory-p path))
                                (line (format "   %s  %-38s  %s\n"
                                              (strata-icon-glyph (if dirp 'folder 'file))
                                              (truncate-string-to-width (file-name-nondirectory path) 38 nil nil "…")
                                              (propertize (abbreviate-file-name (or (file-name-directory path) "/"))
                                                          'face 'shadow))))
                           (add-text-properties 0 (length line)
                                                (append (list 'strata-search-path path
                                                              'mouse-face 'highlight)
                                                        (when dirp (list 'pointer 'hand 'help-echo path)))
                                                line)
                           (insert line)))
                       (goto-char (point-min))))))
             (when (buffer-live-p (process-buffer proc))
               (kill-buffer (process-buffer proc))))))))))

(provide 'strata-dirvish-search)
;;; strata-dirvish-search.el ends here
