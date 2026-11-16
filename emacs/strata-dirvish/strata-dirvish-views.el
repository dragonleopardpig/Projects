;;; strata-dirvish-views.el --- Browser views, sorting, tree, icons, compact, chrome -*- lexical-binding: t; -*-

;;; Commentary:
;; Implements all four Strata browser views (Columns/Miller, List+Tree,
;; Compact horizontal multi-column, Icons thumbnail grid), unified sorting &
;; grouping, per-folder LRU memory, custom folder colors/icons, Dirvish
;; attributes, and Strata header breadcrumbs / footer mode-line.

;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'easymenu)
(require 'tooltip)
(require 'dirvish)
(require 'dirvish-widgets nil t)
(require 'dirvish-vc nil t)
(require 'dirvish-subtree nil t)
(require 'dirvish-collapse nil t)
(require 'dirvish-emerge nil t)
(require 'subr-x)
(require 'strata-dirvish-prefs)
(require 'strata-dirvish-devices)

(declare-function strata-open-location "strata-dirvish-panes" (loc &optional record-history))
(declare-function strata-active-pane "strata-dirvish-panes" ())
(declare-function strata-active-tab "strata-dirvish-panes" ())
(declare-function strata-pane-active-p "strata-dirvish-panes" (&optional win))
(declare-function strata-panes--pane-for-window "strata-dirvish-panes" (win))
(declare-function strata-panes--sync-active-pane-from-window "strata-dirvish-panes" (&optional win))
(declare-function strata-panes--valid-main-window-p "strata-dirvish-panes" (win))
(declare-function strata-panes--window-dir "strata-dirvish-panes" (&optional win))
(declare-function strata-pane-state-id "strata-dirvish-panes" (cl-x))
(declare-function strata-pane-state-buffer "strata-dirvish-panes" (cl-x))
(declare-function strata-tab-state-pane1 "strata-dirvish-panes" (cl-x))
(declare-function strata-tab-state-pane2 "strata-dirvish-panes" (cl-x))
(declare-function strata-split-active-p "strata-dirvish-panes" ())
(declare-function strata-dirvish--flatten-layout "strata-dirvish-panes" ())
(declare-function strata-pane-clipboard-summary "strata-dirvish-ops" ())
(declare-function strata--transfer-files "strata-dirvish-ops" (files dest-dir mode &optional keep-both-default replace-default))
(declare-function strata-clear-all-marks "strata-dirvish-keys" ())
(declare-function strata-preview-at-point "strata-dirvish-previews" ())
(declare-function strata-preview-enter-at-point "strata-dirvish-previews" ())
(declare-function strata-preview-edit-file "strata-dirvish-previews" (file))
(declare-function strata-open-or-edit-at-point "strata-dirvish-previews" ())
(defvar strata-preview-standalone-window)
(defvar strata-sidebar-window)

(defvar strata-active-chord nil
  "Current active multi-key chord label shown in footer (e.g. \"g _\").")

(defvar strata-thumbnail-dir
  (expand-file-name "thumbnails" strata-dirvish-state-dir)
  "Directory storing cached PNG thumbnails for Icons view.")

(defvar strata-thumbnail-pending (make-hash-table :test #'equal)
  "Pending async thumbnail jobs keyed by path.")

(defvar-local strata-local-view-mode nil
  "Buffer-local active view mode overriding/mirroring global preference.")

(defvar-local strata-local-filter nil
  "Active filter string inside current pane buffer.")

(defvar-local strata-visual-anchor nil
  "File path where 10xer visual selection started.")

;;;; File Selection & Cursor Introspection Across All 4 Views

(defun strata-current-file ()
  "Return absolute path of entry under point in any Strata view buffer."
  (or (get-text-property (point) 'strata-entry)
      (get-text-property (line-beginning-position) 'strata-entry)
      (and (derived-mode-p 'dired-mode)
           (ignore-errors (dired-get-filename nil t)))
      (when-let ((tr (get-text-property (line-beginning-position) 'strata-trash-item)))
        (plist-get tr :file))
      (get-text-property (line-beginning-position) 'strata-recent-path)))

(defvar-local strata--selection-anchor-entry nil
  "Anchor path for Shift-click and Shift-arrow range multi-selection.")

(defvar-local strata--empty-click-p nil
  "Non-nil while an empty-space click leaves the browser without a current item.")

(defvar-local strata--selection-range-active nil
  "Non-nil while extending the current keyboard or click range.")

(defvar-local strata--selection-base-keys nil
  "Marks preserved outside an additive Ctrl+Shift range.")

(defvar-local strata--selection-range-additive nil
  "Whether the active range preserves marks outside its bounds.")

(defun strata-view--reset-selection-range (&optional anchor)
  "Finish the active range and use ANCHOR for the next range."
  (setq strata--selection-anchor-entry anchor
        strata--selection-range-active nil
        strata--selection-base-keys nil
        strata--selection-range-additive nil))

(defun strata-view--selection-post-command ()
  "Start the next range at point after ordinary navigation or file commands."
  (unless (eobp) (setq strata--empty-click-p nil))
  (unless (or (null this-command)
              (bound-and-true-p strata-mouse--drag-state)
              (memq this-command
                    '(strata-shift-select-next strata-shift-select-prev
                      strata-shift-select-right strata-shift-select-left
                      strata-shift-select-first strata-shift-select-last
                      strata-mouse-range-select strata-mouse-add-range-select
                      strata-visual-toggle)))
    (strata-view--reset-selection-range (strata-current-file))))

(defun strata-view--dirvish-post-command (original)
  "Run ORIGINAL without moving an empty-space selection onto the last file."
  (unless (and strata--empty-click-p (eobp))
    (funcall original)))

(defun strata--path-key (path)
  "Normalize PATH into a canonical comparison key."
  (and path (directory-file-name (expand-file-name path))))

(defun strata-marked-files-only ()
  "Return explicitly marked paths in the current browser buffer, or nil."
  (cond
   ((derived-mode-p 'dired-mode)
    (let ((marked (ignore-errors (dired-get-marked-files nil nil nil t))))
      (cond
       ((and marked (eq (car marked) t)) (cdr marked))
       ((and marked
             (save-excursion
               (goto-char (point-min))
               (re-search-forward dired-re-mark nil t)))
        marked))))
   ((derived-mode-p 'strata-compact-mode 'strata-icons-mode)
    (when-let ((m (bound-and-true-p strata-marked-entries)))
      (cl-remove-if-not #'file-exists-p (reverse m))))))

(defun strata-selected-files ()
  "Return marked file paths in current Strata view, or file at point."
  (or (strata-marked-files-only)
      (when-let ((cur (strata-current-file)))
        (list cur))))

(defvar-local strata--selection-overlays nil
  "Buffer-local selection overlays highlighting the active file or folder name.")

(defun strata--clear-selection-highlight ()
  "Remove active selection highlight overlays from the current buffer."
  (mapc #'delete-overlay strata--selection-overlays)
  (setq-local strata--selection-overlays nil))

(defun strata--add-selection-overlay (beg end)
  "Highlight BEG..END with `strata-entry-selected' in current buffer."
  (when (and beg end (< beg end))
    (let ((ov (make-overlay beg end nil t nil)))
      (overlay-put ov 'face 'strata-entry-selected)
      (overlay-put ov 'priority 60)
      (push ov strata--selection-overlays))))

(defun strata--prop-span-at (pos prop &optional limit-beg limit-end)
  "Return (BEG . END) bounds of continuous non-nil PROP run containing POS."
  (let* ((lb (or limit-beg (point-min)))
         (le (or limit-end (point-max)))
         (val (and (>= pos lb) (< pos le) (get-text-property pos prop))))
    (when val
      (let* ((beg (if (or (= pos lb)
                          (not (equal (get-text-property (1- pos) prop) val)))
                      pos
                    (or (previous-single-property-change pos prop nil lb) lb)))
             (end (or (next-single-property-change pos prop nil le) le)))
        (cons beg end)))))

(defun strata--highlight-marked-dired (cur-beg cur-end)
  "Overlay marked filenames in Dired excluding CUR-BEG..CUR-END."
  (when (derived-mode-p 'dired-mode)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward dired-re-mark nil t)
        ;; Filename parsing can return to the beginning of an unrecognized
        ;; row.  Keep the scan after its mark so that row cannot repeat.
        (save-excursion
          (ignore-errors
            (when-let* ((beg (dired-move-to-filename))
                        (end (dired-move-to-end-of-filename t)))
              (unless (and cur-beg cur-end (= beg cur-beg) (= end cur-end))
                (strata--add-selection-overlay beg end)))))))))

(defun strata--highlight-marked-spans (prop marked-keys &optional cur-span)
  "Overlay spans carrying PROP whose `strata-entry' is in MARKED-KEYS."
  (when marked-keys
    (let ((pos (point-min)))
      (while (< pos (point-max))
        (let ((next (or (next-single-property-change pos prop) (point-max))))
          (when (get-text-property pos prop)
            (when-let ((key (strata--path-key (get-text-property pos 'strata-entry))))
              (when (and (member key marked-keys)
                         (not (and cur-span (= pos (car cur-span)) (= next (cdr cur-span)))))
                (strata--add-selection-overlay pos next))))
          (setq pos next))))))

(defun strata-view--update-selection-highlight ()
  "Highlight the active and multi-marked file or directory names across all views."
  (when (derived-mode-p 'dired-mode 'strata-compact-mode 'strata-icons-mode)
    (strata--clear-selection-highlight)
    (let ((marked-keys (mapcar #'strata--path-key (bound-and-true-p strata-marked-entries))))
      (cond
       ((derived-mode-p 'dired-mode)
        (let (cur-beg cur-end)
          (ignore-errors
            (save-excursion
              (when-let* ((beg (dired-move-to-filename))
                          (end (dired-move-to-end-of-filename t)))
                (setq cur-beg beg cur-end end)
                (strata--add-selection-overlay beg end))))
          (strata--highlight-marked-dired cur-beg cur-end)))
       ((derived-mode-p 'strata-compact-mode)
        (let* ((p (point))
               (lb (line-beginning-position))
               (le (line-end-position))
               (span (or (strata--prop-span-at p 'strata-entry-label lb le)
                         (when-let ((cur-entry (get-text-property p 'strata-entry)))
                           (let ((cand (next-single-property-change p 'strata-entry-label nil le)))
                             (when (and cand (< cand le)
                                        (equal (get-text-property cand 'strata-entry) cur-entry))
                               (strata--prop-span-at cand 'strata-entry-label lb le)))))))
          (when span
            (strata--add-selection-overlay (car span) (cdr span)))
          (strata--highlight-marked-spans 'strata-entry-label marked-keys span)))
       ((derived-mode-p 'strata-icons-mode)
        (let* ((p (point))
               (idx (and (< p (point-max)) (get-text-property p 'strata-grid-idx)))
               (lb (line-beginning-position))
               (le (line-end-position))
               (span1 (and idx
                           (or (strata--prop-span-at p 'strata-grid-label lb le)
                               (when-let ((cand (next-single-property-change p 'strata-grid-label nil le)))
                                 (when (and (< cand le)
                                            (eql (get-text-property cand 'strata-grid-idx) idx))
                                   (strata--prop-span-at cand 'strata-grid-label lb le))))))
               (span2 nil))
          (when span1
            (strata--add-selection-overlay (car span1) (cdr span1))
            (save-excursion
              (goto-char (car span1))
              (when (= (forward-line 1) 0)
                (let ((q (line-beginning-position))
                      (qe (line-end-position))
                      (found2 nil))
                  (while (and (< q qe) (not found2))
                    (let ((nxt (or (next-single-property-change q 'strata-grid-label-cont nil qe) qe)))
                      (when (and (get-text-property q 'strata-grid-label-cont)
                                 (eql (get-text-property q 'strata-grid-idx) idx))
                        (setq span2 (cons q nxt))
                        (strata--add-selection-overlay q nxt)
                        (setq found2 t))
                      (setq q nxt)))))))
          (strata--highlight-marked-spans 'strata-grid-label marked-keys span1)
          (strata--highlight-marked-spans 'strata-grid-label-cont marked-keys span2)))))))

(defun strata-goto-file (path)
  "Move point to entry matching PATH in current Strata buffer."
  (when path
    (let ((target (directory-file-name (expand-file-name path))))
      (cond
       ((derived-mode-p 'dired-mode)
        (let ((moved (or (ignore-errors (dired-goto-file target))
                         (ignore-errors (dired-goto-file (concat target "/"))))))
          (strata-view--update-selection-highlight)
          moved))
       ((or (derived-mode-p 'strata-compact-mode)
            (derived-mode-p 'strata-icons-mode))
        (let ((pos (point-min))
              (icons-p (derived-mode-p 'strata-icons-mode))
              (lbl-prop (if (derived-mode-p 'strata-icons-mode)
                            'strata-grid-label
                          'strata-entry-label))
              (first-match nil)
              (label-match nil))
          (while (and (< pos (point-max)) (not label-match))
            (let* ((next (or (next-single-property-change pos 'strata-entry) (point-max)))
                   (val (get-text-property pos 'strata-entry)))
              (when (and val (string= (directory-file-name (expand-file-name val)) target))
                (unless first-match (setq first-match pos))
                (let ((lbl (if (get-text-property pos lbl-prop)
                               pos
                             (let ((cand (next-single-property-change pos lbl-prop nil next)))
                               (when (and cand (< cand next)
                                          (get-text-property cand lbl-prop))
                                 cand)))))
                  (when lbl (setq label-match lbl))))
              (setq pos next)))
          (ignore icons-p)
          (when-let ((dest (or label-match first-match)))
            (goto-char dest)
            (strata-view--update-selection-highlight)
            dest)))))))

;;;; Folder Colors & Custom Icons

(defun strata-folder-color-set (dir color-name)
  "Assign COLOR-NAME badge to DIR (`nil' or empty removes customization)."
  (let* ((p (strata-prefs))
         (key (directory-file-name (expand-file-name dir)))
         (tbl (assoc-delete-all key (strata-prefs-folder-colors p))))
    (when (and color-name (not (string-empty-p color-name)))
      (push (cons key color-name) tbl))
    (setf (strata-prefs-folder-colors p) tbl)
    (strata-prefs-save)))

(defun strata-custom-icon-set (path icon-str)
  "Assign custom ICON-STR badge to PATH (`nil' or empty clears it)."
  (let* ((p (strata-prefs))
         (key (directory-file-name (expand-file-name path)))
         (tbl (assoc-delete-all key (strata-prefs-custom-icons p))))
    (when (and icon-str (not (string-empty-p icon-str)))
      (push (cons key icon-str) tbl))
    (setf (strata-prefs-custom-icons p) tbl)
    (strata-prefs-save)))

(defun strata-file--badge-face (path)
  "Return custom face for folder PATH if customized."
  (when-let* ((key (and path (directory-file-name (expand-file-name path))))
              (color (cdr (assoc key (strata-prefs-folder-colors (strata-prefs))))))
    (cdr (assoc (downcase color) strata-folder-color-alist))))

(defconst strata-file--ext-icon-map
  '(("el"       elisp      . font-lock-keyword-face)
    ("elc"      elisp      . shadow)
    ("org"      org        . success)
    ("md"       markdown   . font-lock-type-face)
    ("markdown" markdown   . font-lock-type-face)
    ("nix"      nix        . dired-directory)
    ("rs"       rust       . warning)
    ("py"       python     . font-lock-function-name-face)
    ("js"       js         . warning)
    ("mjs"      js         . warning)
    ("ts"       ts         . font-lock-type-face)
    ("tsx"      ts         . font-lock-type-face)
    ("c"        c          . font-lock-keyword-face)
    ("h"        c          . font-lock-type-face)
    ("cpp"      cpp        . font-lock-keyword-face)
    ("hpp"      cpp        . font-lock-type-face)
    ("cc"       cpp        . font-lock-keyword-face)
    ("go"       go         . font-lock-type-face)
    ("lua"      lua        . font-lock-keyword-face)
    ("sh"       shell      . success)
    ("bash"     shell      . success)
    ("zsh"      shell      . success)
    ("fish"     shell      . success)
    ("json"     json       . font-lock-constant-face)
    ("jsonc"    json       . font-lock-constant-face)
    ("yaml"     yaml       . font-lock-constant-face)
    ("yml"      yaml       . font-lock-constant-face)
    ("toml"     toml       . font-lock-constant-face)
    ("conf"     toml       . shadow)
    ("ini"      toml       . shadow)
    ("html"     html       . warning)
    ("htm"      html       . warning)
    ("css"      css        . font-lock-type-face)
    ("scss"     css        . font-lock-type-face)
    ("pdf"      file-pdf   . error)
    ("zip"      file-zip   . warning)
    ("tar"      file-zip   . warning)
    ("gz"       file-zip   . warning)
    ("xz"       file-zip   . warning)
    ("zst"      file-zip   . warning)
    ("7z"       file-zip   . warning)
    ("rar"      file-zip   . warning)
    ("csv"      file-table . success)
    ("tsv"      file-table . success)
    ("xlsx"     file-table . success)
    ("ods"      file-table . success)
    ("docx"     file-word  . font-lock-type-face)
    ("odt"      file-word  . font-lock-type-face)
    ("rtf"      file-word  . font-lock-type-face)
    ("stl"      file-3d    . font-lock-type-face)
    ("obj"      file-3d    . font-lock-type-face)
    ("3mf"      file-3d    . font-lock-type-face)
    ("gcode"    file-3d    . warning)
    ("ttf"      font       . font-lock-constant-face)
    ("otf"      font       . font-lock-constant-face)
    ("woff"     font       . font-lock-constant-face)
    ("woff2"    font       . font-lock-constant-face)
    ("png"      file-image . font-lock-string-face)
    ("jpg"      file-image . font-lock-string-face)
    ("jpeg"     file-image . font-lock-string-face)
    ("webp"     file-image . font-lock-string-face)
    ("gif"      file-image . font-lock-string-face)
    ("svg"      file-image . font-lock-string-face)
    ("mp3"      file-audio . font-lock-builtin-face)
    ("flac"     file-audio . font-lock-builtin-face)
    ("ogg"      file-audio . font-lock-builtin-face)
    ("wav"      file-audio . font-lock-builtin-face)
    ("m4a"      file-audio . font-lock-builtin-face)
    ("mp4"      file-video . error)
    ("mkv"      file-video . error)
    ("webm"     file-video . error)
    ("mov"      file-video . error)
    ("avi"      file-video . error)
    ("db"       database   . font-lock-constant-face)
    ("sqlite"   database   . font-lock-constant-face)
    ("sqlite3"  database   . font-lock-constant-face)
    ("txt"      file-text  . default)
    ("log"      file-text  . shadow))
  "Extension -> (ICON-KIND . FACE) lookup for verified Nerd Font file icons.")

(defun strata-file--glyph (path &optional dir-p)
  "Return crisp verified Nerd Font icon glyph for PATH honoring custom icons."
  (let* ((key (and path (directory-file-name (expand-file-name path))))
         (custom (cdr (assoc key (strata-prefs-custom-icons (strata-prefs)))))
         (cface (strata-file--badge-face path))
         (fname (downcase (file-name-nondirectory (or path ""))))
         (ext (downcase (or (file-name-extension fname) ""))))
    (cond
     (custom (propertize custom 'face (or cface 'dired-directory)))
     (dir-p
      (let* ((mkind (strata-path-mount-kind path))
             (kind (cond
                    ((eq mkind 'cloud) 'cloud)
                    ((eq mkind 'network) 'network)
                    ((file-symlink-p path) 'folder-open)
                    ((strata-path-unsafe-probe-p path) 'folder)
                    ((file-exists-p (expand-file-name ".git" path)) 'folder-git)
                    (t 'folder))))
        (strata-icon-glyph kind (or cface 'dired-directory)
                           (unless (memq kind '(cloud network)) "▸"))))
     ((string-prefix-p ".git" fname)
      (strata-icon-glyph 'git 'warning "·"))
     ((file-symlink-p path)
      (strata-icon-glyph 'symlink 'font-lock-type-face "→"))
     (t
      (let ((hit (cdr (assoc ext strata-file--ext-icon-map))))
        (strata-icon-glyph (or (car hit) 'file) (or (cdr hit) 'default) "·"))))))

;;;; Sorting, Natural Order & Type Classification Engine

(defun strata-natural-compare (a b &optional case-sensitive)
  "Compare strings A and B naturally so file2 < file10."
  (let ((sa (if case-sensitive a (downcase a)))
        (sb (if case-sensitive b (downcase b)))
        (i 0) (j 0)
        (la (length a)) (lb (length b))
        (cmp 0))
    (while (and (= cmp 0) (< i la) (< j lb))
      (let ((ca (aref sa i))
            (cb (aref sb j)))
        (if (and (<= ?0 ca ?9) (<= ?0 cb ?9))
            (let ((ni i) (nj j))
              (while (and (< ni la) (<= ?0 (aref sa ni) ?9)) (setq ni (1+ ni)))
              (while (and (< nj lb) (<= ?0 (aref sb nj) ?9)) (setq nj (1+ nj)))
              (let* ((va (string-to-number (substring sa i ni)))
                     (vb (string-to-number (substring sb j nj))))
                (cond ((< va vb) (setq cmp -1))
                      ((> va vb) (setq cmp 1))
                      ((< (- ni i) (- nj j)) (setq cmp -1))
                      ((> (- ni i) (- nj j)) (setq cmp 1)))
                (setq i ni j nj)))
          (cond ((< ca cb) (setq cmp -1))
                ((> ca cb) (setq cmp 1)))
          (setq i (1+ i) j (1+ j)))))
    (when (= cmp 0)
      (cond ((< (- la i) (- lb j)) (setq cmp -1))
            ((> (- la i) (- lb j)) (setq cmp 1))))
    cmp))

(defun strata-file-type-group (path &optional dir-p)
  "Classify PATH into a Strata type group symbol."
  (if (or dir-p (file-directory-p path))
      'folders
    (let ((ext (downcase (or (file-name-extension path) ""))))
      (cond
       ((member ext '("png" "jpg" "jpeg" "gif" "webp" "svg" "bmp" "tif" "tiff" "avif" "heic" "cr2" "nef" "arw" "dng")) 'images)
       ((member ext '("mp3" "flac" "wav" "ogg" "opus" "m4a" "aac" "wma")) 'audio)
       ((member ext '("mp4" "mkv" "mov" "webm" "avi" "m4v" "flv")) 'video)
       ((member ext '("pdf" "md" "org" "txt" "docx" "odt" "rtf" "epub" "html" "csv" "tsv" "xlsx" "ods")) 'documents)
       ((member ext '("zip" "tar" "gz" "tgz" "bz2" "xz" "zst" "7z" "rar" "iso")) 'archives)
       ((member ext '("el" "rs" "py" "nix" "js" "ts" "tsx" "c" "cpp" "h" "go" "sh" "toml" "json" "yaml" "yml" "css")) 'code)
       (t 'other)))))

(defun strata-file-group-label (grp)
  "Human heading label for group symbol GRP."
  (pcase grp
    ('folders "Folders")
    ('images "Images")
    ('audio "Audio")
    ('video "Video")
    ('documents "Documents")
    ('archives "Archives")
    ('code "Code & Config")
    (_ "Other Files")))

(defun strata-list-directory-entries (dir &optional prefs)
  "Return sorted entry plists for DIR honoring PREFS & active filter.
Each plist contains (:name :path :dir-p :size :mtime :ctime :ext :group)."
  (let* ((p (or prefs (strata-prefs)))
         (show-hidden (strata-prefs-show-hidden p))
         (sort-key (strata-prefs-sort-key p))
         (sort-dir (strata-prefs-sort-direction p))
         (folders-first (strata-prefs-folders-first p))
         (natural (strata-prefs-natural-sort p))
         (case-sens (strata-prefs-case-sensitive-sort p))
         (group-type (strata-prefs-group-by-type p))
         (dir (file-name-as-directory (expand-file-name dir)))
         (names (when (file-directory-p dir)
                  (condition-case nil
                      (directory-files dir nil "\\`[^.]\\|\\`.[^.]" t)
                    (error nil))))
         (flt (when (and strata-local-filter (not (string-empty-p strata-local-filter)))
                strata-local-filter))
         entries)
    (dolist (n names)
      (when (and (or show-hidden (not (string-prefix-p "." n)))
                 (or (null flt) (let ((case-fold-search t))
                                  (string-match-p (regexp-quote flt) n))))
        (let* ((path (expand-file-name n dir))
               (attrs (file-attributes path 'integer))
               (dir-p (eq t (file-attribute-type attrs)))
               (size (or (file-attribute-size attrs) 0))
               (mtime (file-attribute-modification-time attrs))
               (ctime (file-attribute-status-change-time attrs))
               (ext (downcase (or (file-name-extension n) "")))
               (grp (strata-file-type-group path dir-p)))
          (push (list :name n :path path :dir-p dir-p :size size
                      :mtime mtime :ctime ctime :ext ext :group grp)
                entries))))
    (setq entries (nreverse entries))
    (unless (eq sort-key 'unsorted)
      (let* ((group-rank (lambda (g)
                           (pcase g
                             ('folders 0) ('images 1) ('audio 2) ('video 3)
                             ('documents 4) ('code 5) ('archives 6) (_ 7))))
             (desc (eq sort-dir 'desc)))
        (setq entries
              (sort entries
                    (lambda (a b)
                      (let ((da (plist-get a :dir-p))
                            (db (plist-get b :dir-p)))
                        (cond
                         ((and folders-first (not (eq da db))) da)
                         ((and group-type (not (eq (plist-get a :group) (plist-get b :group))))
                          (< (funcall group-rank (plist-get a :group))
                             (funcall group-rank (plist-get b :group))))
                         (t
                          (let ((cmp
                                 (pcase sort-key
                                   ('size (cond ((< (plist-get a :size) (plist-get b :size)) -1)
                                                ((> (plist-get a :size) (plist-get b :size)) 1)
                                                (t 0)))
                                   ('modified (if (time-less-p (plist-get a :mtime) (plist-get b :mtime))
                                                  -1
                                                (if (time-less-p (plist-get b :mtime) (plist-get a :mtime)) 1 0)))
                                   ('created (if (time-less-p (plist-get a :ctime) (plist-get b :ctime))
                                                 -1
                                               (if (time-less-p (plist-get b :ctime) (plist-get a :ctime)) 1 0)))
                                   ('extension
                                    (let ((ea (plist-get a :ext)) (eb (plist-get b :ext)))
                                      (if (string= ea eb) 0 (if (string-lessp ea eb) -1 1))))
                                   ('type
                                    (let ((ra (funcall group-rank (plist-get a :group)))
                                          (rb (funcall group-rank (plist-get b :group))))
                                      (cond ((< ra rb) -1) ((> ra rb) 1) (t 0))))
                                   (_ 0))))
                            (when (= cmp 0)
                              (setq cmp (if natural
                                            (strata-natural-compare (plist-get a :name)
                                                                    (plist-get b :name)
                                                                    case-sens)
                                          (let ((na (if case-sens (plist-get a :name) (downcase (plist-get a :name))))
                                                (nb (if case-sens (plist-get b :name) (downcase (plist-get b :name)))))
                                            (if (string= na nb) 0 (if (string-lessp na nb) -1 1))))))
                            (if desc (> cmp 0) (< cmp 0)))))))))))
    entries))

(defun strata-compute-dired-switches (&optional prefs)
  "Compute `dired-listing-switches' string matching PREFS."
  (let* ((p (or prefs (strata-prefs)))
         (flags (list "-lh"))
         (sk (strata-prefs-sort-key p)))
    (if (strata-prefs-show-hidden p)
        (push "-A" flags)
      (setq flags (delete "-a" flags)))
    (when (strata-prefs-folders-first p)
      (push "--group-directories-first" flags))
    ;; GNU ls defaults to largest/newest first for these keys.  Strata's
    ;; ascending order means smallest/oldest first in every layout.
    (when (if (memq sk '(size modified created))
              (eq (strata-prefs-sort-direction p) 'asc)
            (eq (strata-prefs-sort-direction p) 'desc))
      (push "-r" flags))
    (pcase sk
      ('modified (push "-t" flags))
      ('created (push "--sort=time" flags) (push "--time=birth" flags))
      ('size (push "-S" flags))
      ('extension (push "-X" flags))
      ('unsorted (push "-U" flags))
      (_ (when (strata-prefs-natural-sort p)
           (push "-v" flags))))
    (string-join (nreverse flags) " ")))

(defun strata-apply-sort-to-dired ()
  "Apply Strata sort & hidden settings directly to active Dired/Dirvish buffer."
  (when (derived-mode-p 'dired-mode)
    (let ((sw (strata-compute-dired-switches)))
      (setq-local dired-actual-switches sw)
      (setq dired-listing-switches sw)
      (revert-buffer))))

;;;; Per-Folder View Memory (LRU 128)

(defun strata-folder-view-remember (dir &optional prefs)
  "Save current view/sort/cursor preferences for DIR into LRU (max 128)."
  (let ((p (or prefs (strata-prefs))))
    (when (and (strata-prefs-remember-folder-views p)
               dir
               (not (strata-location-virtual-p dir))
               (file-directory-p dir))
      (let* ((key (directory-file-name (expand-file-name dir)))
             (snapshot (list :mode (strata-prefs-browser-mode p)
                             :sort-key (strata-prefs-sort-key p)
                             :sort-dir (strata-prefs-sort-direction p)
                             :folders-first (strata-prefs-folders-first p)
                             :natural-sort (strata-prefs-natural-sort p)
                             :group-by-type (strata-prefs-group-by-type p)
                             :show-hidden (strata-prefs-show-hidden p)
                             :compact-full-names (strata-prefs-compact-full-names p)
                             :cursor (strata-current-file))))
        (setq strata-folder-view-lru
              (cons (cons key snapshot)
                    (assoc-delete-all key strata-folder-view-lru)))
        (when (> (length strata-folder-view-lru) strata-folder-view-lru-limit)
          (setcdr (nthcdr (1- strata-folder-view-lru-limit) strata-folder-view-lru) nil))))))

(defun strata-folder-view-restore (dir &optional prefs)
  "Restore remembered view/sort preferences for DIR if available and return snapshot."
  (let ((p (or prefs (strata-prefs))))
    (when (and (strata-prefs-remember-folder-views p)
               dir
               (not (strata-location-virtual-p dir)))
      (let* ((key (directory-file-name (expand-file-name dir)))
             (entry (cdr (assoc key strata-folder-view-lru))))
        (when entry
          (setf (strata-prefs-browser-mode p) (or (plist-get entry :mode) 'columns))
          (setf (strata-prefs-sort-key p) (or (plist-get entry :sort-key) 'name))
          (setf (strata-prefs-sort-direction p) (or (plist-get entry :sort-dir) 'asc))
          (setf (strata-prefs-folders-first p) (plist-get entry :folders-first))
          (setf (strata-prefs-natural-sort p) (plist-get entry :natural-sort))
          (setf (strata-prefs-group-by-type p) (plist-get entry :group-by-type))
          (setf (strata-prefs-show-hidden p) (plist-get entry :show-hidden))
          (setf (strata-prefs-compact-full-names p) (plist-get entry :compact-full-names)))
        entry))))

;;;; Dirvish Custom Attributes & Formatters

(dirvish-define-attribute strata-icon
  "Render verified Strata Nerd Font folder/file glyph before filenames."
  :width 3
  (let* ((dir-p (eq (car f-type) 'dir))
         (g (strata-file--glyph f-name dir-p))
         (icon-str (concat g " "))
         (ov (make-overlay (max (point-min) (1- f-beg)) f-beg)))
    (when hl-face
      (setq icon-str (strata-icon-tint icon-str hl-face t)))
    (when dir-p
      (add-text-properties 0 (length icon-str)
                           (list 'mouse-face 'highlight
                                 'pointer 'hand
                                 'help-echo (format "Open folder %s" (abbreviate-file-name f-name)))
                           icon-str))
    (overlay-put ov 'after-string icon-str)
    `(ov . ,ov)))

(dirvish-define-attribute strata-dir-mouse
  "Make directories highlight and show a hand cursor on mouse hover."
  :width 0
  (when (eq (car f-type) 'dir)
    (let ((ov (make-overlay f-beg f-end)))
      (overlay-put ov 'mouse-face 'highlight)
      (overlay-put ov 'pointer 'hand)
      (overlay-put ov 'help-echo (format "Open folder %s" (abbreviate-file-name f-name)))
      `(ov . ,ov))))

(defun strata-dired-decorate-dirs ()
  "Ensure plain Dired buffers (e.g., split pane 2) mark directories as clickable."
  (when (and (derived-mode-p 'dired-mode)
             (not (and (fboundp 'dirvish-curr) (dirvish-curr)
                       (assq 'strata-dir-mouse (dirvish-prop :attrs)))))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((f-beg (dired-move-to-filename))
                    (f-end (dired-move-to-end-of-filename t))
                    (f (ignore-errors (dired-get-filename nil t))))
          (when (file-directory-p f)
            (with-silent-modifications
              (add-text-properties f-beg f-end
                                   (list 'mouse-face 'highlight
                                         'pointer 'hand
                                         'help-echo (format "Open folder %s" (abbreviate-file-name f)))))))
        (forward-line 1)))))

(add-hook 'dired-after-readin-hook #'strata-dired-decorate-dirs)

(dirvish-define-attribute strata-color
  "Apply Strata custom folder color faces to tagged directory names."
  :width 0
  (let ((badge (strata-file--badge-face f-name)))
    (when badge
      (let ((ov (make-overlay f-beg f-end)))
        (overlay-put ov 'face badge)
        `(ov . ,ov)))))

(dirvish-define-attribute strata-size
  "Format file size honoring Metric (1000) / Binary (1024) and `columns-show-sizes'."
  :right 9
  :when (and (strata-prefs-columns-show-sizes (strata-prefs))
             (>= win-width 20))
  (let* ((dir-p (eq (car f-type) 'dir))
         (sz (and f-attrs (file-attribute-size f-attrs)))
         (str (cond
               (dir-p "")
               ((numberp sz) (strata-format-bytes sz))
               (t "")))
         (out (format "%8s " str)))
    (add-face-text-property 0 (length out) (or hl-face 'dirvish-file-size) t out)
    `(right . ,out)))

(dirvish-define-attribute strata-time
  "Format modification time using Strata relative or ISO date preference."
  :right 17
  :when (>= win-width 38)
  (let* ((tm (and f-attrs (file-attribute-modification-time f-attrs)))
         (str (or (strata-format-time tm) ""))
         (out (format " %-15s" str)))
    (add-face-text-property 0 (length out) (or hl-face 'dirvish-file-time) t out)
    `(right . ,out)))

;;;; Dirvish Header Breadcrumbs & Strata Footer Mode-Line

(defvar strata-sort-header-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'strata-sort-menu)
    (define-key map [header-line mouse-2] #'strata-sort-menu)
    (define-key map [mode-line mouse-1] #'strata-sort-menu)
    (define-key map [mode-line mouse-2] #'strata-sort-menu)
    map)
  "Mouse bindings for the Sort By header control in every directory layout.")

(defvar strata-view-header-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'strata-view-menu)
    (define-key map [header-line mouse-2] #'strata-view-menu)
    (define-key map [mode-line mouse-1] #'strata-view-menu)
    (define-key map [mode-line mouse-2] #'strata-view-menu)
    map)
  "Mouse bindings for the View header control in every directory layout.")

(defun strata-header--select-browser (event)
  "Select the browser owning header EVENT, or use the current browser."
  (when event
    (let* ((clicked (posn-window (event-start event)))
           (target
            (when (window-live-p clicked)
              (with-current-buffer (window-buffer clicked)
                (if (derived-mode-p 'dired-mode 'strata-compact-mode 'strata-icons-mode)
                    clicked
                  ;; Columns puts its header in a separate Dirvish window.
                  (when-let ((dv (dirvish-curr))) (dv-root-window dv)))))))
      (when (window-live-p target)
        (select-window target)
        (strata-panes--sync-active-pane-from-window target))))
  (unless (derived-mode-p 'dired-mode 'strata-compact-mode 'strata-icons-mode)
    (user-error "Open a directory to use this menu")))

(defun strata-view-current-mode ()
  "Return the current browser's layout, preferring its buffer's setting."
  (or strata-local-view-mode (strata-prefs-browser-mode (strata-prefs))))

(defun strata-crumb--make-segment (label target)
  "Return clickable breadcrumb segment LABEL pointing to directory TARGET."
  (let ((km (make-sparse-keymap))
        (open-fn (lambda (ev)
                   (interactive "e")
                   (let ((win (or (posn-window (event-start ev))
                                  (posn-window (event-end ev)))))
                     (when (window-live-p win)
                       (select-window win)
                       (when (fboundp 'strata-panes--sync-active-pane-from-window)
                         (strata-panes--sync-active-pane-from-window win))))
                   (strata-open-location target t))))
    (define-key km [header-line mouse-1] open-fn)
    (define-key km [header-line mouse-2] open-fn)
    (define-key km [mode-line mouse-1] open-fn)
    (define-key km [mode-line mouse-2] open-fn)
    (let ((out (strata-icon-tint (copy-sequence label) 'strata-crumb-segment t)))
      (add-text-properties 0 (length out)
                           (list 'mouse-face 'highlight
                                 'pointer 'hand
                                 'local-map km
                                 'keymap km
                                 'strata-crumb-path target
                                 'help-echo (format "Open folder %s" target))
                           out)
      out)))

(dirvish-define-mode-line strata-breadcrumb
  "Interactive clickable breadcrumb header with active pane badge & view pill."
  (let* ((dir (abbreviate-file-name (or (dirvish-prop :root) default-directory "~/")))
         (clean (directory-file-name dir))
         (parts (split-string clean "/" t))
         (acc (if (string-prefix-p "~" clean) "~" "/"))
         (pane-badge
          (when (and (fboundp 'strata-split-active-p) (strata-split-active-p))
            (let* ((ap (and (fboundp 'strata-active-pane) (strata-active-pane)))
                   (active-id (if ap (strata-pane-state-id ap) 1))
                   (other-id (if (= active-id 1) 2 1))
                   (this-pane
                    (or (when (and (fboundp 'mode-line-window-selected-p)
                                   (fboundp 'strata-panes--valid-main-window-p)
                                   (strata-panes--valid-main-window-p (selected-window)))
                          (if (mode-line-window-selected-p) active-id other-id))
                        (when-let* ((tab (and (fboundp 'strata-active-tab) (strata-active-tab)))
                                    (p1 (strata-tab-state-pane1 tab))
                                    (p2 (strata-tab-state-pane2 tab)))
                          (let ((b1 (strata-pane-state-buffer p1))
                                (b2 (strata-pane-state-buffer p2)))
                            (cond
                             ((and (not (eq b1 b2)) (eq (current-buffer) b1)) 1)
                             ((and (not (eq b1 b2)) (eq (current-buffer) b2)) 2)
                             (t active-id))))
                        active-id))
                   (active-p (= this-pane active-id)))
              (propertize (if active-p
                              (format " [P%d ACTIVE] " this-pane)
                            (format " [P%d] " this-pane))
                          'face (if active-p
                                    'strata-pane-active-badge
                                  'strata-pane-inactive-badge)))))
         (crumbs
          (if (string-prefix-p "~" clean)
              (let ((segs (cdr parts)))
                (concat
                 (strata-crumb--make-segment
                  (if (display-graphic-p)
                      (concat (strata-icon-glyph 'home 'strata-crumb-segment) " ~")
                    "~")
                  (expand-file-name "~/"))
                 (mapconcat
                  (lambda (seg)
                    (setq acc (concat acc "/" seg))
                    (concat (propertize " › " 'face 'strata-crumb-separator)
                            (strata-crumb--make-segment seg (expand-file-name acc))))
                  segs "")))
            (concat
             (strata-crumb--make-segment "/" "/")
             (mapconcat
              (lambda (seg)
                (setq acc (concat (if (string= acc "/") "" acc) "/" seg))
                (concat (propertize " › " 'face 'strata-crumb-separator)
                        (strata-crumb--make-segment seg acc)))
              parts ""))))
         (filter-pill (when strata-local-filter
                        (concat
                         (propertize " " 'face 'strata-pill-filter)
                         (strata-icon-glyph 'search 'strata-pill-filter "Filter:")
                         (propertize (format " %s " strata-local-filter)
                                     'face 'strata-pill-filter)))))
    (concat (or pane-badge "") " " crumbs (when filter-pill (concat "  " filter-pill)))))

(dirvish-define-mode-line strata-view-info
  "Clickable Sort By and View controls in the header."
  (let* ((p (strata-prefs))
         (vmode (strata-view-current-mode))
         (view-lbl (pcase vmode
                     ('columns "Columns")
                     ('icons "Icons")
                     ('list (if (strata-prefs-expandable-tree p) "Tree" "List"))
                     ('compact "Compact")
                     (_ "Columns")))
         (arrow (if (eq (strata-prefs-sort-direction p) 'desc) "↓" "↑"))
         (sort-lbl (capitalize (symbol-name (strata-prefs-sort-key p))))
         (tenx (when (strata-prefs-tenxer-mode p)
                 (propertize " 10X " 'face 'strata-pill-10x))))
    (concat
     (propertize (format " [Sort By… %s %s] " sort-lbl arrow)
                 'face 'strata-header-accent
                 'mouse-face 'highlight 'pointer 'hand
                 'help-echo "Sort files by name, date, size or extension (C-c s)"
                 'local-map strata-sort-header-map 'keymap strata-sort-header-map)
     ;; Adjacent equal mouse-face properties form one hover region even
     ;; when the buttons have different keymaps.  Keep a plain gap between.
     " "
     (propertize (format " [View… %s] " view-lbl)
                 'face 'strata-header-accent
                 'mouse-face 'highlight 'pointer 'hand
                 'help-echo "Choose Columns, Icons, List/Tree or Compact (C-1 / C-2 / C-3 / C-4)"
                 'local-map strata-view-header-map 'keymap strata-view-header-map)
     (or tenx ""))))

(defun strata-view-header-line ()
  "Render breadcrumbs while reserving room for the Sort By and View controls."
  (let* ((right (dirvish-strata-view-info-ml))
         (left (dirvish-strata-breadcrumb-ml))
         (room (max 0 (- (window-width) (string-width right) 1))))
    (concat (truncate-string-to-width left room nil nil "…")
            (propertize " " 'display
                        `(space :align-to (- right ,(string-width right))))
            right)))

(dirvish-define-mode-line strata-footer
  "Strata footer: selection summary, clipboard, chord indicator, and hints."
  (let* ((p (strata-prefs))
         (count (length (strata-marked-files-only)))
         (clip (when (fboundp 'strata-pane-clipboard-summary)
                 (strata-pane-clipboard-summary)))
         (chord (when strata-active-chord
                  (propertize (format " %s " strata-active-chord) 'face 'strata-pill-chord)))
         (hints (when (and (strata-prefs-show-keybinding-hints p) (not chord))
                  (if (strata-prefs-tenxer-mode p)
                      " j/k Nav  g Go  , Sort  ; Act  t Tabs  i Peek  f Filter  ~ Keys"
                    " ←/→ Nav  C-1..4 View  C-c s Sort  F3 Split  C-k Search  C-, Prefs  ? Keys"))))
    (concat
     (if (> count 0)
         (propertize (format " %d selected " count) 'face 'strata-header-accent)
       "")
     (when clip (propertize (format " %s " clip) 'face 'strata-hint-key))
     (or chord "")
     (when hints (propertize hints 'face 'strata-hint-desc)))))

;;;; Async Thumbnail Generator (Icons View)

(defun strata-thumbnail-path (file size)
  "Return cache PNG path for FILE at SIZE."
  (make-directory strata-thumbnail-dir t)
  (expand-file-name (format "%s-%d.png" (md5 file) size) strata-thumbnail-dir))

(defun strata-thumbnail-maybe-generate (file size callback)
  "Return cached thumbnail path if fresh, or generate asynchronously via CALLBACK."
  (let ((out (strata-thumbnail-path file size))
        (ext (downcase (or (file-name-extension file) ""))))
    (if (and (file-exists-p out)
             (file-newer-than-file-p out file))
        out
      (unless (gethash out strata-thumbnail-pending)
        (let ((cmd
               (cond
                ((and (member ext '("png" "jpg" "jpeg" "webp" "bmp" "tif" "tiff" "gif" "svg"))
                      (executable-find "vipsthumbnail"))
                 (list "vipsthumbnail" file "-s" (number-to-string size) "-o" out))
                ((and (member ext '("mp4" "mkv" "mov" "webm" "avi" "m4v"))
                      (executable-find "ffmpegthumbnailer"))
                 (list "ffmpegthumbnailer" "-i" file "-o" out "-s" (number-to-string size)))
                ((and (string= ext "pdf") (executable-find "pdftoppm"))
                 (list "pdftoppm" "-png" "-singlefile" "-f" "1" "-scale-to"
                       (number-to-string size) file (file-name-sans-extension out))))))
          (when cmd
            (puthash out t strata-thumbnail-pending)
            (make-process
             :name (format "strata-thumb-%s" (file-name-nondirectory file))
             :noquery t
             :command cmd
             :sentinel
             (lambda (proc _ev)
               (when (memq (process-status proc) '(exit signal))
                 (remhash out strata-thumbnail-pending)
                 (when (and (= 0 (process-exit-status proc)) (file-exists-p out))
                   (funcall callback out))))))))
      nil)))

;;;; Compact View (Horizontal Multi-Column Flow + Sideways Scroll + Full-Names Toggle)

(defvar-local strata-view-directory nil "Directory displayed in compact/icons view buffer.")
(defvar-local strata-marked-entries nil "Marked file paths in compact/icons view buffer.")
(defvar-local strata-compact-col-width 28 "Current column stride in Compact view.")
(defvar-local strata-compact-rows 20 "Row count per vertical column in Compact view.")

(defvar strata-mouse--inhibit-preview nil
  "Non-nil while tracking a live mouse drag selection to avoid preview churn.")

(defvar strata-mouse--drag-state nil
  "Active drag-selection state plist while holding button-1.")

(defvar strata-mouse--finished-drag-state nil
  "Completed drag-selection state awaiting button-1 release command.")

(defvar strata-mouse--suppress-mouse-3-once nil
  "Non-nil after cancelling a drag with right button to drop trailing release.")

(defun strata-mouse-install-keymap-bindings (map)
  "Install shared Strata mouse click, drag-select, and drop bindings on MAP."
  (define-key map (kbd "<down-mouse-1>") #'strata-mouse-down-entry)
  (define-key map (kbd "<mouse-1>") #'strata-mouse-click-entry)
  (define-key map (kbd "<drag-mouse-1>") #'strata-mouse-drag-drop)
  (define-key map (kbd "<C-down-mouse-1>") #'strata-mouse-down-entry)
  (define-key map (kbd "<C-mouse-1>") #'strata-mouse-toggle-select)
  (define-key map (kbd "<C-drag-mouse-1>") #'strata-mouse-drag-copy)
  (define-key map (kbd "<S-down-mouse-1>") #'strata-mouse-down-entry)
  (define-key map (kbd "<S-mouse-1>") #'strata-mouse-range-select)
  (define-key map (kbd "<S-drag-mouse-1>") #'strata-mouse-drag-move)
  (define-key map (kbd "<C-S-down-mouse-1>") #'strata-mouse-down-entry)
  (define-key map (kbd "<C-S-mouse-1>") #'strata-mouse-add-range-select)
  (define-key map (kbd "<C-S-drag-mouse-1>") #'strata-mouse-drag-drop)
  (define-key map (kbd "<double-drag-mouse-1>") #'strata-mouse-drag-drop)
  (define-key map (kbd "<mouse-2>") #'strata-mouse-activate-at-event)
  (define-key map (kbd "<double-mouse-1>") #'strata-mouse-activate-at-event)
  (define-key map (kbd "<mouse-3>") #'strata-mouse-context-menu)
  map)

(defvar strata-compact-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "j") #'strata-compact-next-item)
    (define-key map (kbd "<down>") #'strata-compact-next-item)
    (define-key map (kbd "k") #'strata-compact-prev-item)
    (define-key map (kbd "<up>") #'strata-compact-prev-item)
    (define-key map (kbd "l") #'strata-compact-next-col)
    (define-key map (kbd "<right>") #'strata-compact-next-col)
    (define-key map (kbd "h") #'strata-compact-prev-col)
    (define-key map (kbd "<left>") #'strata-compact-prev-col)
    (define-key map (kbd "<wheel-up>") (lambda () (interactive) (scroll-right 6)))
    (define-key map (kbd "<wheel-down>") (lambda () (interactive) (scroll-left 6)))
    (define-key map (kbd "<wheel-left>") (lambda () (interactive) (scroll-right 6)))
    (define-key map (kbd "<wheel-right>") (lambda () (interactive) (scroll-left 6)))
    (define-key map (kbd "RET") #'strata-open-or-edit-at-point)
    (strata-mouse-install-keymap-bindings map)
    (define-key map (kbd "SPC") #'strata-preview-at-point)
    (define-key map (kbd "m") #'strata-view-toggle-mark)
    (define-key map (kbd "<backspace>") #'strata-view-up-directory)
    (define-key map (kbd "g") #'strata-compact-refresh)
    (define-key map (kbd "<f5>") #'strata-compact-refresh)
    map)
  "Keymap for `strata-compact-mode'.")

(declare-function strata-preview-update-standalone "strata-dirvish-previews" (file &optional window))
(declare-function dirvish-strata-breadcrumb-ml "strata-dirvish-views" ())
(declare-function dirvish-strata-view-info-ml "strata-dirvish-views" ())
(declare-function dirvish-strata-footer-ml "strata-dirvish-views" ())

(defvar strata--enforcing-no-wrap nil
  "Recursion guard while suppressing `visual-line-mode' in Strata views.")

(defun strata--enforce-no-wrap ()
  "Disable `visual-line-mode' and enforce single-line truncation in Compact/Icons."
  (unless strata--enforcing-no-wrap
    (let ((strata--enforcing-no-wrap t))
      (when (bound-and-true-p visual-line-mode)
        (visual-line-mode -1))
      (when (bound-and-true-p hl-line-mode)
        (hl-line-mode -1))
      (setq-local truncate-lines t
                  word-wrap nil
                  truncate-partial-width-windows nil))))

(define-derived-mode strata-compact-mode special-mode "Strata-Compact"
  "Strata Compact view: vertical columns flowing left-to-right with sideways scroll."
  (strata--enforce-no-wrap)
  (add-hook 'visual-line-mode-hook #'strata--enforce-no-wrap nil t)
  (add-hook 'after-change-major-mode-hook #'strata--enforce-no-wrap 90 t)
  (setq-local header-line-format
              '(:eval (strata-view-header-line)))
  (setq-local mode-line-format
              '(:eval (dirvish-strata-footer-ml)))
  (add-hook 'post-command-hook #'strata-view--sync-preview-on-move nil t))

(defun strata-view--sync-preview-on-move ()
  "Keep selection highlight and preview pane synced across Columns/List/Compact/Icons."
  (strata-view--update-selection-highlight)
  (unless (or strata-mouse--inhibit-preview strata-mouse--drag-state)
    (when-let ((f (strata-current-file)))
      (let ((dv (ignore-errors (dirvish-curr))))
        (cond
         ((and dv
               (window-live-p (dv-preview-window dv))
               (not (eq (dv-preview-window dv) (selected-window))))
          (dirvish-prop :index f)
          (dirvish--preview-update dv f))
         ((when-let ((pwin (or (and (boundp 'strata-preview-standalone-window)
                                    (window-live-p strata-preview-standalone-window)
                                    (eq (window-buffer strata-preview-standalone-window)
                                        (get-buffer "*Strata Preview*"))
                                    strata-preview-standalone-window)
                               (get-buffer-window "*Strata Preview*"))))
            (when (and (not (eq pwin (selected-window)))
                       (fboundp 'strata-preview-update-standalone))
              (strata-preview-update-standalone f pwin)))))))))

(defun strata-compact--fit-name (name maxw full-p)
  "Truncate NAME cleanly to MAXW unless FULL-P is non-nil."
  (if (or full-p (<= (length name) maxw))
      name
    (concat (substring name 0 (max 4 (- maxw 1))) "…")))

(defun strata-compact-render (&optional dir)
  "Render DIR into vertical top-to-bottom, left-to-right columns."
  (strata--enforce-no-wrap)
  (let* ((d (or dir strata-view-directory default-directory))
         (p (strata-prefs))
         (full-p (strata-prefs-compact-full-names p))
         (entries (strata-list-directory-entries d p))
         (rows (max 6 (- (window-body-height) 2)))
         (max-name (if entries (apply #'max (mapcar (lambda (e) (length (plist-get e :name))) entries)) 16))
         (cell-w (if full-p (min 64 (+ 5 max-name)) 26))
         (ncols (max 1 (ceiling (max 1 (length entries)) (float rows))))
         (inhibit-read-only t)
         (cur (strata-current-file)))
    (setq strata-view-directory d
          default-directory (file-name-as-directory d)
          strata-compact-col-width cell-w
          strata-compact-rows rows)
    (erase-buffer)
    (dotimes (r rows)
      (dotimes (c ncols)
        (let ((idx (+ (* c rows) r)))
          (when (< idx (length entries))
            (let* ((e (nth idx entries))
                   (path (plist-get e :path))
                   (name (plist-get e :name))
                   (dir-p (plist-get e :dir-p))
                   (marked (member path strata-marked-entries))
                   (icon (strata-file--glyph path dir-p))
                   (shown (strata-compact--fit-name name (- cell-w 4) full-p))
                   (face (cond (marked 'dired-marked)
                               ((strata-file--badge-face path))
                               (dir-p 'dired-directory)
                               (t 'default)))
                   (cell (concat
                          (propertize (if marked "*" " ") 'face 'dired-marked)
                          icon " "
                          (propertize shown 'face face 'strata-entry-label t)))
                   (pad (max 1 (- cell-w (string-width cell)))))
              (add-text-properties 0 (length cell)
                                   (append (list 'strata-entry path
                                                 'strata-entry-dir dir-p
                                                 'help-echo path)
                                           (when dir-p
                                             '(mouse-face highlight pointer hand)))
                                   cell)
              (insert cell (make-string pad ?\s))))))
      (insert "\n"))
    (goto-char (point-min))
    (cond
     ((and cur (strata-goto-file cur)))
     (entries (strata-goto-file (plist-get (car entries) :path)))
     (t (strata-view--update-selection-highlight)))
    (when (fboundp 'strata-watch-sync)
      (strata-watch-sync (current-buffer)))))

(defun strata-compact-refresh ()
  "Refresh Compact view buffer."
  (interactive)
  (when (derived-mode-p 'strata-compact-mode)
    (strata-compact-render strata-view-directory)))

(defun strata-compact--jump-offset (delta-items)
  "Move cursor by DELTA-ITEMS across Compact column cells."
  (when strata-view-directory
    (let ((entries (strata-list-directory-entries strata-view-directory))
          (cur (strata-current-file)))
      (when entries
        (let* ((paths (mapcar (lambda (e) (plist-get e :path)) entries))
               (idx (or (cl-position cur paths :test #'equal) 0))
               (next (max 0 (min (1- (length paths)) (+ idx delta-items)))))
          (strata-goto-file (nth next paths)))))))

(defun strata-compact-next-item () (interactive) (strata-compact--jump-offset 1))
(defun strata-compact-prev-item () (interactive) (strata-compact--jump-offset -1))
(defun strata-compact-next-col ()
  "Jump right one Compact column or open directory if scoped right."
  (interactive)
  (strata-compact--jump-offset strata-compact-rows))
(defun strata-compact-prev-col ()
  "Jump left one Compact column."
  (interactive)
  (strata-compact--jump-offset (- strata-compact-rows)))

;;;; Icons Thumbnail Grid View

(defvar-local strata-icons--ncols 4 "Current column count rendered in Icons view.")
(defvar-local strata-icons--count 0 "Total entry count rendered in Icons view.")
(defvar-local strata-icons--rendered-win-w nil "Window width captured at last Icons render.")
(defvar-local strata-icons--refresh-timer nil "Coalescing timer for async thumbnail re-renders.")

(defvar strata-icons-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "j") #'strata-icons-next-row)
    (define-key map (kbd "<down>") #'strata-icons-next-row)
    (define-key map (kbd "k") #'strata-icons-prev-row)
    (define-key map (kbd "<up>") #'strata-icons-prev-row)
    (define-key map (kbd "l") #'strata-icons-next-cell)
    (define-key map (kbd "<right>") #'strata-icons-next-cell)
    (define-key map (kbd "h") #'strata-icons-prev-cell)
    (define-key map (kbd "<left>") #'strata-icons-prev-cell)
    (define-key map (kbd "RET") #'strata-open-or-edit-at-point)
    (strata-mouse-install-keymap-bindings map)
    (define-key map (kbd "SPC") #'strata-preview-at-point)
    (define-key map (kbd "m") #'strata-view-toggle-mark)
    (define-key map (kbd "<backspace>") #'strata-view-up-directory)
    (define-key map (kbd "g") #'strata-icons-refresh)
    (define-key map (kbd "<f5>") #'strata-icons-refresh)
    map)
  "Keymap for `strata-icons-mode'.")

(defun strata-icons--update-selection-highlight ()
  "Highlight the active card label cleanly in Icons view."
  (strata-view--update-selection-highlight))

(defun strata-icons--post-command-hook ()
  "Keep selection highlight and preview pane synced after point motion in Icons view."
  (strata-view--sync-preview-on-move))

(defun strata-icons--on-window-size-change (&optional win-or-frame)
  "Reflow visible `strata-icons-mode' buffers when their window width changes."
  (dolist (win (if (windowp win-or-frame) (list win-or-frame) (window-list)))
    (when (window-live-p win)
      (with-current-buffer (window-buffer win)
        (let ((cur-w (window-body-width win (display-graphic-p))))
          (when (and (derived-mode-p 'strata-icons-mode)
                     strata-view-directory
                     strata-icons--rendered-win-w
                     (not (eql cur-w strata-icons--rendered-win-w)))
            (with-selected-window win
              (strata-icons-render strata-view-directory))))))))

(define-derived-mode strata-icons-mode special-mode "Strata-Icons"
  "Strata Icons thumbnail grid view with live thumbnail caching."
  (strata--enforce-no-wrap)
  (setq-local line-spacing 3)
  (add-hook 'visual-line-mode-hook #'strata--enforce-no-wrap nil t)
  (add-hook 'after-change-major-mode-hook #'strata--enforce-no-wrap 90 t)
  (setq-local header-line-format
              '(:eval (strata-view-header-line)))
  (setq-local mode-line-format
              '(:eval (dirvish-strata-footer-ml)))
  (add-hook 'post-command-hook #'strata-icons--post-command-hook nil t)
  (add-hook 'window-size-change-functions #'strata-icons--on-window-size-change nil t))

(defun strata-icons--scale-glyph (glyph thumb-px)
  "Scale GLYPH proportionally to THUMB-PX on GUI frames while preserving family and tint."
  (if (not (display-graphic-p))
      glyph
    (let* ((ch (max 12 (frame-char-height)))
           (scale (max 1.8 (min 4.8 (/ (* thumb-px 0.72) (float ch)))))
           (copy (copy-sequence glyph)))
      (add-face-text-property 0 (length copy) (list :height scale) nil copy)
      copy)))

(defun strata-icons--wrap-name (name max-cols)
  "Wrap filename NAME cleanly into 1 or 2 lines each <= MAX-COLS display width."
  (if (<= (string-width name) max-cols)
      (list name)
    (let* ((pfx (truncate-string-to-width name max-cols))
           (plen (length pfx))
           (min-split (max 1 (/ plen 2)))
           (sep nil))
      (cl-loop for k from (1- plen) downto min-split
               for ch = (aref pfx k)
               when (memq ch '(?\s ?- ?_ ?. ?/))
               do (setq sep k) (cl-return))
      (let* ((split-at (cond
                        ((and sep (eq (aref pfx sep) ?\s) (> sep 0)) sep)
                        ((and sep (< (1+ sep) (length name))) (1+ sep))
                        (t plen)))
             (l1 (string-trim-right (substring name 0 split-at)))
             (rest (string-trim-left (substring name split-at)))
             (l2 (if (<= (string-width rest) max-cols)
                     rest
                   (truncate-string-to-width rest max-cols nil nil "…"))))
        (if (string-empty-p l2)
            (list (truncate-string-to-width name max-cols nil nil "…"))
          (list l1 l2))))))

(defun strata-icons--fit-gui-label (str max-px)
  "Ensure GUI string STR does not exceed MAX-PX pixel width."
  (let ((s str))
    (while (and (> (length s) 3)
                (fboundp 'string-pixel-width)
                (> (string-pixel-width s) max-px))
      (setq s (concat (substring s 0 (max 2 (- (length s) 2))) "…")))
    s))

(defun strata-icons--schedule-refresh (buf dir)
  "Coalesce async thumbnail completions for BUF displaying DIR."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (timerp strata-icons--refresh-timer)
        (cancel-timer strata-icons--refresh-timer))
      (setq-local strata-icons--refresh-timer
                  (run-with-timer
                   0.05 nil
                   (lambda (b d)
                     (when (buffer-live-p b)
                       (with-current-buffer b
                         (setq-local strata-icons--refresh-timer nil)
                         (when (and (derived-mode-p 'strata-icons-mode)
                                    (equal strata-view-directory d))
                           (if-let ((win (get-buffer-window b t)))
                               (with-selected-window win
                                 (strata-icons-render d))
                             (strata-icons-render d))))))
                   buf dir)))))

(defun strata-icons-render (&optional dir)
  "Render aligned, centered thumbnail/icon grid cards for DIR into current buffer."
  (strata--enforce-no-wrap)
  (let* ((d (or dir strata-view-directory default-directory))
         (p (strata-prefs))
         (entries (strata-list-directory-entries d p))
         (thumb-px (max 32 (min 256 (or (strata-prefs-icons-thumbnail-size p) 64))))
         (graphic-p (display-graphic-p))
         (win (selected-window))
         (char-w (max 6 (frame-char-width)))
         (win-raw (window-body-width win graphic-p))
         (tile-chars (max 18 (+ 6 (ceiling thumb-px char-w))))
         (max-lbl-chars (- tile-chars 2))
         (tile-px (* tile-chars char-w))
         (gap-chars 2)
         (gap-px (* gap-chars char-w))
         (left-cols 2)
         (left-px (* left-cols char-w))
         (stride-chars (+ tile-chars gap-chars))
         (stride-px (+ tile-px gap-px))
         (avail-px (max tile-px (- (or win-raw (* (window-body-width win) char-w)) left-px)))
         (avail-cols (max tile-chars (- (max 40 (window-body-width win)) left-cols)))
         (ncols (max 1 (if graphic-p
                           (floor (+ (- avail-px left-px) gap-px) stride-px)
                         (floor (+ avail-cols gap-chars) stride-chars))))
         (inhibit-read-only t)
         (cur (strata-current-file))
         (buf (current-buffer))
         (cards nil)
         (idx 0))
    (setq strata-view-directory d
          default-directory (file-name-as-directory d)
          strata-icons--ncols ncols
          strata-icons--count (length entries)
          strata-icons--rendered-win-w win-raw)
    (erase-buffer)
    (dolist (e entries)
      (let* ((path (plist-get e :path))
             (name (plist-get e :name))
             (dir-p (plist-get e :dir-p))
             (marked (member path strata-marked-entries))
             (thumb (when (and (not dir-p)
                               graphic-p
                               (strata-prefs-show-thumbnails p))
                      (or (strata-thumbnail-maybe-generate
                           path thumb-px
                           (lambda (_out)
                             (strata-icons--schedule-refresh buf d)))
                          (let ((cand (strata-thumbnail-path path thumb-px)))
                            (when (file-exists-p cand) cand)))))
             (img (when (and thumb (image-type-available-p 'png))
                    (create-image thumb 'png nil
                                  :max-height thumb-px :max-width thumb-px :ascent 85)))
             (icon-str (if img
                           (propertize " " 'display img)
                         (strata-icons--scale-glyph (strata-file--glyph path dir-p) thumb-px)))
             (icon-w (if graphic-p
                         (if img
                             (round (or (car (ignore-errors (image-size img t))) thumb-px))
                           (round (if (fboundp 'string-pixel-width)
                                      (string-pixel-width icon-str)
                                    (* 3 char-w))))
                       (string-width icon-str)))
             (face (cond (marked 'dired-marked)
                         ((strata-file--badge-face path))
                         (dir-p 'dired-directory)
                         (t 'default)))
             (wrapped (strata-icons--wrap-name name (if marked (- max-lbl-chars 2) max-lbl-chars)))
             (l1-raw (concat (if marked "✓ " "") (car wrapped)))
             (l2-raw (cadr wrapped))
             (props (append (list 'strata-entry path
                                  'strata-entry-dir dir-p
                                  'strata-grid-idx idx
                                  'help-echo path
                                  'mouse-face 'highlight)
                            (when dir-p '(pointer hand))))
             (icon-cell (apply #'propertize icon-str props))
             (l1-text (if graphic-p
                          (strata-icons--fit-gui-label (propertize l1-raw 'face face) (- tile-px char-w))
                        (propertize l1-raw 'face face)))
             (l1-cell (apply #'propertize l1-text (append (list 'strata-grid-label t) props)))
             (l1-w (if graphic-p
                       (round (if (fboundp 'string-pixel-width)
                                  (string-pixel-width l1-cell)
                                (* (string-width l1-cell) char-w)))
                     (string-width l1-cell)))
             (l2-text (when l2-raw
                        (if graphic-p
                            (strata-icons--fit-gui-label (propertize l2-raw 'face face) (- tile-px char-w))
                          (propertize l2-raw 'face face))))
             (l2-cell (when l2-text
                        (apply #'propertize l2-text (append (list 'strata-grid-label-cont t) props))))
             (l2-w (if l2-cell
                       (if graphic-p
                           (round (if (fboundp 'string-pixel-width)
                                      (string-pixel-width l2-cell)
                                    (* (string-width l2-cell) char-w)))
                         (string-width l2-cell))
                     0)))
        (push (list :icon icon-cell :icon-w icon-w
                    :l1 l1-cell :l1-w l1-w
                    :l2 l2-cell :l2-w l2-w)
              cards)
        (setq idx (1+ idx))))
    (setq cards (nreverse cards))
    (if (null cards)
        (insert "\n" (propertize "  (Empty folder)\n" 'face 'shadow))
      (insert "\n")
      (let ((emit-line
             (lambda (row key w-key)
               (let ((cur-col 0))
                 (dotimes (c (length row))
                   (let* ((card (nth c row))
                          (txt (plist-get card key))
                          (w (plist-get card w-key)))
                     (when txt
                       (if graphic-p
                           (let* ((col-left (+ left-px (* c stride-px)))
                                  (start-px (+ col-left (max 0 (/ (- tile-px w) 2)))))
                             (insert (propertize " " 'display (list 'space :align-to (list start-px)))
                                     txt))
                         (let* ((col-left (+ left-cols (* c stride-chars)))
                                (start-col (+ col-left (max 0 (/ (- tile-chars w) 2))))
                                (pad (max (if (= c 0) 0 1) (- start-col cur-col))))
                           (when (> pad 0)
                             (insert (make-string pad ?\s)))
                           (insert txt)
                           (setq cur-col (+ start-col w)))))))
                 (insert "\n")))))
        (while cards
          (let* ((take-n (min ncols (length cards)))
                 (row (cl-subseq cards 0 take-n)))
            (setq cards (nthcdr take-n cards))
            (funcall emit-line row :icon :icon-w)
            (funcall emit-line row :l1 :l1-w)
            (when (cl-some (lambda (c) (plist-get c :l2)) row)
              (funcall emit-line row :l2 :l2-w))
            (insert "\n")))))
    (goto-char (point-min))
    (cond
     ((and cur (strata-goto-file cur)))
     ((> strata-icons--count 0) (strata-icons--goto-index 0))
     (t (strata-icons--update-selection-highlight)))
    (when (fboundp 'strata-watch-sync)
      (strata-watch-sync (current-buffer)))))

(defun strata-icons-refresh ()
  "Refresh Icons grid view."
  (interactive)
  (when (derived-mode-p 'strata-icons-mode)
    (strata-icons-render strata-view-directory)))

(defun strata-icons--current-index ()
  "Return zero-based index of card at point in Icons view, or nil."
  (or (get-text-property (point) 'strata-grid-idx)
      (when-let ((cur (strata-current-file)))
        (save-excursion
          (strata-goto-file cur)
          (get-text-property (point) 'strata-grid-idx)))))

(defun strata-icons--goto-index (target-idx)
  "Jump to the label start of grid card TARGET-IDX in Icons view."
  (when (and (> strata-icons--count 0) (>= target-idx 0))
    (let* ((idx (min (1- strata-icons--count) target-idx))
           (pos (point-min))
           (best nil)
           (fallback nil))
      (while (and (< pos (point-max)) (not best))
        (let ((next (or (next-single-property-change pos 'strata-grid-idx) (point-max)))
              (v (get-text-property pos 'strata-grid-idx)))
          (when (eql v idx)
            (unless fallback (setq fallback pos))
            (let ((lbl (if (get-text-property pos 'strata-grid-label)
                           pos
                         (let ((cand (next-single-property-change pos 'strata-grid-label nil next)))
                           (when (and cand (< cand next)
                                      (get-text-property cand 'strata-grid-label))
                             cand)))))
              (when lbl (setq best lbl))))
          (setq pos next)))
      (when-let ((dest (or best fallback)))
        (goto-char dest)
        (strata-icons--update-selection-highlight)))))

(defun strata-icons-next-cell ()
  "Move forward to next grid item in Icons view."
  (interactive)
  (when (> strata-icons--count 0)
    (let ((cur (or (strata-icons--current-index) -1)))
      (strata-icons--goto-index (min (1- strata-icons--count) (1+ cur))))))

(defun strata-icons-prev-cell ()
  "Move backward to previous grid item in Icons view."
  (interactive)
  (when (> strata-icons--count 0)
    (let ((cur (or (strata-icons--current-index) 1)))
      (strata-icons--goto-index (max 0 (1- cur))))))

(defun strata-icons-next-row ()
  "Move down one grid row in Icons view."
  (interactive)
  (when (> strata-icons--count 0)
    (let* ((ncols (max 1 strata-icons--ncols))
           (cur (or (strata-icons--current-index) 0))
           (cur-row (/ cur ncols))
           (last-row (/ (1- strata-icons--count) ncols)))
      (when (< cur-row last-row)
        (strata-icons--goto-index (min (1- strata-icons--count) (+ cur ncols)))))))

(defun strata-icons-prev-row ()
  "Move up one grid row in Icons view."
  (interactive)
  (when (> strata-icons--count 0)
    (let* ((ncols (max 1 strata-icons--ncols))
           (cur (or (strata-icons--current-index) 0)))
      (when (>= (- cur ncols) 0)
        (strata-icons--goto-index (- cur ncols))))))

(defun strata-nav-next-line ()
  "Move down one visual item/row across List, Columns, Compact, and Icons views."
  (interactive)
  (cond ((derived-mode-p 'strata-icons-mode) (strata-icons-next-row))
        ((derived-mode-p 'strata-compact-mode) (strata-compact-next-item))
        ((derived-mode-p 'dired-mode) (dired-next-line 1))
        (t (call-interactively #'next-line))))

(defun strata-nav-prev-line ()
  "Move up one visual item/row across List, Columns, Compact, and Icons views."
  (interactive)
  (cond ((derived-mode-p 'strata-icons-mode) (strata-icons-prev-row))
        ((derived-mode-p 'strata-compact-mode) (strata-compact-prev-item))
        ((derived-mode-p 'dired-mode) (dired-previous-line 1))
        (t (call-interactively #'previous-line))))

(defun strata-view--entry-order ()
  "Return ordered list of entry paths visible in the current browser buffer."
  (cond
   ((derived-mode-p 'dired-mode)
    (let (out)
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (unless (invisible-p (line-beginning-position))
            (when-let ((f (ignore-errors (dired-get-filename nil t))))
              (push f out)))
          (forward-line 1)))
      (nreverse out)))
   ((derived-mode-p 'strata-compact-mode 'strata-icons-mode)
    (mapcar (lambda (e) (plist-get e :path))
            (strata-list-directory-entries
             (or strata-view-directory default-directory)
             (strata-prefs))))))

(defun strata-view--set-entry-mark (path mark-p &optional no-refresh)
  "Mark or unmark PATH according to MARK-P across all Strata views."
  (when path
    (let ((key (strata--path-key path)))
      (cond
       ((derived-mode-p 'dired-mode)
        (save-excursion
          (when (or (ignore-errors (dired-goto-file key))
                    (ignore-errors (dired-goto-file (concat key "/"))))
            (let ((marked (save-excursion
                            (beginning-of-line)
                            (looking-at-p dired-re-mark))))
              (cond
               ((and mark-p (not marked)) (dired-mark 1))
               ((and (not mark-p) marked) (dired-unmark 1)))))))
       ((derived-mode-p 'strata-compact-mode 'strata-icons-mode)
        (setq strata-marked-entries
              (cl-remove-if (lambda (e) (equal (strata--path-key e) key))
                            strata-marked-entries))
        (when mark-p
          (push path strata-marked-entries))))
      (unless no-refresh
        (strata-view--refresh-after-mark)))))

(defun strata-view--refresh-after-mark ()
  "Refresh visual marks, selection overlays, and footer count."
  (cond
   ((derived-mode-p 'strata-compact-mode) (strata-compact-refresh))
   ((derived-mode-p 'strata-icons-mode) (strata-icons-refresh)))
  (strata-view--update-selection-highlight)
  (force-mode-line-update t))

(defun strata-view--mark-range (anchor-path target-path &optional additive)
  "Select ANCHOR-PATH through TARGET-PATH, shrinking on reversal.
With ADDITIVE, retain marks that preceded this range."
  (let ((order (strata-view--entry-order)))
    (unless (and strata--selection-range-active
                 (eq (not (null additive)) strata--selection-range-additive)
                 (equal anchor-path strata--selection-anchor-entry))
      (setq strata--selection-base-keys
            (when additive (mapcar #'strata--path-key (strata-marked-files-only)))))
    (setq strata--selection-anchor-entry anchor-path
          strata--selection-range-active t
          strata--selection-range-additive (not (null additive)))
    (strata-mouse--apply-selection-keys
     order (delete-dups
            (append (copy-sequence strata--selection-base-keys)
                    (mapcar #'strata--path-key
                            (strata-mouse--range-entries order anchor-path target-path)))) t)))

(defun strata-shift-select-move (move-fn &optional additive)
  "Extend a contiguous range via MOVE-FN, preserving old marks if ADDITIVE."
  (let* ((cur (strata-current-file))
         (anchor (or strata--selection-anchor-entry cur)))
    (when anchor
      (condition-case nil (funcall move-fn)
        ((beginning-of-buffer end-of-buffer) nil))
      (unless (strata-current-file) (strata-goto-file cur))
      (strata-view--mark-range anchor (or (strata-current-file) cur) additive))))

(defun strata-shift-select-next (&optional additive)
  "Extend selection to the next entry row (`S-<down>')."
  (interactive (list (memq 'control (event-modifiers last-command-event))))
  (strata-shift-select-move #'strata-nav-next-line additive))

(defun strata-shift-select-prev (&optional additive)
  "Extend selection to the previous entry row (`S-<up>')."
  (interactive (list (memq 'control (event-modifiers last-command-event))))
  (strata-shift-select-move #'strata-nav-prev-line additive))

(defun strata-shift-select-right (&optional additive)
  "Extend selection right in grid/compact views or down in list (`S-<right>')."
  (interactive (list (memq 'control (event-modifiers last-command-event))))
  (strata-shift-select-move
   (cond ((derived-mode-p 'strata-icons-mode) #'strata-icons-next-cell)
         ((derived-mode-p 'strata-compact-mode) #'strata-compact-next-col)
         (t #'strata-nav-next-line)) additive))

(defun strata-shift-select-left (&optional additive)
  "Extend selection left in grid/compact views or up in list (`S-<left>')."
  (interactive (list (memq 'control (event-modifiers last-command-event))))
  (strata-shift-select-move
   (cond ((derived-mode-p 'strata-icons-mode) #'strata-icons-prev-cell)
         ((derived-mode-p 'strata-compact-mode) #'strata-compact-prev-col)
         (t #'strata-nav-prev-line)) additive))

(defun strata-shift-select-first (&optional additive)
  "Select through the first visible entry, keeping old marks if ADDITIVE."
  (interactive (list (memq 'control (event-modifiers last-command-event))))
  (strata-shift-select-move
   (lambda () (strata-goto-file (car (strata-view--entry-order)))) additive))

(defun strata-shift-select-last (&optional additive)
  "Select through the last visible entry, keeping old marks if ADDITIVE."
  (interactive (list (memq 'control (event-modifiers last-command-event))))
  (strata-shift-select-move
   (lambda () (strata-goto-file (car (last (strata-view--entry-order))))) additive))

(defun strata-view-toggle-mark ()
  "Toggle selection mark on item at point across Compact/Icons/Dired views."
  (interactive)
  (when-let ((f (strata-current-file)))
    (let* ((key (strata--path-key f))
           (present (cl-some (lambda (e) (equal (strata--path-key e) key))
                             (strata-marked-files-only))))
      (strata-view--reset-selection-range f)
      (strata-view--set-entry-mark f (not present) nil))))

(defun strata-view-unmark ()
  "Unmark the current item without moving point."
  (interactive)
  (when-let ((f (strata-current-file)))
    (strata-view--reset-selection-range f)
    (strata-view--set-entry-mark f nil)))

(defun strata-mouse--entry-at-point ()
  "Resolve clicked entry path in Dired, Dirvish DIRview, Compact, or Icons."
  (or (get-text-property (point) 'strata-entry)
      (when (derived-mode-p 'dired-mode)
        (or (ignore-errors (dired-get-filename nil t))
            (save-excursion
              (when-let* ((b (dired-move-to-filename))
                          (e (dired-move-to-end-of-filename t)))
                (expand-file-name
                 (buffer-substring-no-properties b e)
                 (or (ignore-errors (dired-current-directory)) default-directory))))))
      (when (derived-mode-p 'dirvish-directory-view-mode)
        (let* ((lb (line-beginning-position))
               (le (line-end-position))
               (fn-beg (or (and (get-text-property lb 'dired-filename) lb)
                           (next-single-property-change lb 'dired-filename nil le)))
               (base-dir (or (car-safe (car-safe dired-subdir-alist))
                             default-directory))
               (name (if (and fn-beg (< fn-beg le) (get-text-property fn-beg 'dired-filename))
                         (buffer-substring-no-properties
                          fn-beg (next-single-property-change fn-beg 'dired-filename nil le))
                       (string-trim (buffer-substring-no-properties lb le)))))
          (and (not (string-empty-p name))
               (not (member name '("." "..")))
               (expand-file-name name base-dir))))))

(defun strata-mouse--edit-or-open-file (path)
  "Direct-edit regular file PATH in preview pane, or fall back to `find-file'."
  (if (fboundp 'strata-preview-edit-file)
      (strata-preview-edit-file path)
    (when (fboundp 'strata-dirvish--flatten-layout)
      (strata-dirvish--flatten-layout))
    (find-file path)))

(defun strata-mouse--open-path (path dir-only-p)
  "Open PATH in the appropriate Strata pane; when DIR-ONLY-P, only navigate dirs."
  (when (and path (not (string-empty-p path)))
    (let ((is-dir (file-directory-p path)))
      (when (derived-mode-p 'dirvish-directory-view-mode)
        (when-let* ((dv (or (dirvish-curr)
                            (and (boundp 'dirvish--sessions)
                                 (gethash (dirvish-prop :dv) dirvish--sessions))))
                    (root-win (or (let ((rw (dv-root-window dv)))
                                    (and (window-live-p rw) rw))
                                  (and (fboundp 'strata-panes--main-window)
                                       (strata-panes--main-window)))))
          (when (window-live-p root-win)
            (select-window root-win))))
      (cond
       (is-dir
        (strata-open-location path t))
       ((not dir-only-p)
        (strata-mouse--edit-or-open-file path))))))

(defun strata-mouse--sync-event (event)
  "Move window selection & point to EVENT and sync active split pane."
  (mouse-set-point event)
  (when (fboundp 'strata-panes--sync-active-pane-from-window)
    (strata-panes--sync-active-pane-from-window (selected-window))))

(defun strata-mouse--dired-entry-at-pt (pt)
  "Resolve nearest Dired entry path around buffer position PT."
  (save-excursion
    (goto-char (min (max (point-min) pt) (point-max)))
    (or (strata-mouse--entry-at-point)
        (save-excursion
          (let (found)
            (while (and (not found) (= (forward-line -1) 0))
              (setq found (ignore-errors (dired-get-filename nil t))))
            found))
        (save-excursion
          (let (found)
            (while (and (not found) (= (forward-line 1) 0))
              (setq found (ignore-errors (dired-get-filename nil t))))
            found)))))

(defun strata-mouse--compact-entry-at-pt (pt)
  "Resolve nearest Compact cell path around buffer position PT."
  (save-excursion
    (goto-char (min (max (point-min) pt) (point-max)))
    (or (get-text-property (point) 'strata-entry)
        (let ((find-on-line
               (lambda (ref)
                 (let ((le (line-end-position))
                       (pos (line-beginning-position))
                       (spans nil))
                   (while (< pos le)
                     (let ((nxt (or (next-single-property-change pos 'strata-entry nil le) le))
                           (val (get-text-property pos 'strata-entry)))
                       (when val
                         (push (list pos nxt val) spans))
                       (setq pos nxt)))
                   (when spans
                     (setq spans (nreverse spans))
                     (let ((hit (or (cl-find-if (lambda (s) (<= (car s) ref)) (reverse spans))
                                    (car spans))))
                       (nth 2 hit)))))))
          (or (funcall find-on-line (point))
              (save-excursion
                (let (found)
                  (while (and (not found) (= (forward-line -1) 0))
                    (setq found (funcall find-on-line (point))))
                  found))
              (save-excursion
                (let (found)
                  (while (and (not found) (= (forward-line 1) 0))
                    (setq found (funcall find-on-line (point))))
                  found)))))))

(defun strata-mouse--icons-entry-at-posn (win pt xy)
  "Resolve nearest Icons tile path around WIN position PT / pixel XY."
  (save-excursion
    (goto-char (min (max (point-min) pt) (point-max)))
    (or (get-text-property (point) 'strata-entry)
        (let ((line-spans
               (lambda ()
                 (let ((pos (line-beginning-position))
                       (le (line-end-position))
                       (out nil))
                   (while (< pos le)
                     (let ((nxt (or (next-single-property-change pos 'strata-entry nil le) le))
                           (val (get-text-property pos 'strata-entry)))
                       (when (and val (not (equal val (car (car out)))))
                         (push (list val pos nxt) out))
                       (setq pos nxt)))
                   (nreverse out)))))
          (let ((spans
                 (or (funcall line-spans)
                     (save-excursion (and (= (forward-line -1) 0) (funcall line-spans)))
                     (save-excursion (and (= (forward-line 1) 0) (funcall line-spans)))
                     (save-excursion
                       (let (res)
                         (while (and (not res) (= (forward-line -1) 0))
                           (setq res (funcall line-spans)))
                         res))
                     (save-excursion
                       (let (res)
                         (while (and (not res) (= (forward-line 1) 0))
                           (setq res (funcall line-spans)))
                         res)))))
            (when spans
              (let* ((px (and (consp xy) (integerp (car xy)) (car xy)))
                     (use-px (and px
                                  (window-live-p win)
                                  (display-graphic-p (window-frame win))
                                  (pos-visible-in-window-p (nth 1 (car spans)) win t)))
                     (best nil)
                     (best-dist most-positive-fixnum))
                (dolist (sp spans)
                  (let* ((beg (nth 1 sp))
                         (end (nth 2 sp))
                         (center (if use-px
                                     (let ((p0 (car (pos-visible-in-window-p beg win t)))
                                           (p1 (car (pos-visible-in-window-p (max beg (1- end)) win t))))
                                       (if (and p0 p1) (/ (+ p0 p1) 2) (or p0 0)))
                                   (/ (+ beg end) 2)))
                         (target (if use-px px pt))
                         (dist (abs (- target center))))
                    (when (< dist best-dist)
                      (setq best-dist dist
                            best (car sp)))))
                best)))))))

(defun strata-mouse--posn-fallback-pt (win posn)
  "Estimate buffer point inside WIN when POSN lacks an integer point."
  (let* ((area (and (consp posn) (posn-area posn)))
         (xy (and (consp posn) (posn-x-y posn)))
         (cr (and (consp posn) (posn-col-row posn)))
         (row (and (not (memq area '(header-line tab-bar tool-bar mode-line
                                     bottom-divider horizontal-scroll-bar)))
                   (or (and (integerp (cdr-safe cr)) (cdr cr))
                       (when (and (consp xy) (integerp (cdr xy)))
                         (/ (max 0 (cdr xy))
                            (max 1 (frame-char-height (window-frame win)))))))))
    (cond
     ((memq area '(header-line tab-bar tool-bar))
      (window-start win))
     ((memq area '(mode-line bottom-divider horizontal-scroll-bar))
      (max (point-min) (1- (window-end win t))))
     ((integerp row)
      (save-excursion
        (goto-char (window-start win))
        (forward-line (max 0 row))
        (point)))
     (t (point)))))

(defun strata-mouse--entry-at-posn (posn &optional nearest-p)
  "Resolve entry path at mouse POSN; with NEAREST-P snap across padding/gaps."
  (let* ((win (and (consp posn) (posn-window posn)))
         (area (and (consp posn) (posn-area posn)))
         (raw-pt (and (consp posn) (posn-point posn)))
         (xy (and (consp posn) (posn-x-y posn))))
    (when (and (window-live-p win)
               (buffer-live-p (window-buffer win)))
      (with-current-buffer (window-buffer win)
        (let ((pt (and (not area)
                       (integerp raw-pt)
                       (>= raw-pt (point-min))
                       (< raw-pt (point-max))
                       raw-pt)))
          (save-excursion
            (or (when pt
                  (goto-char (min pt (point-max)))
                  (strata-mouse--entry-at-point))
                (when nearest-p
                  (let ((p (or pt (strata-mouse--posn-fallback-pt win posn))))
                    (cond
                     ((derived-mode-p 'dired-mode) (strata-mouse--dired-entry-at-pt p))
                     ((derived-mode-p 'strata-compact-mode) (strata-mouse--compact-entry-at-pt p))
                     ((derived-mode-p 'strata-icons-mode) (strata-mouse--icons-entry-at-posn win p xy))))))))))))

(defun strata-mouse--range-entries (order anchor target &optional rect-p)
  "Return ordered entry paths between ANCHOR and TARGET in ORDER.
When RECT-P is non-nil in Icons/Compact multi-column views, use the 2D box."
  (let* ((keys (mapcar #'strata--path-key order))
         (i1 (and anchor (cl-position (strata--path-key anchor) keys :test #'equal)))
         (i2 (and target (cl-position (strata--path-key target) keys :test #'equal)))
         (n (length order)))
    (cond
     ((and i1 i2 rect-p (derived-mode-p 'strata-icons-mode) (> (or strata-icons--ncols 1) 1))
      (let* ((ncols (max 1 strata-icons--ncols))
             (r1 (/ i1 ncols)) (c1 (mod i1 ncols))
             (r2 (/ i2 ncols)) (c2 (mod i2 ncols))
             (out nil))
        (cl-loop for r from (min r1 r2) to (max r1 r2) do
                 (cl-loop for c from (min c1 c2) to (max c1 c2)
                          for idx = (+ (* r ncols) c)
                          when (< idx n)
                          do (push (nth idx order) out)))
        (nreverse out)))
     ((and i1 i2 rect-p (derived-mode-p 'strata-compact-mode)
           (> n (max 1 (or strata-compact-rows 1))))
      (let* ((rows (max 1 strata-compact-rows))
             (c1 (/ i1 rows)) (r1 (mod i1 rows))
             (c2 (/ i2 rows)) (r2 (mod i2 rows))
             (out nil))
        (cl-loop for c from (min c1 c2) to (max c1 c2) do
                 (cl-loop for r from (min r1 r2) to (max r1 r2)
                          for idx = (+ (* c rows) r)
                          when (< idx n)
                          do (push (nth idx order) out)))
        (nreverse out)))
     ((and i1 i2)
      (cl-loop for i from (min i1 i2) to (max i1 i2)
               collect (nth i order)))
     (target (list target)))))

(defun strata-mouse--apply-selection-keys (order target-keys &optional final-p)
  "Sync current buffer marks to exact set of TARGET-KEYS efficiently.
When FINAL-P is non-nil in Compact/Icons, re-render mark badges cleanly."
  (let ((want (make-hash-table :test #'equal)))
    (dolist (k target-keys)
      (when k (puthash k t want)))
    (cond
     ((derived-mode-p 'dired-mode)
      (let* ((cur (strata-marked-files-only))
             (have (make-hash-table :test #'equal)))
        (dolist (f cur)
          (puthash (strata--path-key f) t have))
        (save-excursion
          (dolist (f cur)
            (unless (gethash (strata--path-key f) want)
              (when (or (ignore-errors (dired-goto-file f))
                        (ignore-errors (dired-goto-file (concat (directory-file-name f) "/"))))
                (dired-unmark 1))))
          (let ((dired-marker-char ?*))
            (dolist (f order)
              (let ((k (strata--path-key f)))
                (when (and (gethash k want) (not (gethash k have)))
                  (when (or (ignore-errors (dired-goto-file f))
                            (ignore-errors (dired-goto-file (concat (directory-file-name f) "/"))))
                    (dired-mark 1)))))))
        (strata-view--update-selection-highlight)
        (force-mode-line-update t)))
     ((derived-mode-p 'strata-compact-mode 'strata-icons-mode)
      ;; Store reversed so `strata-marked-files-only' yields directory order.
      ;; Filtering can share ORDER's tail; leave the active drag's cached
      ;; directory order intact when a selection includes the final files.
      (setq strata-marked-entries
            (reverse (cl-remove-if-not (lambda (f) (gethash (strata--path-key f) want)) order)))
      (if final-p
          (strata-view--refresh-after-mark)
        (strata-view--update-selection-highlight)
        (force-mode-line-update t))))))

(defun strata-mouse--has-drop-target-p (src-win)
  "Return non-nil when another pane or visible Places sidebar can accept drops."
  (or (and (bound-and-true-p strata-sidebar-window)
           (window-live-p strata-sidebar-window)
           (not (eq strata-sidebar-window src-win)))
      (cl-some (lambda (w)
                 (and (not (eq w src-win))
                      (fboundp 'strata-panes--valid-main-window-p)
                      (strata-panes--valid-main-window-p w)))
               (window-list (and (window-live-p src-win) (window-frame src-win)) 'no-minibuf))))

(defun strata-mouse--drag-exceeded-p (start-xy end-xy start-win end-win exact-start cur-entry)
  "Return non-nil once drag movement crosses click threshold or changes entry."
  (or (not (eq start-win end-win))
      (and cur-entry exact-start
           (not (equal (strata--path-key cur-entry)
                       (strata--path-key exact-start))))
      (and (consp start-xy) (consp end-xy)
           (integerp (car start-xy)) (integerp (cdr start-xy))
           (integerp (car end-xy)) (integerp (cdr end-xy))
           (let ((dx (- (car end-xy) (car start-xy)))
                 (dy (- (cdr end-xy) (cdr start-xy))))
             (> (+ (* dx dx) (* dy dy)) 36)))))

(defun strata-mouse--sync-drag-range (order base-keys anchor hover rect-p last-keys-cell last-hover-cell &optional final-p)
  "Update swept marks from ANCHOR to HOVER inside ORDER when changed."
  (when (and anchor hover)
    (let* ((range (strata-mouse--range-entries order anchor hover rect-p))
           (keys (delete-dups (append (copy-sequence base-keys)
                                      (mapcar #'strata--path-key range)))))
      (setcar last-hover-cell hover)
      (when (or final-p (not (equal keys (car last-keys-cell))))
        (setcar last-keys-cell keys)
        ;; Let the command loop redisplay.  Forced redisplay here can run
        ;; timers and reenter selection updates while processing motion.
        (strata-mouse--apply-selection-keys order keys final-p)))))

(defun strata-mouse--edge-scroll-step (win mcol mrow order base-keys anchor rect-p last-keys-cell last-hover-cell)
  "Scroll WIN one line when dragging above/below its viewport and extend marks."
  (when (and (window-live-p win) (integerp mcol) (integerp mrow))
    (let* ((edges (window-inside-edges win))
           (left (nth 0 edges))
           (top (nth 1 edges))
           (right (nth 2 edges))
           (bottom (nth 3 edges))
           (dir (when (and (<= left mcol) (< mcol right))
                  (cond ((< mrow top) -1)
                        ((>= mrow bottom) 1)
                        (t 0)))))
      (when (and dir (not (zerop dir)))
        (with-selected-window win
          (ignore-errors
            (if (< dir 0) (scroll-down 1) (scroll-up 1)))
          (let* ((probe-pt (if (< dir 0)
                               (window-start win)
                             (max (point-min) (1- (window-end win t)))))
                 (edge-posn (list win probe-pt '(0 . 0) 0))
                 (hover (strata-mouse--entry-at-posn edge-posn t)))
            (strata-mouse--sync-drag-range
             order base-keys anchor hover rect-p last-keys-cell last-hover-cell nil)
            (when hover
              (strata-goto-file hover)))))
      (or dir 0))))

(defun strata-mouse--stop-timer-field (st field)
  "Cancel timer stored in ST under FIELD and clear it."
  (let ((tm (plist-get st field)))
    (when (timerp tm)
      (cancel-timer tm))
    (plist-put st field nil)))

(defun strata-mouse--hide-drag-feedback (st)
  "Remove ST's floating file badge and restore ordinary help tooltips."
  (when (plist-get st :feedback-visible-p)
    (plist-put st :feedback-visible-p nil)
    (let ((use-system-tooltips nil))
      (ignore-errors (x-hide-tip))))
  (when (plist-get st :feedback-suspended-p)
    (plist-put st :feedback-suspended-p nil)
    (when (plist-get st :feedback-tooltip-mode) (tooltip-mode 1))
    (setq show-help-function (plist-get st :feedback-show-help)))
  (plist-put st :feedback-last-time nil))

(defun strata-mouse--drag-feedback-text (files action destination)
  "Describe FILES, ACTION and DESTINATION for the floating drag badge.
Use only the cached filenames; do not probe files while handling motion."
  (let ((count (length files)))
    (concat
     (propertize (format "%d item%s — %s" count (if (= count 1) "" "s") action)
                 'face 'bold)
     "\n"
     (mapconcat
      (lambda (path)
        (concat (strata-icon-glyph 'file nil "▤") "  "
                (truncate-string-to-width
                 (replace-regexp-in-string "[\n\r\t]" " "
                                           (file-name-nondirectory (directory-file-name path)))
                 42 nil nil "…")))
      (cl-subseq files 0 (min 3 count)) "\n")
     (when (> count 3) (format "\n… and %d more" (- count 3)))
     "\n" (truncate-string-to-width destination 52 nil nil "…"))))

(defun strata-mouse--show-drag-feedback (st event files drop-dir)
  "Show a file badge beside the pointer for ST, throttled to 25 updates/sec."
  (when (and files (display-graphic-p (window-frame (plist-get st :src-win)))
             (fboundp 'x-show-tip) (not (plist-get st :feedback-disabled-p)))
    (let* ((mods (event-modifiers event))
           (action (cond ((or (memq 'control mods) (plist-get st :ctrl-p)) "Copy")
                         ((or (memq 'shift mods) (plist-get st :shift-p)) "Move")
                         (t "Copy / Move")))
           (destination (if drop-dir
                            (concat "To: " (abbreviate-file-name drop-dir))
                          (if (eq (posn-window (event-end event)) (plist-get st :src-win))
                              "Drag to another pane or Places folder"
                            "No drop here")))
           (key (list files action destination))
           (now (float-time)))
      (when (or (not (equal key (plist-get st :feedback-key)))
                (>= (- now (or (plist-get st :feedback-last-time) 0)) 0.04))
        (condition-case nil
            (progn
              (unless (plist-get st :feedback-suspended-p)
                (plist-put st :feedback-tooltip-mode tooltip-mode)
                (plist-put st :feedback-show-help show-help-function)
                (plist-put st :feedback-suspended-p t)
                ;; As in Emacs's own text drag, ordinary hover tooltips
                ;; must not hide the file badge before each motion command.
                (when tooltip-mode (tooltip-mode -1)))
              (unless (equal key (plist-get st :feedback-key))
                (plist-put st :feedback-key key)
                (plist-put st :feedback-text
                           (strata-mouse--drag-feedback-text files action destination)))
              (plist-put st :feedback-last-time now)
              (plist-put st :feedback-visible-p t)
              (setq mouse-fine-grained-tracking t)
              (let* ((use-system-tooltips nil)
                     (params (cl-remove-if
                              (lambda (pair) (memq (car pair) '(left right top bottom)))
                              tooltip-frame-parameters))
                     (foreground (face-attribute 'tooltip :foreground))
                     (background (face-attribute 'tooltip :background)))
                (when (stringp foreground)
                  (setf (alist-get 'foreground-color params) foreground
                        (alist-get 'border-color params) foreground))
                (when (stringp background)
                  (setf (alist-get 'background-color params) background))
                (x-show-tip (plist-get st :feedback-text)
                            (window-frame (plist-get st :src-win))
                            params 60 18 24)))
          (error
           ;; Feedback is optional; a display failure must never break a
           ;; transfer or leave mouse tracking and tooltip settings altered.
           (strata-mouse--hide-drag-feedback st)
           (plist-put st :feedback-disabled-p t)))))))

(defun strata-mouse--restore-drag-vars (st)
  "Restore global mouse tracking and scrolling variables captured in ST."
  (when (and st (not (plist-get st :restored-p)))
    (strata-mouse--hide-drag-feedback st)
    (plist-put st :restored-p t)
    (when (plist-member st :saved-fine-tracking)
      (setq mouse-fine-grained-tracking (plist-get st :saved-fine-tracking)))
    (setq track-mouse (plist-get st :saved-track)
          auto-hscroll-mode (plist-get st :saved-hscroll)
          scroll-margin (plist-get st :saved-margin))))

(defun strata-mouse--abort-drag (st)
  "Release all tracking for failed ST and suppress its pending mouse release."
  (when st
    (dolist (field '(:scroll-timer :cleanup-timer :watchdog-timer))
      (strata-mouse--stop-timer-field st field))
    (plist-put st :cancelled-p t)
    (strata-mouse--restore-drag-vars st)
    (unwind-protect
        (when-let ((exit-fn (plist-get st :exit-fn))) (funcall exit-fn))
      (setq strata-mouse--drag-state nil
            strata-mouse--finished-drag-state st))))

(defun strata-mouse--scroll-tick (st)
  "Advance auto-scroll selection by one tick for active drag state ST."
  (condition-case err
      (strata-mouse--scroll-tick-1 st)
    ((error quit)
     (strata-mouse--abort-drag st)
     (message "Drag selection cancelled: %s" (error-message-string err)))))

(defun strata-mouse--scroll-tick-1 (st)
  "Process one auto-scroll tick for ST without leaving failed timers active."
  (if (not (eq st strata-mouse--drag-state))
      (strata-mouse--stop-timer-field st :scroll-timer)
    (let ((src-win (plist-get st :src-win))
          (src-buf (plist-get st :src-buf)))
      (if (or (not (window-live-p src-win))
              (not (buffer-live-p src-buf))
              (not (eq (window-buffer src-win) src-buf))
              (plist-get st :carry-marked-p))
          (strata-mouse--stop-timer-field st :scroll-timer)
        (let* ((strata-mouse--inhibit-preview t)
               (old-start (window-start src-win))
               (mp (cdr (mouse-position)))
               (dir (strata-mouse--edge-scroll-step
                     src-win (car-safe mp) (cdr-safe mp)
                     (plist-get st :order) (plist-get st :base-keys)
                     (plist-get st :anchor) (plist-get st :rect-p)
                     (plist-get st :last-keys-cell) (plist-get st :last-hover-cell))))
          (when (or (null dir) (zerop dir)
                    (= old-start (window-start src-win)))
            (strata-mouse--stop-timer-field st :scroll-timer)))))))

(defun strata-mouse--update-scroll-timer (st)
  "Start or stop viewport edge auto-scroll timer for active drag state ST."
  (let* ((src-win (plist-get st :src-win))
         (mp (and (window-live-p src-win)
                  (not (plist-get st :carry-marked-p))
                  (cdr (mouse-position))))
         (mcol (car-safe mp))
         (mrow (cdr-safe mp))
         (edges (and (integerp mcol) (integerp mrow) (window-inside-edges src-win)))
         (need-p (and edges
                      (<= (nth 0 edges) mcol) (< mcol (nth 2 edges))
                      (or (< mrow (nth 1 edges)) (>= mrow (nth 3 edges))))))
    (if need-p
        (unless (timerp (plist-get st :scroll-timer))
          (plist-put st :scroll-timer (run-at-time 0.12 0.12 #'strata-mouse--scroll-tick st)))
      (strata-mouse--stop-timer-field st :scroll-timer))))

(defun strata-mouse--cleanup-abandoned-drag (st)
  "Finalize drag ST on idle if no button-1 release command consumed it."
  (when (eq strata-mouse--finished-drag-state st)
    (setq strata-mouse--finished-drag-state nil)
    (strata-mouse--stop-timer-field st :cleanup-timer)
    (let ((src-win (plist-get st :src-win))
          (src-buf (plist-get st :src-buf)))
      (when (and (not (plist-get st :cancelled-p))
                 (plist-get st :dragged-p)
                 (window-live-p src-win)
                 (buffer-live-p src-buf)
                 (eq (window-buffer src-win) src-buf))
        (with-selected-window src-win
          (let ((strata-mouse--inhibit-preview t)
                (anchor (plist-get st :anchor))
                (hover (car (plist-get st :last-hover-cell))))
            (when (and anchor hover (not (plist-get st :carry-marked-p)))
              (setq-local strata--selection-anchor-entry anchor)
              (strata-mouse--sync-drag-range
               (plist-get st :order) (plist-get st :base-keys) anchor hover
               (plist-get st :rect-p) (plist-get st :last-keys-cell)
               (plist-get st :last-hover-cell) t)))
          (strata-view--sync-preview-on-move))))))

(defun strata-mouse--on-drag-exit ()
  "Tear down active transient drag state and hand off to button-1 release."
  (let ((st strata-mouse--drag-state))
    (when st
      (strata-mouse--stop-timer-field st :scroll-timer)
      (strata-mouse--stop-timer-field st :watchdog-timer)
      (strata-mouse--restore-drag-vars st)
      (setq strata-mouse--drag-state nil
            strata-mouse--finished-drag-state st)
      (unless (plist-get st :cancelled-p)
        (strata-mouse--stop-timer-field st :cleanup-timer)
        (plist-put st :cleanup-timer
                   (run-at-time 0 nil #'strata-mouse--cleanup-abandoned-drag st))))))

(defun strata-mouse--take-finished-drag (&optional start-posn)
  "Consume and return completed drag state matching START-POSN, if any."
  (let ((st strata-mouse--finished-drag-state)
        (win (and (consp start-posn) (posn-window start-posn))))
    (when (and st (or (null win) (eq win (plist-get st :src-win))))
      (strata-mouse--stop-timer-field st :cleanup-timer)
      (setq strata-mouse--finished-drag-state nil)
      st)))

(defun strata-mouse--drag-keep-p ()
  "Keep transient drag keymap active only for movement and cancel commands."
  (memq this-command '(strata-mouse--drag-move strata-mouse--drag-cancel ignore)))

(defun strata-mouse--drag-keymap ()
  "Build transient keymap handling live mouse motion, cancel, and area releases."
  (let ((bindings '(([mouse-movement] . strata-mouse--drag-move)
                    ([C-mouse-movement] . strata-mouse--drag-move)
                    ([S-mouse-movement] . strata-mouse--drag-move)
                    ([C-S-mouse-movement] . strata-mouse--drag-move)
                    ([M-mouse-movement] . strata-mouse--drag-move)
                    ([escape] . strata-mouse--drag-cancel)
                    ([7] . strata-mouse--drag-cancel)
                    ([down-mouse-3] . strata-mouse--drag-cancel)
                    ([mouse-3] . strata-mouse--drag-cancel)
                    ([drag-mouse-3] . strata-mouse--drag-cancel)
                    ([switch-frame] . strata-mouse--drag-cancel)
                    ([select-window] . strata-mouse--drag-cancel)
                    ([scroll-bar-movement] . ignore)))
        (area-releases '(([drag-mouse-1] . strata-mouse-drag-drop)
                         ([C-drag-mouse-1] . strata-mouse-drag-copy)
                         ([S-drag-mouse-1] . strata-mouse-drag-move)
                         ([C-S-drag-mouse-1] . strata-mouse-drag-drop)
                         ([double-drag-mouse-1] . strata-mouse-drag-drop)
                         ([mouse-1] . strata-mouse-click-entry)
                         ([C-mouse-1] . strata-mouse-toggle-select)
                         ([C-S-mouse-1] . strata-mouse-add-range-select)
                         ([S-mouse-1] . strata-mouse-range-select)))
        (map (make-sparse-keymap)))
    (dolist (pair bindings)
      (define-key map (car pair) (cdr pair)))
    (define-key map (kbd "ESC") #'strata-mouse--drag-cancel)
    (dolist (area '(mode-line header-line vertical-line right-divider bottom-divider
                    left-margin right-margin left-fringe right-fringe
                    tab-bar tool-bar vertical-scroll-bar horizontal-scroll-bar))
      (let ((sub (make-sparse-keymap)))
        (dolist (pair bindings)
          (define-key sub (car pair) (cdr pair)))
        (dolist (pair area-releases)
          (define-key sub (car pair) (cdr pair)))
        (define-key map (vector area) sub)))
    map))

(defun strata-mouse--drag-cancel (&optional ev)
  "Cancel active drag selection and restore original marks cleanly."
  (interactive (list (and (mouse-event-p last-input-event) last-input-event)))
  (let ((st (or strata-mouse--drag-state strata-mouse--finished-drag-state)))
    (when st
      (strata-mouse--stop-timer-field st :scroll-timer)
      (strata-mouse--stop-timer-field st :cleanup-timer)
      (strata-mouse--stop-timer-field st :watchdog-timer)
      (plist-put st :cancelled-p t)
      ;; Release global tracking and the transient map even if refreshing
      ;; the old selection signals an error or quit.
      (strata-mouse--restore-drag-vars st)
      (when-let ((exit-fn (plist-get st :exit-fn))) (funcall exit-fn))
      (when (and ev (memq (event-basic-type ev) '(mouse-3 down-mouse-3 drag-mouse-3)))
        (setq strata-mouse--suppress-mouse-3-once t))
      (let ((src-win (plist-get st :src-win))
            (src-buf (plist-get st :src-buf))
            (pre-keys (plist-get st :pre-keys))
            (last-keys-cell (plist-get st :last-keys-cell)))
        (when (and (window-live-p src-win)
                   (buffer-live-p src-buf)
                   (eq (window-buffer src-win) src-buf)
                   (not (equal (car last-keys-cell) pre-keys)))
          (with-selected-window src-win
            (let ((strata-mouse--inhibit-preview t))
              (strata-mouse--apply-selection-keys (plist-get st :order) pre-keys t)))))
      (setq strata-mouse--drag-state nil
            strata-mouse--finished-drag-state st)
      (message "Drag selection cancelled"))))

(defun strata-mouse--drag-watchdog (st)
  "Release abandoned drag ST after five idle seconds without mouse input."
  (when (eq st strata-mouse--drag-state)
    (strata-mouse--drag-cancel nil)))

(defun strata-mouse--drag-move (ev)
  "Update live drag highlight or cross-pane drop cue for motion event EV."
  (interactive "e")
  ;; Never drain input here.  GTK may report pending input while read-event
  ;; returns nil, causing an infinite busy loop; consuming events here also
  ;; steals releases and C-g from Emacs's native command loop.
  (condition-case err
      (strata-mouse--drag-move-1 ev)
    ((error quit)
     (strata-mouse--abort-drag strata-mouse--drag-state)
     (signal (car err) (cdr err)))))

(defun strata-mouse--drag-move-1 (ev)
  "Update one motion event EV without reading or waiting for further input."
  (let* ((st strata-mouse--drag-state)
         (src-win (plist-get st :src-win))
         (src-buf (plist-get st :src-buf)))
    (when st
      (if (not (and (window-live-p src-win)
                    (buffer-live-p src-buf)
                    (eq (window-buffer src-win) src-buf)))
          (strata-mouse--drag-cancel nil)
        (with-selected-window src-win
          (let* ((strata-mouse--inhibit-preview t)
                 (end (event-end ev))
                 (dst-win (posn-window end))
                 (cur (when (eq dst-win src-win)
                        (strata-mouse--entry-at-posn end t)))
                 (exact-start (plist-get st :exact-start))
                 (order (plist-get st :order))
                 (pre-marked (plist-get st :pre-marked))
                 (pre-keys (plist-get st :pre-keys))
                 (last-keys-cell (plist-get st :last-keys-cell))
                 (last-hover-cell (plist-get st :last-hover-cell))
                 (carry-marked-p (plist-get st :carry-marked-p)))
            (unless (plist-get st :dragged-p)
              (when (strata-mouse--drag-exceeded-p
                     (plist-get st :start-xy) (posn-x-y end)
                     src-win dst-win exact-start cur)
                (plist-put st :dragged-p t)))
            (when (plist-get st :dragged-p)
              (let ((drop-dir (and dst-win (not (eq dst-win src-win))
                                   (strata-mouse--drag-target-dir dst-win end))))
                (cond
                 (drop-dir
                  (strata-mouse--stop-timer-field st :scroll-timer)
                  (when (and carry-marked-p (not (equal (car last-keys-cell) pre-keys)))
                    (setcar last-keys-cell pre-keys)
                    (strata-mouse--apply-selection-keys order pre-keys nil))
                  (let* ((cur-marked (or (strata-marked-files-only)
                                         (when-let ((ns (plist-get st :near-start)))
                                           (list ns))))
                         (n (max 1 (length (if carry-marked-p pre-marked cur-marked)))))
                    (message "Drop %d item(s) into %s to copy/move"
                             n (abbreviate-file-name drop-dir))))
                 ((or (eq dst-win src-win) (null dst-win))
                  (when (and cur (eq dst-win src-win) (not carry-marked-p))
                    (strata-mouse--sync-drag-range
                     order (plist-get st :base-keys) (plist-get st :anchor) cur
                     (plist-get st :rect-p) last-keys-cell last-hover-cell nil))
                  (strata-mouse--update-scroll-timer st))
                 (t
                  (strata-mouse--stop-timer-field st :scroll-timer)))
                (if (or carry-marked-p drop-dir)
                    (strata-mouse--show-drag-feedback
                     st ev (if carry-marked-p pre-marked
                             (or (strata-marked-files-only)
                                 (when exact-start (list exact-start))))
                     drop-dir)
                  (strata-mouse--hide-drag-feedback st))))))))))

(defun strata-mouse-down-entry (event)
  "Start native live drag-selection tracking on button-1 press in a pane."
  (interactive "e")
  (setq strata-mouse--suppress-mouse-3-once nil)
  (when strata-mouse--drag-state
    (if-let ((exit-fn (plist-get strata-mouse--drag-state :exit-fn)))
        (funcall exit-fn)
      (strata-mouse--on-drag-exit)))
  (when strata-mouse--finished-drag-state
    (strata-mouse--stop-timer-field strata-mouse--finished-drag-state :cleanup-timer)
    (setq strata-mouse--finished-drag-state nil))
  (let* ((start (event-start event))
         (src-win (posn-window start)))
    (unless (or (posn-area start)
                (not (window-live-p src-win))
                (not (with-current-buffer (window-buffer src-win)
                       (derived-mode-p 'dired-mode 'strata-compact-mode 'strata-icons-mode))))
      (select-window src-win)
      (when (fboundp 'strata-panes--sync-active-pane-from-window)
        (strata-panes--sync-active-pane-from-window src-win))
      (let* ((mods (event-modifiers event))
             (ctrl-p (memq 'control mods))
             (shift-p (memq 'shift mods))
             (start-xy (posn-x-y start))
             (order (strata-view--entry-order))
             (exact-start (strata-mouse--entry-at-posn start nil))
             (near-start (or exact-start (strata-mouse--entry-at-posn start t)))
             (pre-marked (strata-marked-files-only))
             (pre-keys (mapcar #'strata--path-key pre-marked))
             (started-on-marked-p
              (and exact-start (member (strata--path-key exact-start) pre-keys)))
             (carry-marked-p
              (and started-on-marked-p
                   (not ctrl-p)
                   (or shift-p
                       (strata-mouse--has-drop-target-p src-win))))
             (rect-p (derived-mode-p 'strata-compact-mode 'strata-icons-mode))
             (anchor (if shift-p
                         (or strata--selection-anchor-entry near-start)
                       near-start))
             (base-keys (when (or ctrl-p shift-p) pre-keys)))
        (when order
          (let ((st (list :src-win src-win
                          :src-buf (window-buffer src-win)
                          :start start
                          :start-xy start-xy
                          :ctrl-p ctrl-p
                          :shift-p shift-p
                          :order order
                          :exact-start exact-start
                          :near-start near-start
                          :pre-marked pre-marked
                          :pre-keys pre-keys
                          :carry-marked-p carry-marked-p
                          :rect-p rect-p
                          :anchor anchor
                          :base-keys base-keys
                          :last-keys-cell (list pre-keys)
                          :last-hover-cell (list near-start)
                          :dragged-p nil
                          :cancelled-p nil
                          :saved-hscroll auto-hscroll-mode
                          :saved-margin scroll-margin
                          :saved-track track-mouse
                          :saved-fine-tracking mouse-fine-grained-tracking
                          :scroll-timer nil
                          :watchdog-timer nil
                          :cleanup-timer nil
                          :restored-p nil
                          :feedback-visible-p nil
                          :feedback-suspended-p nil
                          :feedback-disabled-p nil
                          :feedback-key nil
                          :feedback-text nil
                          :feedback-last-time nil
                          :exit-fn nil)))
            ;; Set `track-mouse' directly instead of using `(track-mouse ...)' so
            ;; emacs bug#51794 does not cancel motion over `header-line-format'.
            (setq strata-mouse--drag-state st
                  auto-hscroll-mode nil
                  scroll-margin 0
                  track-mouse 'drag-tracking)
            (plist-put st :exit-fn
                       (set-transient-map
                        (strata-mouse--drag-keymap)
                        #'strata-mouse--drag-keep-p
                        #'strata-mouse--on-drag-exit))
            (plist-put st :watchdog-timer
                       (run-with-idle-timer 5 nil #'strata-mouse--drag-watchdog st))))))))

(defun strata-mouse--run-click-action (event)
  "Execute single click for EVENT: open clicked dir, preview file, or clear."
  ;; Resolve the actual hit before mouse-set-point can clamp empty space
  ;; below the listing onto its final row.  Nearest-entry lookup is for
  ;; sweeping a drag range, never for an ordinary click.
  (let ((p (strata-mouse--entry-at-posn (event-end event))))
    (strata-mouse--sync-event event)
    (if p
      (progn
        (strata-clear-all-marks)
        (strata-view--reset-selection-range p)
        (if (file-directory-p p)
            (strata-mouse--open-path p t)
          (when (derived-mode-p 'strata-icons-mode)
            (strata-goto-file p))
          (strata-view--sync-preview-on-move)))
      (strata-clear-all-marks)
      (goto-char (point-max))
      (setq strata--empty-click-p t)
      (strata-view--reset-selection-range)
      (strata-view--update-selection-highlight))))

(defun strata-mouse--run-toggle-action (event)
  "Execute control-click for EVENT: toggle mark on clicked entry."
  (strata-mouse--sync-event event)
  (when-let ((p (strata-mouse--entry-at-point)))
    (let* ((key (strata--path-key p))
           (marked (cl-some (lambda (e) (equal (strata--path-key e) key))
                            (strata-marked-files-only))))
      (strata-view--reset-selection-range p)
      (strata-view--set-entry-mark p (not marked) nil))))

(defun strata-mouse--run-range-action (event &optional additive)
  "Execute shift-click for EVENT: select contiguous range from anchor."
  (let* ((ev-win (or (posn-window (event-start event)) (selected-window)))
         (prev-anchor (when (window-live-p ev-win)
                        (with-current-buffer (window-buffer ev-win)
                          (or strata--selection-anchor-entry
                              (strata-current-file))))))
    (strata-mouse--sync-event event)
    (when-let ((target (strata-mouse--entry-at-point)))
      (let ((anchor (or prev-anchor target)))
        (strata-view--mark-range anchor target additive)))))

(defun strata-mouse--run-activate-action (event)
  "Execute activation click for EVENT: open directory or edit file."
  (strata-mouse--sync-event event)
  (when-let ((p (strata-mouse--entry-at-point)))
    (strata-mouse--open-path p nil)))

(defun strata-mouse--finish-drag (st event &optional forced-mode)
  "Finalize drag ST on release EVENT, performing selection, drop, or click."
  (unless (plist-get st :cancelled-p)
    (let* ((src-win (plist-get st :src-win))
           (src-buf (plist-get st :src-buf))
           (end (event-end event))
           (dst-win (or (posn-window end) src-win))
           (end-mods (event-modifiers event))
           (cur (when (and (window-live-p src-win) (eq dst-win src-win))
                  (strata-mouse--entry-at-posn end t))))
      (when (and (window-live-p src-win)
                 (buffer-live-p src-buf)
                 (eq (window-buffer src-win) src-buf))
        (unless (plist-get st :dragged-p)
          (when (strata-mouse--drag-exceeded-p
                 (plist-get st :start-xy) (posn-x-y end)
                 src-win dst-win (plist-get st :exact-start) cur)
            (plist-put st :dragged-p t)))
        (if (not (plist-get st :dragged-p))
            (cond
             ((memq 'double end-mods) (strata-mouse--run-activate-action event))
             ((and (or (memq 'control end-mods) (plist-get st :ctrl-p))
                   (or (memq 'shift end-mods) (plist-get st :shift-p)))
              (strata-mouse--run-range-action event t))
             ((or (memq 'control end-mods) (plist-get st :ctrl-p))
              (strata-mouse--run-toggle-action event))
             ((or (memq 'shift end-mods) (plist-get st :shift-p))
              (strata-mouse--run-range-action event))
             (t (strata-mouse--run-click-action event)))
          (select-window src-win)
          (when (fboundp 'strata-panes--sync-active-pane-from-window)
            (strata-panes--sync-active-pane-from-window src-win))
          (let* ((drop-dir (and (not (eq dst-win src-win))
                                (strata-mouse--drag-target-dir dst-win end)))
                 (effective-mode
                  (or forced-mode
                      (cond ((memq 'control end-mods) 'copy)
                            ((memq 'shift end-mods) 'cut)
                            ((plist-get st :ctrl-p) 'copy)
                            ((plist-get st :shift-p) 'cut)
                            (t nil))))
                 (pre-keys (plist-get st :pre-keys))
                 (carry-marked-p (plist-get st :carry-marked-p)))
            (if drop-dir
                (progn
                  (when (and carry-marked-p
                             (not (equal (car (plist-get st :last-keys-cell)) pre-keys)))
                    (strata-mouse--apply-selection-keys (plist-get st :order) pre-keys nil))
                  (strata-mouse--drag-drop-now
                   src-win dst-win (plist-get st :start) end
                   (plist-get st :exact-start)
                   (or (strata-marked-files-only) (plist-get st :pre-marked))
                   effective-mode))
              (let ((anchor (plist-get st :anchor))
                    (exact-start (plist-get st :exact-start))
                    (hover (or cur (car (plist-get st :last-hover-cell)))))
                (when (and anchor hover
                           (or (not carry-marked-p)
                               (and (eq dst-win src-win)
                                    exact-start
                                    (not (equal (strata--path-key hover)
                                                (strata--path-key exact-start))))))
                  (setq-local strata--selection-anchor-entry anchor)
                  (strata-mouse--sync-drag-range
                   (plist-get st :order) (plist-get st :base-keys) anchor hover
                   (plist-get st :rect-p) (plist-get st :last-keys-cell)
                   (plist-get st :last-hover-cell) t)
                  (strata-goto-file hover)
                  (message "Selected %d item(s)" (length (strata-marked-files-only))))
                (strata-view--sync-preview-on-move)))))))))

(defun strata-mouse-toggle-select (event)
  "Toggle multi-selection mark on clicked entry (`C-<mouse-1>')."
  (interactive "e")
  (if-let ((st (strata-mouse--take-finished-drag (event-start event))))
      (strata-mouse--finish-drag st event)
    (strata-mouse--run-toggle-action event)))

(defun strata-mouse-range-select (event)
  "Select contiguous range of entries from anchor to EVENT (`S-<mouse-1>')."
  (interactive "e")
  (if-let ((st (strata-mouse--take-finished-drag (event-start event))))
      (strata-mouse--finish-drag st event)
    (strata-mouse--run-range-action event)))

(defun strata-mouse-add-range-select (event)
  "Add the range to EVENT to the current selection (`C-S-<mouse-1>')."
  (interactive "e")
  (if-let ((st (strata-mouse--take-finished-drag (event-start event))))
      (strata-mouse--finish-drag st event)
    (strata-mouse--run-range-action event t)))

(defun strata-mouse--drag-target-dir (dst-win end-posn)
  "Resolve writable drop folder for drag-and-drop into DST-WIN at END-POSN."
  (when (window-live-p dst-win)
    (cond
     ((eq dst-win (bound-and-true-p strata-sidebar-window))
      (with-current-buffer (window-buffer dst-win)
        (let* ((pt (or (and (integerp (posn-point end-posn)) (posn-point end-posn))
                       (point)))
               (loc (or (get-text-property pt 'strata-sidebar-loc)
                        (save-excursion
                          (goto-char (min pt (point-max)))
                          (get-text-property (line-beginning-position) 'strata-sidebar-loc)))))
          (when (and (stringp loc) (file-directory-p loc))
            loc))))
     ((and (fboundp 'strata-panes--valid-main-window-p)
           (strata-panes--valid-main-window-p dst-win)
           (fboundp 'strata-panes--window-dir))
      (strata-panes--window-dir dst-win)))))

(defun strata-mouse--drag-drop-now (src-win dst-win _start end src-entry marked &optional forced-mode)
  "Copy or move MARKED/SRC-ENTRY dragged from SRC-WIN into DST-WIN."
  (let* ((marked-keys (mapcar #'strata--path-key marked))
         (files (if (and marked
                         (or (not src-entry)
                             (member (strata--path-key src-entry) marked-keys)))
                    marked
                  (when src-entry (list src-entry))))
         (dest-dir (strata-mouse--drag-target-dir dst-win end))
         (src-dir (and (fboundp 'strata-panes--window-dir)
                       (strata-panes--window-dir src-win))))
    (unless files
      (user-error "No file or folder selected to drag"))
    (unless (and dest-dir (file-directory-p dest-dir))
      (user-error "Drop onto another split pane folder or Places directory"))
    (when (and src-dir
               (equal (file-truename src-dir) (file-truename dest-dir)))
      (user-error "Source and destination folders are identical"))
    (let* ((mode (or forced-mode
                    (if (strata-ui-mouse-p)
                        (strata-ui-choice
                         (format "Drop %d item(s) into %s"
                                 (length files) (abbreviate-file-name dest-dir))
                         '(("Copy" . copy) ("Move" . cut) ("Cancel" . nil)))
                     (pcase (read-char-choice
                             (format "Drop %d item(s) into %s: [c] Copy  [m] Move  [q] Cancel? "
                                     (length files) (abbreviate-file-name dest-dir))
                             '(?c ?C ?m ?M ?q ?Q ?\e))
                       ((or ?c ?C) 'copy)
                       ((or ?m ?M) 'cut)
                       (_ nil))))))
      (when mode
        (with-selected-window src-win
          (strata--transfer-files files dest-dir mode)
          (when (eq mode 'cut)
            (when (derived-mode-p 'dired-mode)
              (dired-unmark-all-marks))
            (when (boundp 'strata-marked-entries)
              (setq strata-marked-entries nil))
            (strata-view--refresh-after-mark)))))))

(defun strata-mouse-drag-drop (event &optional forced-mode)
  "Drag highlighted files inside a pane to select, or across panes to copy/move."
  (interactive "e")
  (if-let ((st (strata-mouse--take-finished-drag (event-start event))))
      (strata-mouse--finish-drag st event forced-mode)
    (let* ((start (event-start event))
           (end (event-end event))
           (src-win (posn-window start))
           (dst-win (or (posn-window end) src-win)))
      (when (window-live-p src-win)
        (select-window src-win)
        (when (fboundp 'strata-panes--sync-active-pane-from-window)
          (strata-panes--sync-active-pane-from-window src-win))
        (let* ((src-entry (strata-mouse--entry-at-posn start t))
               (marked (strata-marked-files-only)))
          (cond
           ((eq src-win dst-win)
            (let ((end-entry (strata-mouse--entry-at-posn end t)))
              (cond
               ((and src-entry end-entry
                     (not (equal (strata--path-key src-entry)
                                 (strata--path-key end-entry))))
                (let* ((order (strata-view--entry-order))
                       (rect-p (derived-mode-p 'strata-compact-mode 'strata-icons-mode))
                       (mods (event-modifiers event))
                       (base-keys (when (or (memq 'control mods) (memq 'shift mods))
                                    (mapcar #'strata--path-key marked)))
                       (range (strata-mouse--range-entries order src-entry end-entry rect-p))
                       (keys (delete-dups (append (copy-sequence base-keys)
                                                  (mapcar #'strata--path-key range)))))
                  (setq-local strata--selection-anchor-entry src-entry)
                  (strata-mouse--apply-selection-keys order keys t)
                  (strata-goto-file end-entry)))
               (src-entry
                (setq-local strata--selection-anchor-entry src-entry)
                (if (file-directory-p src-entry)
                    (strata-mouse--open-path src-entry t)
                  (when (derived-mode-p 'strata-icons-mode)
                    (strata-goto-file src-entry))
                  (strata-view--sync-preview-on-move))))))
           (t
            (strata-mouse--drag-drop-now
             src-win dst-win start end src-entry marked
             (or forced-mode
                 (cond ((memq 'control (event-modifiers event)) 'copy)
                       ((memq 'shift (event-modifiers event)) 'cut)))))))))))

(defun strata-mouse-drag-copy (event)
  "Drag highlighted files into another split pane and copy (`C-<drag-mouse-1>')."
  (interactive "e")
  (strata-mouse-drag-drop event 'copy))

(defun strata-mouse-drag-move (event)
  "Drag highlighted files into another split pane and move (`S-<drag-mouse-1>')."
  (interactive "e")
  (strata-mouse-drag-drop event 'cut))

(defun strata-mouse-click-entry (event)
  "Handle single `<mouse-1>' click: open clicked directory or preview file."
  (interactive "e")
  (if-let ((st (strata-mouse--take-finished-drag (event-start event))))
      (strata-mouse--finish-drag st event)
    (strata-mouse--run-click-action event)))

(defun strata-mouse-activate-at-event (event)
  "Handle `<mouse-2>' or `<double-mouse-1>' click: open directory or file."
  (interactive "e")
  (if-let ((st (and (not (eq (event-basic-type event) 'mouse-2))
                    (strata-mouse--take-finished-drag (event-start event)))))
      (strata-mouse--finish-drag st event)
    (strata-mouse--run-activate-action event)))

(defun strata-view-activate-at-point ()
  "Open directory in browser pane or edit file in preview pane."
  (interactive)
  (if (fboundp 'strata-open-or-edit-at-point)
      (strata-open-or-edit-at-point)
    (when-let ((f (strata-current-file)))
      (if (file-directory-p f)
          (strata-open-location f)
        (find-file f)))))

(defun strata-view-up-directory ()
  "Navigate to parent directory from Compact or Icons view."
  (interactive)
  (let ((parent (file-name-directory (directory-file-name default-directory))))
    (when parent (strata-open-location parent))))

;;;; View Mode Switcher & Appearance Toggles

(defun strata-view--menu ()
  "Build the clickable layout menu with the current view checked."
  (easy-menu-create-menu
   "View…"
   '(["Columns" (strata-view-menu-select 'columns)
      :style radio :selected (eq (strata-view-current-mode) 'columns)]
     ["Icons" (strata-view-menu-select 'icons)
      :style radio :selected (eq (strata-view-current-mode) 'icons)]
     ["List / Tree" (strata-view-menu-select 'list)
      :style radio :selected (eq (strata-view-current-mode) 'list)]
     ["Compact" (strata-view-menu-select 'compact)
      :style radio :selected (eq (strata-view-current-mode) 'compact)])))

(defun strata-view-menu (&optional event)
  "Show the clickable View menu for the directory at EVENT."
  (interactive (list (when (mouse-event-p last-input-event) last-input-event)))
  (strata-header--select-browser event)
  (popup-menu (strata-view--menu) event))

(defun strata-view-menu-select (mode)
  "Switch to MODE from the View menu unless it is already displayed."
  (unless (eq (strata-view-current-mode) mode)
    (strata-switch-view-mode mode)))

(defun strata-switch-view-mode (mode)
  "Switch active browser pane to Strata view MODE (`columns', `icons', `list', `compact')."
  (interactive
   (list (intern (strata-ui-completing-read "View mode: " '("columns" "icons" "list" "compact") nil t))))
  (let* ((p (strata-prefs))
         (dir (or (bound-and-true-p strata-view-directory)
                  (dirvish-prop :root)
                  default-directory))
         (cur (strata-current-file)))
    (setf (strata-prefs-browser-mode p) mode)
    (strata-prefs-save)
    (pcase mode
      ('columns
       (unless (and (derived-mode-p 'dired-mode) (dirvish-curr))
         (dirvish dir)
         (set-buffer (window-buffer (selected-window))))
       (when-let ((dv (dirvish-curr)))
         (setf (dv-ff-layout dv) '(1 0.14 0.48))
         (if (dv-curr-layout dv)
             (progn
               (setf (dv-curr-layout dv) '(1 0.14 0.48))
               (dirvish--build-layout dv))
           (dirvish-layout-toggle))
         (set-buffer (window-buffer (selected-window))))
       (when (fboundp 'strata-sidebar-ensure)
         (strata-sidebar-ensure))
       (when (derived-mode-p 'dired-mode)
         (dired-hide-details-mode 1)))
      ('list
       (unless (derived-mode-p 'dired-mode)
         (dirvish dir)
         (set-buffer (window-buffer (selected-window))))
       (when (fboundp 'strata-dirvish--flatten-layout)
         (strata-dirvish--flatten-layout))
       (set-buffer (window-buffer (selected-window)))
       (when (fboundp 'strata-sidebar-ensure)
         (strata-sidebar-ensure))
       (when (derived-mode-p 'dired-mode)
         (dired-hide-details-mode -1)))
      ('compact
       (when (fboundp 'strata-dirvish--flatten-layout)
         (strata-dirvish--flatten-layout))
       (when (fboundp 'strata-sidebar-ensure)
         (strata-sidebar-ensure))
       (let ((buf (get-buffer-create (format "*Strata Compact: %s*"
                                             (file-name-nondirectory (directory-file-name dir))))))
         (switch-to-buffer buf)
         (strata-compact-mode)
         (setq-local strata-local-view-mode 'compact)
         (strata-compact-render dir)))
      ('icons
       (when (fboundp 'strata-dirvish--flatten-layout)
         (strata-dirvish--flatten-layout))
       (when (fboundp 'strata-sidebar-ensure)
         (strata-sidebar-ensure))
       (let ((buf (get-buffer-create (format "*Strata Icons: %s*"
                                             (file-name-nondirectory (directory-file-name dir))))))
         (switch-to-buffer buf)
         (strata-icons-mode)
         (setq-local strata-local-view-mode 'icons)
         (strata-icons-render dir))))
    ;; Set this on the displayed buffer after switching.  Setting it on the
    ;; source buffer leaves stale labels when Dired is reused from another view.
    (setq-local strata-local-view-mode mode)
    (force-mode-line-update t)
    (when cur (strata-goto-file cur))
    (strata-folder-view-remember dir p)))

(defun strata-view-columns () (interactive) (strata-switch-view-mode 'columns))
(defun strata-view-icons () (interactive) (strata-switch-view-mode 'icons))
(defun strata-view-list () (interactive) (strata-switch-view-mode 'list))
(defun strata-view-compact () (interactive) (strata-switch-view-mode 'compact))

(defun strata-toggle-hidden-files ()
  "Toggle visibility of hidden dot-files across Strata views."
  (interactive)
  (let ((p (strata-prefs)))
    (setf (strata-prefs-show-hidden p) (not (strata-prefs-show-hidden p)))
    (strata-prefs-save)
    (cond ((derived-mode-p 'dired-mode) (strata-apply-sort-to-dired))
          ((derived-mode-p 'strata-compact-mode) (strata-compact-refresh))
          ((derived-mode-p 'strata-icons-mode) (strata-icons-refresh)))
    (message "Hidden files %s" (if (strata-prefs-show-hidden p) "shown" "hidden"))))

(defun strata-toggle-compact-full-names ()
  "Toggle full filename display vs truncated columns in Compact view."
  (interactive)
  (let ((p (strata-prefs)))
    (setf (strata-prefs-compact-full-names p) (not (strata-prefs-compact-full-names p)))
    (strata-prefs-save)
    (when (derived-mode-p 'strata-compact-mode) (strata-compact-refresh))
    (message "Compact full names %s" (if (strata-prefs-compact-full-names p) "ON" "OFF"))))

(defun strata-toggle-expandable-tree ()
  "Toggle expandable folders (`dirvish-subtree') in List view."
  (interactive)
  (let ((p (strata-prefs)))
    (setf (strata-prefs-expandable-tree p) (not (strata-prefs-expandable-tree p)))
    (strata-prefs-save)
    (message "Expandable folders in List view: %s"
             (if (strata-prefs-expandable-tree p) "ON" "OFF"))))

(defun strata-tree-expand-or-open ()
  "Toggle Tree List subtree, move in Icons grid, or read preview (`<right>')."
  (interactive)
  (let ((p (strata-prefs))
        (f (strata-current-file)))
    (cond
     ((derived-mode-p 'strata-icons-mode)
      (strata-icons-next-cell))
     ((derived-mode-p 'strata-computer-mode)
      (call-interactively #'strata-computer-open-at-point))
     ((and (derived-mode-p 'dired-mode)
           (eq (strata-prefs-browser-mode p) 'list)
           (strata-prefs-expandable-tree p)
           f
           (file-directory-p f))
      (dirvish-subtree-toggle))
     ((and f (file-directory-p f))
      (if (fboundp 'strata-open-or-edit-at-point)
          (strata-open-or-edit-at-point)
        (if (derived-mode-p 'dired-mode)
            (dired-find-file)
          (strata-open-location f t))))
     (f
      (if (fboundp 'strata-preview-enter-at-point)
          (strata-preview-enter-at-point)
        (if (fboundp 'strata-preview-at-point)
            (strata-preview-at-point)
          (user-error "Preview unavailable for %s" f))))
     (t
      (user-error "No entry at point")))))

(defun strata-tree-collapse-or-up ()
  "Move left in Icons grid, collapse subtree in List view, or navigate up."
  (interactive)
  (cond
   ((derived-mode-p 'strata-icons-mode)
    (strata-icons-prev-cell))
   ((and (derived-mode-p 'dired-mode)
         (eq (strata-prefs-browser-mode (strata-prefs)) 'list)
         (strata-prefs-expandable-tree (strata-prefs))
         (dirvish-subtree--expanded-p))
    (dirvish-subtree-remove))
   ((derived-mode-p 'dired-mode)
    (dired-up-directory))
   (t
    (strata-view-up-directory))))

(defun strata-sort--menu ()
  "Build the clickable sort menu with current choices marked."
  (easy-menu-create-menu
   "Sort By…"
   '(["Name" (strata-sort-set 'name (strata-prefs-sort-direction (strata-prefs)))
      :style radio :selected (eq (strata-prefs-sort-key (strata-prefs)) 'name)]
     ["Modification date" (strata-sort-set 'modified (strata-prefs-sort-direction (strata-prefs)))
      :style radio :selected (eq (strata-prefs-sort-key (strata-prefs)) 'modified)]
     ["Size" (strata-sort-set 'size (strata-prefs-sort-direction (strata-prefs)))
      :style radio :selected (eq (strata-prefs-sort-key (strata-prefs)) 'size)]
     ["Type / extension" (strata-sort-set 'extension (strata-prefs-sort-direction (strata-prefs)))
      :style radio :selected (eq (strata-prefs-sort-key (strata-prefs)) 'extension)]
     ["Unsorted (directory order)" (strata-sort-set 'unsorted 'asc)
      :style radio :selected (eq (strata-prefs-sort-key (strata-prefs)) 'unsorted)]
     "--"
     ["Ascending (A–Z, smallest, oldest)" strata-sort-ascending
      :style radio :selected (eq (strata-prefs-sort-direction (strata-prefs)) 'asc)
      :enable (not (eq (strata-prefs-sort-key (strata-prefs)) 'unsorted))]
     ["Descending (Z–A, largest, newest)" strata-sort-descending
      :style radio :selected (eq (strata-prefs-sort-direction (strata-prefs)) 'desc)
      :enable (not (eq (strata-prefs-sort-key (strata-prefs)) 'unsorted))]
     "--"
     ["Folders first" strata-sort-toggle-folders-first
      :style toggle :selected (strata-prefs-folders-first (strata-prefs))
      :enable (not (eq (strata-prefs-sort-key (strata-prefs)) 'unsorted))]
     ["Natural names (file2 before file10)" strata-sort-toggle-natural
      :style toggle :selected (strata-prefs-natural-sort (strata-prefs))
      :enable (eq (strata-prefs-sort-key (strata-prefs)) 'name)])))

(defun strata-sort-menu (&optional event)
  "Show the clickable Sort By menu for the directory at EVENT (`C-c s')."
  (interactive (list (when (mouse-event-p last-input-event) last-input-event)))
  (strata-header--select-browser event)
  (popup-menu (strata-sort--menu) event))

(defun strata-sort-ascending ()
  "Sort the current directory in ascending order."
  (interactive)
  (strata-sort-set (strata-prefs-sort-key (strata-prefs)) 'asc))

(defun strata-sort-descending ()
  "Sort the current directory in descending order."
  (interactive)
  (strata-sort-set (strata-prefs-sort-key (strata-prefs)) 'desc))

(defun strata-sort-set (key &optional direction)
  "Sort active browser by KEY (`name', `modified', `size', `type', `extension', `created', `unsorted').
With DIRECTION, set that order explicitly; otherwise selecting the already
active sort key toggles ascending/descending (the 10xer sort chord)."
  (interactive
   (list (intern (strata-ui-completing-read "Sort by: "
                                  '("name" "modified" "size" "type" "extension" "created" "unsorted")
                                  nil t))))
  (let ((p (strata-prefs)))
    (if direction
        (setf (strata-prefs-sort-key p) key
              (strata-prefs-sort-direction p) direction)
      (if (eq (strata-prefs-sort-key p) key)
          (setf (strata-prefs-sort-direction p)
                (if (eq (strata-prefs-sort-direction p) 'asc) 'desc 'asc))
        (setf (strata-prefs-sort-key p) key
              (strata-prefs-sort-direction p) 'asc)))
    (strata-prefs-save)
    (cond ((derived-mode-p 'dired-mode) (strata-apply-sort-to-dired))
          ((derived-mode-p 'strata-compact-mode) (strata-compact-refresh))
          ((derived-mode-p 'strata-icons-mode) (strata-icons-refresh)))
    (force-mode-line-update t)
    (message "Sorted by %s (%s)" key (strata-prefs-sort-direction p))))

(defun strata-sort-toggle-folders-first ()
  "Toggle Folders First sorting while keeping sort key and direction."
  (interactive)
  (unless (strata-location-virtual-p (dirvish-prop :root))
    (let ((p (strata-prefs)))
      (setf (strata-prefs-folders-first p) (not (strata-prefs-folders-first p)))
      (strata-prefs-save)
      (cond ((derived-mode-p 'dired-mode) (strata-apply-sort-to-dired))
            ((derived-mode-p 'strata-compact-mode) (strata-compact-refresh))
            ((derived-mode-p 'strata-icons-mode) (strata-icons-refresh)))
      (message "Folders first: %s" (if (strata-prefs-folders-first p) "ON" "OFF")))))

(defun strata-sort-toggle-natural ()
  "Toggle Natural numeric sorting."
  (interactive)
  (let ((p (strata-prefs)))
    (setf (strata-prefs-natural-sort p) (not (strata-prefs-natural-sort p)))
    (strata-prefs-save)
    (cond ((derived-mode-p 'dired-mode) (strata-apply-sort-to-dired))
          ((derived-mode-p 'strata-compact-mode) (strata-compact-refresh))
          ((derived-mode-p 'strata-icons-mode) (strata-icons-refresh)))
    (message "Natural sort: %s" (if (strata-prefs-natural-sort p) "ON" "OFF"))))

(defun strata-sort-toggle-direction ()
  "Toggle ascending / descending sort order."
  (interactive)
  (let ((p (strata-prefs)))
    (setf (strata-prefs-sort-direction p)
          (if (eq (strata-prefs-sort-direction p) 'asc) 'desc 'asc))
    (strata-prefs-save)
    (cond ((derived-mode-p 'dired-mode) (strata-apply-sort-to-dired))
          ((derived-mode-p 'strata-compact-mode) (strata-compact-refresh))
          ((derived-mode-p 'strata-icons-mode) (strata-icons-refresh)))))

(defun strata-toggle-group-by-type ()
  "Toggle Group by Type section grouping."
  (interactive)
  (let ((p (strata-prefs)))
    (setf (strata-prefs-group-by-type p) (not (strata-prefs-group-by-type p)))
    (strata-prefs-save)
    (when (require 'dirvish-emerge nil t)
      (setq-local dirvish-emerge-groups
                  '(("Folders" (predicate . directories))
                    ("Images" (extensions "png" "jpg" "jpeg" "gif" "webp" "svg" "cr2" "nef" "dng"))
                    ("Audio" (extensions "mp3" "flac" "wav" "ogg" "opus" "m4a" "aac"))
                    ("Video" (extensions "mp4" "mkv" "mov" "webm" "avi" "m4v"))
                    ("Documents" (extensions "pdf" "md" "org" "txt" "docx" "odt" "rtf" "csv" "xlsx"))
                    ("Archives" (extensions "zip" "7z" "tar" "gz" "tgz" "zst" "xz" "iso"))))
      (dirvish-emerge-mode (if (strata-prefs-group-by-type p) 1 -1)))
    (cond ((derived-mode-p 'strata-compact-mode) (strata-compact-refresh))
          ((derived-mode-p 'strata-icons-mode) (strata-icons-refresh)))
    (message "Group by type: %s" (if (strata-prefs-group-by-type p) "ON" "OFF"))))

(defun strata-thumbnails-scale (delta)
  "Adjust Icons view thumbnail size by DELTA px (0 resets to 64px)."
  (interactive "P")
  (let* ((p (strata-prefs))
         (cur (strata-prefs-icons-thumbnail-size p))
         (next (if (= delta 0) 64 (max 32 (min 256 (+ cur delta))))))
    (setf (strata-prefs-icons-thumbnail-size p) next)
    (strata-prefs-save)
    (when (derived-mode-p 'strata-icons-mode) (strata-icons-refresh))
    (message "Icon thumbnail size: %dpx" next)))

(defun strata-make-first-column ()
  "Alt+Down (`columns'): descend or focus current folder as primary view."
  (interactive)
  (when-let ((f (strata-current-file)))
    (if (file-directory-p f)
        (strata-open-location f)
      (strata-switch-view-mode 'list))))

(provide 'strata-dirvish-views)
;;; strata-dirvish-views.el ends here
