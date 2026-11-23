;;; emacs-minder.el --- Native Cairo/LaTeX Mind Map Mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: emacs-minder
;; Keywords: outlines, org, multimedia, hypermedia
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; Native Mind Mapping major mode powered by the Rust/Cairo/PangoCairo/librsvg/LaTeX
;; dynamic module (`libemacs_minder.so`).  Supports both native Minder `.minder`
;; (.tar.gz + XML) files and live `.org` files, with inline LaTeX equations,
;; node tables, embedded SVGs/rasters, and transparent PNG compositing in Emacs.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(declare-function emacs-minder-core-new "emacs-minder-core" (&optional title))
(declare-function emacs-minder-core-open-file "emacs-minder-core" (path))
(declare-function emacs-minder-core-save-file "emacs-minder-core" (handle path))
(declare-function emacs-minder-core-render-png "emacs-minder-core" (handle width height))
(declare-function emacs-minder-core-export-png "emacs-minder-core" (handle out-path &optional max-dim))
(declare-function emacs-minder-core-set-viewport "emacs-minder-core" (handle width height))
(declare-function emacs-minder-core-command "emacs-minder-core" (handle json-cmd))
(declare-function emacs-minder-core-hit-test "emacs-minder-core" (handle x y))
(declare-function emacs-minder-core-state-json "emacs-minder-core" (handle))
(declare-function emacs-minder-core-poll-updates "emacs-minder-core" (handle))
(declare-function emacs-minder-core-wait-latex "emacs-minder-core" (handle))
(declare-function org-table-align "org-table" (&optional no-shrink))

(defgroup emacs-minder nil
  "Native mind-mapping interface powered by libemacs_minder."
  :group 'applications
  :prefix "emacs-minder-")

