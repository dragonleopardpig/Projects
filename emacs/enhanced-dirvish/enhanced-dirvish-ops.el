;;; enhanced-dirvish-ops.el --- File operations, trash, undo, archives, props, actions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 dragonleopardpig
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.  It is part of Enhanced Dirvish;
;; see enhanced-dirvish.el for the full license notice.

;;; Commentary:
;; Implements Enhanced Dirvish file operations cleanly inside Emacs:
;; clipboard copy/cut/paste with conflict resolution (Replace / Keep Both / Merge),
;; cross-pane transfer, relative rename, new folder with selection, XDG trash
;; with FUSE fallback, Undo/Redo stack, Content Drop (wl-paste / clipboard),
;; Smart Archive Compress/Extract, Properties buffer with async dir summary &
;; chmod, Folder Customize, Open With (.desktop + recent apps), and Custom
;; Actions (~/.config/enhanced-dirvish/actions/*/action.toml + ; . folder chord + Jobs).

;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'json)
(require 'subr-x)
(require 'enhanced-dirvish-prefs)
(require 'enhanced-dirvish-devices)
(require 'enhanced-dirvish-views)
(require 'enhanced-dirvish-panes)

(defvar enhanced-dirvish-clipboard nil
  "Plist `(:mode copy|cut :files (PATHS...))' for the file clipboard.")

(defvar enhanced-dirvish-undo-stack nil "List of reversible Enhanced Dirvish file-operation plists.")
(defvar enhanced-dirvish-redo-stack nil "List of redone Enhanced Dirvish file-operation plists.")
(defconst enhanced-dirvish-undo-limit 50)

(defvar enhanced-dirvish-jobs-list nil "List of recorded async job plists for `*Enhanced Dirvish Jobs*'.")
(defvar enhanced-dirvish-next-job-id 0)

;;;; Refresh Helper & Undo/Redo Helpers

(defun enhanced-dirvish--refresh-buffer (buf)
  "Refresh browser buffer BUF safely without changing window focus."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (bound-and-true-p enhanced-dirvish-marked-entries)
        (setq enhanced-dirvish-marked-entries (cl-remove-if-not #'file-exists-p enhanced-dirvish-marked-entries)))
      (cond
       ((derived-mode-p 'dired-mode) (revert-buffer nil t t))
       ((derived-mode-p 'enhanced-dirvish-compact-mode) (enhanced-dirvish-compact-refresh))
       ((derived-mode-p 'enhanced-dirvish-icons-mode) (enhanced-dirvish-icons-refresh))
       ((derived-mode-p 'enhanced-dirvish-computer-mode) (enhanced-dirvish-computer-refresh))
       ((derived-mode-p 'enhanced-dirvish-trash-mode) (enhanced-dirvish-trash-refresh))))))

(defun enhanced-dirvish-refresh-active-view ()
  "Refresh active browser buffer, opposite split pane, and sidebar."
  (enhanced-dirvish--refresh-buffer (current-buffer))
  (when (and (fboundp 'enhanced-dirvish-split-active-p) (enhanced-dirvish-split-active-p))
    (when-let* ((other (and (fboundp 'enhanced-dirvish-other-pane) (enhanced-dirvish-other-pane)))
                (obuf (enhanced-dirvish-pane-state-buffer other)))
      (unless (eq obuf (current-buffer))
        (let ((owin (enhanced-dirvish-pane-state-window other)))
          (if (window-live-p owin)
              (with-selected-window owin
                (enhanced-dirvish--refresh-buffer obuf))
            (enhanced-dirvish--refresh-buffer obuf))))))
  (enhanced-dirvish-sidebar-refresh))

(defun enhanced-dirvish-undo--push (op)
  "Push undoable operation OP onto `enhanced-dirvish-undo-stack'; clear redo."
  (push op enhanced-dirvish-undo-stack)
  (when (> (length enhanced-dirvish-undo-stack) enhanced-dirvish-undo-limit)
    (setcdr (nthcdr (1- enhanced-dirvish-undo-limit) enhanced-dirvish-undo-stack) nil))
  (setq enhanced-dirvish-redo-stack nil))

(defun enhanced-dirvish-pane-clipboard-summary ()
  "Short badge summarizing clipboard contents for footer mode-line."
  (when-let ((files (plist-get enhanced-dirvish-clipboard :files)))
    (format "%s %d"
            (if (eq (plist-get enhanced-dirvish-clipboard :mode) 'cut) "Cut" "Copy")
            (length files))))

(defun enhanced-dirvish-unique-copy-name (dest-path)
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

(defun enhanced-dirvish--ensure-writable-target (&optional dir op-name)
  "Return writable target directory DIR or signal `user-error'."
  (let ((d (or dir (ignore-errors (enhanced-dirvish-pane-state-dir (enhanced-dirvish-active-pane))) default-directory)))
    (enhanced-dirvish-guard-writable-location d op-name)
    (unless (file-directory-p d)
      (user-error "Not a writable directory: %s" d))
    d))

(defun enhanced-dirvish--guard-not-self-contained (src dest-dir)
  "Refuse moving/copying directory SRC inside itself DEST-DIR."
  (let ((cs (file-name-as-directory (file-truename src)))
        (cd (file-name-as-directory (file-truename dest-dir))))
    (when (and (file-directory-p src) (string-prefix-p cs cd))
      (user-error "Cannot copy or move folder '%s' inside itself" (file-name-nondirectory src)))))

;;;; Clipboard: Copy / Cut / Paste (Keep Both / Replace / Merge) / Unyank

(defun enhanced-dirvish-copy-selection ()
  "Copy selected item(s) to Enhanced Dirvish clipboard (`y' in 10xer mode)."
  (interactive)
  (let* ((dir (ignore-errors (enhanced-dirvish-pane-state-dir (enhanced-dirvish-active-pane))))
         (_ (when (enhanced-dirvish-computer-location-p dir)
              (user-error "Cannot copy items inside computer:///")))
         (files (enhanced-dirvish-selected-files)))
    (unless files (user-error "No file selected"))
    (setq enhanced-dirvish-clipboard (list :mode 'copy :files files))
    (kill-new (string-join files "\n"))
    (force-mode-line-update t)
    (message "Copied %d item(s)" (length files))))

(defun enhanced-dirvish-cut-selection ()
  "Cut selected item(s) to Enhanced Dirvish clipboard (`x' in 10xer mode)."
  (interactive)
  (let* ((dir (ignore-errors (enhanced-dirvish-pane-state-dir (enhanced-dirvish-active-pane))))
         (_ (enhanced-dirvish-guard-writable-location dir "Cut"))
         (files (enhanced-dirvish-selected-files)))
    (unless files (user-error "No file selected"))
    (setq enhanced-dirvish-clipboard (list :mode 'cut :files files))
    (force-mode-line-update t)
    (message "Cut %d item(s)" (length files))))

(defun enhanced-dirvish-unyank ()
  "Clear Enhanced Dirvish clipboard (`Y' / `X')."
  (interactive)
  (setq enhanced-dirvish-clipboard nil)
  (force-mode-line-update t)
  (message "Cleared Enhanced Dirvish clipboard"))

(defun enhanced-dirvish-copy-path ()
  "Copy selected path(s) to clipboard (`c c` / Default `y')."
  (interactive)
  (let ((files (enhanced-dirvish-selected-files)))
    (unless files (user-error "No file selected"))
    (kill-new (string-join files "\n"))
    (message "Copied path(s): %s" (car files))))

(defun enhanced-dirvish-copy-name ()
  "Copy selected basename(s) to clipboard (`c n')."
  (interactive)
  (let ((files (enhanced-dirvish-selected-files)))
    (unless files (user-error "No file selected"))
    (kill-new (mapconcat (lambda (f) (file-name-nondirectory (directory-file-name f)))
                         files "\n"))
    (message "Copied name(s): %s" (file-name-nondirectory (directory-file-name (car files))))))

(defun enhanced-dirvish--merge-directory (src dest)
  "Recursively copy/merge SRC directory contents into existing DEST directory."
  (make-directory dest t)
  (dolist (f (directory-files src t "\\`[^.]\\|\\`.[^.]" t))
    (let ((target (expand-file-name (file-name-nondirectory f) dest)))
      (if (file-directory-p f)
          (enhanced-dirvish--merge-directory f target)
        (copy-file f target t t t t)))))

(defun enhanced-dirvish--replace-target (src target mode)
  "Transfer SRC onto existing TARGET using MODE (`copy' or `cut') with rollback."
  (let* ((dir (file-name-directory (directory-file-name target)))
         (backup (make-temp-name (expand-file-name ".enhanced-dirvish-replace-" dir))))
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

(defun enhanced-dirvish--transfer-files (files dest-dir mode &optional keep-both-default replace-default)
  "Copy or move FILES into DEST-DIR handling conflicts & Undo recording.
MODE is `copy' or `cut'. KEEP-BOTH-DEFAULT or REPLACE-DEFAULT skips prompting
when set."
  (enhanced-dirvish--ensure-writable-target dest-dir (if (eq mode 'cut) "Move" "Copy"))
  (let ((undo-items nil)
        (all-choice nil)
        (moved 0))
    (dolist (src files)
      (when (or (file-exists-p src) (file-symlink-p src))
        (enhanced-dirvish--guard-not-self-contained src dest-dir)
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
                         (pick (intern (enhanced-dirvish-ui-completing-read
                                        (format "Conflict for '%s': " base)
                                        opts nil t nil nil "keep-both"))))
                    (when (enhanced-dirvish-ui-y-or-n-p "Apply choice to any remaining conflicts? ")
                      (setq all-choice pick))
                    pick)))))
          (when (and (eq action 'replace) same-path-p)
            (user-error "Cannot replace '%s' with itself" base))
          (unless (eq action 'skip)
            (when (eq action 'keep-both)
              (setq target (enhanced-dirvish-unique-copy-name target)))
            (cond
             ((and (eq action 'merge) (file-directory-p src) (file-directory-p target))
              (enhanced-dirvish--merge-directory src target)
              (when (eq mode 'cut) (delete-directory src t)))
             ((and (eq action 'replace)
                   (or (and (file-directory-p target) (not (file-symlink-p target)))
                       (and (file-directory-p src)
                            (or (file-exists-p target) (file-symlink-p target)))))
              (enhanced-dirvish--replace-target src target mode)
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
      (enhanced-dirvish-undo--push (list :batch (nreverse undo-items))))
    (when (eq mode 'cut) (setq enhanced-dirvish-clipboard nil))
    (enhanced-dirvish-refresh-active-view)
    (message "%s %d item(s) -> %s"
             (if (eq mode 'cut) "Moved" "Copied") moved (abbreviate-file-name dest-dir))))

(defun enhanced-dirvish-paste-keep-both ()
  "Paste clipboard items keeping both on conflicts (`p' in 10xer mode)."
  (interactive)
  (let ((files (plist-get enhanced-dirvish-clipboard :files))
        (mode (or (plist-get enhanced-dirvish-clipboard :mode) 'copy)))
    (unless files (user-error "Enhanced Dirvish clipboard is empty"))
    (enhanced-dirvish--transfer-files files default-directory mode t nil)))

(defun enhanced-dirvish-paste-replace ()
  "Paste Enhanced Dirvish clipboard items replacing existing targets (`P')."
  (interactive)
  (let ((files (plist-get enhanced-dirvish-clipboard :files))
        (mode (or (plist-get enhanced-dirvish-clipboard :mode) 'copy)))
    (unless files (user-error "Enhanced Dirvish clipboard is empty"))
    (enhanced-dirvish--transfer-files files default-directory mode nil t)))

(defun enhanced-dirvish-copy-to-other-pane ()
  "Copy selected items directly into the opposite split pane (`C-S-c')."
  (interactive)
  (let ((dest (enhanced-dirvish-other-pane-directory))
        (files (enhanced-dirvish-selected-files)))
    (unless files (user-error "No item selected"))
    (enhanced-dirvish--transfer-files files dest 'copy)))

(defun enhanced-dirvish-move-to-other-pane ()
  "Move selected items directly into the opposite split pane (`C-S-x')."
  (interactive)
  (let ((dest (enhanced-dirvish-other-pane-directory))
        (files (enhanced-dirvish-selected-files)))
    (unless files (user-error "No item selected"))
    (enhanced-dirvish--transfer-files files dest 'cut)))

(defun enhanced-dirvish--record-send-to-dest (dest)
  "Remember DEST in recent Send-To destinations."
  (let* ((p (enhanced-dirvish-prefs))
         (canon (directory-file-name (expand-file-name dest)))
         (cur (assoc-default "global" (enhanced-dirvish-prefs-send-to-recent-destinations p)))
         (next (cons canon (seq-take (delete canon cur) 7))))
    (setf (enhanced-dirvish-prefs-send-to-recent-destinations p)
          (cons (cons "global" next)
                (assoc-delete-all "global" (enhanced-dirvish-prefs-send-to-recent-destinations p))))
    (enhanced-dirvish-prefs-save)))

(defun enhanced-dirvish-copy-to ()
  "Copy selected items to any chosen folder or Send-To destination (`C')."
  (interactive)
  (let* ((files (enhanced-dirvish-selected-files))
         (recents (assoc-default "global" (enhanced-dirvish-prefs-send-to-recent-destinations (enhanced-dirvish-prefs))))
         (dest (enhanced-dirvish-ui-read-directory-name "Copy selected to: " (or (car recents) default-directory))))
    (unless files (user-error "No item selected"))
    (enhanced-dirvish--record-send-to-dest dest)
    (enhanced-dirvish--transfer-files files dest 'copy)))

(defun enhanced-dirvish-move-to ()
  "Move selected items to any chosen folder (`M')."
  (interactive)
  (let* ((files (enhanced-dirvish-selected-files))
         (recents (assoc-default "global" (enhanced-dirvish-prefs-send-to-recent-destinations (enhanced-dirvish-prefs))))
         (dest (enhanced-dirvish-ui-read-directory-name "Move selected to: " (or (car recents) default-directory))))
    (unless files (user-error "No item selected"))
    (enhanced-dirvish--record-send-to-dest dest)
    (enhanced-dirvish--transfer-files files dest 'cut)))

(defun enhanced-dirvish-duplicate ()
  "Duplicate selected items right beside originals (`C-d')."
  (interactive)
  (enhanced-dirvish--ensure-writable-target default-directory "Duplicate")
  (let ((files (enhanced-dirvish-selected-files)))
    (unless files (user-error "No item selected"))
    (enhanced-dirvish--transfer-files files default-directory 'copy t nil)))

;;;; Create / Relative-Path Rename / Content Drops

(defun enhanced-dirvish-new-folder (&optional name)
  "Create new folder in current writable directory (`C-S-n')."
  (interactive)
  (let* ((dir (enhanced-dirvish--ensure-writable-target default-directory "Create folder"))
         (nm (or name (enhanced-dirvish-ui-read-string "New folder name: ")))
         (clean (string-trim nm)))
    (when (string-empty-p clean) (user-error "Folder name cannot be empty"))
    (let ((target (expand-file-name clean dir)))
      (when (file-exists-p target) (user-error "Already exists: %s" target))
      (make-directory target t)
      (enhanced-dirvish-undo--push (list :batch (list (list :type 'create :path target))))
      (enhanced-dirvish-refresh-active-view)
      (enhanced-dirvish-goto-file target)
      (message "Created folder %s" clean))))

(defun enhanced-dirvish-new-file (&optional name)
  "Create new empty file in current writable directory."
  (interactive)
  (let* ((dir (enhanced-dirvish--ensure-writable-target default-directory "Create file"))
         (nm (or name (enhanced-dirvish-ui-read-string "New file name: ")))
         (clean (string-trim nm)))
    (when (string-empty-p clean) (user-error "File name cannot be empty"))
    (let ((target (expand-file-name clean dir)))
      (when (file-exists-p target) (user-error "Already exists: %s" target))
      (make-directory (file-name-directory target) t)
      (write-region "" nil target)
      (enhanced-dirvish-undo--push (list :batch (list (list :type 'create :path target))))
      (enhanced-dirvish-refresh-active-view)
      (enhanced-dirvish-goto-file target)
      (message "Created file %s" clean))))

(defun enhanced-dirvish-create-entry ()
  "Yazi-style unified create (`a'): trailing `/' creates folder, else file."
  (interactive)
  (enhanced-dirvish--ensure-writable-target default-directory "Create")
  (let ((raw (enhanced-dirvish-ui-read-string "Create (end with / for folder): ")))
    (when (string-empty-p (string-trim raw)) (user-error "Name cannot be empty"))
    (if (string-suffix-p "/" raw)
        (enhanced-dirvish-new-folder (directory-file-name raw))
      (enhanced-dirvish-new-file raw))))

(defun enhanced-dirvish-new-folder-with-selection ()
  "Create a new folder and move current selection into it (`C-M-n')."
  (interactive)
  (let ((dir (enhanced-dirvish--ensure-writable-target default-directory "New Folder with Selection"))
        (files (enhanced-dirvish-selected-files)))
    (unless files (user-error "Select one or more items first"))
    (let* ((nm (string-trim (enhanced-dirvish-ui-read-string "New folder name: " "New Folder")))
           (target (expand-file-name nm dir)))
      (when (file-exists-p target) (user-error "Folder already exists: %s" target))
      (make-directory target t)
      (enhanced-dirvish--transfer-files files target 'cut t nil)
      (enhanced-dirvish-goto-file target))))

(defun enhanced-dirvish-rename (&optional new-name)
  "Rename entry at point (`F2' / `r').
Parent directories are created when NEW-NAME contains slashes."
  (interactive)
  (enhanced-dirvish--ensure-writable-target default-directory "Rename")
  (let ((src (or (enhanced-dirvish-current-file) (user-error "No item at point"))))
    (let* ((dir (file-name-directory (directory-file-name src)))
           (old (file-name-nondirectory (directory-file-name src)))
           (input (or new-name (enhanced-dirvish-ui-read-string (format "Rename '%s' to: " old) old)))
           (dest (expand-file-name input dir)))
      (when (equal (directory-file-name src) (directory-file-name dest))
        (user-error "Unchanged name"))
      (when (file-exists-p dest)
        (unless (enhanced-dirvish-ui-y-or-n-p (format "Target %s exists. Replace? " (file-name-nondirectory dest)))
          (user-error "Rename cancelled")))
      (make-directory (file-name-directory dest) t)
      (rename-file src dest t)
      (enhanced-dirvish-undo--push (list :batch (list (list :type 'move :from src :to dest))))
      (enhanced-dirvish-refresh-active-view)
      (enhanced-dirvish-goto-file dest)
      (message "Renamed -> %s" input))))

(defun enhanced-dirvish-paste-content-drop ()
  "Save the system clipboard image or text as a new file in the folder.
Images are read with `wl-paste'."
  (interactive)
  (let ((dir (enhanced-dirvish--ensure-writable-target default-directory "Save clipboard")))
    (cond
     ((and (executable-find "wl-paste")
           (= 0 (process-file "wl-paste" nil nil nil "--list-types"))
           (string-search "image/png"
                          (with-temp-buffer
                            (process-file "wl-paste" nil t nil "--list-types")
                            (buffer-string))))
      (let* ((out (enhanced-dirvish-unique-copy-name
                   (expand-file-name (format-time-string "clipboard-%Y%m%d-%H%M%S.png") dir))))
        (with-temp-file out
          (set-buffer-multibyte nil)
          (process-file "wl-paste" nil t nil "--type" "image/png"))
        (enhanced-dirvish-undo--push (list :batch (list (list :type 'create :path out))))
        (enhanced-dirvish-refresh-active-view)
        (enhanced-dirvish-goto-file out)
        (message "Saved clipboard image: %s" (file-name-nondirectory out))))
     ((when-let ((txt (or (ignore-errors (current-kill 0 t))
                          (ignore-errors (gui-get-selection 'CLIPBOARD 'STRING)))))
        (let* ((is-url (string-match-p "\\`https?://" (string-trim txt)))
               (ext (if is-url "url" "txt"))
               (out (enhanced-dirvish-unique-copy-name
                     (expand-file-name (format-time-string (concat "pasted-%Y%m%d-%H%M%S." ext)) dir))))
          (with-temp-file out
            (insert (if is-url (format "[InternetShortcut]\nURL=%s\n" (string-trim txt)) txt)))
          (enhanced-dirvish-undo--push (list :batch (list (list :type 'create :path out))))
          (enhanced-dirvish-refresh-active-view)
          (enhanced-dirvish-goto-file out)
          (message "Saved clipboard content: %s" (file-name-nondirectory out)))))
     (t (user-error "Clipboard has no saveable image or text")))))

;;;; Trash & Undo/Redo Engine

(defun enhanced-dirvish--removal-focus-candidates ()
  "Remember current entry and its neighbours before removing files.
Prefer the next surviving entry, then the previous one, in the displayed order."
  (let* ((order (enhanced-dirvish-view--entry-order))
         (current (enhanced-dirvish-current-file))
         (index (and current
                     (cl-position (enhanced-dirvish--path-key current) order
                                  :key #'enhanced-dirvish--path-key :test #'equal))))
    (if index
        (append (list current) (nthcdr (1+ index) order)
                (reverse (cl-subseq order 0 index)))
      (append (when current (list current)) order))))

(defun enhanced-dirvish--refresh-after-removal (candidates)
  "Refresh after removal and focus the first surviving entry in CANDIDATES."
  ;; Discard old ranges before read-in moves overlay endpoints.  Rebuild the
  ;; highlight only after the refreshed buffer has a valid neighbouring file.
  (enhanced-dirvish--clear-selection-highlight)
  (setq enhanced-dirvish-visual-anchor nil)
  (enhanced-dirvish-view--reset-selection-range)
  (deactivate-mark)
  ;; Dirvish saves the current filename before reverting and restores its
  ;; subtree afterwards.  A deleted path sends that search to the last row
  ;; (and fails on an empty listing), so give it a surviving neighbour first.
  (when (derived-mode-p 'dired-mode)
    (unless (cl-some (lambda (file)
                       (and (or (file-exists-p file) (file-symlink-p file))
                            (dired-goto-file file)))
                     candidates)
      (goto-char (point-max))))
  (enhanced-dirvish-refresh-active-view)
  (unless (cl-some (lambda (file)
                     (and (or (file-exists-p file) (file-symlink-p file))
                          (enhanced-dirvish-goto-file file)))
                   candidates)
    (goto-char (point-max))
    (setq enhanced-dirvish--empty-click-p t enhanced-dirvish--empty-click-position nil))
  (enhanced-dirvish-view--reset-selection-range (enhanced-dirvish-current-file))
  (enhanced-dirvish-view--update-selection-highlight)
  (force-mode-line-update t))

(defun enhanced-dirvish--trash-with-gio-fallback (path)
  "Trash PATH via XDG spec / `gio trash', returning trashed destination or nil."
  (let* ((trash-files (expand-file-name "files" (enhanced-dirvish-trash--dir)))
         (trash-info (expand-file-name "info" (enhanced-dirvish-trash--dir)))
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
             (tpath (enhanced-dirvish-unique-copy-name (expand-file-name base trash-files)))
             (tname (file-name-nondirectory tpath))
             (info (expand-file-name (concat tname ".trashinfo") trash-info)))
        (rename-file path tpath)
        (with-temp-file info
          (insert (format "[Trash Info]\nPath=%s\nDeletionDate=%s\n"
                          (url-hexify-string (expand-file-name path)
                                             (append url-unreserved-chars '(?/)))
                          (format-time-string "%Y-%m-%dT%H:%M:%S"))))
        tpath)))))

(defun enhanced-dirvish-move-to-trash ()
  "Move selected items to Trash (`DEL' / `d').
Where Trash is unsupported, offer to delete them permanently."
  (interactive)
  (if (derived-mode-p 'enhanced-dirvish-trash-mode)
      (call-interactively #'enhanced-dirvish-trash-delete-at-point)
    (enhanced-dirvish--ensure-writable-target default-directory "Trash")
    (let ((files (enhanced-dirvish-selected-files)))
      (unless files (user-error "No item selected"))
      (when (enhanced-dirvish-ui-yes-or-no-p (format "Move %d item(s) to Trash? " (length files)))
        (let ((undo-items nil)
              (candidates (enhanced-dirvish--removal-focus-candidates)))
          (dolist (f files)
            (let ((trashed (enhanced-dirvish--trash-with-gio-fallback f)))
              (if trashed
                  (push (list :type 'trash :orig f :trashed trashed) undo-items)
                (when (enhanced-dirvish-ui-yes-or-no-p (format "Filesystem for '%s' has no Trash. Delete permanently? "
                                           (file-name-nondirectory f)))
                  (if (file-directory-p f) (delete-directory f t) (delete-file f))))))
          (when undo-items
            (enhanced-dirvish-undo--push (list :batch (nreverse undo-items))))
          (enhanced-dirvish--refresh-after-removal candidates)
          (message "Moved %d item(s) to Trash" (length files)))))))

(defun enhanced-dirvish-delete-permanently ()
  "Permanently delete selected items bypassing Trash (`S-DEL' / `D')."
  (interactive)
  (if (derived-mode-p 'enhanced-dirvish-trash-mode)
      (call-interactively #'enhanced-dirvish-trash-delete-at-point)
    (enhanced-dirvish--ensure-writable-target default-directory "Permanent delete")
    (let ((files (enhanced-dirvish-selected-files)))
      (unless files (user-error "No item selected"))
      (when (enhanced-dirvish-ui-yes-or-no-p (format "PERMANENTLY delete %d item(s)? This cannot be undone! "
                                 (length files)))
        (let ((candidates (enhanced-dirvish--removal-focus-candidates)))
          (dolist (f files)
            (when (file-exists-p f)
              (if (file-directory-p f) (delete-directory f t) (delete-file f))))
          (enhanced-dirvish--refresh-after-removal candidates))
        (message "Deleted %d item(s) permanently" (length files))))))

(defun enhanced-dirvish-undo ()
  "Undo last Enhanced Dirvish file operation (`C-z')."
  (interactive)
  (let ((op (pop enhanced-dirvish-undo-stack)))
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
                         (expand-file-name "info" (enhanced-dirvish-trash--dir)))))
             (when (file-exists-p trashed)
               (make-directory (file-name-directory orig) t)
               (rename-file trashed orig t)
               (when (file-exists-p info) (delete-file info))
               (push (list :type 'trash :orig orig) redos))))))
      (when redos
        (push (list :batch redos) enhanced-dirvish-redo-stack))
      (enhanced-dirvish-refresh-active-view)
      (message "Undid Enhanced Dirvish operation"))))

(defun enhanced-dirvish-redo ()
  "Redo last undone Enhanced Dirvish file operation (`C-S-z' / `C-y')."
  (interactive)
  (let ((op (pop enhanced-dirvish-redo-stack)))
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
                                (enhanced-dirvish--trash-with-gio-fallback orig))))
             (when trashed
               (push (list :type 'trash :orig orig :trashed trashed) undos))))))
      (when undos (push (list :batch undos) enhanced-dirvish-undo-stack))
      (enhanced-dirvish-refresh-active-view)
      (message "Redid Enhanced Dirvish operation"))))

;;;; Archives Compress & Smart Extract

(defun enhanced-dirvish-archive-compress (&optional encrypt)
  "Compress selected files/folders (`; c').
With ENCRYPT (interactively, a prefix), require an encrypted 7z or ZIP archive."
  (interactive "P")
  (let* ((dir (enhanced-dirvish--ensure-writable-target default-directory "Compress"))
         (files (or (enhanced-dirvish-selected-files)
                    (user-error "No file or folder selected")))
         (default-name (file-name-sans-extension
                        (file-name-nondirectory (directory-file-name (car files)))))
         (name (string-trim (enhanced-dirvish-ui-read-string "Archive name (without extension): "
                                         (if (> (length files) 1) "archive" default-name))))
         (formats (if encrypt '("7z" "zip") '("zip" "tar.gz" "tar.zst" "7z" "tar")))
         (fmt (enhanced-dirvish-ui-completing-read "Format: " formats nil t nil nil (car formats)))
         (source (current-buffer))
         pw)
    (unless (and (not (string-empty-p name))
                 (equal name (file-name-nondirectory name))
                 (not (member name '("." ".."))))
      (user-error "Enter an archive filename without a directory"))
    (unless (member fmt formats) (user-error "Unsupported archive format: %s" fmt))
    (unless (executable-find (if (member fmt '("zip" "7z")) "7z" "tar"))
      (user-error "Archive tool %s is unavailable" (if (member fmt '("zip" "7z")) "7z" "tar")))
    (unwind-protect
        (progn
          (when (and (member fmt '("zip" "7z"))
                     (or encrypt (enhanced-dirvish-ui-y-or-n-p "Protect archive with password? ")))
            (setq pw (enhanced-dirvish-ui-read-passwd "Archive password: " t))
            (when (string-empty-p pw) (user-error "Encryption requires a nonempty password")))
          (let* ((out (enhanced-dirvish-unique-copy-name (expand-file-name (concat name "." fmt) dir)))
                 (rels (mapcar (lambda (f) (concat "./" (file-relative-name f dir))) files))
                 (cmd
                  (if (member fmt '("zip" "7z"))
                      (append (list "7z" "a" (concat "-t" fmt))
                              (when pw
                                (list (concat "-p" pw)
                                      (if (equal fmt "7z") "-mhe=on" "-mem=AES256")))
                              (list "--" out) rels)
                    (append (pcase fmt
                              ("tar.gz" '("tar" "-czf"))
                              ("tar.zst" '("tar" "--zstd" "-cf"))
                              (_ '("tar" "-cf")))
                            (list out "--") rels))))
            (let ((default-directory dir))
              (enhanced-dirvish-run-job
               (format "Compress %s" (file-name-nondirectory out)) cmd
               (lambda ()
                 (when (buffer-live-p source)
                   (with-current-buffer source
                     (enhanced-dirvish-refresh-active-view)
                     (enhanced-dirvish-goto-file out))))))))
      (when pw (clear-string pw)))))

(defun enhanced-dirvish-archive-compress-encrypted ()
  "Create an AES-encrypted 7z or ZIP archive of the selected files/folders."
  (interactive)
  (enhanced-dirvish-archive-compress t))

(defun enhanced-dirvish-archive--tar-p (archive)
  "Return non-nil for tar archives, including compressed tar variants."
  (string-match-p "\\.\\(?:tar\\(?:\\.\\(?:gz\\|bz2\\|xz\\|zst\\)\\)?\\|tgz\\|tbz2?\\|txz\\|tzst\\)\\'"
                  (downcase archive)))

(defun enhanced-dirvish-archive--inspect (archive &optional password)
  "List ARCHIVE noninteractively, returning its exit status and output.
PASSWORD is supplied only when opening an encrypted archive."
  (let ((tar-p (enhanced-dirvish-archive--tar-p archive)))
    (unless (executable-find (if tar-p "tar" "7z"))
      (user-error "Archive tool %s is unavailable" (if tar-p "tar" "7z")))
    (with-temp-buffer
      (let ((status (apply #'process-file (if tar-p "tar" "7z") nil t nil
                           (if tar-p (list "-tf" archive)
                             (append '("l" "-slt" "-ba")
                                     (when password (list (concat "-p" password)))
                                     (list "--" archive))))))
        (cons status (buffer-string))))))

(defun enhanced-dirvish-archive--roots (listing tar-p)
  "Read top-level entry names from LISTING, using tar format when TAR-P."
  (let (roots)
    (dolist (line (split-string listing "\n" t))
      (let ((path (if tar-p (string-remove-suffix "\r" line)
                    (when (string-match "\\`Path = \\(.*?\\)\r?\\'" line)
                      (match-string 1 line)))))
        (when path
          (while (string-prefix-p "./" path) (setq path (substring path 2)))
          (when-let ((top (car (split-string path "/" t))))
            (unless (member top roots) (push top roots))))))
    (nreverse roots)))

(defun enhanced-dirvish-archive--top-level-roots (archive &optional password)
  "Return distinct top-level entry names inside ARCHIVE, using PASSWORD if set."
  (let ((info (enhanced-dirvish-archive--inspect archive password)))
    (when (eq (car info) 0)
      (enhanced-dirvish-archive--roots (cdr info) (enhanced-dirvish-archive--tar-p archive)))))

(defun enhanced-dirvish-archive-extract (&optional ask-dest)
  "Smart extract archive at point (`; e` here, `; E` choose folder).
Single-root archives extract cleanly as-is; multi-root archives extract into a
wrapping folder named after the archive so parent folders stay uncluttered."
  (interactive "P")
  (let* ((archive (or (enhanced-dirvish-current-file) (user-error "Select an archive first")))
         (base-dest (if ask-dest
                        (enhanced-dirvish-ui-read-directory-name "Extract to folder: " default-directory)
                      (file-name-directory archive)))
         (tar-p (enhanced-dirvish-archive--tar-p archive))
         (info (enhanced-dirvish-archive--inspect archive))
         (source (current-buffer))
         password)
    (enhanced-dirvish-guard-writable-location base-dest "Extract archive")
    (unwind-protect
        (progn
          (when (and (not tar-p)
                     (string-match-p "Encrypted = [+]\\|[Ee]nter password\\|encrypted archive" (cdr info)))
            (setq password (enhanced-dirvish-ui-read-passwd "Archive password: "))
            (when (string-empty-p password) (user-error "Enter the archive password"))
            (setq info (enhanced-dirvish-archive--inspect archive password)))
          (unless (eq (car info) 0) (user-error "Cannot read archive: %s" (string-trim (cdr info))))
          (let* ((roots (enhanced-dirvish-archive--roots (cdr info) tar-p))
                 (stem (file-name-sans-extension (file-name-nondirectory archive)))
                 (stem (if (string-suffix-p ".tar" stem) (file-name-sans-extension stem) stem))
                 (target-dir (if (<= (length roots) 1) base-dest
                               (enhanced-dirvish-unique-copy-name (expand-file-name stem base-dest)))))
            (make-directory target-dir t)
            (enhanced-dirvish-run-job
             (format "Extract %s" (file-name-nondirectory archive))
             (if tar-p (list "tar" "-xf" archive "-C" target-dir)
               (append (list "7z" "x" "-y" "-aou" (concat "-o" target-dir))
                       (when password (list (concat "-p" password))) (list "--" archive)))
             (lambda ()
               (when (buffer-live-p source)
                 (with-current-buffer source (enhanced-dirvish-refresh-active-view)))
               (message "Extracted -> %s" (abbreviate-file-name target-dir))))))
      (when password (clear-string password)))))

;;;; Properties Modal/Buffer & Customize Folder

(defun enhanced-dirvish-show-properties-for-path (path &optional device)
  "Show the Properties buffer for PATH or device DEVICE (`M-RET' / `P')."
  (interactive (list (or (enhanced-dirvish-current-file) default-directory)))
  (let* ((buf (get-buffer-create "*Enhanced Dirvish Properties*"))
         (dev (or device (cl-find-if (lambda (d) (equal (enhanced-dirvish-device-mountpoint d) path))
                                     (enhanced-dirvish-devices-list))))
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
                                          (enhanced-dirvish-device-name dev)))
                                'face 'enhanced-dirvish-header-accent))
        (local-set-key (kbd "x") (lambda () (interactive)
                                   (when (and path (file-exists-p path))
                                     (let* ((m (file-modes path))
                                            (next (if (zerop (logand m #o100))
                                                      (logior m #o111)
                                                    (logand m (lognot #o111)))))
                                       (set-file-modes path next)
                                       (enhanced-dirvish-show-properties-for-path path dev)))))
        (local-set-key (kbd "c") (lambda () (interactive)
                                   (when path (enhanced-dirvish-customize-folder path))))
        (insert "\n")
        (when path
          (insert (format "  Name:        %s\n" (file-name-nondirectory (directory-file-name path))))
          (insert (format "  Location:    %s\n" (abbreviate-file-name path)))
          (insert (format "  Type / MIME: %s%s\n"
                          (if dir-p "Folder" "File")
                          (if (and mime (not (string-empty-p mime))) (format " (%s)" mime) "")))
          (when attrs
            (insert (format "  Size:        %s\n"
                            (if dir-p "Measuring…" (enhanced-dirvish-format-bytes (file-attribute-size attrs)))))
            (insert (format "  Permissions: %s (octal %03o)  [press x to toggle executable]\n"
                            (file-attribute-modes attrs)
                            (logand (or (file-modes path) 0) #o777)))
            (insert (format "  Modified:    %s (%s)\n"
                            (enhanced-dirvish-format-time (file-attribute-modification-time attrs) 'iso)
                            (enhanced-dirvish-format-time (file-attribute-modification-time attrs) 'relative)))))
        (when dev
          (insert "\n" (propertize "  DRIVE / VOLUME\n" 'face 'enhanced-dirvish-section-heading))
          (insert (format "  Device:      %s (%s)\n" (or (enhanced-dirvish-device-device dev) "-")
                          (or (enhanced-dirvish-device-fstype dev) "-")))
          (when (enhanced-dirvish-device-uuid dev)
            (insert (format "  UUID:        %s\n" (enhanced-dirvish-device-uuid dev))))
          (when (enhanced-dirvish-device-usage dev)
            (insert (format "  Capacity:    %s\n" (enhanced-dirvish-format-capacity-bar (enhanced-dirvish-device-usage dev) 18 nil)))))
        (goto-char (point-min))))
    ;; Async bounded recursive folder summary
    (when (and path (file-directory-p path) (executable-find "du"))
      (make-process
       :name "enhanced-dirvish-prop-du"
       :buffer (generate-new-buffer " *enhanced-dirvish-du*")
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
                           (replace-match (enhanced-dirvish-format-bytes bytes))))))))
             (when (buffer-live-p (process-buffer proc))
               (kill-buffer (process-buffer proc))))))))
    (pop-to-buffer buf)))

(defun enhanced-dirvish-customize-folder (&optional dir)
  "Assign custom color badge and custom icon to DIR (`Customize…`)."
  (interactive (list (or (let ((f (enhanced-dirvish-current-file))) (when (and f (file-directory-p f)) f))
                         default-directory)))
  (enhanced-dirvish-guard-writable-location dir "Customize")
  (let* ((color (enhanced-dirvish-ui-completing-read "Folder color (empty to clear): "
                                 (cons "" (mapcar #'car enhanced-dirvish-folder-color-alist)) nil nil))
         (icon (enhanced-dirvish-ui-read-string "Custom icon/emoji (empty to keep/clear): "
                            (or (cdr (assoc (directory-file-name (expand-file-name dir))
                                            (enhanced-dirvish-prefs-custom-icons (enhanced-dirvish-prefs))))
                                ""))))
    (enhanced-dirvish-folder-color-set dir color)
    (enhanced-dirvish-custom-icon-set dir icon)
    (enhanced-dirvish-refresh-active-view)
    (message "Updated customization for %s" (file-name-nondirectory (directory-file-name dir)))))

;;;; Open With (.desktop scanner + Recent Apps)

(defun enhanced-dirvish-desktop--parse-file (file)
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

(defun enhanced-dirvish-desktop-apps ()
  "Discover desktop applications across NixOS & XDG application dirs."
  (let ((dirs (delete-dups
               (append
                (list "/run/current-system/sw/share/applications"
                      (format "/etc/profiles/per-user/%s/share/applications" (user-login-name))
                      "~/.nix-profile/share/applications"
                      (expand-file-name "applications"
                                        (or (getenv "XDG_DATA_HOME") "~/.local/share"))
                      "/usr/share/applications")
                (mapcar (lambda (d) (expand-file-name "applications" d))
                        (split-string (or (getenv "XDG_DATA_DIRS") "") ":" t)))))
        apps)
    (dolist (d dirs)
      (let ((exp (expand-file-name d)))
        (when (file-directory-p exp)
          (dolist (f (directory-files exp t "\\.desktop\\'" t))
            (when (file-readable-p f)
              (when-let ((entry (enhanced-dirvish-desktop--parse-file f)))
                (push entry apps)))))))
    (cl-delete-duplicates (nreverse apps) :key #'car :test #'equal)))

(defun enhanced-dirvish-open-with ()
  "Open selected item(s) with an independent installed application (`O`).
The application keeps running after Emacs exits."
  (interactive)
  (let* ((files (enhanced-dirvish-selected-files))
         (apps (enhanced-dirvish-desktop-apps))
         (choice (enhanced-dirvish-ui-completing-read "Open With application: " (mapcar #'car apps) nil t))
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

;;;; Custom Actions (~/.config/enhanced-dirvish/actions/*/action.toml) + Recipes + Jobs Dashboard

