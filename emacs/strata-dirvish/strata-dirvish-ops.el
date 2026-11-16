;;; strata-dirvish-ops.el --- File operations, trash, undo, archives, props, actions -*- lexical-binding: t; -*-

;;; Commentary:
;; Implements Strata file operations cleanly inside Emacs:
;; clipboard copy/cut/paste with conflict resolution (Replace / Keep Both / Merge),
;; cross-pane transfer, relative rename, new folder with selection, XDG trash
;; with FUSE fallback, Undo/Redo stack, Content Drop (wl-paste / clipboard),
;; Smart Archive Compress/Extract, Properties buffer with async dir summary &
;; chmod, Folder Customize, Open With (.desktop + recent apps), and Custom
;; Actions (~/.config/strata/actions/*/action.toml + ; . folder chord + Jobs).

;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'json)
(require 'subr-x)
(require 'strata-dirvish-prefs)
(require 'strata-dirvish-devices)
(require 'strata-dirvish-views)
(require 'strata-dirvish-panes)

(defvar strata-clipboard nil
  "Plist `(:mode copy|cut :files (PATHS...))' for Strata file clipboard.")

(defvar strata-undo-stack nil "List of reversible Strata file-operation plists.")
(defvar strata-redo-stack nil "List of redone Strata file-operation plists.")
(defconst strata-undo-limit 50)

(defvar strata-jobs-list nil "List of recorded async job plists for `*Strata Jobs*'.")
(defvar strata-next-job-id 0)

;;;; Refresh Helper & Undo/Redo Helpers

(defun strata--refresh-buffer (buf)
  "Refresh Strata browser buffer BUF safely without changing window focus."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (bound-and-true-p strata-marked-entries)
        (setq strata-marked-entries (cl-remove-if-not #'file-exists-p strata-marked-entries)))
      (cond
       ((derived-mode-p 'dired-mode) (revert-buffer nil t t))
       ((derived-mode-p 'strata-compact-mode) (strata-compact-refresh))
       ((derived-mode-p 'strata-icons-mode) (strata-icons-refresh))
       ((derived-mode-p 'strata-computer-mode) (strata-computer-refresh))
       ((derived-mode-p 'strata-trash-mode) (strata-trash-refresh))))))

(defun strata-refresh-active-view ()
  "Refresh active Strata browser buffer, opposite split pane, and sidebar."
  (strata--refresh-buffer (current-buffer))
  (when (and (fboundp 'strata-split-active-p) (strata-split-active-p))
    (when-let* ((other (and (fboundp 'strata-other-pane) (strata-other-pane)))
                (obuf (strata-pane-state-buffer other)))
      (unless (eq obuf (current-buffer))
        (let ((owin (strata-pane-state-window other)))
          (if (window-live-p owin)
              (with-selected-window owin
                (strata--refresh-buffer obuf))
            (strata--refresh-buffer obuf))))))
  (strata-sidebar-refresh))

(defun strata-undo--push (op)
  "Push undoable operation OP onto `strata-undo-stack' and clear redo stack."
  (push op strata-undo-stack)
  (when (> (length strata-undo-stack) strata-undo-limit)
    (setcdr (nthcdr (1- strata-undo-limit) strata-undo-stack) nil))
  (setq strata-redo-stack nil))

(defun strata-pane-clipboard-summary ()
  "Short badge summarizing clipboard contents for footer mode-line."
  (when-let ((files (plist-get strata-clipboard :files)))
    (format "%s %d"
            (if (eq (plist-get strata-clipboard :mode) 'cut) "Cut" "Copy")
            (length files))))

(defun strata-unique-copy-name (dest-path)
  "Generate non-colliding numbered path for Keep Both beside DEST-PATH."
  (if (not (file-exists-p dest-path))
      dest-path
    (let* ((dir (file-name-directory dest-path))
           (base (file-name-nondirectory (directory-file-name dest-path)))
           (dir-p (file-directory-p dest-path))
           (stem (if dir-p base (file-name-sans-extension base)))
           (ext (if dir-p "" (let ((e (file-name-extension base))) (if e (concat "." e) ""))))
           (n 1)
           (cand nil))
      (while (progn
               (setq cand (expand-file-name
                           (if (= n 1)
                               (format "%s (copy)%s" stem ext)
                             (format "%s (copy %d)%s" stem n ext))
                           dir))
               (file-exists-p cand))
        (setq n (1+ n)))
      cand)))

(defun strata--ensure-writable-target (&optional dir op-name)
  "Return writable target directory DIR or signal `user-error'."
  (let ((d (or dir (ignore-errors (strata-pane-state-dir (strata-active-pane))) default-directory)))
    (strata-guard-writable-location d op-name)
    (unless (file-directory-p d)
      (user-error "Not a writable directory: %s" d))
    d))

(defun strata--guard-not-self-contained (src dest-dir)
  "Refuse moving/copying directory SRC inside itself DEST-DIR."
  (let ((cs (file-name-as-directory (file-truename src)))
        (cd (file-name-as-directory (file-truename dest-dir))))
    (when (and (file-directory-p src) (string-prefix-p cs cd))
      (user-error "Cannot copy or move folder '%s' inside itself" (file-name-nondirectory src)))))

;;;; Clipboard: Copy / Cut / Paste (Keep Both / Replace / Merge) / Unyank

(defun strata-copy-selection ()
  "Copy selected item(s) to Strata clipboard (`y' / `C-c c')."
  (interactive)
  (let* ((dir (ignore-errors (strata-pane-state-dir (strata-active-pane))))
         (_ (when (strata-computer-location-p dir)
              (user-error "Cannot copy items inside computer:///")))
         (files (strata-selected-files)))
    (unless files (user-error "No file selected"))
    (setq strata-clipboard (list :mode 'copy :files files))
    (kill-new (string-join files "\n"))
    (force-mode-line-update t)
    (message "Copied %d item(s)" (length files))))

(defun strata-cut-selection ()
  "Cut selected item(s) to Strata clipboard (`x' / `C-c x')."
  (interactive)
  (let* ((dir (ignore-errors (strata-pane-state-dir (strata-active-pane))))
         (_ (strata-guard-writable-location dir "Cut"))
         (files (strata-selected-files)))
    (unless files (user-error "No file selected"))
    (setq strata-clipboard (list :mode 'cut :files files))
    (force-mode-line-update t)
    (message "Cut %d item(s)" (length files))))

(defun strata-unyank ()
  "Clear Strata clipboard (`Y' / `X')."
  (interactive)
  (setq strata-clipboard nil)
  (force-mode-line-update t)
  (message "Cleared Strata clipboard"))

(defun strata-copy-path ()
  "Copy selected path(s) to clipboard (`c c` / Default `y')."
  (interactive)
  (let ((files (strata-selected-files)))
    (unless files (user-error "No file selected"))
    (kill-new (string-join files "\n"))
    (message "Copied path(s): %s" (car files))))

(defun strata-copy-name ()
  "Copy selected basename(s) to clipboard (`c n')."
  (interactive)
  (let ((files (strata-selected-files)))
    (unless files (user-error "No file selected"))
    (kill-new (mapconcat (lambda (f) (file-name-nondirectory (directory-file-name f)))
                         files "\n"))
    (message "Copied name(s): %s" (file-name-nondirectory (directory-file-name (car files))))))

(defun strata--merge-directory (src dest)
  "Recursively copy/merge SRC directory contents into existing DEST directory."
  (make-directory dest t)
  (dolist (f (directory-files src t "\\`[^.]\\|\\`.[^.]" t))
    (let ((target (expand-file-name (file-name-nondirectory f) dest)))
      (if (file-directory-p f)
          (strata--merge-directory f target)
        (copy-file f target t t t t)))))

(defun strata--replace-target (src target mode)
  "Transfer SRC onto existing TARGET using MODE (`copy' or `cut') with rollback."
  (let* ((dir (file-name-directory (directory-file-name target)))
         (backup (make-temp-name (expand-file-name ".strata-replace-" dir))))
    (rename-file target backup)
    (condition-case err
        (progn
          (if (eq mode 'cut)
              (rename-file src target t)
            (if (file-directory-p src)
                (copy-directory src target t t)
              (copy-file src target t t t t)))
          (if (and (file-directory-p backup) (not (file-symlink-p backup)))
              (delete-directory backup t)
            (delete-file backup)))
      (error
       (unless (or (file-exists-p target) (file-symlink-p target))
         (ignore-errors (rename-file backup target t)))
       (signal (car err) (cdr err))))))

(defun strata--transfer-files (files dest-dir mode &optional keep-both-default replace-default)
  "Copy or move FILES into DEST-DIR handling conflicts & Undo recording.
MODE is `copy' or `cut'. KEEP-BOTH-DEFAULT or REPLACE-DEFAULT skips prompting when set."
  (strata--ensure-writable-target dest-dir (if (eq mode 'cut) "Move" "Copy"))
  (let ((undo-items nil)
        (all-choice nil)
        (moved 0))
    (dolist (src files)
      (when (or (file-exists-p src) (file-symlink-p src))
        (strata--guard-not-self-contained src dest-dir)
        (let* ((base (file-name-nondirectory (directory-file-name src)))
               (target (expand-file-name base dest-dir))
               (norm-src (directory-file-name (expand-file-name src)))
               (norm-tgt (directory-file-name (expand-file-name target)))
               (same-path-p
                (or (equal norm-src norm-tgt)
                    (let ((ts (ignore-errors (file-truename norm-src)))
                          (tt (ignore-errors (file-truename norm-tgt))))
                      (and ts tt (equal (directory-file-name ts)
                                        (directory-file-name tt))))))
               (action
                (cond
                 ((not (or (file-exists-p target) (file-symlink-p target))) 'write)
                 (keep-both-default 'keep-both)
                 (replace-default 'replace)
                 (all-choice all-choice)
                 (t
                  (let* ((opts (append '("keep-both" "replace" "skip")
                                       (when (and (file-directory-p src) (file-directory-p target))
                                         '("merge"))))
                         (pick (intern (strata-ui-completing-read
                                        (format "Conflict for '%s': " base)
                                        opts nil t nil nil "keep-both"))))
                    (when (strata-ui-y-or-n-p "Apply choice to any remaining conflicts? ")
                      (setq all-choice pick))
                    pick)))))
          (when (and (eq action 'replace) same-path-p)
            (user-error "Cannot replace '%s' with itself" base))
          (unless (eq action 'skip)
            (when (eq action 'keep-both)
              (setq target (strata-unique-copy-name target)))
            (cond
             ((and (eq action 'merge) (file-directory-p src) (file-directory-p target))
              (strata--merge-directory src target)
              (when (eq mode 'cut) (delete-directory src t)))
             ((and (eq action 'replace)
                   (or (and (file-directory-p target) (not (file-symlink-p target)))
                       (and (file-directory-p src)
                            (or (file-exists-p target) (file-symlink-p target)))))
              (strata--replace-target src target mode)
              (push (list :type (if (eq mode 'cut) 'move 'copy) :from src :to target)
                    undo-items))
             ((eq mode 'cut)
              (rename-file src target (eq action 'replace))
              (push (list :type 'move :from src :to target) undo-items))
             (t
              (if (file-directory-p src)
                  (copy-directory src target t t)
                (copy-file src target (eq action 'replace) t t t))
              (push (list :type 'copy :from src :to target) undo-items)))
            (setq moved (1+ moved))))))
    (when undo-items
      (strata-undo--push (list :batch (nreverse undo-items))))
    (when (eq mode 'cut) (setq strata-clipboard nil))
    (strata-refresh-active-view)
    (message "%s %d item(s) -> %s"
             (if (eq mode 'cut) "Moved" "Copied") moved (abbreviate-file-name dest-dir))))

(defun strata-paste-keep-both ()
  "Paste Strata clipboard items keeping both on conflicts (`p' / `C-c v')."
  (interactive)
  (let ((files (plist-get strata-clipboard :files))
        (mode (or (plist-get strata-clipboard :mode) 'copy)))
    (unless files (user-error "Strata clipboard is empty"))
    (strata--transfer-files files default-directory mode t nil)))

(defun strata-paste-replace ()
  "Paste Strata clipboard items replacing existing targets (`P')."
  (interactive)
  (let ((files (plist-get strata-clipboard :files))
        (mode (or (plist-get strata-clipboard :mode) 'copy)))
    (unless files (user-error "Strata clipboard is empty"))
    (strata--transfer-files files default-directory mode nil t)))

(defun strata-copy-to-other-pane ()
  "Copy selected items directly into the opposite split pane (`C-S-c')."
  (interactive)
  (let ((dest (strata-other-pane-directory))
        (files (strata-selected-files)))
    (unless files (user-error "No item selected"))
    (strata--transfer-files files dest 'copy)))

(defun strata-move-to-other-pane ()
  "Move selected items directly into the opposite split pane (`C-S-x')."
  (interactive)
  (let ((dest (strata-other-pane-directory))
        (files (strata-selected-files)))
    (unless files (user-error "No item selected"))
    (strata--transfer-files files dest 'cut)))

(defun strata--record-send-to-dest (dest)
  "Remember DEST in recent Send-To destinations."
  (let* ((p (strata-prefs))
         (canon (directory-file-name (expand-file-name dest)))
         (cur (assoc-default "global" (strata-prefs-send-to-recent-destinations p)))
         (next (cons canon (seq-take (delete canon cur) 7))))
    (setf (strata-prefs-send-to-recent-destinations p)
          (cons (cons "global" next)
                (assoc-delete-all "global" (strata-prefs-send-to-recent-destinations p))))
    (strata-prefs-save)))

(defun strata-copy-to ()
  "Copy selected items to any chosen folder or Send-To destination (`C')."
  (interactive)
  (let* ((files (strata-selected-files))
         (recents (assoc-default "global" (strata-prefs-send-to-recent-destinations (strata-prefs))))
         (dest (strata-ui-read-directory-name "Copy selected to: " (or (car recents) default-directory))))
    (unless files (user-error "No item selected"))
    (strata--record-send-to-dest dest)
    (strata--transfer-files files dest 'copy)))

(defun strata-move-to ()
  "Move selected items to any chosen folder (`M')."
  (interactive)
  (let* ((files (strata-selected-files))
         (recents (assoc-default "global" (strata-prefs-send-to-recent-destinations (strata-prefs))))
         (dest (strata-ui-read-directory-name "Move selected to: " (or (car recents) default-directory))))
    (unless files (user-error "No item selected"))
    (strata--record-send-to-dest dest)
    (strata--transfer-files files dest 'cut)))

(defun strata-duplicate ()
  "Duplicate selected items right beside originals (`C-d')."
  (interactive)
  (strata--ensure-writable-target default-directory "Duplicate")
  (let ((files (strata-selected-files)))
    (unless files (user-error "No item selected"))
    (strata--transfer-files files default-directory 'copy t nil)))

;;;; Create / Relative-Path Rename / Content Drops

(defun strata-new-folder (&optional name)
  "Create new folder in current writable directory (`C-S-n')."
  (interactive)
  (let* ((dir (strata--ensure-writable-target default-directory "Create folder"))
         (nm (or name (strata-ui-read-string "New folder name: ")))
         (clean (string-trim nm)))
    (when (string-empty-p clean) (user-error "Folder name cannot be empty"))
    (let ((target (expand-file-name clean dir)))
      (when (file-exists-p target) (user-error "Already exists: %s" target))
      (make-directory target t)
      (strata-undo--push (list :batch (list (list :type 'create :path target))))
      (strata-refresh-active-view)
      (strata-goto-file target)
      (message "Created folder %s" clean))))

(defun strata-new-file (&optional name)
  "Create new empty file in current writable directory."
  (interactive)
  (let* ((dir (strata--ensure-writable-target default-directory "Create file"))
         (nm (or name (strata-ui-read-string "New file name: ")))
         (clean (string-trim nm)))
    (when (string-empty-p clean) (user-error "File name cannot be empty"))
    (let ((target (expand-file-name clean dir)))
      (when (file-exists-p target) (user-error "Already exists: %s" target))
      (make-directory (file-name-directory target) t)
      (write-region "" nil target)
      (strata-undo--push (list :batch (list (list :type 'create :path target))))
      (strata-refresh-active-view)
      (strata-goto-file target)
      (message "Created file %s" clean))))

(defun strata-create-entry ()
  "Yazi/Strata unified create (`a'): trailing `/' creates folder, else file."
  (interactive)
  (strata--ensure-writable-target default-directory "Create")
  (let ((raw (strata-ui-read-string "Create (end with / for folder): ")))
    (when (string-empty-p (string-trim raw)) (user-error "Name cannot be empty"))
    (if (string-suffix-p "/" raw)
        (strata-new-folder (directory-file-name raw))
      (strata-new-file raw))))

(defun strata-new-folder-with-selection ()
  "Create a new folder and move current selection into it (`C-M-n')."
  (interactive)
  (let ((dir (strata--ensure-writable-target default-directory "New Folder with Selection"))
        (files (strata-selected-files)))
    (unless files (user-error "Select one or more items first"))
    (let* ((nm (string-trim (strata-ui-read-string "New folder name: " "New Folder")))
           (target (expand-file-name nm dir)))
      (when (file-exists-p target) (user-error "Folder already exists: %s" target))
      (make-directory target t)
      (strata--transfer-files files target 'cut t nil)
      (strata-goto-file target))))

(defun strata-rename (&optional new-name)
  "Rename entry at point, creating parent dirs when NEW-NAME contains slashes (`F2' / `r')."
  (interactive)
  (strata--ensure-writable-target default-directory "Rename")
  (let ((src (or (strata-current-file) (user-error "No item at point"))))
    (let* ((dir (file-name-directory (directory-file-name src)))
           (old (file-name-nondirectory (directory-file-name src)))
           (input (or new-name (strata-ui-read-string (format "Rename '%s' to: " old) old)))
           (dest (expand-file-name input dir)))
      (when (equal (directory-file-name src) (directory-file-name dest))
        (user-error "Unchanged name"))
      (when (file-exists-p dest)
        (unless (strata-ui-y-or-n-p (format "Target %s exists. Replace? " (file-name-nondirectory dest)))
          (user-error "Rename cancelled")))
      (make-directory (file-name-directory dest) t)
      (rename-file src dest t)
      (strata-undo--push (list :batch (list (list :type 'move :from src :to dest))))
      (strata-refresh-active-view)
      (strata-goto-file dest)
      (message "Renamed -> %s" input))))

(defun strata-paste-content-drop ()
  "Save system clipboard image (`wl-paste`) or text directly as a new file in folder."
  (interactive)
  (let ((dir (strata--ensure-writable-target default-directory "Save clipboard")))
    (cond
     ((and (executable-find "wl-paste")
           (= 0 (process-file "wl-paste" nil nil nil "--list-types"))
           (string-search "image/png"
                          (with-temp-buffer
                            (process-file "wl-paste" nil t nil "--list-types")
                            (buffer-string))))
      (let* ((out (strata-unique-copy-name
                   (expand-file-name (format-time-string "clipboard-%Y%m%d-%H%M%S.png") dir))))
        (with-temp-file out
          (set-buffer-multibyte nil)
          (process-file "wl-paste" nil t nil "--type" "image/png"))
        (strata-undo--push (list :batch (list (list :type 'create :path out))))
        (strata-refresh-active-view)
        (strata-goto-file out)
        (message "Saved clipboard image: %s" (file-name-nondirectory out))))
     ((when-let ((txt (or (ignore-errors (current-kill 0 t))
                          (ignore-errors (gui-get-selection 'CLIPBOARD 'STRING)))))
        (let* ((is-url (string-match-p "\\`https?://" (string-trim txt)))
               (ext (if is-url "url" "txt"))
               (out (strata-unique-copy-name
                     (expand-file-name (format-time-string (concat "pasted-%Y%m%d-%H%M%S." ext)) dir))))
          (with-temp-file out
            (insert (if is-url (format "[InternetShortcut]\nURL=%s\n" (string-trim txt)) txt)))
          (strata-undo--push (list :batch (list (list :type 'create :path out))))
          (strata-refresh-active-view)
          (strata-goto-file out)
          (message "Saved clipboard content: %s" (file-name-nondirectory out)))))
     (t (user-error "Clipboard has no saveable image or text")))))

;;;; Trash & Undo/Redo Engine

(defun strata--trash-with-gio-fallback (path)
  "Trash PATH via XDG spec / `gio trash', returning trashed destination or nil."
  (let* ((trash-files (expand-file-name "files" (strata-trash--dir)))
         (trash-info (expand-file-name "info" (strata-trash--dir)))
         (before (when (file-directory-p trash-files)
                   (directory-files trash-files nil "\\`[^.]" t))))
    (cond
     ((executable-find "gio")
      (when (= 0 (process-file "gio" nil nil nil "trash" path))
        (let* ((after (directory-files trash-files nil "\\`[^.]" t))
               (added (car (cl-set-difference after before :test #'equal))))
          (when added (expand-file-name added trash-files)))))
     (t
      (make-directory trash-files t)
      (make-directory trash-info t)
      (let* ((base (file-name-nondirectory (directory-file-name path)))
             (tpath (strata-unique-copy-name (expand-file-name base trash-files)))
             (tname (file-name-nondirectory tpath))
             (info (expand-file-name (concat tname ".trashinfo") trash-info)))
        (rename-file path tpath)
        (with-temp-file info
          (insert (format "[Trash Info]\nPath=%s\nDeletionDate=%s\n"
                          (url-hexify-string (expand-file-name path)
                                             (append url-unreserved-chars '(?/)))
                          (format-time-string "%Y-%m-%dT%H:%M:%S"))))
        tpath)))))

(defun strata-move-to-trash ()
  "Move selected items to Trash (`DEL' / `d'), with permanent delete fallback when Trash is unsupported."
  (interactive)
  (if (derived-mode-p 'strata-trash-mode)
      (call-interactively #'strata-trash-delete-at-point)
    (strata--ensure-writable-target default-directory "Trash")
    (let ((files (strata-selected-files)))
      (unless files (user-error "No item selected"))
      (when (strata-ui-yes-or-no-p (format "Move %d item(s) to Trash? " (length files)))
        (let ((undo-items nil))
          (dolist (f files)
            (let ((trashed (strata--trash-with-gio-fallback f)))
              (if trashed
                  (push (list :type 'trash :orig f :trashed trashed) undo-items)
                (when (strata-ui-yes-or-no-p (format "Filesystem for '%s' has no Trash. Delete permanently? "
                                           (file-name-nondirectory f)))
                  (if (file-directory-p f) (delete-directory f t) (delete-file f))))))
          (when undo-items
            (strata-undo--push (list :batch (nreverse undo-items))))
          (strata-refresh-active-view)
          (message "Moved %d item(s) to Trash" (length files)))))))

(defun strata-delete-permanently ()
  "Permanently delete selected items bypassing Trash (`S-DEL' / `D')."
  (interactive)
  (if (derived-mode-p 'strata-trash-mode)
      (call-interactively #'strata-trash-delete-at-point)
    (strata--ensure-writable-target default-directory "Permanent delete")
    (let ((files (strata-selected-files)))
      (unless files (user-error "No item selected"))
      (when (strata-ui-yes-or-no-p (format "PERMANENTLY delete %d item(s)? This cannot be undone! "
                                 (length files)))
        (dolist (f files)
          (when (file-exists-p f)
            (if (file-directory-p f) (delete-directory f t) (delete-file f))))
        (strata-refresh-active-view)
        (message "Deleted %d item(s) permanently" (length files))))))

(defun strata-undo ()
  "Undo last Strata file operation (`C-z')."
  (interactive)
  (let ((op (pop strata-undo-stack)))
    (unless op (user-error "Nothing left to undo"))
    (let (redos)
      (dolist (step (reverse (plist-get op :batch)))
        (pcase (plist-get step :type)
          ('move
           (let ((from (plist-get step :from))
                 (to (plist-get step :to)))
             (when (file-exists-p to)
               (make-directory (file-name-directory from) t)
               (rename-file to from t)
               (push step redos))))
          ('copy
           (let ((to (plist-get step :to)))
             (when (file-exists-p to)
               (if (file-directory-p to) (delete-directory to t) (delete-file to))
               (push step redos))))
          ('create
           (let ((p (plist-get step :path)))
             (when (file-exists-p p)
               (if (file-directory-p p) (delete-directory p t) (delete-file p)))))
          ('trash
           (let* ((orig (plist-get step :orig))
                  (trashed (plist-get step :trashed))
                  (info (expand-file-name
                         (concat (file-name-nondirectory trashed) ".trashinfo")
                         (expand-file-name "info" (strata-trash--dir)))))
             (when (file-exists-p trashed)
               (make-directory (file-name-directory orig) t)
               (rename-file trashed orig t)
               (when (file-exists-p info) (delete-file info))
               (push (list :type 'trash :orig orig) redos))))))
      (when redos
        (push (list :batch redos) strata-redo-stack))
      (strata-refresh-active-view)
      (message "Undid Strata operation"))))

(defun strata-redo ()
  "Redo last undone Strata file operation (`C-S-z' / `C-y')."
  (interactive)
  (let ((op (pop strata-redo-stack)))
    (unless op (user-error "Nothing left to redo"))
    (let (undos)
      (dolist (step (plist-get op :batch))
        (pcase (plist-get step :type)
          ('move
           (let ((from (plist-get step :from))
                 (to (plist-get step :to)))
             (when (file-exists-p from)
               (make-directory (file-name-directory to) t)
               (rename-file from to t)
               (push step undos))))
          ('copy
           (let ((from (plist-get step :from))
                 (to (plist-get step :to)))
             (when (file-exists-p from)
               (if (file-directory-p from)
                   (copy-directory from to t t)
                 (copy-file from to t t t t))
               (push step undos))))
          ('trash
           (let* ((orig (plist-get step :orig))
                  (trashed (and (file-exists-p orig)
                                (strata--trash-with-gio-fallback orig))))
             (when trashed
               (push (list :type 'trash :orig orig :trashed trashed) undos))))))
      (when undos (push (list :batch undos) strata-undo-stack))
      (strata-refresh-active-view)
      (message "Redid Strata operation"))))

;;;; Archives Compress & Smart Extract

(defun strata-archive-compress ()
  "Compress selected files/folders into zip, tar.gz, tar.zst, 7z, or tar (`; c')."
  (interactive)
  (let* ((dir (strata--ensure-writable-target default-directory "Compress"))
         (files (or (strata-selected-files)
                    (user-error "No file or folder selected")))
         (default-name (file-name-sans-extension
                        (file-name-nondirectory (directory-file-name (car files)))))
         (name (string-trim (strata-ui-read-string "Archive name (without extension): "
                                         (if (> (length files) 1) "archive" default-name))))
         (fmt (strata-ui-completing-read "Format: " '("zip" "tar.gz" "tar.zst" "7z" "tar") nil t nil nil "zip"))
         (pw (when (and (member fmt '("zip" "7z"))
                        (strata-ui-y-or-n-p "Protect archive with password? "))
               (strata-ui-read-passwd "Archive password: ")))
         (out (strata-unique-copy-name (expand-file-name (concat name "." fmt) dir)))
         (rels (mapcar (lambda (f) (file-relative-name f dir)) files))
         (cmd
          (pcase fmt
            ("zip" (append '("7z" "a" "-tzip") (when (and pw (not (string-empty-p pw))) (list (concat "-p" pw))) (list out) rels))
            ("7z" (append '("7z" "a" "-t7z") (when (and pw (not (string-empty-p pw))) (list (concat "-p" pw))) (list out) rels))
            ("tar.gz" (append '("tar" "-czf" ) (list out) rels))
            ("tar.zst" (append '("tar" "--zstd" "-cf") (list out) rels))
            ("tar" (append '("tar" "-cf") (list out) rels)))))
    (let ((default-directory dir))
      (strata-run-job (format "Compress %s" (file-name-nondirectory out)) cmd
                      (lambda () (strata-refresh-active-view) (strata-goto-file out))))
    (when pw (clear-string pw))))

(defun strata-archive--top-level-roots (archive)
  "Return distinct top-level entry names inside ARCHIVE."
  (when (executable-find "7z")
    (with-temp-buffer
      (when (= 0 (process-file "7z" nil t nil "l" "-ba" archive))
        (let (roots)
          (dolist (line (split-string (buffer-string) "\n" t))
            (when (string-match " \\([^ ]+\\)\\'" line)
              (let* ((p (match-string 1 line))
                     (top (car (split-string p "/" t))))
                (when top (push top roots)))))
          (delete-dups roots))))))

(defun strata-archive-extract (&optional ask-dest)
  "Smart extract archive at point (`; e` here, `; E` choose folder).
Single-root archives extract cleanly as-is; multi-root archives extract into a
wrapping folder named after the archive so parent folders stay uncluttered."
  (interactive "P")
  (let* ((archive (or (strata-current-file) (user-error "Select an archive first")))
         (base-dest (if ask-dest
                        (strata-ui-read-directory-name "Extract to folder: " default-directory)
                      (file-name-directory archive)))
         (roots (strata-archive--top-level-roots archive))
         (stem (file-name-sans-extension (file-name-nondirectory archive)))
         (stem (if (string-suffix-p ".tar" stem) (file-name-sans-extension stem) stem))
         (target-dir (if (<= (length roots) 1)
                         base-dest
                       (strata-unique-copy-name (expand-file-name stem base-dest)))))
    (strata-guard-writable-location base-dest "Extract archive")
    (make-directory target-dir t)
    (strata-run-job
     (format "Extract %s" (file-name-nondirectory archive))
     (list "7z" "x" "-y" (concat "-o" target-dir) archive)
     (lambda ()
       (strata-refresh-active-view)
       (message "Extracted -> %s" (abbreviate-file-name target-dir))))))

;;;; Properties Modal/Buffer & Customize Folder

(defun strata-show-properties-for-path (path &optional device)
  "Display rich Strata Properties buffer for PATH or `strata-device' DEVICE (`M-RET` / `P`)."
  (interactive (list (or (strata-current-file) default-directory)))
  (let* ((buf (get-buffer-create "*Strata Properties*"))
         (dev (or device (cl-find-if (lambda (d) (equal (strata-device-mountpoint d) path))
                                     (strata-devices-list))))
         (attrs (when path (file-attributes path)))
         (dir-p (and path (file-directory-p path)))
         (mime (when (and path (executable-find "xdg-mime") (file-exists-p path))
                 (string-trim (with-output-to-string
                                (with-current-buffer standard-output
                                  (process-file "xdg-mime" nil t nil "query" "filetype" path)))))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (setq-local header-line-format
                    (propertize (format "  ℹ  Properties — %s   [x: Toggle +x · c: Customize · q: Close]"
                                        (if path (file-name-nondirectory (directory-file-name path))
                                          (strata-device-name dev)))
                                'face 'strata-header-accent))
        (local-set-key (kbd "x") (lambda () (interactive)
                                   (when (and path (file-exists-p path))
                                     (let* ((m (file-modes path))
                                            (next (if (zerop (logand m #o100))
                                                      (logior m #o111)
                                                    (logand m (lognot #o111)))))
                                       (set-file-modes path next)
                                       (strata-show-properties-for-path path dev)))))
        (local-set-key (kbd "c") (lambda () (interactive)
                                   (when path (strata-customize-folder path))))
        (insert "\n")
        (when path
          (insert (format "  Name:        %s\n" (file-name-nondirectory (directory-file-name path))))
          (insert (format "  Location:    %s\n" (abbreviate-file-name path)))
          (insert (format "  Type / MIME: %s%s\n"
                          (if dir-p "Folder" "File")
                          (if (and mime (not (string-empty-p mime))) (format " (%s)" mime) "")))
          (when attrs
            (insert (format "  Size:        %s\n"
                            (if dir-p "Measuring…" (strata-format-bytes (file-attribute-size attrs)))))
            (insert (format "  Permissions: %s (octal %03o)  [press x to toggle executable]\n"
                            (file-attribute-modes attrs)
                            (logand (or (file-modes path) 0) #o777)))
            (insert (format "  Modified:    %s (%s)\n"
                            (strata-format-time (file-attribute-modification-time attrs) 'iso)
                            (strata-format-time (file-attribute-modification-time attrs) 'relative)))))
        (when dev
          (insert "\n" (propertize "  DRIVE / VOLUME\n" 'face 'strata-section-heading))
          (insert (format "  Device:      %s (%s)\n" (or (strata-device-device dev) "-")
                          (or (strata-device-fstype dev) "-")))
          (when (strata-device-uuid dev)
            (insert (format "  UUID:        %s\n" (strata-device-uuid dev))))
          (when (strata-device-usage dev)
            (insert (format "  Capacity:    %s\n" (strata-format-capacity-bar (strata-device-usage dev) 18 nil)))))
        (goto-char (point-min))))
    ;; Async bounded recursive folder summary
    (when (and path (file-directory-p path) (executable-find "du"))
      (make-process
       :name "strata-prop-du"
       :buffer (generate-new-buffer " *strata-du*")
       :noquery t
       :command (list "timeout" "3" "du" "-sb" path)
       :sentinel
       (lambda (proc _ev)
         (when (memq (process-status proc) '(exit signal))
           (unwind-protect
               (when (and (= 0 (process-exit-status proc))
                          (buffer-live-p buf)
                          (buffer-live-p (process-buffer proc)))
                 (let ((bytes (string-to-number
                               (with-current-buffer (process-buffer proc) (buffer-string)))))
                   (with-current-buffer buf
                     (let ((inhibit-read-only t))
                       (save-excursion
                         (goto-char (point-min))
                         (when (search-forward "Measuring…" nil t)
                           (replace-match (strata-format-bytes bytes))))))))
             (when (buffer-live-p (process-buffer proc))
               (kill-buffer (process-buffer proc))))))))
    (pop-to-buffer buf)))

(defun strata-customize-folder (&optional dir)
  "Assign custom color badge and custom icon to DIR (`Customize…`)."
  (interactive (list (or (let ((f (strata-current-file))) (when (and f (file-directory-p f)) f))
                         default-directory)))
  (strata-guard-writable-location dir "Customize")
  (let* ((color (strata-ui-completing-read "Folder color (empty to clear): "
                                 (cons "" (mapcar #'car strata-folder-color-alist)) nil nil))
         (icon (strata-ui-read-string "Custom icon/emoji (empty to keep/clear): "
                            (or (cdr (assoc (directory-file-name (expand-file-name dir))
                                            (strata-prefs-custom-icons (strata-prefs))))
                                ""))))
    (strata-folder-color-set dir color)
    (strata-custom-icon-set dir icon)
    (strata-refresh-active-view)
    (message "Updated customization for %s" (file-name-nondirectory (directory-file-name dir)))))

;;;; Open With (.desktop scanner + Recent Apps)

(defun strata-desktop--parse-file (file)
  "Return (LABEL . CMD) from `[Desktop Entry]' in FILE when runnable and visible."
  (with-temp-buffer
    (insert-file-contents file nil 0 16384)
    (goto-char (point-min))
    (when (re-search-forward "^\\[Desktop Entry\\][ \t]*$" nil t)
      (let* ((start (match-end 0))
             (end (if (re-search-forward "^\\[" nil t) (match-beginning 0) (point-max)))
             (field (lambda (key)
                      (goto-char start)
                      (when (re-search-forward
                             (format "^%s=\\(.*\\)$" (regexp-quote key)) end t)
                        (string-trim (match-string 1)))))
             (type (funcall field "Type"))
             (no-display (funcall field "NoDisplay"))
             (hidden (funcall field "Hidden"))
             (try-exec (funcall field "TryExec"))
             (nm (funcall field "Name"))
             (ex (funcall field "Exec"))
             (cmd (when (and ex (not (string-empty-p ex)))
                    (car (ignore-errors (split-string-shell-command ex))))))
        (when (and nm cmd
                   (not (string-empty-p nm))
                   (or (null type) (string= type "Application"))
                   (not (equal no-display "true"))
                   (not (equal hidden "true"))
                   (or (null try-exec) (string-empty-p try-exec) (executable-find try-exec))
                   (executable-find cmd))
          (cons (format "%s (%s)" nm (file-name-nondirectory file)) cmd))))))

(defun strata-desktop-apps ()
  "Discover desktop applications across NixOS & XDG application dirs."
  (let ((dirs '("/run/current-system/sw/share/applications"
                "/etc/profiles/per-user/thinky/share/applications"
                "~/.nix-profile/share/applications"
                "~/.local/share/applications"
                "/usr/share/applications"))
        apps)
    (dolist (d dirs)
      (let ((exp (expand-file-name d)))
        (when (file-directory-p exp)
          (dolist (f (directory-files exp t "\\.desktop\\'" t))
            (when (file-readable-p f)
              (when-let ((entry (strata-desktop--parse-file f)))
                (push entry apps)))))))
    (cl-delete-duplicates (nreverse apps) :key #'car :test #'equal)))

(defun strata-open-with ()
  "Open selected item(s) with an independent installed application (`O`).
The application keeps running after Emacs exits."
  (interactive)
  (let* ((files (strata-selected-files))
         (apps (strata-desktop-apps))
         (choice (strata-ui-completing-read "Open With application: " (mapcar #'car apps) nil t))
         (cmd (or (cdr (assoc choice apps)) choice)))
    (unless files (user-error "No file selected"))
    (let* ((program (or (executable-find cmd)
                        (user-error "Application executable not found: %s" cmd)))
           (launcher (or (executable-find "setsid")
                         (user-error "Cannot launch independently: setsid is unavailable")))
           ;; Wait only for the launcher to fork, not for the application.
           ;; Unlike an Emacs-managed process, its new session and null
           ;; standard streams survive Emacs exit without SIGHUP/SIGPIPE.
           (status (apply #'call-process launcher nil nil nil "--fork" "--" program files)))
      (unless (equal status 0)
        (user-error "Could not launch %s: %s" choice status)))
    (message "Launched %s for %d item(s)" choice (length files))))

;;;; Custom Actions (~/.config/strata/actions/*/action.toml) + Recipes + Jobs Dashboard