(defcustom emacs-minder-module-path nil
  "Explicit path to `libemacs_minder.so'.  When nil, search standard locations."
  :type '(choice (const nil) file)
  :group 'emacs-minder)

(defcustom emacs-minder-transparent-background t
  "When non-nil, render canvas background transparently for Emacs translucency."
  :type 'boolean
  :group 'emacs-minder)

(defcustom emacs-minder-sync-emacs-theme t
  "When non-nil, synchronize mind map colors with the active Emacs theme."
  :type 'boolean
  :group 'emacs-minder)

(defcustom emacs-minder-auto-fit-on-open t
  "When non-nil, zoom-fit the mind map after opening a file."
  :type 'boolean
  :group 'emacs-minder)

(defvar emacs-minder--loaded nil)

(defvar-local emacs-minder--handle nil)
(defvar-local emacs-minder--file-path nil)
(put 'emacs-minder--file-path 'permanent-local t)
(defvar-local emacs-minder--state nil)
(defvar-local emacs-minder--timer nil)
(defvar-local emacs-minder--last-size nil)
(defvar-local emacs-minder--render-in-progress nil)

(defvar-local emacs-minder--source-buffer nil)
(defvar-local emacs-minder--target-node-id nil)

(defun emacs-minder--find-module ()
  "Locate `libemacs_minder.so'."
  (let* ((this-dir (file-name-directory (or load-file-name buffer-file-name default-directory)))
         (candidates
          (delq nil
                (list
                 emacs-minder-module-path
                 (expand-file-name "~/.emacs.d/modules/emacs-minder/lib/libemacs_minder.so")
                 (expand-file-name "../lib/libemacs_minder.so" this-dir)
                 (expand-file-name "../target/release/libemacs_minder.so" this-dir)
                 (expand-file-name "../target/debug/libemacs_minder.so" this-dir)
                 (expand-file-name "~/Projects/emacs-minder/target/release/libemacs_minder.so")
                 (expand-file-name "~/Projects/emacs-minder/target/debug/libemacs_minder.so")))))
    (cl-find-if #'file-exists-p candidates)))

;;;###autoload
(defun emacs-minder-ensure-module ()
  "Load the native `emacs-minder-core' dynamic module if not already loaded."
  (unless (featurep 'emacs-minder-core)
    (let ((so (emacs-minder--find-module)))
      (unless so
        (error "Cannot locate libemacs_minder.so; run nix build or cargo build --release"))
      (module-load so))
    (unless (featurep 'emacs-minder-core)
      (error "Loaded dynamic library did not provide `emacs-minder-core'")))
  (setq emacs-minder--loaded t))

(defun emacs-minder--parse-json (str)
  "Parse JSON response STR into an alist."
  (json-parse-string str :object-type 'alist :array-type 'list :null-object nil :false-object nil))

(defun emacs-minder--color-hex (face attr fallback)
  "Resolve FACE ATTR as `#RRGGBB' string, using FALLBACK when unspecified."
  (let ((col (face-attribute face attr nil 'default)))
    (if (and (stringp col) (not (member col '("unspecified" "unspecified-bg" "unspecified-fg"))))
        (let ((rgb (ignore-errors (color-name-to-rgb col))))
          (if rgb
              (apply #'format "#%02x%02x%02x"
                     (mapcar (lambda (c) (min 255 (max 0 (round (* c 255.0))))) rgb))
            fallback))
      fallback)))

(defun emacs-minder--sync-theme-to-core ()
  "Push active Emacs theme palette and transparency setting to the Rust engine."
  (when emacs-minder--handle
    (when emacs-minder-sync-emacs-theme
      (let* ((bg (emacs-minder--color-hex 'default :background "#1f2430"))
             (fg (emacs-minder--color-hex 'default :foreground "#eceff4"))
             (accent (emacs-minder--color-hex 'font-lock-keyword-face :foreground "#5e81ac"))
             (sel-bg (emacs-minder--color-hex 'region :background "#4c566a"))
             (sel-fg (emacs-minder--color-hex 'default :foreground "#ffffff"))
             (branch-faces '(outline-1 outline-2 outline-3 outline-4
                             outline-5 outline-6 outline-7 outline-8))
             (branches (mapcar (lambda (f)
                                 (emacs-minder--color-hex
                                  (if (facep f) f 'font-lock-function-name-face)
                                  :foreground accent))
                               branch-faces)))
        (emacs-minder--cmd-raw
         `((op . "set_emacs_colors")
           (bg . ,bg)
           (fg . ,fg)
           (accent . ,accent)
           (selection_bg . ,sel-bg)
           (selection_fg . ,sel-fg)
           (branch_colors . ,(vconcat branches))))))
    (emacs-minder--cmd-raw
     `((op . "set_transparent_bg")
       (enabled . ,(if emacs-minder-transparent-background t :json-false))))))

(defun emacs-minder--cmd-raw (alist)
  "Send command ALIST to the Rust session without redrawing."
  (when emacs-minder--handle
    (let* ((json-str (json-encode alist))
           (resp (emacs-minder-core-command emacs-minder--handle json-str)))
      (setq emacs-minder--state (emacs-minder--parse-json resp))
      emacs-minder--state)))

(defun emacs-minder--cmd (alist)
  "Execute EditCommand ALIST and re-render the canvas."
  (emacs-minder--cmd-raw alist)
  (emacs-minder--render)
  emacs-minder--state)

(defun emacs-minder--viewport-pixels ()
  "Compute pixel (WIDTH . HEIGHT) for the current window canvas."
  (let* ((win (or (get-buffer-window (current-buffer) 'visible)
                  (selected-window)))
         (edges (and (window-live-p win) (window-inside-pixel-edges win)))
         (w (if edges (max 240 (- (nth 2 edges) (nth 0 edges) 8)) 1200))
         (h (if edges (max 180 (- (nth 3 edges) (nth 1 edges) 8)) 800)))
    (cons w h)))

(defun emacs-minder--update-header ()
  "Refresh the informative header line from current state."
  (let* ((st emacs-minder--state)
         (fmt (or (alist-get 'format st) "new"))
         (theme (or (alist-get 'theme_name st) "default"))
         (scale (or (alist-get 'scale st) 1.0))
         (nodes (or (alist-get 'node_count st) 0))
         (sel (alist-get 'selected st))
         (title (or (and sel (alist-get 'text sel)) "<none>"))
         (short-title (truncate-string-to-width (replace-regexp-in-string "\n" " " title) 36 nil nil "…"))
         (conn-from (alist-get 'connect_from st)))
    (setq header-line-format
          (format " Minder[%s|%s]  %d%%  Nodes:%d  Sel:%s%s   [TAB]Child [o]Sib [RET]Edit [f]Fold [v]Table [L]Layout [b]Balance [C-x C-s]Save [?]Help"
                  fmt theme (round (* 100 scale)) nodes short-title
                  (if conn-from (format " [CONNECTING from %d]" conn-from) "")))))

(defun emacs-minder--render ()
  "Render current canvas PNG bytes cleanly into the buffer."
  (when (and emacs-minder--handle (not emacs-minder--render-in-progress))
    (let ((emacs-minder--render-in-progress t)
          (inhibit-read-only t))
      (pcase-let ((`(,w . ,h) (emacs-minder--viewport-pixels)))
        (setq emacs-minder--last-size (cons w h))
        (let* ((png (emacs-minder-core-render-png emacs-minder--handle w h))
               (img (create-image png 'png t :scale 1.0))
               (st (emacs-minder--parse-json (emacs-minder-core-state-json emacs-minder--handle))))
          (setq emacs-minder--state st)
          (set-buffer-modified-p (and (alist-get 'dirty st) t))
          (emacs-minder--update-header)
          (erase-buffer)
          (insert (propertize " " 'display img 'pointer 'arrow))
          (goto-char (point-min)))))))

(defun emacs-minder--poll-tick (buf)
  "Check whether background LaTeX compiles completed for BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (and emacs-minder--handle
                 (get-buffer-window buf 'visible)
                 (emacs-minder-core-poll-updates emacs-minder--handle))
        (emacs-minder--render)))))

(defun emacs-minder--on-window-size-change (&optional frame)
  "Re-render mind map buffers cleanly when window pixel geometry changes."
  (dolist (win (window-list frame 'no-minibuf))
    (let ((buf (window-buffer win)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when (and (derived-mode-p 'emacs-minder-mode) emacs-minder--handle)
            (let ((sz (emacs-minder--viewport-pixels)))
              (unless (equal sz emacs-minder--last-size)
                (setq emacs-minder--state
                      (emacs-minder--parse-json
                       (emacs-minder-core-set-viewport emacs-minder--handle (car sz) (cdr sz))))
                (emacs-minder--render)))))))))

(defun emacs-minder--on-theme-change (_theme)
  "Update theme colors across open `emacs-minder-mode' buffers."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (derived-mode-p 'emacs-minder-mode)
        (emacs-minder--sync-theme-to-core)
        (emacs-minder--render)))))

(defun emacs-minder--cleanup-buffer ()
  "Stop buffer-local polling timer when killing a mind map buffer."
  (when (timerp emacs-minder--timer)
    (cancel-timer emacs-minder--timer)
    (setq emacs-minder--timer nil)))

(defun emacs-minder--backing-file ()
  "Return the file path associated with the current mind map buffer, if any."
  (or buffer-file-name
      emacs-minder--file-path
      (alist-get 'file_path emacs-minder--state)))

(defun emacs-minder--write-contents ()
  "Save the current `emacs-minder-mode' buffer to disk."
  (let ((dest (emacs-minder--backing-file)))
    (when (and emacs-minder--handle dest)
      (let ((abs (expand-file-name dest)))
        (emacs-minder-core-save-file emacs-minder--handle abs)
        (setq emacs-minder--state
              (emacs-minder--parse-json (emacs-minder-core-state-json emacs-minder--handle)))
        (set-buffer-modified-p nil)
        (emacs-minder--update-header)
        (when-let* ((orig (find-buffer-visiting abs)))
          (unless (or (eq orig (current-buffer)) (buffer-modified-p orig))
            (with-current-buffer orig
              (revert-buffer t t t))))
        (message "Saved mind map to %s" abs)
        t))))

(defun emacs-minder-save ()
  "Save the current mind map buffer to its `.minder' or `.org' file."
  (interactive)
  (unless emacs-minder--handle
    (user-error "Not in a Minder buffer"))
  (let ((dest (or (emacs-minder--backing-file)
                  (read-file-name "Save mind map to (.minder or .org): "))))
    (setq emacs-minder--file-path (expand-file-name dest))
    (unless (emacs-minder--write-contents)
      (user-error "Failed to save mind map to %s" dest))))

(defun emacs-minder--revert-buffer (&optional _ignore-auto _noconfirm)
  "Reload the mind map from its backing file."
  (let ((dest (emacs-minder--backing-file)))
    (unless (and dest (file-exists-p dest))
      (user-error "No backing file to revert from"))
    (setq emacs-minder--handle (emacs-minder-core-open-file (expand-file-name dest)))
    (pcase-let ((`(,w . ,h) (emacs-minder--viewport-pixels)))
      (setq emacs-minder--state
            (emacs-minder--parse-json
             (emacs-minder-core-set-viewport emacs-minder--handle w h))))
    (when emacs-minder-auto-fit-on-open
      (emacs-minder--cmd-raw '((op . "zoom_fit"))))
    (emacs-minder--sync-theme-to-core)
    (emacs-minder--render)))

;;; Navigation & Editing Commands

(defun emacs-minder-nav-left () (interactive) (emacs-minder--cmd '((op . "select_relative") (dir . "left"))))
(defun emacs-minder-nav-right () (interactive) (emacs-minder--cmd '((op . "select_relative") (dir . "right"))))
(defun emacs-minder-nav-up () (interactive) (emacs-minder--cmd '((op . "select_relative") (dir . "up"))))
(defun emacs-minder-nav-down () (interactive) (emacs-minder--cmd '((op . "select_relative") (dir . "down"))))
(defun emacs-minder-nav-parent () (interactive) (emacs-minder--cmd '((op . "select_relative") (dir . "parent"))))
(defun emacs-minder-nav-next-root () (interactive) (emacs-minder--cmd '((op . "select_relative") (dir . "next_root"))))

(defun emacs-minder-add-child ()
  "Create a child node under the selected node and prompt for its text."
  (interactive)
  (let ((txt (read-string "Child node text: ")))
    (emacs-minder--cmd `((op . "add_child")
                         (text . ,(if (string-empty-p txt) "New Node" txt))))))

(defun emacs-minder-add-sibling ()
  "Create a sibling node next to the selected node and prompt for its text."
  (interactive)
  (let ((txt (read-string "Sibling node text: ")))
    (emacs-minder--cmd `((op . "add_sibling")
                         (text . ,(if (string-empty-p txt) "Sibling Node" txt))))))

(defun emacs-minder-add-parent ()
  "Insert a new parent wrapper node above the selected node."
  (interactive)
  (let ((txt (read-string "Parent topic text: ")))
    (emacs-minder--cmd `((op . "add_parent")
                         (text . ,(if (string-empty-p txt) "Parent Topic" txt))))))

(defun emacs-minder-add-root ()
  "Add a new root topic."
  (interactive)
  (let ((txt (read-string "Root topic text: ")))
    (emacs-minder--cmd `((op . "add_root")
                         (text . ,(if (string-empty-p txt) "Main Idea" txt))))))

(defun emacs-minder-delete-selected ()
  "Delete the currently selected node subtree."
  (interactive)
  (emacs-minder--cmd '((op . "delete_selected"))))

(defun emacs-minder-edit-node-text ()
  "Edit the selected node title (supports LaTeX `$...$' and `\\(...\\)')."
  (interactive)
  (let* ((sel (alist-get 'selected emacs-minder--state))
         (cur (or (and sel (alist-get 'text sel)) ""))
         (updated (read-string "Node text (LaTeX OK): " cur)))
    (emacs-minder--cmd `((op . "set_text") (text . ,updated)))))

(defvar emacs-minder-subedit-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-c") #'emacs-minder-subedit-commit)
    (define-key m (kbd "C-c C-k") #'emacs-minder-subedit-abort)
    m))

(define-minor-mode emacs-minder-subedit-mode
  "Minor mode for committing side-buffer edits back into an Emacs Minder node."
  :lighter " MinderEdit"
  :keymap emacs-minder-subedit-mode-map)

(defvar-local emacs-minder--subedit-kind nil)

(defun emacs-minder-subedit-commit ()
  "Commit the side edit buffer back into the source mind map."
  (interactive)
  (let ((src emacs-minder--source-buffer)
        (nid emacs-minder--target-node-id)
        (kind emacs-minder--subedit-kind)
        (content (buffer-substring-no-properties (point-min) (point-max))))
    (quit-window t)
    (when (buffer-live-p src)
      (with-current-buffer src
        (pcase kind
          ('note
           (emacs-minder--cmd `((op . "set_note") (id . ,nid) (note . ,(string-trim-right content)))))
          ('table
           (let ((tbl (emacs-minder--parse-org-table-string content)))
             (when tbl
               (emacs-minder--cmd `((op . "set_table") (id . ,nid) (table . ,tbl)))))))))))

(defun emacs-minder-subedit-abort ()
  "Abort side-buffer editing."
  (interactive)
  (quit-window t))

(defun emacs-minder-edit-node-note ()
  "Edit the selected node note in an Org/text side buffer."
  (interactive)
  (let* ((sel (alist-get 'selected emacs-minder--state))
         (nid (and sel (alist-get 'id sel)))
         (note (or (and sel (alist-get 'note sel)) ""))
         (src (current-buffer))
         (buf (get-buffer-create (format "*Minder Note [%s]*" (or nid 0)))))
    (with-current-buffer buf
      (erase-buffer)
      (insert note)
      (when (fboundp 'org-mode) (org-mode))
      (setq emacs-minder--source-buffer src
            emacs-minder--target-node-id nid
            emacs-minder--subedit-kind 'note)
      (emacs-minder-subedit-mode 1)
      (setq header-line-format " Edit note -> C-c C-c to commit, C-c C-k to abort"))
    (pop-to-buffer buf)))

(defun emacs-minder--table-to-org-string (tbl)
  "Convert a Rust NodeTable alist TBL into aligned Org table text."
  (if (not tbl)
      "| Header 1 | Header 2 |\n|----------+----------|\n| Value 1  | Value 2  |\n"
    (let* ((rows (max 1 (or (alist-get 'rows tbl) 1)))
           (cols (max 1 (or (alist-get 'columns tbl) 1)))
           (cells (alist-get 'cells tbl))
           (grid (make-vector rows nil))
           (hi (make-vector rows nil)))
      (dotimes (r rows)
        (aset grid r (make-vector cols "")))
      (dolist (c cells)
        (let ((r (or (alist-get 'row c) 0))
              (col (or (alist-get 'col c) 0))
              (txt (or (alist-get 'text c) "")))
          (when (and (< r rows) (< col cols))
            (aset (aref grid r) col (replace-regexp-in-string "\n" " " txt))
            (when (alist-get 'highlighted c)
              (aset hi r t)))))
      (with-temp-buffer
        (dotimes (r rows)
          (insert "|")
          (dotimes (col cols)
            (insert " " (aref (aref grid r) col) " |"))
          (insert "\n")
          (when (and (aref hi r) (< (1+ r) rows))
            (insert "|---|\n")))
        (when (fboundp 'org-mode)
          (org-mode)
          (goto-char (point-min))
          (ignore-errors (org-table-align)))
        (buffer-string)))))

(defun emacs-minder--parse-org-table-string (str)
  "Parse an Org table buffer STR into a Rust NodeTable alist."
  (let ((rows-data nil)
        (prev-hi nil))
    (dolist (line (split-string str "\n"))
      (let ((tr (string-trim line)))
        (cond
         ((string-prefix-p "|-" tr)
          (when rows-data
            (setf (cdr (car rows-data)) t)
            (setq prev-hi t)))
         ((string-prefix-p "|" tr)
          (let* ((inner (string-remove-suffix "|" (string-remove-prefix "|" tr)))
                 (cols (mapcar #'string-trim (split-string inner "|"))))
            (push (cons cols nil) rows-data))))))
    (setq rows-data (nreverse rows-data))
    (ignore prev-hi)
    (when rows-data
      (let* ((nrows (length rows-data))
             (ncols (apply #'max (mapcar (lambda (r) (length (car r))) rows-data)))
             (cells nil))
        (cl-loop for r from 0 below nrows
                 for row in rows-data do
                 (let ((cols (car row))
                       (hi (cdr row)))
                   (cl-loop for c from 0 below ncols do
                            (let ((val (or (nth c cols) "")))
                              (push `((row . ,r)
                                      (col . ,c)
                                      (rowspan . 1)
                                      (colspan . 1)
                                      (text . ,val)
                                      (align . "left")
                                      (highlighted . ,(if hi t :json-false))
                                      (bold . ,(if hi t :json-false))
                                      (italic . :json-false)
                                      (underline . :json-false)
                                      (strikethrough . :json-false))
                                    cells)))))
        `((rows . ,nrows)
          (columns . ,ncols)
          (cells . ,(vconcat (nreverse cells))))))))

(defun emacs-minder-edit-node-table ()
  "Edit the selected node table using native Emacs `org-mode' table alignment."
  (interactive)
  (let* ((sel (alist-get 'selected emacs-minder--state))
         (nid (and sel (alist-get 'id sel)))
         (tbl (and sel (alist-get 'table sel)))
         (src (current-buffer))
         (buf (get-buffer-create (format "*Minder Table [%s]*" (or nid 0)))))
    (with-current-buffer buf
      (erase-buffer)
      (insert (emacs-minder--table-to-org-string tbl))
      (when (fboundp 'org-mode) (org-mode))
      (goto-char (point-min))
      (setq emacs-minder--source-buffer src
            emacs-minder--target-node-id nid
            emacs-minder--subedit-kind 'table)
      (emacs-minder-subedit-mode 1)
      (setq header-line-format " Edit Org table (TAB aligns) -> C-c C-c to commit, C-c C-k to abort"))
    (pop-to-buffer buf)))

(defun emacs-minder-toggle-fold () (interactive) (emacs-minder--cmd '((op . "toggle_fold"))))

(defun emacs-minder-fold-all (arg)
  "Toggle folding all subtrees; with prefix ARG unfold all."
  (interactive "P")
  (emacs-minder--cmd `((op . "fold_all") (fold . ,(if arg :json-false t)))))

(defun emacs-minder-toggle-task () (interactive) (emacs-minder--cmd '((op . "toggle_task"))))

(defun emacs-minder-set-todo-keyword ()
  "Set Org TODO state on the selected node."
  (interactive)
  (let ((kw (completing-read "TODO state (empty clears): "
                             '("TODO" "NEXT" "FEEDBACK" "VERIFY" "DONE" "CANCELED" "")
                             nil nil)))
    (emacs-minder--cmd `((op . "set_todo_keyword")
                         (keyword . ,(if (string-empty-p kw) nil kw))))))

(defun emacs-minder-balance () (interactive) (emacs-minder--cmd '((op . "balance"))))
(defun emacs-minder-move-sibling-up () (interactive) (emacs-minder--cmd '((op . "move_sibling") (delta . -1))))
(defun emacs-minder-move-sibling-down () (interactive) (emacs-minder--cmd '((op . "move_sibling") (delta . 1))))

(defun emacs-minder-choose-layout ()
  "Pick one of the 7 Minder layout modes."
  (interactive)
  (let ((choice (completing-read "Layout: "
                                 '("Horizontal" "To right" "To left" "Vertical" "Upwards" "Downwards" "Manual")
                                 nil t)))
    (emacs-minder--cmd `((op . "set_layout") (layout . ,choice)))))

(defun emacs-minder-choose-linktype ()
  "Pick branch link curve style."
  (interactive)
  (let ((choice (completing-read "Link style: " '("curved" "rounded" "squared" "straight") nil t)))
    (emacs-minder--cmd `((op . "set_linktype") (linktype . ,choice)))))

(defun emacs-minder-choose-nodeborder ()
  "Pick node border style."
  (interactive)
  (let ((choice (completing-read "Node border: " '("underlined" "rounded" "squared" "pill" "bracket" "none") nil t)))
    (emacs-minder--cmd `((op . "set_nodeborder") (nodeborder . ,choice)))))

(defun emacs-minder-set-font ()
  "Set mind map Pango font description (e.g. `Sans 12', `JetBrainsMono 11')."
  (interactive)
  (let ((f (read-string "Pango font description: " "Sans 12")))
    (unless (string-empty-p f)
      (emacs-minder--cmd `((op . "set_font") (font . ,f))))))

(defun emacs-minder-choose-theme ()
  "Switch mind map theme preset."
  (interactive)
  (let ((th (completing-read "Theme: " '("default" "dark" "solarized_light" "solarized_dark") nil t)))
    (let ((emacs-minder-sync-emacs-theme nil))
      (emacs-minder--cmd `((op . "set_theme") (theme . ,th))))))

(defun emacs-minder-toggle-transparent-bg ()
  "Toggle transparent canvas background vs opaque theme background."
  (interactive)
  (setq emacs-minder-transparent-background (not emacs-minder-transparent-background))
  (emacs-minder--cmd `((op . "set_transparent_bg")
                       (enabled . ,(if emacs-minder-transparent-background t :json-false)))))

(defun emacs-minder-connect () (interactive) (emacs-minder--cmd '((op . "start_or_finish_connection"))))

(defun emacs-minder-set-url ()
  "Set or open hyperlink URL on the selected node."
  (interactive)
  (let* ((sel (alist-get 'selected emacs-minder--state))
         (cur (or (and sel (alist-get 'url sel)) ""))
         (u (read-string "URL (blank clears): " cur)))
    (emacs-minder--cmd `((op . "set_url") (url . ,(if (string-empty-p u) nil u))))))

(defun emacs-minder-open-url ()
  "Open hyperlink on selected node via `browse-url'."
  (interactive)
  (let* ((sel (alist-get 'selected emacs-minder--state))
         (u (and sel (alist-get 'url sel))))
    (if (and u (not (string-empty-p u)))
        (browse-url u)
      (message "Selected node has no URL"))))

(defun emacs-minder-set-tags ()
  "Edit comma/space separated tags on selected node."
  (interactive)
  (let* ((sel (alist-get 'selected emacs-minder--state))
         (cur (mapconcat #'identity (and sel (alist-get 'tags sel)) ","))
         (raw (read-string "Tags (comma separated): " cur))
         (tags (cl-remove-if #'string-empty-p (mapcar #'string-trim (split-string raw "[,:]")))))
    (emacs-minder--cmd `((op . "set_tags") (tags . ,(vconcat tags))))))

(defun emacs-minder-set-callout ()
  "Attach or clear callout annotation on selected node."
  (interactive)
  (let* ((sel (alist-get 'selected emacs-minder--state))
         (cur (or (and sel (alist-get 'callout sel)) ""))
         (txt (read-string "Callout text (blank removes): " cur)))
    (emacs-minder--cmd `((op . "set_callout") (text . ,(if (string-empty-p txt) nil txt))))))

(defun emacs-minder-attach-image ()
  "Attach an image file (PNG, JPG, SVG, etc.) to the selected node."
  (interactive)
  (let ((file (read-file-name "Attach image file: " nil nil t)))
    (emacs-minder--cmd `((op . "attach_image_file") (path . ,(expand-file-name file)) (size . 220.0)))))

(defun emacs-minder-detach-image () (interactive) (emacs-minder--cmd '((op . "detach_image"))))

(defun emacs-minder-paste-clipboard-image ()
  "Grab PNG from Wayland clipboard (`wl-paste') and attach to selected node."
  (interactive)
  (unless (executable-find "wl-paste")
    (user-error "wl-paste not found in PATH"))
  (let* ((tmp (make-temp-file "minder-clip-" nil ".png"))
         (buf (current-buffer))
         (proc (make-process
                :name "minder-wl-paste"
                :buffer nil
                :command (list "sh" "-c" (format "wl-paste -t image/png > %s" (shell-quote-argument tmp)))
                :sentinel
                (lambda (p _ev)
                  (when (eq (process-status p) 'exit)
                    (if (and (zerop (process-exit-status p))
                             (> (file-attribute-size (file-attributes tmp)) 0)
                             (buffer-live-p buf))
                        (with-current-buffer buf
                          (emacs-minder--cmd `((op . "attach_image_file") (path . ,tmp) (size . 220.0))))
                      (delete-file tmp)
                      (message "No PNG image found in Wayland clipboard")))))))
    (ignore proc)))

(defun emacs-minder-vectorize-clipboard-png ()
  "Trace clipboard bitmap with `potrace' into SVG and attach to selected node."
  (interactive)
  (unless (and (executable-find "wl-paste") (executable-find "potrace"))
    (user-error "Requires both wl-paste and potrace in PATH"))
  (let* ((svg (make-temp-file "minder-vec-" nil ".svg"))
         (buf (current-buffer))
         (cmd (format "wl-paste -t image/png | convert png:- pnm:- | potrace -s -o %s -"
                      (shell-quote-argument svg))))
    (make-process
     :name "minder-potrace"
     :buffer nil
     :command (list "sh" "-c" cmd)
     :sentinel
     (lambda (p _ev)
       (when (eq (process-status p) 'exit)
         (if (and (zerop (process-exit-status p))
                  (file-exists-p svg)
                  (> (file-attribute-size (file-attributes svg)) 0)
                  (buffer-live-p buf))
             (with-current-buffer buf
               (emacs-minder--cmd `((op . "attach_image_file") (path . ,svg) (size . 220.0))))
           (delete-file svg)
           (message "Vectorization failed (check imagemagick convert / clipboard)")))))))

(defun emacs-minder-zoom-in () (interactive) (emacs-minder--cmd '((op . "zoom") (factor . 1.2))))
(defun emacs-minder-zoom-out () (interactive) (emacs-minder--cmd '((op . "zoom") (factor . 0.8333))))
(defun emacs-minder-zoom-reset () (interactive) (emacs-minder--cmd '((op . "zoom_reset"))))
(defun emacs-minder-zoom-fit () (interactive) (emacs-minder--cmd '((op . "zoom_fit"))))
(defun emacs-minder-center () (interactive) (emacs-minder--cmd '((op . "center_on_selected"))))

(defun emacs-minder-pan-left () (interactive) (emacs-minder--cmd '((op . "pan") (dx . -120.0) (dy . 0.0))))
(defun emacs-minder-pan-right () (interactive) (emacs-minder--cmd '((op . "pan") (dx . 120.0) (dy . 0.0))))
(defun emacs-minder-pan-up () (interactive) (emacs-minder--cmd '((op . "pan") (dx . 0.0) (dy . -120.0))))
(defun emacs-minder-pan-down () (interactive) (emacs-minder--cmd '((op . "pan") (dx . 0.0) (dy . 120.0))))

(defun emacs-minder-undo () (interactive) (emacs-minder--cmd '((op . "undo"))))
(defun emacs-minder-redo () (interactive) (emacs-minder--cmd '((op . "redo"))))

(defun emacs-minder-search ()
  "Search nodes by title, note, or tags."
  (interactive)
  (let ((q (read-string "Search mind map: ")))
    (emacs-minder--cmd `((op . "search") (query . ,q)))))

(defun emacs-minder-search-next () (interactive) (emacs-minder--cmd '((op . "search_next"))))

(defun emacs-minder-export-png ()
  "Export full mind map diagram as a transparent PNG file."
  (interactive)
  (let ((out (read-file-name "Export full map PNG to: " nil nil nil
                             (concat (file-name-base (or (emacs-minder--backing-file) "mindmap")) ".png"))))
    (emacs-minder-core-export-png emacs-minder--handle (expand-file-name out) 2400)
    (message "Exported PNG to %s" out)))

(defun emacs-minder-open-source-org ()
  "Open the underlying `.org' (or XML) file in standard text mode."
  (interactive)
  (let ((f (emacs-minder--backing-file)))
    (unless (and f (file-exists-p f))
      (user-error "No file associated with this mind map"))
    (let ((buf (find-file-noselect f t)))
      (with-current-buffer buf
        (when (derived-mode-p 'emacs-minder-mode)
          (if (string-suffix-p ".org" (downcase f))
              (org-mode)
            (xml-mode))))
      (pop-to-buffer buf))))

(defun emacs-minder-help ()
  "Display keybinding summary for `emacs-minder-mode'."
  (interactive)
  (message "Nav: arrows/hjkl  Add: TAB(child) o(sib) P(parent) R(root)  Edit: RET N(note) v(table)  Fold: f/F  Layout: L B r b  Zoom: = - 0 z  Image: I M-y  Save: C-x C-s"))

;;; Mouse interaction

(defun emacs-minder--mouse-click (event)
  "Select/toggle node under mouse click EVENT."
  (interactive "e")
  (let* ((pos (event-start event))
         (xy (posn-object-x-y pos)))
    (when (and xy emacs-minder--handle)
      (let* ((hit (emacs-minder--parse-json
                   (emacs-minder-core-hit-test emacs-minder--handle (car xy) (cdr xy))))
             (kind (alist-get 'kind hit))
             (nid (alist-get 'node_id hit)))
        (pcase kind
          ("fold"
           (emacs-minder--cmd `((op . "select_node") (id . ,nid)))
           (emacs-minder--cmd `((op . "toggle_fold") (id . ,nid))))
          ("task"
           (emacs-minder--cmd `((op . "select_node") (id . ,nid)))
           (emacs-minder--cmd `((op . "toggle_task") (id . ,nid))))
          ("node"
           (emacs-minder--cmd `((op . "select_node") (id . ,nid))))
          (_
           (emacs-minder--cmd '((op . "select_clear")))))))))

(defun emacs-minder--mouse-double-click (event)
  "Edit node under mouse double-click EVENT."
  (interactive "e")
  (emacs-minder--mouse-click event)
  (when (alist-get 'selected_node emacs-minder--state)
    (emacs-minder-edit-node-text)))

(defun emacs-minder--mouse-drag-pan (event)
  "Pan canvas when dragging on background."
  (interactive "e")
  (let* ((p1 (posn-x-y (event-start event)))
         (p2 (posn-x-y (event-end event))))
    (when (and p1 p2 emacs-minder--handle)
      (let ((dx (- (car p1) (car p2)))
            (dy (- (cdr p1) (cdr p2))))
        (when (> (+ (abs dx) (abs dy)) 3)
          (emacs-minder--cmd `((op . "pan") (dx . ,(float dx)) (dy . ,(float dy)))))))))

;;; Keymap & Major Mode

(defvar emacs-minder-mode-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map t)
    ;; Navigation
    (define-key map (kbd "<left>")  #'emacs-minder-nav-left)
    (define-key map (kbd "<right>") #'emacs-minder-nav-right)
    (define-key map (kbd "<up>")    #'emacs-minder-nav-up)
    (define-key map (kbd "<down>")  #'emacs-minder-nav-down)
    (define-key map (kbd "h")       #'emacs-minder-nav-left)
    (define-key map (kbd "l")       #'emacs-minder-nav-right)
    (define-key map (kbd "k")       #'emacs-minder-nav-up)
    (define-key map (kbd "j")       #'emacs-minder-nav-down)
    (define-key map (kbd "n")       #'emacs-minder-nav-down)
    (define-key map (kbd "p")       #'emacs-minder-nav-up)
    (define-key map (kbd "^")       #'emacs-minder-nav-parent)
    (define-key map (kbd "]")       #'emacs-minder-nav-next-root)

    ;; Structure editing
    (define-key map (kbd "TAB")        #'emacs-minder-add-child)
    (define-key map (kbd "<tab>")      #'emacs-minder-add-child)
    (define-key map (kbd "a")          #'emacs-minder-add-child)
    (define-key map (kbd "o")          #'emacs-minder-add-sibling)
    (define-key map (kbd "S-<return>") #'emacs-minder-add-sibling)
    (define-key map (kbd "P")          #'emacs-minder-add-parent)
    (define-key map (kbd "R")          #'emacs-minder-add-root)
    (define-key map (kbd "d")          #'emacs-minder-delete-selected)
    (define-key map (kbd "<delete>")   #'emacs-minder-delete-selected)
    (define-key map (kbd "DEL")        #'emacs-minder-delete-selected)
    (define-key map (kbd "C-S-<up>")   #'emacs-minder-move-sibling-up)
    (define-key map (kbd "C-S-<down>") #'emacs-minder-move-sibling-down)

    ;; Node content
    (define-key map (kbd "RET")   #'emacs-minder-edit-node-text)
    (define-key map (kbd "e")     #'emacs-minder-edit-node-text)
    (define-key map (kbd "N")     #'emacs-minder-edit-node-note)
    (define-key map (kbd "v")     #'emacs-minder-edit-node-table)
    (define-key map (kbd "f")     #'emacs-minder-toggle-fold)
    (define-key map (kbd "F")     #'emacs-minder-fold-all)
    (define-key map (kbd "t")     #'emacs-minder-toggle-task)
    (define-key map (kbd "T")     #'emacs-minder-set-todo-keyword)
    (define-key map (kbd "c")     #'emacs-minder-connect)
    (define-key map (kbd "u")     #'emacs-minder-undo)
    (define-key map (kbd "U")     #'emacs-minder-set-url)
    (define-key map (kbd "C-c U") #'emacs-minder-open-url)
    (define-key map (kbd "g")     #'emacs-minder-set-tags)
    (define-key map (kbd "K")     #'emacs-minder-set-callout)
    (define-key map (kbd "I")     #'emacs-minder-attach-image)
    (define-key map (kbd "X")     #'emacs-minder-detach-image)
    (define-key map (kbd "M-y")   #'emacs-minder-paste-clipboard-image)
    (define-key map (kbd "M-v")   #'emacs-minder-vectorize-clipboard-png)

    ;; Layout, style, zoom, pan
    (define-key map (kbd "L")         #'emacs-minder-choose-layout)
    (define-key map (kbd "B")         #'emacs-minder-choose-linktype)
    (define-key map (kbd "r")         #'emacs-minder-choose-nodeborder)
    (define-key map (kbd "M-f")       #'emacs-minder-set-font)
    (define-key map (kbd "b")         #'emacs-minder-balance)
    (define-key map (kbd "C-c t")     #'emacs-minder-choose-theme)
    (define-key map (kbd "C-c T")     #'emacs-minder-toggle-transparent-bg)
    (define-key map (kbd "=")         #'emacs-minder-zoom-in)
    (define-key map (kbd "+")         #'emacs-minder-zoom-in)
    (define-key map (kbd "-")         #'emacs-minder-zoom-out)
    (define-key map (kbd "0")         #'emacs-minder-zoom-reset)
    (define-key map (kbd "z")         #'emacs-minder-zoom-fit)
    (define-key map (kbd "C-l")       #'emacs-minder-center)
    (define-key map (kbd "M-<left>")  #'emacs-minder-pan-left)
    (define-key map (kbd "M-<right>") #'emacs-minder-pan-right)
    (define-key map (kbd "M-<up>")    #'emacs-minder-pan-up)
    (define-key map (kbd "M-<down>")  #'emacs-minder-pan-down)

    ;; Undo / redo / search / IO
    (define-key map [remap save-buffer] #'emacs-minder-save)
    (define-key map (kbd "C-/") #'emacs-minder-undo)
    (define-key map (kbd "C-?") #'emacs-minder-redo)
    (define-key map (kbd "C-r") #'emacs-minder-redo)
    (define-key map (kbd "/")   #'emacs-minder-search)
    (define-key map (kbd ";")   #'emacs-minder-search-next)
    (define-key map (kbd "E")   #'emacs-minder-export-png)
    (define-key map (kbd "O")   #'emacs-minder-open-source-org)
    (define-key map (kbd "?")   #'emacs-minder-help)
    (define-key map (kbd "q")   #'quit-window)

    ;; Mouse
    (define-key map [mouse-1]        #'emacs-minder--mouse-click)
    (define-key map [double-mouse-1] #'emacs-minder--mouse-double-click)
    (define-key map [drag-mouse-1]   #'emacs-minder--mouse-drag-pan)
    (define-key map [wheel-up]       #'emacs-minder-zoom-in)
    (define-key map [wheel-down]     #'emacs-minder-zoom-out)
    (define-key map [mouse-4]        #'emacs-minder-zoom-in)
    (define-key map [mouse-5]        #'emacs-minder-zoom-out)
    map)
  "Keymap for `emacs-minder-mode'.")

;;;###autoload
(define-derived-mode emacs-minder-mode special-mode "Minder"
  "Native Cairo/LaTeX Mind Map major mode supporting `.minder' and `.org'."
  (emacs-minder-ensure-module)
  (setq buffer-read-only t
        truncate-lines t
        cursor-type nil)
  (setq-local show-trailing-whitespace nil)
  (let ((file (and (emacs-minder--backing-file)
                   (expand-file-name (emacs-minder--backing-file)))))
    (setq emacs-minder--handle
          (if file
              (emacs-minder-core-open-file file)
            (emacs-minder-core-new "Central Topic")))
    (when file
      (setq emacs-minder--file-path file))
    (pcase-let ((`(,w . ,h) (emacs-minder--viewport-pixels)))
      (setq emacs-minder--state
            (emacs-minder--parse-json
             (emacs-minder-core-set-viewport emacs-minder--handle w h)))
      (when (and file emacs-minder-auto-fit-on-open)
        (emacs-minder--cmd-raw '((op . "zoom_fit")))))
    (emacs-minder--sync-theme-to-core)
    (emacs-minder--render))
  (setq-local revert-buffer-function #'emacs-minder--revert-buffer)
  (add-hook 'write-contents-functions #'emacs-minder--write-contents nil t)
  (add-hook 'kill-buffer-hook #'emacs-minder--cleanup-buffer nil t)
  (add-hook 'window-size-change-functions #'emacs-minder--on-window-size-change)
  (when (boundp 'enable-theme-functions)
    (add-hook 'enable-theme-functions #'emacs-minder--on-theme-change))
  (setq emacs-minder--timer
        (run-with-timer 0.25 0.25 #'emacs-minder--poll-tick (current-buffer))))

;;;###autoload
(defun emacs-minder-new (&optional title)
  "Create and display a fresh mind map buffer with optional TITLE."
  (interactive)
  (let ((buf (generate-new-buffer (format "*Minder: %s*" (or title "Untitled")))))
    (with-current-buffer buf
      (emacs-minder-mode)
      (when title
        (emacs-minder--cmd `((op . "set_text") (id . 0) (text . ,title)))))
    (switch-to-buffer buf)))

;;;###autoload
(defun emacs-minder-open-org (&optional file)
  "Open FILE (or current `org-mode' file) in a dedicated Minder Mind Map buffer."
  (interactive)
  (let* ((target (or file buffer-file-name)))
    (unless target
      (user-error "Current buffer is not visiting an Org file"))
    (when (and buffer-file-name
               (equal (expand-file-name target) (expand-file-name buffer-file-name))
               (buffer-modified-p)
               (y-or-n-p (format "Save %s before opening Mind Map? " (file-name-nondirectory target))))
      (save-buffer))
    (let* ((abs (expand-file-name target))
           (bufname (format "*Minder: %s*" (file-name-nondirectory abs)))
           (buf (get-buffer-create bufname)))
      (with-current-buffer buf
        (when (derived-mode-p 'emacs-minder-mode)
          (emacs-minder--cleanup-buffer))
        (setq emacs-minder--file-path abs)
        (emacs-minder-mode)
        (setq emacs-minder--file-path abs)
        (rename-buffer bufname t))
      (switch-to-buffer buf))))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.minder\\'" . emacs-minder-mode))

(provide 'emacs-minder)
;;; emacs-minder.el ends here