(defun enhanced-dirvish-actions-load ()
  "Load validated custom actions from the config dir's actions/*/action.toml."
  (let ((dir (expand-file-name "actions" enhanced-dirvish-config-dir))
        out)
    (when (file-directory-p dir)
      (dolist (sub (directory-files dir t "\\`[^.]" t))
        (let ((manifest (expand-file-name "action.toml" sub)))
          (when (and (file-directory-p sub) (file-readable-p manifest))
            (let* ((parsed (enhanced-dirvish-toml-parse-file manifest))
                   (root (cdr (assoc "" parsed)))
                   (when-sec (cdr (assoc "when" parsed)))
                   (run-sec (cdr (assoc "run" parsed))))
              (push (list :id (or (cdr (assoc "id" root)) (file-name-nondirectory sub))
                          :name (or (cdr (assoc "name" root)) (file-name-nondirectory sub))
                          :description (cdr (assoc "description" root))
                          :enabled (enhanced-dirvish-toml--bool (cdr (assoc "enabled" root)) t)
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
                          :confirm (enhanced-dirvish-toml--bool (cdr (assoc "confirm" run-sec)) nil))
                    out))))))
    (sort out (lambda (a b) (string-lessp (plist-get a :name) (plist-get b :name))))))

(defun enhanced-dirvish-action-matches-p (act items)
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

(defun enhanced-dirvish-run-job (label cmd &optional on-done)
  "Execute CMD asynchronously logging status & output to `*Enhanced Dirvish Jobs*'.
Call ON-DONE only after a successful exit."
  (let* ((id (cl-incf enhanced-dirvish-next-job-id))
         (buf (generate-new-buffer (format " *enhanced-dirvish-job-%d*" id)))
         (job (list :id id :label label :status 'running :started (current-time) :output "")))
    (push job enhanced-dirvish-jobs-list)
    (make-process
     :name (format "enhanced-dirvish-job-%d" id)
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
           (when (get-buffer "*Enhanced Dirvish Jobs*") (enhanced-dirvish-jobs-dashboard t))
           (when (and ok on-done) (funcall on-done))
           (message "Job %s: %s" label (if ok "done" (format "failed (%s)" txt)))))))
    job))

(defun enhanced-dirvish-jobs-dashboard (&optional no-switch)
  "Open `*Enhanced Dirvish Jobs*' showing background transfers & custom actions."
  (interactive)
  (let ((buf (get-buffer-create "*Enhanced Dirvish Jobs*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (setq-local header-line-format
                    (concat "  "
                            (enhanced-dirvish-icon-glyph 'gear 'enhanced-dirvish-header-accent)
                            (propertize "  Enhanced Dirvish Background Jobs   [g: Refresh · q: Close]"
                                        'face 'enhanced-dirvish-header-accent)))
        (insert "\n")
        (if (null enhanced-dirvish-jobs-list)
            (insert "   No background jobs recorded in this session.\n")
          (dolist (j enhanced-dirvish-jobs-list)
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

(defun enhanced-dirvish-run-custom-action (&optional index focused-folder-only)
  "Run a custom action on the selection or FOCUSED-FOLDER-ONLY (`; .').
INDEX is 1-based; without it, prompt for the action."
  (interactive)
  (let* ((targets (if focused-folder-only
                      (let ((f (enhanced-dirvish-current-file)))
                        (unless (and f (file-directory-p f))
                          (user-error "Focused item is not a folder"))
                        (list f))
                    (enhanced-dirvish-selected-files)))
         (acts (cl-remove-if-not (lambda (a) (enhanced-dirvish-action-matches-p a targets))
                                 (enhanced-dirvish-actions-load))))
    (unless acts (user-error "No matching enabled actions found in ~/.config/enhanced-dirvish/actions/ (see Settings -> Actions Recipes)"))
    (let* ((act (if (and index (<= 1 index (length acts)))
                    (nth (1- index) acts)
                  (let* ((names (mapcar (lambda (a) (plist-get a :name)) acts))
                         (picked (enhanced-dirvish-ui-completing-read "Run Custom Action: " names nil t)))
                    (cl-find picked acts :key (lambda (a) (plist-get a :name)) :test #'equal)))))
      (when (or (not (plist-get act :confirm))
                (enhanced-dirvish-ui-yes-or-no-p (format "Run custom action '%s' on %d item(s)? "
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
                (enhanced-dirvish-run-job (format "%s (%s)" (plist-get act :name) (file-name-nondirectory it))
                                (append base-cmd (list it))
                                #'enhanced-dirvish-refresh-active-view))
            (let* ((args (or (plist-get act :args) '("{paths}")))
                   (final-args
                    (cl-mapcan (lambda (a)
                                 (pcase a
                                   ("{paths}" (copy-sequence targets))
                                   ("{path}" (list (car targets)))
                                   ("{parent}" (list parent))
                                   (_ (list a))))
                               args)))
              (enhanced-dirvish-run-job (plist-get act :name)
                              (append base-cmd final-args)
                              #'enhanced-dirvish-refresh-active-view))))))))

(defconst enhanced-dirvish-builtin-action-recipes
  '(("log-selected" "Log selected paths" "Log selected paths & parent directory cleanly." "python" "action.py"
     "#!/usr/bin/env python3\nimport sys\nfor p in sys.argv[1:]:\n    print(p)\n")
    ("sha256-checksums" "SHA-256 checksums" "Write .sha256 checksum sidecar without overwriting." "python" "checksums.py"
     "#!/usr/bin/env python3\nimport hashlib, sys, pathlib\nfor arg in sys.argv[1:]:\n    p = pathlib.Path(arg)\n    if p.is_file():\n        out = pathlib.Path(str(p) + '.sha256')\n        if not out.exists():\n            h = hashlib.sha256(p.read_bytes()).hexdigest()\n            out.write_text(f'{h}  {p.name}\\n')\n")
    ("count-lines" "Count lines" "Count lines across selected text files." "bash" "count.sh"
     "#!/usr/bin/env bash\nwc -l \"$@\"\n"))
  "Starter action recipes installable to ~/.config/enhanced-dirvish/actions/.")

(defun enhanced-dirvish-install-action-recipe ()
  "Install a built-in action recipe into ~/.config/enhanced-dirvish/actions/."
  (interactive)
  (let* ((picked (enhanced-dirvish-ui-completing-read "Install action recipe: "
                                  (mapcar #'cadr enhanced-dirvish-builtin-action-recipes) nil t))
         (rec (cl-find picked enhanced-dirvish-builtin-action-recipes :key #'cadr :test #'equal))
         (id (nth 0 rec))
         (dir (expand-file-name (concat "actions/" id) enhanced-dirvish-config-dir))
         (entry (nth 4 rec)))
    (make-directory dir t)
    (with-temp-file (expand-file-name "action.toml" dir)
      (insert (format "schema_version = 1\nid = %S\nname = %S\ndescription = %S\nenabled = true\n\n[when]\nkinds = [\"file\", \"folder\"]\n\n[run]\nruntime = %S\nentrypoint = %S\nargs = [\"{paths}\"]\n"
                      id (nth 1 rec) (nth 2 rec) (nth 3 rec) entry)))
    (let ((ep (expand-file-name entry dir)))
      (with-temp-file ep (insert (nth 5 rec)))
      (set-file-modes ep #o755))
    (message "Installed action '%s' in %s" (nth 1 rec) dir)))

(provide 'enhanced-dirvish-ops)
;;; enhanced-dirvish-ops.el ends here