(defun strata-actions-load ()
  "Load validated custom action plists from `~/.config/strata/actions/*/action.toml'."
  (let ((dir (expand-file-name "actions" strata-dirvish-config-dir))
        out)
    (when (file-directory-p dir)
      (dolist (sub (directory-files dir t "\\`[^.]" t))
        (let ((manifest (expand-file-name "action.toml" sub)))
          (when (and (file-directory-p sub) (file-readable-p manifest))
            (let* ((parsed (strata-toml-parse-file manifest))
                   (root (cdr (assoc "" parsed)))
                   (when-sec (cdr (assoc "when" parsed)))
                   (run-sec (cdr (assoc "run" parsed))))
              (push (list :id (or (cdr (assoc "id" root)) (file-name-nondirectory sub))
                          :name (or (cdr (assoc "name" root)) (file-name-nondirectory sub))
                          :description (cdr (assoc "description" root))
                          :enabled (strata-toml--bool (cdr (assoc "enabled" root)) t)
                          :dir sub
                          :kinds (cdr (assoc "kinds" when-sec))
                          :extensions (cdr (assoc "extensions" when-sec))
                          :min-items (or (cdr (assoc "min_items" when-sec)) 1)
                          :max-items (cdr (assoc "max_items" when-sec))
                          :runtime (or (cdr (assoc "runtime" run-sec)) "python")
                          :entrypoint (cdr (assoc "entrypoint" run-sec))
                          :program (cdr (assoc "program" run-sec))
                          :args (cdr (assoc "args" run-sec))
                          :mode (or (cdr (assoc "mode" run-sec)) "whole-selection")
                          :confirm (strata-toml--bool (cdr (assoc "confirm" run-sec)) nil))
                    out))))))
    (sort out (lambda (a b) (string-lessp (plist-get a :name) (plist-get b :name))))))

(defun strata-action-matches-p (act items)
  "Return non-nil if custom action ACT matches selected ITEMS."
  (and (plist-get act :enabled)
       (>= (length items) (or (plist-get act :min-items) 1))
       (or (null (plist-get act :max-items))
           (<= (length items) (plist-get act :max-items)))
       (cl-every
        (lambda (it)
          (let ((kinds (plist-get act :kinds))
                (exts (plist-get act :extensions))
                (dir-p (file-directory-p it))
                (ext (downcase (or (file-name-extension it) ""))))
            (and (or (null kinds)
                     (member (if dir-p "folder" "file") kinds))
                 (or (null exts)
                     (member ext exts)))))
        items)))

(defun strata-run-job (label cmd &optional on-done)
  "Execute CMD asynchronously logging status & output to `*Strata Jobs*'."
  (let* ((id (cl-incf strata-next-job-id))
         (buf (generate-new-buffer (format " *strata-job-%d*" id)))
         (job (list :id id :label label :status 'running :started (current-time) :output "")))
    (push job strata-jobs-list)
    (make-process
     :name (format "strata-job-%d" id)
     :buffer buf
     :noquery t
     :command cmd
     :sentinel
     (lambda (proc _ev)
       (when (memq (process-status proc) '(exit signal))
         (let ((ok (= 0 (process-exit-status proc)))
               (txt (if (buffer-live-p buf)
                        (with-current-buffer buf (string-trim (buffer-string)))
                      "")))
           (plist-put job :status (if ok 'done 'failed))
           (plist-put job :output txt)
           (when (buffer-live-p buf) (kill-buffer buf))
           (when (get-buffer "*Strata Jobs*") (strata-jobs-dashboard t))
           (when on-done (funcall on-done))
           (message "Job %s: %s" label (if ok "done" (format "failed (%s)" txt)))))))
    job))

(defun strata-jobs-dashboard (&optional no-switch)
  "Open `*Strata Jobs*' showing background transfers & custom actions."
  (interactive)
  (let ((buf (get-buffer-create "*Strata Jobs*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (setq-local header-line-format
                    (concat "  "
                            (strata-icon-glyph 'gear 'strata-header-accent)
                            (propertize "  Strata Background Jobs   [g: Refresh · q: Close]"
                                        'face 'strata-header-accent)))
        (insert "\n")
        (if (null strata-jobs-list)
            (insert "   No background jobs recorded in this session.\n")
          (dolist (j strata-jobs-list)
            (let ((st (plist-get j :status)))
              (insert (format "   #%d  %-10s  %s\n"
                              (plist-get j :id)
                              (propertize (upcase (symbol-name st))
                                          'face (pcase st ('running 'warning) ('done 'success) (_ 'error)))
                              (plist-get j :label)))
              (unless (string-empty-p (or (plist-get j :output) ""))
                (insert (propertize (format "        %s\n" (plist-get j :output)) 'face 'shadow))))))
        (goto-char (point-min))))
    (unless no-switch (pop-to-buffer buf))))

(defun strata-run-custom-action (&optional index focused-folder-only)
  "Run custom action (by 1-based INDEX, or prompt) on selection or FOCUSED-FOLDER-ONLY (`; .`)."
  (interactive)
  (let* ((targets (if focused-folder-only
                      (let ((f (strata-current-file)))
                        (unless (and f (file-directory-p f))
                          (user-error "Focused item is not a folder"))
                        (list f))
                    (strata-selected-files)))
         (acts (cl-remove-if-not (lambda (a) (strata-action-matches-p a targets))
                                 (strata-actions-load))))
    (unless acts (user-error "No matching enabled actions found in ~/.config/strata/actions/ (see Settings -> Actions Recipes)"))
    (let* ((act (if (and index (<= 1 index (length acts)))
                    (nth (1- index) acts)
                  (let* ((names (mapcar (lambda (a) (plist-get a :name)) acts))
                         (picked (strata-ui-completing-read "Run Custom Action: " names nil t)))
                    (cl-find picked acts :key (lambda (a) (plist-get a :name)) :test #'equal)))))
      (when (or (not (plist-get act :confirm))
                (strata-ui-yes-or-no-p (format "Run custom action '%s' on %d item(s)? "
                                     (plist-get act :name) (length targets))))
        (let* ((rt (plist-get act :runtime))
               (entry (plist-get act :entrypoint))
               (prog (or (plist-get act :program)
                         (pcase rt ("bash" "bash") (_ "python3"))))
               (script (when entry (expand-file-name entry (plist-get act :dir))))
               (base-cmd (if script (list prog script) (list prog)))
               (parent default-directory))
          (if (string= (plist-get act :mode) "per-item")
              (dolist (it targets)
                (strata-run-job (format "%s (%s)" (plist-get act :name) (file-name-nondirectory it))
                                (append base-cmd (list it))
                                #'strata-refresh-active-view))
            (let* ((args (or (plist-get act :args) '("{paths}")))
                   (final-args
                    (cl-mapcan (lambda (a)
                                 (pcase a
                                   ("{paths}" (copy-sequence targets))
                                   ("{path}" (list (car targets)))
                                   ("{parent}" (list parent))
                                   (_ (list a))))
                               args)))
              (strata-run-job (plist-get act :name)
                              (append base-cmd final-args)
                              #'strata-refresh-active-view))))))))

(defconst strata-builtin-action-recipes
  '(("log-selected" "Log selected paths" "Log selected paths & parent directory cleanly." "python" "action.py"
     "#!/usr/bin/env python3\nimport sys\nfor p in sys.argv[1:]:\n    print(p)\n")
    ("sha256-checksums" "SHA-256 checksums" "Write .sha256 checksum sidecar without overwriting." "python" "checksums.py"
     "#!/usr/bin/env python3\nimport hashlib, sys, pathlib\nfor arg in sys.argv[1:]:\n    p = pathlib.Path(arg)\n    if p.is_file():\n        out = pathlib.Path(str(p) + '.sha256')\n        if not out.exists():\n            h = hashlib.sha256(p.read_bytes()).hexdigest()\n            out.write_text(f'{h}  {p.name}\\n')\n")
    ("count-lines" "Count lines" "Count lines across selected text files." "bash" "count.sh"
     "#!/usr/bin/env bash\nwc -l \"$@\"\n"))
  "Starter Strata action recipes installable to ~/.config/strata/actions/.")

(defun strata-install-action-recipe ()
  "Install one of Strata's built-in Custom Action recipes into ~/.config/strata/actions/."
  (interactive)
  (let* ((picked (strata-ui-completing-read "Install action recipe: "
                                  (mapcar #'cadr strata-builtin-action-recipes) nil t))
         (rec (cl-find picked strata-builtin-action-recipes :key #'cadr :test #'equal))
         (id (nth 0 rec))
         (dir (expand-file-name (concat "actions/" id) strata-dirvish-config-dir))
         (entry (nth 4 rec)))
    (make-directory dir t)
    (with-temp-file (expand-file-name "action.toml" dir)
      (insert (format "schema_version = 1\nid = %S\nname = %S\ndescription = %S\nenabled = true\n\n[when]\nkinds = [\"file\", \"folder\"]\n\n[run]\nruntime = %S\nentrypoint = %S\nargs = [\"{paths}\"]\n"
                      id (nth 1 rec) (nth 2 rec) (nth 3 rec) entry)))
    (let ((ep (expand-file-name entry dir)))
      (with-temp-file ep (insert (nth 5 rec)))
      (set-file-modes ep #o755))
    (message "Installed action '%s' in %s" (nth 1 rec) dir)))

(provide 'strata-dirvish-ops)
;;; strata-dirvish-ops.el ends here
