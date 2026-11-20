;;; enhanced-dirvish-views.el --- Browser views, sorting, tree, icons, compact, chrome -*- lexical-binding: t; -*-

;; Copyright (C) 2026 dragonleopardpig
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.  It is part of Enhanced Dirvish;
;; see enhanced-dirvish.el for the full license notice.

;;; Commentary:
;; Implements all four Enhanced Dirvish browser views (Columns/Miller, List+Tree,
;; Compact horizontal multi-column, Icons thumbnail grid), unified sorting &
;; grouping, per-folder LRU memory, custom folder colors/icons, Dirvish
;; attributes, and Enhanced Dirvish header breadcrumbs / footer mode-line.

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
(require 'enhanced-dirvish-prefs)
(require 'enhanced-dirvish-devices)

;; Graphical builds only (image support for `image-size').
(declare-function x-hide-tip "xfns.c" ())
(declare-function image-size "image.c" (spec &optional pixels frame))

(declare-function enhanced-dirvish-open-location "enhanced-dirvish-panes" (loc &optional record-history))
(declare-function enhanced-dirvish--guard-not-self-contained "enhanced-dirvish-ops" (src dest-dir))
(declare-function enhanced-dirvish-mouse-context-menu "enhanced-dirvish-keys" (event))
(declare-function enhanced-dirvish-active-pane "enhanced-dirvish-panes" ())
(declare-function enhanced-dirvish-active-tab "enhanced-dirvish-panes" ())
(declare-function enhanced-dirvish-pane-active-p "enhanced-dirvish-panes" (&optional win))
(declare-function enhanced-dirvish-panes--pane-for-window "enhanced-dirvish-panes" (win))
(declare-function enhanced-dirvish-panes--sync-active-pane-from-window "enhanced-dirvish-panes" (&optional win))
(declare-function enhanced-dirvish-panes--valid-main-window-p "enhanced-dirvish-panes" (win))
(declare-function enhanced-dirvish-panes--main-window "enhanced-dirvish-panes" (&optional pane))
(declare-function enhanced-dirvish-panes--window-dir "enhanced-dirvish-panes" (&optional win))
(declare-function enhanced-dirvish-pane-state-id "enhanced-dirvish-panes" (cl-x) t)
(declare-function enhanced-dirvish-pane-state-buffer "enhanced-dirvish-panes" (cl-x) t)
(declare-function enhanced-dirvish-pane-state-history-back "enhanced-dirvish-panes" (cl-x) t)
(declare-function enhanced-dirvish-pane-state-history-fwd "enhanced-dirvish-panes" (cl-x) t)
(declare-function enhanced-dirvish-tab-state-pane1 "enhanced-dirvish-panes" (cl-x) t)
(declare-function enhanced-dirvish-tab-state-pane2 "enhanced-dirvish-panes" (cl-x) t)
(declare-function enhanced-dirvish-split-active-p "enhanced-dirvish-panes" ())
(declare-function enhanced-dirvish--flatten-layout "enhanced-dirvish-panes" ())
(declare-function enhanced-dirvish-panes--set-active-view "enhanced-dirvish-panes" (buffer window))
(declare-function enhanced-dirvish-pane-clipboard-summary "enhanced-dirvish-ops" ())
(declare-function enhanced-dirvish--transfer-files "enhanced-dirvish-ops" (files dest-dir mode &optional keep-both-default replace-default))
(declare-function enhanced-dirvish-clear-all-marks "enhanced-dirvish-keys" ())
(declare-function enhanced-dirvish-preview-at-point "enhanced-dirvish-previews" ())
(declare-function enhanced-dirvish-preview-enter-at-point "enhanced-dirvish-previews" ())
(declare-function enhanced-dirvish-history-back "enhanced-dirvish-search" ())
(declare-function enhanced-dirvish-history-forward "enhanced-dirvish-search" ())
(declare-function enhanced-dirvish-preview-edit-file "enhanced-dirvish-previews" (file))
(declare-function enhanced-dirvish-preview--close-standalone "enhanced-dirvish-previews" ())
(declare-function enhanced-dirvish-open-or-edit-at-point "enhanced-dirvish-previews" ())
(defvar enhanced-dirvish-preview-standalone-window)
(defvar enhanced-dirvish-sidebar-window)

(defvar enhanced-dirvish-active-chord nil
  "Current active multi-key chord label shown in footer (e.g. \"g _\").")

(defvar enhanced-dirvish-thumbnail-dir
  (expand-file-name "thumbnails" enhanced-dirvish-state-dir)
  "Directory storing cached PNG thumbnails for Icons view.")

(defvar enhanced-dirvish-thumbnail-pending (make-hash-table :test #'equal)
  "Pending async thumbnail jobs keyed by path.")

(defvar-local enhanced-dirvish-local-view-mode nil
  "Buffer-local active view mode overriding/mirroring global preference.")

(defvar-local enhanced-dirvish-local-filter nil
  "Active filter string inside current pane buffer.")

(defvar-local enhanced-dirvish-visual-anchor nil
  "File path where 10xer visual selection started.")

;;;; File Selection & Cursor Introspection Across All 4 Views

(defvar-local enhanced-dirvish--empty-click-p nil
  "Non-nil while an empty-space click leaves the browser without a current item.")

(defvar-local enhanced-dirvish--empty-click-position nil
  "Visible cursor position used by Compact view after a blank-space click.")

(defun enhanced-dirvish-view--empty-selection-p ()
  "Whether point still represents an empty-space deselection."
  (and enhanced-dirvish--empty-click-p
       (if enhanced-dirvish--empty-click-position
           (= (point) enhanced-dirvish--empty-click-position)
         (eobp))))

(defun enhanced-dirvish-view--dot-entry-p (path)
  "Non-nil if PATH names a directory's own `.' or `..' listing line.
Dired shows them under `-a' switches; they are not entries a browser
can focus, select or act on, and `expand-file-name' would fold \"dir/.\"
into \"dir\" so `enhanced-dirvish-goto-file' could never land on them anyway."
  (member (file-name-nondirectory path) '("." "..")))

(defun enhanced-dirvish-view--dired-entry-at-point ()
  "Return the Dired file on this line, unless it is `.' or `..'."
  (when-let ((f (ignore-errors (dired-get-filename nil t))))
    (unless (enhanced-dirvish-view--dot-entry-p f) f)))

(defun enhanced-dirvish-current-file ()
  "Return absolute path of entry under point in any view buffer."
  (unless (enhanced-dirvish-view--empty-selection-p)
    (or (get-text-property (point) 'enhanced-dirvish-entry)
        (get-text-property (line-beginning-position) 'enhanced-dirvish-entry)
        (and (derived-mode-p 'dired-mode)
             (enhanced-dirvish-view--dired-entry-at-point))
        (when-let ((tr (get-text-property (line-beginning-position) 'enhanced-dirvish-trash-item)))
          (plist-get tr :file))
        (get-text-property (line-beginning-position) 'enhanced-dirvish-recent-path))))

(defvar-local enhanced-dirvish--selection-anchor-entry nil
  "Anchor path for Shift-click and Shift-arrow range multi-selection.")

(defvar-local enhanced-dirvish--selection-range-active nil
  "Non-nil while extending the current keyboard or click range.")

(defvar-local enhanced-dirvish--selection-base-keys nil
  "Marks preserved outside an additive Ctrl+Shift range.")

(defvar-local enhanced-dirvish--selection-range-additive nil
  "Whether the active range preserves marks outside its bounds.")

(defun enhanced-dirvish-view--reset-selection-range (&optional anchor)
  "Finish the active range and use ANCHOR for the next range."
  (setq enhanced-dirvish--selection-anchor-entry anchor
        enhanced-dirvish--selection-range-active nil
        enhanced-dirvish--selection-base-keys nil
        enhanced-dirvish--selection-range-additive nil))

(defun enhanced-dirvish-view--selection-post-command ()
  "Start the next range at point after ordinary navigation or file commands."
  (unless (enhanced-dirvish-view--empty-selection-p)
    (setq enhanced-dirvish--empty-click-p nil enhanced-dirvish--empty-click-position nil))
  (unless (or (null this-command)
              (bound-and-true-p enhanced-dirvish-mouse--drag-state)
              (memq this-command
                    '(enhanced-dirvish-shift-select-next enhanced-dirvish-shift-select-prev
                      enhanced-dirvish-shift-select-right enhanced-dirvish-shift-select-left
                      enhanced-dirvish-shift-select-first enhanced-dirvish-shift-select-last
                      enhanced-dirvish-mouse-range-select enhanced-dirvish-mouse-add-range-select
                      enhanced-dirvish-visual-toggle)))
    (enhanced-dirvish-view--reset-selection-range (enhanced-dirvish-current-file))))

(defun enhanced-dirvish-view--dirvish-post-command (original)
  "Run ORIGINAL without moving an empty-space selection onto the last file."
  (unless (and enhanced-dirvish--empty-click-p (eobp))
    (funcall original)))

(defun enhanced-dirvish--path-key (path)
  "Normalize PATH into a canonical comparison key."
  (and path (directory-file-name (expand-file-name path))))

(defun enhanced-dirvish-marked-files-only ()
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
   ((derived-mode-p 'enhanced-dirvish-compact-mode 'enhanced-dirvish-icons-mode)
    (when-let ((m (bound-and-true-p enhanced-dirvish-marked-entries)))
      (cl-remove-if-not #'file-exists-p (reverse m))))))

(defun enhanced-dirvish-selected-files ()
  "Return marked file paths in current Enhanced Dirvish view, or file at point."
  (or (enhanced-dirvish-marked-files-only)
      (when-let ((cur (enhanced-dirvish-current-file)))
        (list cur))))

(defvar-local enhanced-dirvish--selection-overlays nil
  "Buffer-local selection overlays highlighting the active file or folder name.")

(defun enhanced-dirvish--clear-selection-highlight ()
  "Remove active selection highlight overlays from the current buffer."
  (mapc #'delete-overlay enhanced-dirvish--selection-overlays)
  (setq-local enhanced-dirvish--selection-overlays nil))

(defun enhanced-dirvish--add-selection-overlay (beg end)
  "Highlight BEG..END with `enhanced-dirvish-entry-selected' in current buffer."
  (when (and beg end (< beg end))
    (let ((ov (make-overlay beg end nil t nil)))
      (overlay-put ov 'face 'enhanced-dirvish-entry-selected)
      (overlay-put ov 'priority 60)
      (push ov enhanced-dirvish--selection-overlays))))

(defun enhanced-dirvish--prop-span-at (pos prop &optional limit-beg limit-end)
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

(defun enhanced-dirvish--highlight-marked-dired (cur-beg cur-end)
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
                (enhanced-dirvish--add-selection-overlay beg end)))))))))

(defun enhanced-dirvish--highlight-marked-spans (prop marked-keys &optional cur-span)
  "Overlay spans carrying PROP whose `enhanced-dirvish-entry' is in MARKED-KEYS."
  (when marked-keys
    (let ((pos (point-min)))
      (while (< pos (point-max))
        (let ((next (or (next-single-property-change pos prop) (point-max))))
          (when (get-text-property pos prop)
            (when-let ((key (enhanced-dirvish--path-key (get-text-property pos 'enhanced-dirvish-entry))))
              (when (and (member key marked-keys)
                         (not (and cur-span (= pos (car cur-span)) (= next (cdr cur-span)))))
                (enhanced-dirvish--add-selection-overlay pos next))))
          (setq pos next))))))

(defun enhanced-dirvish-view--update-selection-highlight ()
  "Highlight the active and multi-marked file or directory names across all views."
  (when (derived-mode-p 'dired-mode 'enhanced-dirvish-compact-mode 'enhanced-dirvish-icons-mode)
    (enhanced-dirvish--clear-selection-highlight)
    (let ((marked-keys (mapcar #'enhanced-dirvish--path-key (bound-and-true-p enhanced-dirvish-marked-entries))))
      (cond
       ((enhanced-dirvish-view--empty-selection-p))
       ((derived-mode-p 'dired-mode)
        (let (cur-beg cur-end)
          (ignore-errors
            (save-excursion
              (when-let* ((beg (dired-move-to-filename))
                          (end (dired-move-to-end-of-filename t)))
                (setq cur-beg beg cur-end end)
                (enhanced-dirvish--add-selection-overlay beg end))))
          (enhanced-dirvish--highlight-marked-dired cur-beg cur-end)))
       ((derived-mode-p 'enhanced-dirvish-compact-mode)
        (let* ((p (point))
               (lb (line-beginning-position))
               (le (line-end-position))
               (span (or (enhanced-dirvish--prop-span-at p 'enhanced-dirvish-entry-label lb le)
                         (when-let ((cur-entry (get-text-property p 'enhanced-dirvish-entry)))
                           (let ((cand (next-single-property-change p 'enhanced-dirvish-entry-label nil le)))
                             (when (and cand (< cand le)
                                        (equal (get-text-property cand 'enhanced-dirvish-entry) cur-entry))
                               (enhanced-dirvish--prop-span-at cand 'enhanced-dirvish-entry-label lb le)))))))
          (when span
            (enhanced-dirvish--add-selection-overlay (car span) (cdr span)))
          (enhanced-dirvish--highlight-marked-spans 'enhanced-dirvish-entry-label marked-keys span)))
       ((derived-mode-p 'enhanced-dirvish-icons-mode)
        (let* ((p (point))
               (idx (and (< p (point-max)) (get-text-property p 'enhanced-dirvish-grid-idx)))
               (lb (line-beginning-position))
               (le (line-end-position))
               (span1 (and idx
                           (or (enhanced-dirvish--prop-span-at p 'enhanced-dirvish-grid-label lb le)
                               (when-let ((cand (next-single-property-change p 'enhanced-dirvish-grid-label nil le)))
                                 (when (and (< cand le)
                                            (eql (get-text-property cand 'enhanced-dirvish-grid-idx) idx))
                                   (enhanced-dirvish--prop-span-at cand 'enhanced-dirvish-grid-label lb le))))))
               (span2 nil))
          (when span1
            (enhanced-dirvish--add-selection-overlay (car span1) (cdr span1))
            (save-excursion
              (goto-char (car span1))
              (when (= (forward-line 1) 0)
                (let ((q (line-beginning-position))
                      (qe (line-end-position))
                      (found2 nil))
                  (while (and (< q qe) (not found2))
                    (let ((nxt (or (next-single-property-change q 'enhanced-dirvish-grid-label-cont nil qe) qe)))
                      (when (and (get-text-property q 'enhanced-dirvish-grid-label-cont)
                                 (eql (get-text-property q 'enhanced-dirvish-grid-idx) idx))
                        (setq span2 (cons q nxt))
                        (enhanced-dirvish--add-selection-overlay q nxt)
                        (setq found2 t))
                      (setq q nxt)))))))
          (enhanced-dirvish--highlight-marked-spans 'enhanced-dirvish-grid-label marked-keys span1)
          (enhanced-dirvish--highlight-marked-spans 'enhanced-dirvish-grid-label-cont marked-keys span2)))))))

(defun enhanced-dirvish-goto-file (path)
  "Move point to entry matching PATH in current Enhanced Dirvish buffer."
  (when path
    (let ((target (directory-file-name (expand-file-name path))))
      (cond
       ((derived-mode-p 'dired-mode)
        (let ((moved (or (ignore-errors (dired-goto-file target))
                         (ignore-errors (dired-goto-file (concat target "/"))))))
          (when moved (setq enhanced-dirvish--empty-click-p nil enhanced-dirvish--empty-click-position nil))
          (enhanced-dirvish-view--update-selection-highlight)
          moved))
       ((or (derived-mode-p 'enhanced-dirvish-compact-mode)
            (derived-mode-p 'enhanced-dirvish-icons-mode))
        (let ((pos (point-min))
              (icons-p (derived-mode-p 'enhanced-dirvish-icons-mode))
              (lbl-prop (if (derived-mode-p 'enhanced-dirvish-icons-mode)
                            'enhanced-dirvish-grid-label
                          'enhanced-dirvish-entry-label))
              (first-match nil)
              (label-match nil))
          (while (and (< pos (point-max)) (not label-match))
            (let* ((next (or (next-single-property-change pos 'enhanced-dirvish-entry) (point-max)))
                   (val (get-text-property pos 'enhanced-dirvish-entry)))
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
            (setq enhanced-dirvish--empty-click-p nil enhanced-dirvish--empty-click-position nil)
            (enhanced-dirvish-view--update-selection-highlight)
            dest)))))))

;;;; Folder Colors & Custom Icons

(defun enhanced-dirvish-folder-color-set (dir color-name)
  "Assign COLOR-NAME badge to DIR (`nil' or empty removes customization)."
  (let* ((p (enhanced-dirvish-prefs))
         (key (directory-file-name (expand-file-name dir)))
         (tbl (assoc-delete-all key (enhanced-dirvish-prefs-folder-colors p))))
    (when (and color-name (not (string-empty-p color-name)))
      (push (cons key color-name) tbl))
    (setf (enhanced-dirvish-prefs-folder-colors p) tbl)
    (enhanced-dirvish-prefs-save)))

(defun enhanced-dirvish-custom-icon-set (path icon-str)
  "Assign custom ICON-STR badge to PATH (`nil' or empty clears it)."
  (let* ((p (enhanced-dirvish-prefs))
         (key (directory-file-name (expand-file-name path)))
         (tbl (assoc-delete-all key (enhanced-dirvish-prefs-custom-icons p))))
    (when (and icon-str (not (string-empty-p icon-str)))
      (push (cons key icon-str) tbl))
    (setf (enhanced-dirvish-prefs-custom-icons p) tbl)
    (enhanced-dirvish-prefs-save)))

(defun enhanced-dirvish-file--badge-face (path)
  "Return custom face for folder PATH if customized."
  (when-let* ((key (and path (directory-file-name (expand-file-name path))))
              (color (cdr (assoc key (enhanced-dirvish-prefs-folder-colors (enhanced-dirvish-prefs))))))
    (cdr (assoc (downcase color) enhanced-dirvish-folder-color-alist))))

(defconst enhanced-dirvish-file--ext-icon-map
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

(defun enhanced-dirvish-file--glyph (path &optional dir-p)
  "Return crisp verified Nerd Font icon glyph for PATH honoring custom icons."
  (let* ((key (and path (directory-file-name (expand-file-name path))))
         (custom (cdr (assoc key (enhanced-dirvish-prefs-custom-icons (enhanced-dirvish-prefs)))))
         (cface (enhanced-dirvish-file--badge-face path))
         (fname (downcase (file-name-nondirectory (or path ""))))
         (ext (downcase (or (file-name-extension fname) ""))))
    (cond
     (custom (propertize custom 'face (or cface 'dired-directory)))
     (dir-p
      (let* ((mkind (enhanced-dirvish-path-mount-kind path))
             (kind (cond
                    ((eq mkind 'cloud) 'cloud)
                    ((eq mkind 'network) 'network)
                    ((file-symlink-p path) 'folder-open)
                    ((enhanced-dirvish-path-unsafe-probe-p path) 'folder)
                    ((file-exists-p (expand-file-name ".git" path)) 'folder-git)
                    (t 'folder))))
        (enhanced-dirvish-icon-glyph kind (or cface 'dired-directory)
                           (unless (memq kind '(cloud network)) "▸"))))
     ((string-prefix-p ".git" fname)
      (enhanced-dirvish-icon-glyph 'git 'warning "·"))
     ((file-symlink-p path)
      (enhanced-dirvish-icon-glyph 'symlink 'font-lock-type-face "→"))
     (t
      (let ((hit (cdr (assoc ext enhanced-dirvish-file--ext-icon-map))))
        (enhanced-dirvish-icon-glyph (or (car hit) 'file) (or (cdr hit) 'default) "·"))))))

;;;; Sorting, Natural Order & Type Classification Engine

(defun enhanced-dirvish-natural-compare (a b &optional case-sensitive)
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

(defun enhanced-dirvish-file-type-group (path &optional dir-p known-p)
  "Classify PATH into an Enhanced Dirvish type group symbol.
With KNOWN-P, DIR-P is taken as the answer and PATH is never statted."
  (if (or dir-p (and (not known-p) (file-directory-p path)))
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

(defun enhanced-dirvish-file-group-label (grp)
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

(defcustom enhanced-dirvish-slow-mount-list-timeout 15
  "Seconds to wait for a folder listing on a cloud, network or removable mount.
Such folders are read by a `find' subprocess, never inside Emacs, so a
mount that stops answering costs at most this long instead of freezing
Emacs in an uninterruptible system call -- and Esc cancels the wait at
any time (other keys typed meanwhile are kept for afterwards)."
  :type 'number
  :group 'enhanced-dirvish)

(defun enhanced-dirvish--list-slow-mount (dir)
  "Entries of DIR read by a `find' subprocess, for mounts that may hang.
Return a list of (NAME DIR-P SIZE MTIME CTIME), the symbol `timeout' when
the mount did not answer within `enhanced-dirvish-slow-mount-list-timeout',
`cancelled' when Esc was pressed meanwhile, or nil when `find' is missing
or DIR cannot be listed."
  (when-let ((find (executable-find "find")))
    (let ((proc (enhanced-dirvish--slow-mount-start
                 "enhanced-dirvish-find"
                 (list find (directory-file-name dir) "-mindepth" "1" "-maxdepth" "1"
                       "-printf" "%y\\0%s\\0%T@\\0%C@\\0%f\\0"))))
      (unwind-protect
          (pcase (enhanced-dirvish--slow-mount-wait
                  proc (+ (float-time) enhanced-dirvish-slow-mount-list-timeout)
                  (abbreviate-file-name (directory-file-name dir)))
            ((and (or 'timeout 'cancelled) why) why)
            (_
             ;; (find exits 1 when some entries are unreadable; keep the readable ones)
             (when (memq (process-exit-status proc) '(0 1))
               (let ((fields (split-string (with-current-buffer (process-buffer proc) (buffer-string)) "\0"))
                     entries)
                 (while (>= (length fields) 5)
                   (pcase-let ((`(,type ,size ,mtime ,ctime ,name . ,rest) fields))
                     (push (list name (equal type "d") (string-to-number size)
                                 (seconds-to-time (string-to-number mtime))
                                 (seconds-to-time (string-to-number ctime)))
                           entries)
                     (setq fields rest)))
                 (nreverse entries)))))
        (enhanced-dirvish--slow-mount-cleanup proc)))))

(defun enhanced-dirvish-list-directory-entries (dir &optional prefs)
  "Return sorted entry plists for DIR honoring PREFS & active filter.
Each plist contains (:name :path :dir-p :size :mtime :ctime :ext :group)."
  (let* ((p (or prefs (enhanced-dirvish-prefs)))
         (show-hidden (enhanced-dirvish-prefs-show-hidden p))
         (sort-key (enhanced-dirvish-prefs-sort-key p))
         (sort-dir (enhanced-dirvish-prefs-sort-direction p))
         (folders-first (enhanced-dirvish-prefs-folders-first p))
         (natural (enhanced-dirvish-prefs-natural-sort p))
         (case-sens (enhanced-dirvish-prefs-case-sensitive-sort p))
         (group-type (enhanced-dirvish-prefs-group-by-type p))
         (dir (file-name-as-directory (expand-file-name dir)))
         ;; A cloud/network/removable mount can stop answering; reading it here
         ;; would freeze Emacs in the kernel (11-20: a wedged Filen rclone mount).
         (slow (and (not (file-remote-p dir)) (enhanced-dirvish-path-unsafe-probe-p dir)))
         (listed (when slow (enhanced-dirvish--list-slow-mount dir)))
         (names (cond
                 (slow (pcase listed
                         ('timeout (message "%s is not responding (%gs); listing skipped -- F5 to try again"
                                            (abbreviate-file-name dir)
                                            enhanced-dirvish-slow-mount-list-timeout)
                                   nil)
                         ('cancelled (message "Listing %s cancelled -- F5 to try again"
                                              (abbreviate-file-name dir))
                                     nil)
                         (_ (mapcar #'car listed))))
                 ((file-directory-p dir)
                  (condition-case nil
                      (directory-files dir nil "\\`[^.]\\|\\`.[^.]" t)
                    (error nil)))))
         (flt (when (and enhanced-dirvish-local-filter (not (string-empty-p enhanced-dirvish-local-filter)))
                enhanced-dirvish-local-filter))
         entries)
    (dolist (n names)
      (when (and (or show-hidden (not (string-prefix-p "." n)))
                 (or (null flt) (let ((case-fold-search t))
                                  (string-match-p (regexp-quote flt) n))))
        (let* ((path (expand-file-name n dir))
               (row (when slow (assoc n listed)))
               (attrs (unless slow (file-attributes path 'integer)))
               (dir-p (if slow (nth 1 row) (eq t (file-attribute-type attrs))))
               (size (or (if slow (nth 2 row) (file-attribute-size attrs)) 0))
               (mtime (if slow (nth 3 row) (file-attribute-modification-time attrs)))
               (ctime (if slow (nth 4 row) (file-attribute-status-change-time attrs)))
               (ext (downcase (or (file-name-extension n) "")))
               (grp (enhanced-dirvish-file-type-group path dir-p slow)))
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
                                            (enhanced-dirvish-natural-compare (plist-get a :name)
                                                                    (plist-get b :name)
                                                                    case-sens)
                                          (let ((na (if case-sens (plist-get a :name) (downcase (plist-get a :name))))
                                                (nb (if case-sens (plist-get b :name) (downcase (plist-get b :name)))))
                                            (if (string= na nb) 0 (if (string-lessp na nb) -1 1))))))
                            (if desc (> cmp 0) (< cmp 0)))))))))))
    entries))

(defun enhanced-dirvish-compute-dired-switches (&optional prefs)
  "Compute `dired-listing-switches' string matching PREFS."
  (let* ((p (or prefs (enhanced-dirvish-prefs)))
         (flags (list "-lh"))
         (sk (enhanced-dirvish-prefs-sort-key p)))
    (if (enhanced-dirvish-prefs-show-hidden p)
        (push "-A" flags)
      (setq flags (delete "-a" flags)))
    (when (enhanced-dirvish-prefs-folders-first p)
      (push "--group-directories-first" flags))
    ;; GNU ls defaults to largest/newest first for these keys.  Enhanced Dirvish's
    ;; ascending order means smallest/oldest first in every layout.
    (when (if (memq sk '(size modified created))
              (eq (enhanced-dirvish-prefs-sort-direction p) 'asc)
            (eq (enhanced-dirvish-prefs-sort-direction p) 'desc))
      (push "-r" flags))
    (pcase sk
      ('modified (push "-t" flags))
      ('created (push "--sort=time" flags) (push "--time=birth" flags))
      ('size (push "-S" flags))
      ('extension (push "-X" flags))
      ('unsorted (push "-U" flags))
      (_ (when (enhanced-dirvish-prefs-natural-sort p)
           (push "-v" flags))))
    (string-join (nreverse flags) " ")))

(defun enhanced-dirvish-apply-sort-to-dired ()
  "Apply sort & hidden settings directly to active Dired/Dirvish buffer."
  (when (derived-mode-p 'dired-mode)
    (let ((sw (enhanced-dirvish-compute-dired-switches)))
      (setq-local dired-actual-switches sw)
      (setq dired-listing-switches sw)
      (revert-buffer))))

;;;; Per-Folder View Memory (LRU 128)

(defun enhanced-dirvish-folder-view-remember (dir &optional prefs)
  "Save current view/sort/cursor preferences for DIR into LRU (max 128)."
  (let ((p (or prefs (enhanced-dirvish-prefs))))
    (when (and (enhanced-dirvish-prefs-remember-folder-views p)
               dir
               (not (enhanced-dirvish-location-virtual-p dir))
               (file-directory-p dir))
      (let* ((key (directory-file-name (expand-file-name dir)))
             (snapshot (list :mode (enhanced-dirvish-prefs-browser-mode p)
                             :sort-key (enhanced-dirvish-prefs-sort-key p)
                             :sort-dir (enhanced-dirvish-prefs-sort-direction p)
                             :folders-first (enhanced-dirvish-prefs-folders-first p)
                             :natural-sort (enhanced-dirvish-prefs-natural-sort p)
                             :group-by-type (enhanced-dirvish-prefs-group-by-type p)
                             :show-hidden (enhanced-dirvish-prefs-show-hidden p)
                             :compact-full-names (enhanced-dirvish-prefs-compact-full-names p)
                             :cursor (enhanced-dirvish-current-file))))
        (setq enhanced-dirvish-folder-view-lru
              (cons (cons key snapshot)
                    (assoc-delete-all key enhanced-dirvish-folder-view-lru)))
        (when (> (length enhanced-dirvish-folder-view-lru) enhanced-dirvish-folder-view-lru-limit)
          (setcdr (nthcdr (1- enhanced-dirvish-folder-view-lru-limit) enhanced-dirvish-folder-view-lru) nil))))))

(defun enhanced-dirvish-folder-view-restore (dir &optional prefs)
  "Restore remembered view and sort preferences for DIR.
Return the snapshot, if any."
  (let ((p (or prefs (enhanced-dirvish-prefs))))
    (when (and (enhanced-dirvish-prefs-remember-folder-views p)
               dir
               (not (enhanced-dirvish-location-virtual-p dir)))
      (let* ((key (directory-file-name (expand-file-name dir)))
             (entry (cdr (assoc key enhanced-dirvish-folder-view-lru))))
        (when entry
          (setf (enhanced-dirvish-prefs-browser-mode p) (or (plist-get entry :mode) 'columns))
          (setf (enhanced-dirvish-prefs-sort-key p) (or (plist-get entry :sort-key) 'name))
          (setf (enhanced-dirvish-prefs-sort-direction p) (or (plist-get entry :sort-dir) 'asc))
          (setf (enhanced-dirvish-prefs-folders-first p) (plist-get entry :folders-first))
          (setf (enhanced-dirvish-prefs-natural-sort p) (plist-get entry :natural-sort))
          (setf (enhanced-dirvish-prefs-group-by-type p) (plist-get entry :group-by-type))
          (setf (enhanced-dirvish-prefs-show-hidden p) (plist-get entry :show-hidden))
          (setf (enhanced-dirvish-prefs-compact-full-names p) (plist-get entry :compact-full-names)))
        entry))))

;;;; Dirvish Custom Attributes & Formatters

(dirvish-define-attribute enhanced-dirvish-icon
  "Render verified Enhanced Dirvish Nerd Font folder/file glyph before filenames."
  :width 3
  (let* ((dir-p (eq (car f-type) 'dir))
         (g (enhanced-dirvish-file--glyph f-name dir-p))
         (icon-str (concat g " "))
         (ov (make-overlay (max (point-min) (1- f-beg)) f-beg)))
    (when hl-face
      (setq icon-str (enhanced-dirvish-icon-tint icon-str hl-face t)))
    (when dir-p
      (add-text-properties 0 (length icon-str)
                           (list 'mouse-face 'highlight
                                 'pointer 'hand
                                 'help-echo (format "Open folder %s" (abbreviate-file-name f-name)))
                           icon-str))
    (overlay-put ov 'after-string icon-str)
    `(ov . ,ov)))

(dirvish-define-attribute enhanced-dirvish-dir-mouse
  "Make directories highlight and show a hand cursor on mouse hover."
  :width 0
  (when (eq (car f-type) 'dir)
    (let ((ov (make-overlay f-beg f-end)))
      (overlay-put ov 'mouse-face 'highlight)
      (overlay-put ov 'pointer 'hand)
      (overlay-put ov 'help-echo (format "Open folder %s" (abbreviate-file-name f-name)))
      `(ov . ,ov))))

(defun enhanced-dirvish-dired-decorate-dirs ()
  "Ensure plain Dired buffers (e.g., split pane 2) mark directories as clickable."
  (when (and (derived-mode-p 'dired-mode)
             (not (and (fboundp 'dirvish-curr) (dirvish-curr)
                       (assq 'enhanced-dirvish-dir-mouse (dirvish-prop :attrs)))))
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

(dirvish-define-attribute enhanced-dirvish-color
  "Apply Enhanced Dirvish custom folder color faces to tagged directory names."
  :width 0
  (let ((badge (enhanced-dirvish-file--badge-face f-name)))
    (when badge
      (let ((ov (make-overlay f-beg f-end)))
        (overlay-put ov 'face badge)
        `(ov . ,ov)))))

(dirvish-define-attribute enhanced-dirvish-size
  "Format file size honoring Metric (1000) / Binary (1024) and `columns-show-sizes'."
  :right 9
  :when (and (enhanced-dirvish-prefs-columns-show-sizes (enhanced-dirvish-prefs))
             (>= win-width 20))
  (let* ((dir-p (eq (car f-type) 'dir))
         (sz (and f-attrs (file-attribute-size f-attrs)))
         (str (cond
               (dir-p "")
               ((numberp sz) (enhanced-dirvish-format-bytes sz))
               (t "")))
         (out (format "%8s " str)))
    (add-face-text-property 0 (length out) (or hl-face 'dirvish-file-size) t out)
    `(right . ,out)))

(dirvish-define-attribute enhanced-dirvish-time
  "Format modification time using relative or ISO date preference."
  :right 17
  :when (>= win-width 38)
  (let* ((tm (and f-attrs (file-attribute-modification-time f-attrs)))
         (str (or (enhanced-dirvish-format-time tm) ""))
         (out (format " %-15s" str)))
    (add-face-text-property 0 (length out) (or hl-face 'dirvish-file-time) t out)
    `(right . ,out)))

;;;; Dirvish Header Breadcrumbs & Enhanced Dirvish Footer Mode-Line

(defvar enhanced-dirvish-sort-header-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'enhanced-dirvish-sort-menu)
    (define-key map [header-line mouse-2] #'enhanced-dirvish-sort-menu)
    (define-key map [mode-line mouse-1] #'enhanced-dirvish-sort-menu)
    (define-key map [mode-line mouse-2] #'enhanced-dirvish-sort-menu)
    map)
  "Mouse bindings for the Sort By header control in every directory layout.")

(defvar enhanced-dirvish-view-header-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'enhanced-dirvish-view-menu)
    (define-key map [header-line mouse-2] #'enhanced-dirvish-view-menu)
    (define-key map [mode-line mouse-1] #'enhanced-dirvish-view-menu)
    (define-key map [mode-line mouse-2] #'enhanced-dirvish-view-menu)
    map)
  "Mouse bindings for the View header control in every directory layout.")

(defun enhanced-dirvish-header--select-browser (event)
  "Select the browser owning header EVENT, or use the current browser."
  (when event
    (let* ((clicked (posn-window (event-start event)))
           (target
            (when (window-live-p clicked)
              (with-current-buffer (window-buffer clicked)
                (if (derived-mode-p 'dired-mode 'enhanced-dirvish-compact-mode 'enhanced-dirvish-icons-mode)
                    clicked
                  ;; Columns puts its header in a separate Dirvish window.
                  (when-let ((dv (dirvish-curr))) (dv-root-window dv)))))))
      (when (window-live-p target)
        (select-window target)
        (enhanced-dirvish-panes--sync-active-pane-from-window target))))
  (unless (derived-mode-p 'dired-mode 'enhanced-dirvish-compact-mode 'enhanced-dirvish-icons-mode)
    (user-error "Open a directory to use this menu")))

(defun enhanced-dirvish-view-current-mode ()
  "Return the current browser's layout, preferring its buffer's setting."
  (or enhanced-dirvish-local-view-mode (enhanced-dirvish-prefs-browser-mode (enhanced-dirvish-prefs))))

(defun enhanced-dirvish-crumb--make-segment (label target)
  "Return clickable breadcrumb segment LABEL pointing to directory TARGET."
  (let ((km (make-sparse-keymap))
        (open-fn (lambda (ev)
                   (interactive "e")
                   (let ((win (or (posn-window (event-start ev))
                                  (posn-window (event-end ev)))))
                     (when (window-live-p win)
                       (select-window win)
                       (when (fboundp 'enhanced-dirvish-panes--sync-active-pane-from-window)
                         (enhanced-dirvish-panes--sync-active-pane-from-window win))))
                   (enhanced-dirvish-open-location target t))))
    (define-key km [header-line mouse-1] open-fn)
    (define-key km [header-line mouse-2] open-fn)
    (define-key km [mode-line mouse-1] open-fn)
    (define-key km [mode-line mouse-2] open-fn)
    (let ((out (enhanced-dirvish-icon-tint (copy-sequence label) 'enhanced-dirvish-crumb-segment t)))
      (add-text-properties 0 (length out)
                           (list 'mouse-face 'highlight
                                 'pointer 'hand
                                 'local-map km
                                 'keymap km
                                 'enhanced-dirvish-crumb-path target
                                 'help-echo (format "Open folder %s" target))
                           out)
      out)))

(dirvish-define-mode-line enhanced-dirvish-breadcrumb
  "Interactive clickable breadcrumb header with active pane badge & view pill."
  (let* ((dir (abbreviate-file-name (or (dirvish-prop :root) default-directory "~/")))
         (clean (directory-file-name dir))
         (parts (split-string clean "/" t))
         (acc (if (string-prefix-p "~" clean) "~" "/"))
         (pane-badge
          (when (and (fboundp 'enhanced-dirvish-split-active-p) (enhanced-dirvish-split-active-p))
            (let* ((ap (and (fboundp 'enhanced-dirvish-active-pane) (enhanced-dirvish-active-pane)))
                   (active-id (if ap (enhanced-dirvish-pane-state-id ap) 1))
                   (other-id (if (= active-id 1) 2 1))
                   (this-pane
                    (or (when (and (fboundp 'mode-line-window-selected-p)
                                   (fboundp 'enhanced-dirvish-panes--valid-main-window-p)
                                   (enhanced-dirvish-panes--valid-main-window-p (selected-window)))
                          (if (mode-line-window-selected-p) active-id other-id))
                        (when-let* ((tab (and (fboundp 'enhanced-dirvish-active-tab) (enhanced-dirvish-active-tab)))
                                    (p1 (enhanced-dirvish-tab-state-pane1 tab))
                                    (p2 (enhanced-dirvish-tab-state-pane2 tab)))
                          (let ((b1 (enhanced-dirvish-pane-state-buffer p1))
                                (b2 (enhanced-dirvish-pane-state-buffer p2)))
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
                                    'enhanced-dirvish-pane-active-badge
                                  'enhanced-dirvish-pane-inactive-badge)))))
         (crumbs
          (if (string-prefix-p "~" clean)
              (let ((segs (cdr parts)))
                (concat
                 (enhanced-dirvish-crumb--make-segment
                  (if (display-graphic-p)
                      (concat (enhanced-dirvish-icon-glyph 'home 'enhanced-dirvish-crumb-segment) " ~")
                    "~")
                  (expand-file-name "~/"))
                 (mapconcat
                  (lambda (seg)
                    (setq acc (concat acc "/" seg))
                    (concat (propertize " › " 'face 'enhanced-dirvish-crumb-separator)
                            (enhanced-dirvish-crumb--make-segment seg (expand-file-name acc))))
                  segs "")))
            (concat
             (enhanced-dirvish-crumb--make-segment "/" "/")
             (mapconcat
              (lambda (seg)
                (setq acc (concat (if (string= acc "/") "" acc) "/" seg))
                (concat (propertize " › " 'face 'enhanced-dirvish-crumb-separator)
                        (enhanced-dirvish-crumb--make-segment seg acc)))
              parts ""))))
         (filter-pill (when enhanced-dirvish-local-filter
                        (concat
                         (propertize " " 'face 'enhanced-dirvish-pill-filter)
                         (enhanced-dirvish-icon-glyph 'search 'enhanced-dirvish-pill-filter "Filter:")
                         (propertize (format " %s " enhanced-dirvish-local-filter)
                                     'face 'enhanced-dirvish-pill-filter)))))
    (concat (or pane-badge "") " " crumbs (when filter-pill (concat "  " filter-pill)))))

(dirvish-define-mode-line enhanced-dirvish-view-info
  "Clickable Sort By and View controls in the header."
  (let* ((p (enhanced-dirvish-prefs))
         (vmode (enhanced-dirvish-view-current-mode))
         (view-lbl (pcase vmode
                     ('columns "Columns")
                     ('icons "Icons")
                     ('list (if (enhanced-dirvish-prefs-expandable-tree p) "Tree" "List"))
                     ('compact "Compact")
                     (_ "Columns")))
         (arrow (if (eq (enhanced-dirvish-prefs-sort-direction p) 'desc) "↓" "↑"))
         (sort-lbl (capitalize (symbol-name (enhanced-dirvish-prefs-sort-key p))))
         (tenx (when (enhanced-dirvish-prefs-tenxer-mode p)
                 (propertize " 10X " 'face 'enhanced-dirvish-pill-10x))))
    (concat
     (propertize (format " [Sort By… %s %s] " sort-lbl arrow)
                 'face 'enhanced-dirvish-header-accent
                 'mouse-face 'highlight 'pointer 'hand
                 'help-echo (concat "Sort files by name, date, size or extension"
                                    (and (bound-and-true-p enhanced-dirvish-file-manager-keys) " (C-c s)"))
                 'local-map enhanced-dirvish-sort-header-map 'keymap enhanced-dirvish-sort-header-map)
     ;; Adjacent equal mouse-face properties form one hover region even
     ;; when the buttons have different keymaps.  Keep a plain gap between.
     " "
     (propertize (format " [View… %s] " view-lbl)
                 'face 'enhanced-dirvish-header-accent
                 'mouse-face 'highlight 'pointer 'hand
                 'help-echo "Choose Columns, Icons, List/Tree or Compact (C-1 / C-2 / C-3 / C-4)"
                 'local-map enhanced-dirvish-view-header-map 'keymap enhanced-dirvish-view-header-map)
     (or tenx ""))))

(defun enhanced-dirvish-view-header-line ()
  "Render breadcrumbs while reserving room for the Sort By and View controls."
  (let* ((right (dirvish-enhanced-dirvish-view-info-ml))
         (left (dirvish-enhanced-dirvish-breadcrumb-ml))
         (room (max 0 (- (window-width) (string-width right) 1))))
    (concat (truncate-string-to-width left room nil nil "…")
            (propertize " " 'display
                        `(space :align-to (- right ,(string-width right))))
            right)))

(dirvish-define-mode-line enhanced-dirvish-footer
  "Footer: selection summary, clipboard, chord indicator, and hints."
  (let* ((p (enhanced-dirvish-prefs))
         (count (length (enhanced-dirvish-marked-files-only)))
         (clip (when (fboundp 'enhanced-dirvish-pane-clipboard-summary)
                 (enhanced-dirvish-pane-clipboard-summary)))
         (chord (when enhanced-dirvish-active-chord
                  (propertize (format " %s " enhanced-dirvish-active-chord) 'face 'enhanced-dirvish-pill-chord)))
         (hints (when (and (enhanced-dirvish-prefs-show-keybinding-hints p) (not chord))
                  (if (enhanced-dirvish-prefs-tenxer-mode p)
                      " j/k Nav  g Go  , Sort  ; Act  t Tabs  i Peek  f Filter  ~ Keys"
                    (concat " ←/→ Nav  C-1..4 View  "
                            (and (bound-and-true-p enhanced-dirvish-file-manager-keys) "C-c s Sort  ")
                            "F3 Split  C-k Search  C-, Prefs  ? Keys")))))
    (concat
     (if (> count 0)
         (propertize (format " %d selected " count) 'face 'enhanced-dirvish-header-accent)
       "")
     (when clip (propertize (format " %s " clip) 'face 'enhanced-dirvish-hint-key))
     (or chord "")
     (when hints (propertize hints 'face 'enhanced-dirvish-hint-desc)))))

;;;; Async Thumbnail Generator (Icons View)

(defun enhanced-dirvish-thumbnail-path (file size)
  "Return cache PNG path for FILE at SIZE."
  (make-directory enhanced-dirvish-thumbnail-dir t)
  (expand-file-name (format "%s-%d.png" (md5 file) size) enhanced-dirvish-thumbnail-dir))

(defun enhanced-dirvish-thumbnail-maybe-generate (file size callback)
  "Return cached thumbnail path if fresh, or generate asynchronously via CALLBACK."
  (let ((out (enhanced-dirvish-thumbnail-path file size))
        (ext (downcase (or (file-name-extension file) ""))))
    (if (and (file-exists-p out)
             (file-newer-than-file-p out file))
        out
      (unless (gethash out enhanced-dirvish-thumbnail-pending)
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
            (puthash out t enhanced-dirvish-thumbnail-pending)
            (make-process
             :name (format "enhanced-dirvish-thumb-%s" (file-name-nondirectory file))
             :noquery t
             :command cmd
             :sentinel
             (lambda (proc _ev)
               (when (memq (process-status proc) '(exit signal))
                 (remhash out enhanced-dirvish-thumbnail-pending)
                 (when (and (= 0 (process-exit-status proc)) (file-exists-p out))
                   (funcall callback out))))))))
      nil)))

;;;; Compact View (Horizontal Multi-Column Flow + Sideways Scroll + Full-Names Toggle)

(defvar-local enhanced-dirvish-view-directory nil "Directory displayed in compact/icons view buffer.")
(defvar-local enhanced-dirvish-marked-entries nil "Marked file paths in compact/icons view buffer.")
(defvar-local enhanced-dirvish-compact-col-width 28 "Current column stride in Compact view.")
(defvar-local enhanced-dirvish-compact-rows 20 "Row count per vertical column in Compact view.")

(defun enhanced-dirvish-view--buffer (label dir)
  "Return the LABEL (\"Compact\" or \"Icons\") view buffer for DIR.
The buffer is for the selected window.  A view buffer is named after its
folder alone, so one shown in another window (the other split pane, or
another frame) is never taken: rendering a different folder into it would
move that window too, as with a folder holding a same-named subfolder."
  (let* ((key (directory-file-name (expand-file-name dir)))
         (nm (file-name-nondirectory key))
         (base (format "*Enhanced Dirvish %s: %s" label (if (string-empty-p nm) "/" nm)))
         (name (concat base "*"))
         (n 1)
         (win (selected-window)))
    (while (when-let ((buf (get-buffer name)))
             (cl-some (lambda (w) (not (eq w win)))
                      (get-buffer-window-list buf nil t)))
      (setq name (format "%s<%d>*" base (cl-incf n))))
    (get-buffer-create name)))

(defvar enhanced-dirvish-mouse--inhibit-preview nil
  "Non-nil while tracking a live mouse drag selection to avoid preview churn.")

(defvar enhanced-dirvish-mouse--drag-state nil
  "Active drag-selection state plist while holding button-1.")

(defvar enhanced-dirvish-mouse--finished-drag-state nil
  "Completed drag-selection state awaiting button-1 release command.")

(defvar enhanced-dirvish-mouse--suppress-mouse-3-once nil
  "Non-nil after cancelling a drag with right button to drop trailing release.")

(defvar enhanced-dirvish-mouse--recent-dir-open nil
  "Snapshot of last single-click directory navigation to guard double-clicks.")

(defun enhanced-dirvish-mouse--history (direction event)
  "Navigate DIRECTION in the browser pane owning mouse EVENT."
  ;; `mouse-event-p' only recognizes the primary buttons on some Emacs builds.
  ;; Thumb buttons still carry the normal positional event structure.
  (let* ((clicked (and (consp event) (posn-window (event-start event))))
         (target (and (window-live-p clicked)
                      (with-current-buffer (window-buffer clicked)
                        (if (and (enhanced-dirvish-panes--valid-main-window-p clicked)
                                 (derived-mode-p 'dired-mode 'enhanced-dirvish-compact-mode 'enhanced-dirvish-icons-mode
                                                 'enhanced-dirvish-computer-mode 'enhanced-dirvish-trash-mode
                                                 'enhanced-dirvish-recent-mode 'enhanced-dirvish-network-mode))
                            clicked
                          (when-let ((dv (dirvish-curr))) (dv-root-window dv)))))))
    (setq target (or (and (window-live-p target) target) (enhanced-dirvish-panes--main-window)))
    (when (window-live-p target)
      (select-window target)
      (enhanced-dirvish-panes--sync-active-pane-from-window target)
      (let ((pane (enhanced-dirvish-active-pane)))
        ;; At either end of history the thumb button behaves like a disabled
        ;; Back or Forward control instead of interrupting mouse navigation.
        (if (eq direction 'back)
            (when (enhanced-dirvish-pane-state-history-back pane) (enhanced-dirvish-history-back))
          (when (enhanced-dirvish-pane-state-history-fwd pane) (enhanced-dirvish-history-forward)))))))

(defun enhanced-dirvish-mouse-history-back (&optional event)
  "Go back in the pane under mouse EVENT, or the active pane."
  (interactive (list (when (consp last-input-event) last-input-event)))
  (enhanced-dirvish-mouse--history 'back event))

(defun enhanced-dirvish-mouse-history-forward (&optional event)
  "Go forward in the pane under mouse EVENT, or the active pane."
  (interactive (list (when (consp last-input-event) last-input-event)))
  (enhanced-dirvish-mouse--history 'forward event))

(defun enhanced-dirvish-mouse-install-history-bindings (map)
  "Install Back/Forward thumb buttons and hardware keys on browser MAP."
  (dolist (pair '((8 . enhanced-dirvish-mouse-history-back) (9 . enhanced-dirvish-mouse-history-forward)))
    (dolist (prefix '("mouse-" "double-mouse-" "triple-mouse-" "drag-mouse-"
                      "down-mouse-" "double-down-mouse-" "triple-down-mouse-"))
      (let ((event (intern (format "%s%d" prefix (car pair))))
            (command (if (string-match-p "down-" prefix) #'ignore (cdr pair))))
        (dolist (area '(nil header-line mode-line))
          (define-key map (if area (vector area event) (vector event)) command)))))
  (define-key map [XF86Back] #'enhanced-dirvish-mouse-history-back)
  (define-key map [XF86Forward] #'enhanced-dirvish-mouse-history-forward)
  map)

(defun enhanced-dirvish-mouse-install-keymap-bindings (map)
  "Install shared mouse click, drag-select, and drop bindings on MAP."
  (define-key map (kbd "<down-mouse-1>") #'enhanced-dirvish-mouse-down-entry)
  (define-key map (kbd "<mouse-1>") #'enhanced-dirvish-mouse-click-entry)
  (define-key map (kbd "<drag-mouse-1>") #'enhanced-dirvish-mouse-drag-drop)
  (define-key map (kbd "<C-down-mouse-1>") #'enhanced-dirvish-mouse-down-entry)
  (define-key map (kbd "<C-mouse-1>") #'enhanced-dirvish-mouse-toggle-select)
  (define-key map (kbd "<C-drag-mouse-1>") #'enhanced-dirvish-mouse-drag-copy)
  (define-key map (kbd "<S-down-mouse-1>") #'enhanced-dirvish-mouse-down-entry)
  (define-key map (kbd "<S-mouse-1>") #'enhanced-dirvish-mouse-range-select)
  (define-key map (kbd "<S-drag-mouse-1>") #'enhanced-dirvish-mouse-drag-move)
  (define-key map (kbd "<C-S-down-mouse-1>") #'enhanced-dirvish-mouse-down-entry)
  (define-key map (kbd "<C-S-mouse-1>") #'enhanced-dirvish-mouse-add-range-select)
  (define-key map (kbd "<C-S-drag-mouse-1>") #'enhanced-dirvish-mouse-drag-drop)
  (define-key map (kbd "<double-drag-mouse-1>") #'enhanced-dirvish-mouse-drag-drop)
  (define-key map (kbd "<mouse-2>") #'enhanced-dirvish-mouse-activate-at-event)
  (define-key map (kbd "<double-mouse-1>") #'enhanced-dirvish-mouse-activate-at-event)
  (define-key map (kbd "<mouse-3>") #'enhanced-dirvish-mouse-context-menu)
  (enhanced-dirvish-mouse-install-history-bindings map)
  map)

(defvar enhanced-dirvish-compact-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "j") #'enhanced-dirvish-compact-next-item)
    (define-key map (kbd "<down>") #'enhanced-dirvish-compact-next-item)
    (define-key map (kbd "k") #'enhanced-dirvish-compact-prev-item)
    (define-key map (kbd "<up>") #'enhanced-dirvish-compact-prev-item)
    (define-key map (kbd "l") #'enhanced-dirvish-compact-next-col)
    (define-key map (kbd "<right>") #'enhanced-dirvish-compact-next-col)
    (define-key map (kbd "h") #'enhanced-dirvish-compact-prev-col)
    (define-key map (kbd "<left>") #'enhanced-dirvish-compact-prev-col)
    (define-key map (kbd "<wheel-up>") (lambda () (interactive) (scroll-right 6)))
    (define-key map (kbd "<wheel-down>") (lambda () (interactive) (scroll-left 6)))
    (define-key map (kbd "<wheel-left>") (lambda () (interactive) (scroll-right 6)))
    (define-key map (kbd "<wheel-right>") (lambda () (interactive) (scroll-left 6)))
    (define-key map (kbd "RET") #'enhanced-dirvish-open-or-edit-at-point)
    (enhanced-dirvish-mouse-install-keymap-bindings map)
    (define-key map (kbd "SPC") #'enhanced-dirvish-preview-at-point)
    (define-key map (kbd "m") #'enhanced-dirvish-view-toggle-mark)
    (define-key map (kbd "<backspace>") #'enhanced-dirvish-view-up-directory)
    (define-key map (kbd "g") #'enhanced-dirvish-compact-refresh)
    map)
  "Keymap for `enhanced-dirvish-compact-mode'.")

(declare-function enhanced-dirvish-preview-update-standalone "enhanced-dirvish-previews" (file &optional window))
(declare-function dirvish-enhanced-dirvish-breadcrumb-ml "enhanced-dirvish-views" () t)
(declare-function dirvish-enhanced-dirvish-view-info-ml "enhanced-dirvish-views" () t)
(declare-function dirvish-enhanced-dirvish-footer-ml "enhanced-dirvish-views" () t)

(defvar enhanced-dirvish--enforcing-no-wrap nil
  "Recursion guard while suppressing `visual-line-mode' in views.")

(defun enhanced-dirvish--enforce-no-wrap ()
  "Disable `visual-line-mode' and enforce single-line truncation in Compact/Icons."
  (unless enhanced-dirvish--enforcing-no-wrap
    (let ((enhanced-dirvish--enforcing-no-wrap t))
      (when (bound-and-true-p visual-line-mode)
        (visual-line-mode -1))
      (when (bound-and-true-p hl-line-mode)
        (hl-line-mode -1))
      (setq-local truncate-lines t
                  word-wrap nil
                  truncate-partial-width-windows nil))))

(define-derived-mode enhanced-dirvish-compact-mode special-mode "Enhanced-Dirvish-Compact"
  "Enhanced Dirvish Compact view: entries in columns, read top to bottom.
Columns run left to right and scroll sideways."
  (enhanced-dirvish--enforce-no-wrap)
  (add-hook 'visual-line-mode-hook #'enhanced-dirvish--enforce-no-wrap nil t)
  (add-hook 'after-change-major-mode-hook #'enhanced-dirvish--enforce-no-wrap 90 t)
  (setq-local header-line-format
              '(:eval (enhanced-dirvish-view-header-line)))
  (setq-local mode-line-format
              '(:eval (dirvish-enhanced-dirvish-footer-ml)))
  (add-hook 'post-command-hook #'enhanced-dirvish-view--sync-preview-on-move nil t))

(defun enhanced-dirvish-view--sync-preview-on-move ()
  "Keep selection highlight and preview pane synced on point motion.
In Columns, List, Compact and Icons views."
  (enhanced-dirvish-view--update-selection-highlight)
  (unless (or enhanced-dirvish-mouse--inhibit-preview enhanced-dirvish-mouse--drag-state)
    (when-let ((f (enhanced-dirvish-current-file)))
      (let ((dv (ignore-errors (dirvish-curr))))
        (cond
         ((and dv
               (window-live-p (dv-preview-window dv))
               (not (eq (dv-preview-window dv) (selected-window))))
          (dirvish-prop :index f)
          (dirvish--preview-update dv f))
         ((when-let ((pwin (or (and (boundp 'enhanced-dirvish-preview-standalone-window)
                                    (window-live-p enhanced-dirvish-preview-standalone-window)
                                    (eq (window-buffer enhanced-dirvish-preview-standalone-window)
                                        (get-buffer "*Enhanced Dirvish Preview*"))
                                    enhanced-dirvish-preview-standalone-window)
                               (get-buffer-window "*Enhanced Dirvish Preview*"))))
            (when (and (not (eq pwin (selected-window)))
                       (fboundp 'enhanced-dirvish-preview-update-standalone))
              (enhanced-dirvish-preview-update-standalone f pwin)))))))))

(defun enhanced-dirvish-compact--fit-name (name maxw full-p)
  "Fit NAME within MAXW display columns unless FULL-P is non-nil."
  (if full-p name (truncate-string-to-width name maxw nil nil "…")))

(defun enhanced-dirvish-compact-render (&optional dir)
  "Render DIR into vertical top-to-bottom, left-to-right columns."
  (enhanced-dirvish--enforce-no-wrap)
  (let* ((d (or dir enhanced-dirvish-view-directory default-directory))
         (p (enhanced-dirvish-prefs))
         (full-p (enhanced-dirvish-prefs-compact-full-names p))
         (entries (enhanced-dirvish-list-directory-entries d p))
         (cells
          (mapcar
           (lambda (e)
             (let* ((path (plist-get e :path))
                    (dir-p (plist-get e :dir-p))
                    (marked (member path enhanced-dirvish-marked-entries))
                    (prefix (concat (propertize (if marked "*" " ") 'face 'dired-marked)
                                    (enhanced-dirvish-file--glyph path dir-p) " "))
                    (shown (enhanced-dirvish-compact--fit-name (plist-get e :name)
                                                    (- 26 (string-width prefix) 1) full-p))
                    (face (cond (marked 'dired-marked)
                                ((enhanced-dirvish-file--badge-face path))
                                (dir-p 'dired-directory)
                                (t 'default)))
                    (cell (concat prefix (propertize shown 'face face 'enhanced-dirvish-entry-label t))))
               (add-text-properties 0 (length cell)
                                    (append (list 'enhanced-dirvish-entry path
                                                  'enhanced-dirvish-entry-dir dir-p
                                                  'help-echo path)
                                            (when dir-p '(mouse-face highlight pointer hand)))
                                    cell)
               cell))
           entries))
         (rows (max 6 (- (window-body-height) 2)))
         ;; Full names must fit the stride too; capping only the spacing lets
         ;; a long name push every later cell on its row out of alignment.
         (cell-w (if full-p
                     (if cells (+ 2 (apply #'max (mapcar #'string-width cells))) 21)
                   26))
         (ncols (max 1 (ceiling (max 1 (length entries)) (float rows))))
         (inhibit-read-only t)
         (cur (enhanced-dirvish-current-file)))
    (setq enhanced-dirvish-view-directory d
          default-directory (file-name-as-directory d)
          enhanced-dirvish-compact-col-width cell-w
          enhanced-dirvish-compact-rows rows)
    (erase-buffer)
    (dotimes (r rows)
      (dotimes (c ncols)
        (let ((idx (+ (* c rows) r)))
          (when (< idx (length entries))
            (let* ((cell (nth idx cells))
                   (pad (max 1 (- cell-w (string-width cell)))))
              (insert cell (propertize (make-string pad ?\s)
                                      'display `(space :align-to ,(* (1+ c) cell-w))))))))
      (insert "\n"))
    (goto-char (point-min))
    (cond
     ((and cur (enhanced-dirvish-goto-file cur)))
     (entries (enhanced-dirvish-goto-file (plist-get (car entries) :path)))
     (t (enhanced-dirvish-view--update-selection-highlight)))
    (when (fboundp 'enhanced-dirvish-watch-sync)
      (enhanced-dirvish-watch-sync (current-buffer)))))

(defun enhanced-dirvish-compact-refresh ()
  "Refresh Compact view buffer."
  (interactive)
  (when (derived-mode-p 'enhanced-dirvish-compact-mode)
    (enhanced-dirvish-compact-render enhanced-dirvish-view-directory)))

(defun enhanced-dirvish-compact--jump-offset (delta-items)
  "Move cursor by DELTA-ITEMS across Compact column cells."
  (when enhanced-dirvish-view-directory
    (let ((entries (enhanced-dirvish-list-directory-entries enhanced-dirvish-view-directory))
          (cur (enhanced-dirvish-current-file)))
      (when entries
        (let* ((paths (mapcar (lambda (e) (plist-get e :path)) entries))
               (idx (or (cl-position cur paths :test #'equal) 0))
               (next (max 0 (min (1- (length paths)) (+ idx delta-items)))))
          (enhanced-dirvish-goto-file (nth next paths)))))))

(defun enhanced-dirvish-compact-next-item () (interactive) (enhanced-dirvish-compact--jump-offset 1))
(defun enhanced-dirvish-compact-prev-item () (interactive) (enhanced-dirvish-compact--jump-offset -1))
(defun enhanced-dirvish-compact-next-col ()
  "Jump right one Compact column or open directory if scoped right."
  (interactive)
  (enhanced-dirvish-compact--jump-offset enhanced-dirvish-compact-rows))
(defun enhanced-dirvish-compact-prev-col ()
  "Jump left one Compact column."
  (interactive)
  (enhanced-dirvish-compact--jump-offset (- enhanced-dirvish-compact-rows)))

;;;; Icons Thumbnail Grid View

(defvar-local enhanced-dirvish-icons--ncols 4 "Current column count rendered in Icons view.")
(defvar-local enhanced-dirvish-icons--count 0 "Total entry count rendered in Icons view.")
(defvar-local enhanced-dirvish-icons--rendered-win-w nil "Window width captured at last Icons render.")
(defvar-local enhanced-dirvish-icons--refresh-timer nil "Coalescing timer for async thumbnail re-renders.")

(defvar enhanced-dirvish-icons-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "j") #'enhanced-dirvish-icons-next-row)
    (define-key map (kbd "<down>") #'enhanced-dirvish-icons-next-row)
    (define-key map (kbd "k") #'enhanced-dirvish-icons-prev-row)
    (define-key map (kbd "<up>") #'enhanced-dirvish-icons-prev-row)
    (define-key map (kbd "l") #'enhanced-dirvish-icons-next-cell)
    (define-key map (kbd "<right>") #'enhanced-dirvish-icons-next-cell)
    (define-key map (kbd "h") #'enhanced-dirvish-icons-prev-cell)
    (define-key map (kbd "<left>") #'enhanced-dirvish-icons-prev-cell)
    (define-key map (kbd "RET") #'enhanced-dirvish-open-or-edit-at-point)
    (enhanced-dirvish-mouse-install-keymap-bindings map)
    (define-key map (kbd "SPC") #'enhanced-dirvish-preview-at-point)
    (define-key map (kbd "m") #'enhanced-dirvish-view-toggle-mark)
    (define-key map (kbd "<backspace>") #'enhanced-dirvish-view-up-directory)
    (define-key map (kbd "g") #'enhanced-dirvish-icons-refresh)
    map)
  "Keymap for `enhanced-dirvish-icons-mode'.")

(defun enhanced-dirvish-icons--update-selection-highlight ()
  "Highlight the active card label cleanly in Icons view."
  (enhanced-dirvish-view--update-selection-highlight))

(defun enhanced-dirvish-icons--post-command-hook ()
  "Keep selection highlight and preview synced after motion in Icons view."
  (enhanced-dirvish-view--sync-preview-on-move))

(defun enhanced-dirvish-icons--on-window-size-change (&optional win-or-frame)
  "Reflow visible `enhanced-dirvish-icons-mode' buffers on window resize."
  (dolist (win (if (windowp win-or-frame) (list win-or-frame) (window-list)))
    (when (window-live-p win)
      (with-current-buffer (window-buffer win)
        (let ((cur-w (window-body-width win (display-graphic-p))))
          (when (and (derived-mode-p 'enhanced-dirvish-icons-mode)
                     enhanced-dirvish-view-directory
                     enhanced-dirvish-icons--rendered-win-w
                     (not (eql cur-w enhanced-dirvish-icons--rendered-win-w)))
            (with-selected-window win
              (enhanced-dirvish-icons-render enhanced-dirvish-view-directory))))))))

(define-derived-mode enhanced-dirvish-icons-mode special-mode "Enhanced-Dirvish-Icons"
  "Enhanced Dirvish Icons thumbnail grid view with live thumbnail caching."
  (enhanced-dirvish--enforce-no-wrap)
  (setq-local line-spacing 3)
  (add-hook 'visual-line-mode-hook #'enhanced-dirvish--enforce-no-wrap nil t)
  (add-hook 'after-change-major-mode-hook #'enhanced-dirvish--enforce-no-wrap 90 t)
  (setq-local header-line-format
              '(:eval (enhanced-dirvish-view-header-line)))
  (setq-local mode-line-format
              '(:eval (dirvish-enhanced-dirvish-footer-ml)))
  (add-hook 'post-command-hook #'enhanced-dirvish-icons--post-command-hook nil t)
  (add-hook 'window-size-change-functions #'enhanced-dirvish-icons--on-window-size-change nil t))

(defun enhanced-dirvish-icons--scale-glyph (glyph thumb-px)
  "Scale GLYPH proportionally to THUMB-PX on GUI frames.
Its font family and tint are kept."
  (if (not (display-graphic-p))
      glyph
    (let* ((ch (max 12 (frame-char-height)))
           (scale (max 1.8 (min 4.8 (/ (* thumb-px 0.72) (float ch)))))
           (copy (copy-sequence glyph)))
      (add-face-text-property 0 (length copy) (list :height scale) nil copy)
      copy)))

(defun enhanced-dirvish-icons--wrap-name (name max-cols)
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

(defun enhanced-dirvish-icons--fit-gui-label (str max-px)
  "Ensure GUI string STR does not exceed MAX-PX pixel width."
  (let ((s str))
    (while (and (> (length s) 3)
                (fboundp 'string-pixel-width)
                (> (string-pixel-width s) max-px))
      (setq s (concat (substring s 0 (max 2 (- (length s) 2))) "…")))
    s))

(defun enhanced-dirvish-icons--schedule-refresh (buf dir)
  "Coalesce async thumbnail completions for BUF displaying DIR."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (timerp enhanced-dirvish-icons--refresh-timer)
        (cancel-timer enhanced-dirvish-icons--refresh-timer))
      (setq-local enhanced-dirvish-icons--refresh-timer
                  (run-with-timer
                   0.05 nil
                   (lambda (b d)
                     (when (buffer-live-p b)
                       (with-current-buffer b
                         (setq-local enhanced-dirvish-icons--refresh-timer nil)
                         (when (and (derived-mode-p 'enhanced-dirvish-icons-mode)
                                    (equal enhanced-dirvish-view-directory d))
                           (if-let ((win (get-buffer-window b t)))
                               (with-selected-window win
                                 (enhanced-dirvish-icons-render d))
                             (enhanced-dirvish-icons-render d))))))
                   buf dir)))))

(defun enhanced-dirvish-icons-render (&optional dir)
  "Render aligned, centered thumbnail/icon grid cards for DIR into current buffer."
  (enhanced-dirvish--enforce-no-wrap)
  (let* ((d (or dir enhanced-dirvish-view-directory default-directory))
         (p (enhanced-dirvish-prefs))
         (entries (enhanced-dirvish-list-directory-entries d p))
         (thumb-px (max 32 (min 256 (or (enhanced-dirvish-prefs-icons-thumbnail-size p) 64))))
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
         (cur (enhanced-dirvish-current-file))
         (buf (current-buffer))
         (cards nil)
         (idx 0))
    (setq enhanced-dirvish-view-directory d
          default-directory (file-name-as-directory d)
          enhanced-dirvish-icons--ncols ncols
          enhanced-dirvish-icons--count (length entries)
          enhanced-dirvish-icons--rendered-win-w win-raw)
    (erase-buffer)
    (dolist (e entries)
      (let* ((path (plist-get e :path))
             (name (plist-get e :name))
             (dir-p (plist-get e :dir-p))
             (marked (member path enhanced-dirvish-marked-entries))
             (thumb (when (and (not dir-p)
                               graphic-p
                               (enhanced-dirvish-prefs-show-thumbnails p))
                      (or (enhanced-dirvish-thumbnail-maybe-generate
                           path thumb-px
                           (lambda (_out)
                             (enhanced-dirvish-icons--schedule-refresh buf d)))
                          (let ((cand (enhanced-dirvish-thumbnail-path path thumb-px)))
                            (when (file-exists-p cand) cand)))))
             (img (when (and thumb (image-type-available-p 'png))
                    (create-image thumb 'png nil
                                  :max-height thumb-px :max-width thumb-px :ascent 85)))
             (icon-str (if img
                           (propertize " " 'display img)
                         (enhanced-dirvish-icons--scale-glyph (enhanced-dirvish-file--glyph path dir-p) thumb-px)))
             (icon-w (if graphic-p
                         (if img
                             (round (or (car (ignore-errors (image-size img t))) thumb-px))
                           (round (if (fboundp 'string-pixel-width)
                                      (string-pixel-width icon-str)
                                    (* 3 char-w))))
                       (string-width icon-str)))
             (face (cond (marked 'dired-marked)
                         ((enhanced-dirvish-file--badge-face path))
                         (dir-p 'dired-directory)
                         (t 'default)))
             (wrapped (enhanced-dirvish-icons--wrap-name name (if marked (- max-lbl-chars 2) max-lbl-chars)))
             (l1-raw (concat (if marked "✓ " "") (car wrapped)))
             (l2-raw (cadr wrapped))
             (props (append (list 'enhanced-dirvish-entry path
                                  'enhanced-dirvish-entry-dir dir-p
                                  'enhanced-dirvish-grid-idx idx
                                  'help-echo path
                                  'mouse-face 'highlight)
                            (when dir-p '(pointer hand))))
             (icon-cell (apply #'propertize icon-str props))
             (l1-text (if graphic-p
                          (enhanced-dirvish-icons--fit-gui-label (propertize l1-raw 'face face) (- tile-px char-w))
                        (propertize l1-raw 'face face)))
             (l1-cell (apply #'propertize l1-text (append (list 'enhanced-dirvish-grid-label t) props)))
             (l1-w (if graphic-p
                       (round (if (fboundp 'string-pixel-width)
                                  (string-pixel-width l1-cell)
                                (* (string-width l1-cell) char-w)))
                     (string-width l1-cell)))
             (l2-text (when l2-raw
                        (if graphic-p
                            (enhanced-dirvish-icons--fit-gui-label (propertize l2-raw 'face face) (- tile-px char-w))
                          (propertize l2-raw 'face face))))
             (l2-cell (when l2-text
                        (apply #'propertize l2-text (append (list 'enhanced-dirvish-grid-label-cont t) props))))
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
     ((and cur (enhanced-dirvish-goto-file cur)))
     ((> enhanced-dirvish-icons--count 0) (enhanced-dirvish-icons--goto-index 0))
     (t (enhanced-dirvish-icons--update-selection-highlight)))
    (when (fboundp 'enhanced-dirvish-watch-sync)
      (enhanced-dirvish-watch-sync (current-buffer)))))

(defun enhanced-dirvish-icons-refresh ()
  "Refresh Icons grid view."
  (interactive)
  (when (derived-mode-p 'enhanced-dirvish-icons-mode)
    (enhanced-dirvish-icons-render enhanced-dirvish-view-directory)))

(defun enhanced-dirvish-icons--current-index ()
  "Return zero-based index of card at point in Icons view, or nil."
  (or (get-text-property (point) 'enhanced-dirvish-grid-idx)
      (when-let ((cur (enhanced-dirvish-current-file)))
        (save-excursion
          (enhanced-dirvish-goto-file cur)
          (get-text-property (point) 'enhanced-dirvish-grid-idx)))))

(defun enhanced-dirvish-icons--goto-index (target-idx)
  "Jump to the label start of grid card TARGET-IDX in Icons view."
  (when (and (> enhanced-dirvish-icons--count 0) (>= target-idx 0))
    (let* ((idx (min (1- enhanced-dirvish-icons--count) target-idx))
           (pos (point-min))
           (best nil)
           (fallback nil))
      (while (and (< pos (point-max)) (not best))
        (let ((next (or (next-single-property-change pos 'enhanced-dirvish-grid-idx) (point-max)))
              (v (get-text-property pos 'enhanced-dirvish-grid-idx)))
          (when (eql v idx)
            (unless fallback (setq fallback pos))
            (let ((lbl (if (get-text-property pos 'enhanced-dirvish-grid-label)
                           pos
                         (let ((cand (next-single-property-change pos 'enhanced-dirvish-grid-label nil next)))
                           (when (and cand (< cand next)
                                      (get-text-property cand 'enhanced-dirvish-grid-label))
                             cand)))))
              (when lbl (setq best lbl))))
          (setq pos next)))
      (when-let ((dest (or best fallback)))
        (goto-char dest)
        (enhanced-dirvish-icons--update-selection-highlight)))))

(defun enhanced-dirvish-icons-next-cell ()
  "Move forward to next grid item in Icons view."
  (interactive)
  (when (> enhanced-dirvish-icons--count 0)
    (let ((cur (or (enhanced-dirvish-icons--current-index) -1)))
      (enhanced-dirvish-icons--goto-index (min (1- enhanced-dirvish-icons--count) (1+ cur))))))

(defun enhanced-dirvish-icons-prev-cell ()
  "Move backward to previous grid item in Icons view."
  (interactive)
  (when (> enhanced-dirvish-icons--count 0)
    (let ((cur (or (enhanced-dirvish-icons--current-index) 1)))
      (enhanced-dirvish-icons--goto-index (max 0 (1- cur))))))

(defun enhanced-dirvish-icons-next-row ()
  "Move down one grid row in Icons view."
  (interactive)
  (when (> enhanced-dirvish-icons--count 0)
    (let* ((ncols (max 1 enhanced-dirvish-icons--ncols))
           (cur (or (enhanced-dirvish-icons--current-index) 0))
           (cur-row (/ cur ncols))
           (last-row (/ (1- enhanced-dirvish-icons--count) ncols)))
      (when (< cur-row last-row)
        (enhanced-dirvish-icons--goto-index (min (1- enhanced-dirvish-icons--count) (+ cur ncols)))))))

(defun enhanced-dirvish-icons-prev-row ()
  "Move up one grid row in Icons view."
  (interactive)
  (when (> enhanced-dirvish-icons--count 0)
    (let* ((ncols (max 1 enhanced-dirvish-icons--ncols))
           (cur (or (enhanced-dirvish-icons--current-index) 0)))
      (when (>= (- cur ncols) 0)
        (enhanced-dirvish-icons--goto-index (- cur ncols))))))

(defun enhanced-dirvish-nav-next-line ()
  "Move down one visual item/row across List, Columns, Compact, and Icons views."
  (interactive)
  (cond ((derived-mode-p 'enhanced-dirvish-icons-mode) (enhanced-dirvish-icons-next-row))
        ((derived-mode-p 'enhanced-dirvish-compact-mode) (enhanced-dirvish-compact-next-item))
        ((derived-mode-p 'dired-mode) (dired-next-line 1))
        (t (call-interactively #'next-line))))

(defun enhanced-dirvish-nav-prev-line ()
  "Move up one visual item/row across List, Columns, Compact, and Icons views."
  (interactive)
  (cond ((derived-mode-p 'enhanced-dirvish-icons-mode) (enhanced-dirvish-icons-prev-row))
        ((derived-mode-p 'enhanced-dirvish-compact-mode) (enhanced-dirvish-compact-prev-item))
        ((derived-mode-p 'dired-mode) (dired-previous-line 1))
        (t (call-interactively #'previous-line))))

(defun enhanced-dirvish-view--move-focus (move)
  "Run MOVE within file entries, preserving marks and stopping at boundaries."
  (let ((current (enhanced-dirvish-current-file)))
    (if current
        (progn
          (condition-case nil (funcall move)
            ((beginning-of-buffer end-of-buffer) nil))
          (unless (enhanced-dirvish-current-file) (enhanced-dirvish-goto-file current)))
      (enhanced-dirvish-goto-file (car (enhanced-dirvish-view--entry-order))))
    (deactivate-mark)
    (enhanced-dirvish-view--reset-selection-range (enhanced-dirvish-current-file))
    (enhanced-dirvish-view--update-selection-highlight)))

(defun enhanced-dirvish-view--focus-down ()
  "Move focus down one entry or grid row, keeping explicit selections."
  (interactive)
  (enhanced-dirvish-view--move-focus #'enhanced-dirvish-nav-next-line))

(defun enhanced-dirvish-view--focus-up ()
  "Move focus up one entry or grid row, keeping explicit selections."
  (interactive)
  (enhanced-dirvish-view--move-focus #'enhanced-dirvish-nav-prev-line))

(defun enhanced-dirvish-view--focus-horizontal (direction)
  "Move focus DIRECTION columns or entries without opening folders."
  (enhanced-dirvish-view--move-focus
   (lambda ()
     (cond
      ((derived-mode-p 'enhanced-dirvish-icons-mode)
       (if (> direction 0) (enhanced-dirvish-icons-next-cell) (enhanced-dirvish-icons-prev-cell)))
      ((derived-mode-p 'enhanced-dirvish-compact-mode)
       (let* ((order (enhanced-dirvish-view--entry-order))
              (index (cl-position (enhanced-dirvish-current-file) order :test #'equal))
              (rows (max 1 enhanced-dirvish-compact-rows))
              (column (and index (+ (/ index rows) direction))))
         (when (and column (>= column 0) (< (* column rows) (length order)))
           (enhanced-dirvish-goto-file (nth (min (1- (length order)) (+ index (* direction rows))) order)))))
      ((> direction 0) (enhanced-dirvish-nav-next-line))
      (t (enhanced-dirvish-nav-prev-line))))))

(defun enhanced-dirvish-view--focus-right ()
  "Move focus right one entry or column, preserving explicit selections."
  (interactive)
  (enhanced-dirvish-view--focus-horizontal 1))

(defun enhanced-dirvish-view--focus-left ()
  "Move focus left one entry or column, preserving explicit selections."
  (interactive)
  (enhanced-dirvish-view--focus-horizontal -1))

(defun enhanced-dirvish-view--entry-order ()
  "Return ordered list of entry paths visible in the current browser buffer."
  (cond
   ((derived-mode-p 'dired-mode)
    (let (out)
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (unless (invisible-p (line-beginning-position))
            (when-let ((f (enhanced-dirvish-view--dired-entry-at-point)))
              (push f out)))
          (forward-line 1)))
      (nreverse out)))
   ((derived-mode-p 'enhanced-dirvish-compact-mode 'enhanced-dirvish-icons-mode)
    (mapcar (lambda (e) (plist-get e :path))
            (enhanced-dirvish-list-directory-entries
             (or enhanced-dirvish-view-directory default-directory)
             (enhanced-dirvish-prefs))))))

(defun enhanced-dirvish-view--set-entry-mark (path mark-p &optional no-refresh)
  "Mark or unmark PATH according to MARK-P across all Enhanced Dirvish views."
  (when path
    (let ((key (enhanced-dirvish--path-key path)))
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
       ((derived-mode-p 'enhanced-dirvish-compact-mode 'enhanced-dirvish-icons-mode)
        (setq enhanced-dirvish-marked-entries
              (cl-remove-if (lambda (e) (equal (enhanced-dirvish--path-key e) key))
                            enhanced-dirvish-marked-entries))
        (when mark-p
          (push path enhanced-dirvish-marked-entries))))
      (unless no-refresh
        (enhanced-dirvish-view--refresh-after-mark)))))

(defun enhanced-dirvish-view--refresh-after-mark ()
  "Refresh visual marks, selection overlays, and footer count."
  (cond
   ((derived-mode-p 'enhanced-dirvish-compact-mode) (enhanced-dirvish-compact-refresh))
   ((derived-mode-p 'enhanced-dirvish-icons-mode) (enhanced-dirvish-icons-refresh)))
  (enhanced-dirvish-view--update-selection-highlight)
  (force-mode-line-update t))

(defun enhanced-dirvish-view--mark-range (anchor-path target-path &optional additive)
  "Select ANCHOR-PATH through TARGET-PATH, shrinking on reversal.
With ADDITIVE, retain marks that preceded this range."
  (let ((order (enhanced-dirvish-view--entry-order)))
    (unless (and enhanced-dirvish--selection-range-active
                 (eq (not (null additive)) enhanced-dirvish--selection-range-additive)
                 (equal anchor-path enhanced-dirvish--selection-anchor-entry))
      (setq enhanced-dirvish--selection-base-keys
            (when additive (mapcar #'enhanced-dirvish--path-key (enhanced-dirvish-marked-files-only)))))
    (setq enhanced-dirvish--selection-anchor-entry anchor-path
          enhanced-dirvish--selection-range-active t
          enhanced-dirvish--selection-range-additive (not (null additive)))
    (enhanced-dirvish-mouse--apply-selection-keys
     order (delete-dups
            (append (copy-sequence enhanced-dirvish--selection-base-keys)
                    (mapcar #'enhanced-dirvish--path-key
                            (enhanced-dirvish-mouse--range-entries order anchor-path target-path)))) t)))

(defun enhanced-dirvish-shift-select-move (move-fn &optional additive)
  "Extend a contiguous range via MOVE-FN, preserving old marks if ADDITIVE."
  (let* ((cur (enhanced-dirvish-current-file))
         (anchor (or enhanced-dirvish--selection-anchor-entry cur)))
    (when anchor
      (condition-case nil (funcall move-fn)
        ((beginning-of-buffer end-of-buffer) nil))
      (unless (enhanced-dirvish-current-file) (enhanced-dirvish-goto-file cur))
      (enhanced-dirvish-view--mark-range anchor (or (enhanced-dirvish-current-file) cur) additive))))

(defun enhanced-dirvish-shift-select-next (&optional additive)
  "Extend selection to the next entry row (`S-<down>')."
  (interactive (list (memq 'control (event-modifiers last-command-event))))
  (enhanced-dirvish-shift-select-move #'enhanced-dirvish-nav-next-line additive))

(defun enhanced-dirvish-shift-select-prev (&optional additive)
  "Extend selection to the previous entry row (`S-<up>')."
  (interactive (list (memq 'control (event-modifiers last-command-event))))
  (enhanced-dirvish-shift-select-move #'enhanced-dirvish-nav-prev-line additive))

(defun enhanced-dirvish-shift-select-right (&optional additive)
  "Extend selection right in grid/compact views or down in list (`S-<right>')."
  (interactive (list (memq 'control (event-modifiers last-command-event))))
  (enhanced-dirvish-shift-select-move
   (cond ((derived-mode-p 'enhanced-dirvish-icons-mode) #'enhanced-dirvish-icons-next-cell)
         ((derived-mode-p 'enhanced-dirvish-compact-mode) #'enhanced-dirvish-compact-next-col)
         (t #'enhanced-dirvish-nav-next-line)) additive))

(defun enhanced-dirvish-shift-select-left (&optional additive)
  "Extend selection left in grid/compact views or up in list (`S-<left>')."
  (interactive (list (memq 'control (event-modifiers last-command-event))))
  (enhanced-dirvish-shift-select-move
   (cond ((derived-mode-p 'enhanced-dirvish-icons-mode) #'enhanced-dirvish-icons-prev-cell)
         ((derived-mode-p 'enhanced-dirvish-compact-mode) #'enhanced-dirvish-compact-prev-col)
         (t #'enhanced-dirvish-nav-prev-line)) additive))

(defun enhanced-dirvish-shift-select-first (&optional additive)
  "Select through the first visible entry, keeping old marks if ADDITIVE."
  (interactive (list (memq 'control (event-modifiers last-command-event))))
  (enhanced-dirvish-shift-select-move
   (lambda () (enhanced-dirvish-goto-file (car (enhanced-dirvish-view--entry-order)))) additive))

(defun enhanced-dirvish-shift-select-last (&optional additive)
  "Select through the last visible entry, keeping old marks if ADDITIVE."
  (interactive (list (memq 'control (event-modifiers last-command-event))))
  (enhanced-dirvish-shift-select-move
   (lambda () (enhanced-dirvish-goto-file (car (last (enhanced-dirvish-view--entry-order))))) additive))

(defun enhanced-dirvish-view-toggle-mark ()
  "Toggle selection mark on item at point across Compact/Icons/Dired views."
  (interactive)
  (when-let ((f (enhanced-dirvish-current-file)))
    (let* ((key (enhanced-dirvish--path-key f))
           (present (cl-some (lambda (e) (equal (enhanced-dirvish--path-key e) key))
                             (enhanced-dirvish-marked-files-only))))
      (enhanced-dirvish-view--reset-selection-range f)
      (enhanced-dirvish-view--set-entry-mark f (not present) nil))))

(defun enhanced-dirvish-view-unmark ()
  "Unmark the current item without moving point."
  (interactive)
  (when-let ((f (enhanced-dirvish-current-file)))
    (enhanced-dirvish-view--reset-selection-range f)
    (enhanced-dirvish-view--set-entry-mark f nil)))

(defun enhanced-dirvish-mouse--entry-at-point ()
  "Resolve clicked entry path in Dired, Dirvish DIRview, Compact, or Icons."
  (or (get-text-property (point) 'enhanced-dirvish-entry)
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

(defun enhanced-dirvish-mouse--edit-or-open-file (path)
  "Direct-edit regular file PATH in preview pane, or fall back to `find-file'."
  (if (fboundp 'enhanced-dirvish-preview-edit-file)
      (enhanced-dirvish-preview-edit-file path)
    (when (fboundp 'enhanced-dirvish--flatten-layout)
      (enhanced-dirvish--flatten-layout))
    (find-file path)))

(defun enhanced-dirvish-mouse--open-path (path dir-only-p)
  "Open PATH in the appropriate pane; when DIR-ONLY-P, only navigate dirs."
  (when (and path (not (string-empty-p path)))
    (let ((is-dir (file-directory-p path)))
      (when (derived-mode-p 'dirvish-directory-view-mode)
        (when-let* ((dv (or (dirvish-curr)
                            (and (boundp 'dirvish--sessions)
                                 (gethash (dirvish-prop :dv) dirvish--sessions))))
                    (root-win (or (let ((rw (dv-root-window dv)))
                                    (and (window-live-p rw) rw))
                                  (and (fboundp 'enhanced-dirvish-panes--main-window)
                                       (enhanced-dirvish-panes--main-window)))))
          (when (window-live-p root-win)
            (select-window root-win))))
      (cond
       (is-dir
        (enhanced-dirvish-open-location path t))
       ((not dir-only-p)
        (enhanced-dirvish-mouse--edit-or-open-file path))))))

(defun enhanced-dirvish-mouse--sync-event (event)
  "Move window selection & point to EVENT and sync active split pane."
  (mouse-set-point event)
  (when (fboundp 'enhanced-dirvish-panes--sync-active-pane-from-window)
    (enhanced-dirvish-panes--sync-active-pane-from-window (selected-window))))

(defun enhanced-dirvish-mouse--compact-position (posn)
  "Capture the visible Compact viewport before moving point to mouse POSN."
  (when-let ((win (and (consp posn) (posn-window posn))))
    (when (and (window-live-p win)
               (with-current-buffer (window-buffer win) (derived-mode-p 'enhanced-dirvish-compact-mode)))
      (list (window-point win) (window-start win)
            (window-hscroll win) (window-vscroll win t)))))

(defun enhanced-dirvish-mouse--clear-focus (&optional compact-position)
  "Deselect without scrolling Compact view away from COMPACT-POSITION."
  (if compact-position
      (progn
        ;; EOB can fall below the last fully visible row in a GUI font.
        ;; Parking point there makes redisplay recenter and hide early folders.
        (goto-char (min (car compact-position) (point-max)))
        (set-window-start nil (min (nth 1 compact-position) (point-max)) t)
        (set-window-hscroll nil (nth 2 compact-position))
        (set-window-vscroll nil (nth 3 compact-position) t)
        (setq enhanced-dirvish--empty-click-position (point)))
    (goto-char (point-max))
    (setq enhanced-dirvish--empty-click-position nil))
  (setq enhanced-dirvish--empty-click-p t)
  (enhanced-dirvish-view--reset-selection-range)
  (enhanced-dirvish-view--update-selection-highlight))

(defun enhanced-dirvish-mouse--dired-entry-at-pt (pt)
  "Resolve nearest Dired entry path around buffer position PT."
  (save-excursion
    (goto-char (min (max (point-min) pt) (point-max)))
    (or (enhanced-dirvish-mouse--entry-at-point)
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

(defun enhanced-dirvish-mouse--compact-entry-at-pt (pt)
  "Resolve nearest Compact cell path around buffer position PT."
  (save-excursion
    (goto-char (min (max (point-min) pt) (point-max)))
    (or (get-text-property (point) 'enhanced-dirvish-entry)
        (let ((find-on-line
               (lambda (ref)
                 (let ((le (line-end-position))
                       (pos (line-beginning-position))
                       (spans nil))
                   (while (< pos le)
                     (let ((nxt (or (next-single-property-change pos 'enhanced-dirvish-entry nil le) le))
                           (val (get-text-property pos 'enhanced-dirvish-entry)))
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

(defun enhanced-dirvish-mouse--icons-entry-at-posn (win pt xy)
  "Resolve nearest Icons tile path around WIN position PT / pixel XY."
  (save-excursion
    (goto-char (min (max (point-min) pt) (point-max)))
    (or (get-text-property (point) 'enhanced-dirvish-entry)
        (let ((line-spans
               (lambda ()
                 (let ((pos (line-beginning-position))
                       (le (line-end-position))
                       (out nil))
                   (while (< pos le)
                     (let ((nxt (or (next-single-property-change pos 'enhanced-dirvish-entry nil le) le))
                           (val (get-text-property pos 'enhanced-dirvish-entry)))
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

(defun enhanced-dirvish-mouse--posn-fallback-pt (win posn)
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

(defun enhanced-dirvish-mouse--entry-at-posn (posn &optional nearest-p)
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
                  (enhanced-dirvish-mouse--entry-at-point))
                (when nearest-p
                  (let ((p (or pt (enhanced-dirvish-mouse--posn-fallback-pt win posn))))
                    (cond
                     ((derived-mode-p 'dired-mode) (enhanced-dirvish-mouse--dired-entry-at-pt p))
                     ((derived-mode-p 'enhanced-dirvish-compact-mode) (enhanced-dirvish-mouse--compact-entry-at-pt p))
                     ((derived-mode-p 'enhanced-dirvish-icons-mode) (enhanced-dirvish-mouse--icons-entry-at-posn win p xy))))))))))))

(defun enhanced-dirvish-mouse--range-entries (order anchor target &optional rect-p)
  "Return ordered entry paths between ANCHOR and TARGET in ORDER.
When RECT-P is non-nil in Icons/Compact multi-column views, use the 2D box."
  (let* ((keys (mapcar #'enhanced-dirvish--path-key order))
         (i1 (and anchor (cl-position (enhanced-dirvish--path-key anchor) keys :test #'equal)))
         (i2 (and target (cl-position (enhanced-dirvish--path-key target) keys :test #'equal)))
         (n (length order)))
    (cond
     ((and i1 i2 rect-p (derived-mode-p 'enhanced-dirvish-icons-mode) (> (or enhanced-dirvish-icons--ncols 1) 1))
      (let* ((ncols (max 1 enhanced-dirvish-icons--ncols))
             (r1 (/ i1 ncols)) (c1 (mod i1 ncols))
             (r2 (/ i2 ncols)) (c2 (mod i2 ncols))
             (out nil))
        (cl-loop for r from (min r1 r2) to (max r1 r2) do
                 (cl-loop for c from (min c1 c2) to (max c1 c2)
                          for idx = (+ (* r ncols) c)
                          when (< idx n)
                          do (push (nth idx order) out)))
        (nreverse out)))
     ((and i1 i2 rect-p (derived-mode-p 'enhanced-dirvish-compact-mode)
           (> n (max 1 (or enhanced-dirvish-compact-rows 1))))
      (let* ((rows (max 1 enhanced-dirvish-compact-rows))
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

(defun enhanced-dirvish-mouse--apply-selection-keys (order target-keys &optional final-p)
  "Sync current buffer marks to exact set of TARGET-KEYS efficiently.
When FINAL-P is non-nil in Compact/Icons, re-render mark badges cleanly."
  (let ((want (make-hash-table :test #'equal)))
    (dolist (k target-keys)
      (when k (puthash k t want)))
    (cond
     ((derived-mode-p 'dired-mode)
      (let* ((cur (enhanced-dirvish-marked-files-only))
             (have (make-hash-table :test #'equal)))
        (dolist (f cur)
          (puthash (enhanced-dirvish--path-key f) t have))
        (save-excursion
          (dolist (f cur)
            (unless (gethash (enhanced-dirvish--path-key f) want)
              (when (or (ignore-errors (dired-goto-file f))
                        (ignore-errors (dired-goto-file (concat (directory-file-name f) "/"))))
                (dired-unmark 1))))
          (let ((dired-marker-char ?*))
            (dolist (f order)
              (let ((k (enhanced-dirvish--path-key f)))
                (when (and (gethash k want) (not (gethash k have)))
                  (when (or (ignore-errors (dired-goto-file f))
                            (ignore-errors (dired-goto-file (concat (directory-file-name f) "/"))))
                    (dired-mark 1)))))))
        (enhanced-dirvish-view--update-selection-highlight)
        (force-mode-line-update t)))
     ((derived-mode-p 'enhanced-dirvish-compact-mode 'enhanced-dirvish-icons-mode)
      ;; Store reversed so `enhanced-dirvish-marked-files-only' yields directory order.
      ;; Filtering can share ORDER's tail; leave the active drag's cached
      ;; directory order intact when a selection includes the final files.
      (setq enhanced-dirvish-marked-entries
            (reverse (cl-remove-if-not (lambda (f) (gethash (enhanced-dirvish--path-key f) want)) order)))
      (if final-p
          (enhanced-dirvish-view--refresh-after-mark)
        (enhanced-dirvish-view--update-selection-highlight)
        (force-mode-line-update t))))))

(defun enhanced-dirvish-mouse--drag-files (entry marked)
  "Return the original drag payload for ENTRY and pre-drag MARKED files."
  (if (and marked (or (not entry)
                      (member (enhanced-dirvish--path-key entry)
                              (mapcar #'enhanced-dirvish--path-key marked))))
      marked
    (when entry (list entry))))

(defun enhanced-dirvish-mouse--drag-exceeded-p (start-xy end-xy start-win end-win exact-start cur-entry)
  "Return non-nil once drag movement crosses click threshold or changes entry."
  (or (not (eq start-win end-win))
      (and cur-entry exact-start
           (not (equal (enhanced-dirvish--path-key cur-entry)
                       (enhanced-dirvish--path-key exact-start))))
      (and (consp start-xy) (consp end-xy)
           (integerp (car start-xy)) (integerp (cdr start-xy))
           (integerp (car end-xy)) (integerp (cdr end-xy))
           (let ((dx (- (car end-xy) (car start-xy)))
                 (dy (- (cdr end-xy) (cdr start-xy))))
             (> (+ (* dx dx) (* dy dy)) 36)))))

(defun enhanced-dirvish-mouse--sync-drag-range (order base-keys anchor hover rect-p last-keys-cell last-hover-cell &optional final-p)
  "Update swept marks from ANCHOR to HOVER inside ORDER when changed."
  (when (and anchor hover)
    (let* ((range (enhanced-dirvish-mouse--range-entries order anchor hover rect-p))
           (keys (delete-dups (append (copy-sequence base-keys)
                                      (mapcar #'enhanced-dirvish--path-key range)))))
      (setcar last-hover-cell hover)
      (when (or final-p (not (equal keys (car last-keys-cell))))
        (setcar last-keys-cell keys)
        ;; Let the command loop redisplay.  Forced redisplay here can run
        ;; timers and reenter selection updates while processing motion.
        (enhanced-dirvish-mouse--apply-selection-keys order keys final-p)))))

(defun enhanced-dirvish-mouse--edge-scroll-step (win mcol mrow order base-keys anchor rect-p last-keys-cell last-hover-cell)
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
                 (hover (enhanced-dirvish-mouse--entry-at-posn edge-posn t)))
            (enhanced-dirvish-mouse--sync-drag-range
             order base-keys anchor hover rect-p last-keys-cell last-hover-cell nil)
            (when hover
              (enhanced-dirvish-goto-file hover)))))
      (or dir 0))))

(defun enhanced-dirvish-mouse--stop-timer-field (st field)
  "Cancel timer stored in ST under FIELD and clear it."
  (let ((tm (plist-get st field)))
    (when (timerp tm)
      (cancel-timer tm))
    (plist-put st field nil)))

(defun enhanced-dirvish-mouse--hide-drag-feedback (st)
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

(defun enhanced-dirvish-mouse--drag-feedback-text (files action destination)
  "Describe FILES, ACTION and DESTINATION for the floating drag badge.
Use only the cached filenames; do not probe files while handling motion."
  (let ((count (length files)))
    (concat
     (propertize (format "%d item%s — %s" count (if (= count 1) "" "s") action)
                 'face 'bold)
     "\n"
     (mapconcat
      (lambda (path)
        (concat (enhanced-dirvish-icon-glyph 'file nil "▤") "  "
                (truncate-string-to-width
                 (replace-regexp-in-string "[\n\r\t]" " "
                                           (file-name-nondirectory (directory-file-name path)))
                 42 nil nil "…")))
      (cl-subseq files 0 (min 3 count)) "\n")
     (when (> count 3) (format "\n… and %d more" (- count 3)))
     "\n" (truncate-string-to-width destination 52 nil nil "…"))))

(defun enhanced-dirvish-mouse--show-drag-feedback (st event files drop-dir)
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
                              "Drag to a folder, another pane or Places"
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
                           (enhanced-dirvish-mouse--drag-feedback-text files action destination)))
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
           (enhanced-dirvish-mouse--hide-drag-feedback st)
           (plist-put st :feedback-disabled-p t)))))))

(defun enhanced-dirvish-mouse--restore-drag-vars (st)
  "Restore global mouse tracking and scrolling variables captured in ST."
  (when (and st (not (plist-get st :restored-p)))
    (enhanced-dirvish-mouse--hide-drag-feedback st)
    (plist-put st :restored-p t)
    (when (plist-member st :saved-fine-tracking)
      (setq mouse-fine-grained-tracking (plist-get st :saved-fine-tracking)))
    (setq track-mouse (plist-get st :saved-track)
          auto-hscroll-mode (plist-get st :saved-hscroll)
          scroll-margin (plist-get st :saved-margin))))

(defun enhanced-dirvish-mouse--abort-drag (st)
  "Release all tracking for failed ST and suppress its pending mouse release."
  (when st
    (dolist (field '(:scroll-timer :cleanup-timer :watchdog-timer))
      (enhanced-dirvish-mouse--stop-timer-field st field))
    (plist-put st :cancelled-p t)
    (enhanced-dirvish-mouse--restore-drag-vars st)
    (unwind-protect
        (when-let ((exit-fn (plist-get st :exit-fn))) (funcall exit-fn))
      (setq enhanced-dirvish-mouse--drag-state nil
            enhanced-dirvish-mouse--finished-drag-state st))))

(defun enhanced-dirvish-mouse--scroll-tick (st)
  "Advance auto-scroll selection by one tick for active drag state ST."
  (condition-case err
      (enhanced-dirvish-mouse--scroll-tick-1 st)
    ((error quit)
     (enhanced-dirvish-mouse--abort-drag st)
     (message "Drag selection cancelled: %s" (error-message-string err)))))

(defun enhanced-dirvish-mouse--scroll-tick-1 (st)
  "Process one auto-scroll tick for ST without leaving failed timers active."
  (if (not (eq st enhanced-dirvish-mouse--drag-state))
      (enhanced-dirvish-mouse--stop-timer-field st :scroll-timer)
    (let ((src-win (plist-get st :src-win))
          (src-buf (plist-get st :src-buf)))
      (if (or (not (window-live-p src-win))
              (not (buffer-live-p src-buf))
              (not (eq (window-buffer src-win) src-buf))
              (plist-get st :carry-marked-p))
          (enhanced-dirvish-mouse--stop-timer-field st :scroll-timer)
        (let* ((enhanced-dirvish-mouse--inhibit-preview t)
               (old-start (window-start src-win))
               (mp (cdr (mouse-position)))
               (dir (enhanced-dirvish-mouse--edge-scroll-step
                     src-win (car-safe mp) (cdr-safe mp)
                     (plist-get st :order) (plist-get st :base-keys)
                     (plist-get st :anchor) (plist-get st :rect-p)
                     (plist-get st :last-keys-cell) (plist-get st :last-hover-cell))))
          (when (or (null dir) (zerop dir)
                    (= old-start (window-start src-win)))
            (enhanced-dirvish-mouse--stop-timer-field st :scroll-timer)))))))

(defun enhanced-dirvish-mouse--update-scroll-timer (st)
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
          (plist-put st :scroll-timer (run-at-time 0.12 0.12 #'enhanced-dirvish-mouse--scroll-tick st)))
      (enhanced-dirvish-mouse--stop-timer-field st :scroll-timer))))

(defun enhanced-dirvish-mouse--cleanup-abandoned-drag (st)
  "Finalize drag ST on idle if no button-1 release command consumed it."
  (when (eq enhanced-dirvish-mouse--finished-drag-state st)
    (setq enhanced-dirvish-mouse--finished-drag-state nil)
    (enhanced-dirvish-mouse--stop-timer-field st :cleanup-timer)
    (let ((src-win (plist-get st :src-win))
          (src-buf (plist-get st :src-buf)))
      (when (and (not (plist-get st :cancelled-p))
                 (plist-get st :dragged-p)
                 (window-live-p src-win)
                 (buffer-live-p src-buf)
                 (eq (window-buffer src-win) src-buf))
        (with-selected-window src-win
          (let ((enhanced-dirvish-mouse--inhibit-preview t)
                (anchor (plist-get st :anchor))
                (hover (car (plist-get st :last-hover-cell))))
            (when (and anchor hover (not (plist-get st :carry-marked-p)))
              (setq-local enhanced-dirvish--selection-anchor-entry anchor)
              (enhanced-dirvish-mouse--sync-drag-range
               (plist-get st :order) (plist-get st :base-keys) anchor hover
               (plist-get st :rect-p) (plist-get st :last-keys-cell)
               (plist-get st :last-hover-cell) t)))
          (enhanced-dirvish-view--sync-preview-on-move))))))

(defun enhanced-dirvish-mouse--on-drag-exit ()
  "Tear down active transient drag state and hand off to button-1 release."
  (let ((st enhanced-dirvish-mouse--drag-state))
    (when st
      (enhanced-dirvish-mouse--stop-timer-field st :scroll-timer)
      (enhanced-dirvish-mouse--stop-timer-field st :watchdog-timer)
      (enhanced-dirvish-mouse--restore-drag-vars st)
      (setq enhanced-dirvish-mouse--drag-state nil
            enhanced-dirvish-mouse--finished-drag-state st)
      (unless (plist-get st :cancelled-p)
        (enhanced-dirvish-mouse--stop-timer-field st :cleanup-timer)
        (plist-put st :cleanup-timer
                   (run-at-time 0 nil #'enhanced-dirvish-mouse--cleanup-abandoned-drag st))))))

(defun enhanced-dirvish-mouse--take-finished-drag (&optional start-posn)
  "Consume and return completed drag state matching START-POSN, if any."
  (let ((st enhanced-dirvish-mouse--finished-drag-state)
        (win (and (consp start-posn) (posn-window start-posn))))
    (when (and st (or (null win) (eq win (plist-get st :src-win))))
      (enhanced-dirvish-mouse--stop-timer-field st :cleanup-timer)
      (setq enhanced-dirvish-mouse--finished-drag-state nil)
      st)))

(defun enhanced-dirvish-mouse--drag-keep-p ()
  "Keep transient drag keymap active only for movement and cancel commands."
  (memq this-command '(enhanced-dirvish-mouse--drag-move enhanced-dirvish-mouse--drag-cancel ignore)))

(defun enhanced-dirvish-mouse--drag-keymap ()
  "Build transient keymap handling live mouse motion, cancel, and area releases."
  (let ((bindings '(([mouse-movement] . enhanced-dirvish-mouse--drag-move)
                    ([C-mouse-movement] . enhanced-dirvish-mouse--drag-move)
                    ([S-mouse-movement] . enhanced-dirvish-mouse--drag-move)
                    ([C-S-mouse-movement] . enhanced-dirvish-mouse--drag-move)
                    ([M-mouse-movement] . enhanced-dirvish-mouse--drag-move)
                    ([escape] . enhanced-dirvish-mouse--drag-cancel)
                    ([7] . enhanced-dirvish-mouse--drag-cancel)
                    ([down-mouse-3] . enhanced-dirvish-mouse--drag-cancel)
                    ([mouse-3] . enhanced-dirvish-mouse--drag-cancel)
                    ([drag-mouse-3] . enhanced-dirvish-mouse--drag-cancel)
                    ([switch-frame] . enhanced-dirvish-mouse--drag-cancel)
                    ([select-window] . enhanced-dirvish-mouse--drag-cancel)
                    ([scroll-bar-movement] . ignore)))
        (area-releases '(([drag-mouse-1] . enhanced-dirvish-mouse-drag-drop)
                         ([C-drag-mouse-1] . enhanced-dirvish-mouse-drag-copy)
                         ([S-drag-mouse-1] . enhanced-dirvish-mouse-drag-move)
                         ([C-S-drag-mouse-1] . enhanced-dirvish-mouse-drag-drop)
                         ([double-drag-mouse-1] . enhanced-dirvish-mouse-drag-drop)
                         ([mouse-1] . enhanced-dirvish-mouse-click-entry)
                         ([C-mouse-1] . enhanced-dirvish-mouse-toggle-select)
                         ([C-S-mouse-1] . enhanced-dirvish-mouse-add-range-select)
                         ([S-mouse-1] . enhanced-dirvish-mouse-range-select)))
        (map (make-sparse-keymap)))
    (dolist (pair bindings)
      (define-key map (car pair) (cdr pair)))
    (define-key map [escape] #'enhanced-dirvish-mouse--drag-cancel)
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

(defun enhanced-dirvish-mouse--drag-cancel (&optional ev)
  "Cancel active drag selection and restore original marks cleanly."
  (interactive (list (and (mouse-event-p last-input-event) last-input-event)))
  (let ((st (or enhanced-dirvish-mouse--drag-state enhanced-dirvish-mouse--finished-drag-state)))
    (when st
      (enhanced-dirvish-mouse--stop-timer-field st :scroll-timer)
      (enhanced-dirvish-mouse--stop-timer-field st :cleanup-timer)
      (enhanced-dirvish-mouse--stop-timer-field st :watchdog-timer)
      (plist-put st :cancelled-p t)
      ;; Release global tracking and the transient map even if refreshing
      ;; the old selection signals an error or quit.
      (enhanced-dirvish-mouse--restore-drag-vars st)
      (when-let ((exit-fn (plist-get st :exit-fn))) (funcall exit-fn))
      (when (and ev (memq (event-basic-type ev) '(mouse-3 down-mouse-3 drag-mouse-3)))
        (setq enhanced-dirvish-mouse--suppress-mouse-3-once t))
      (let ((src-win (plist-get st :src-win))
            (src-buf (plist-get st :src-buf))
            (pre-keys (plist-get st :pre-keys))
            (last-keys-cell (plist-get st :last-keys-cell)))
        (when (and (window-live-p src-win)
                   (buffer-live-p src-buf)
                   (eq (window-buffer src-win) src-buf)
                   (not (equal (car last-keys-cell) pre-keys)))
          (with-selected-window src-win
            (let ((enhanced-dirvish-mouse--inhibit-preview t))
              (enhanced-dirvish-mouse--apply-selection-keys (plist-get st :order) pre-keys t)))))
      (setq enhanced-dirvish-mouse--drag-state nil
            enhanced-dirvish-mouse--finished-drag-state st)
      (message "Drag selection cancelled"))))

(defun enhanced-dirvish-mouse--drag-watchdog (st)
  "Release abandoned drag ST after five idle seconds without mouse input."
  (when (eq st enhanced-dirvish-mouse--drag-state)
    (enhanced-dirvish-mouse--drag-cancel nil)))

(defun enhanced-dirvish-mouse--drag-move (ev)
  "Update live drag highlight or cross-pane drop cue for motion event EV."
  (interactive "e")
  ;; Never drain input here.  GTK may report pending input while read-event
  ;; returns nil, causing an infinite busy loop; consuming events here also
  ;; steals releases and C-g from Emacs's native command loop.
  (condition-case err
      (enhanced-dirvish-mouse--drag-move-1 ev)
    ((error quit)
     (enhanced-dirvish-mouse--abort-drag enhanced-dirvish-mouse--drag-state)
     (signal (car err) (cdr err)))))

(defun enhanced-dirvish-mouse--drag-move-1 (ev)
  "Update one motion event EV without reading or waiting for further input."
  (let* ((st enhanced-dirvish-mouse--drag-state)
         (src-win (plist-get st :src-win))
         (src-buf (plist-get st :src-buf)))
    (when st
      (if (not (and (window-live-p src-win)
                    (buffer-live-p src-buf)
                    (eq (window-buffer src-win) src-buf)))
          (enhanced-dirvish-mouse--drag-cancel nil)
        (with-selected-window src-win
          (let* ((enhanced-dirvish-mouse--inhibit-preview t)
                 (end (event-end ev))
                 (dst-win (posn-window end))
                 (cur (when (eq dst-win src-win)
                        (enhanced-dirvish-mouse--entry-at-posn end t)))
                 (exact-start (plist-get st :exact-start))
                 (order (plist-get st :order))
                 (pre-marked (plist-get st :pre-marked))
                 (pre-keys (plist-get st :pre-keys))
                 (last-keys-cell (plist-get st :last-keys-cell))
                 (last-hover-cell (plist-get st :last-hover-cell))
                 (carry-marked-p (plist-get st :carry-marked-p))
                 (drop-marked (if exact-start pre-marked (enhanced-dirvish-marked-files-only))))
            (unless (plist-get st :dragged-p)
              (when (enhanced-dirvish-mouse--drag-exceeded-p
                     (plist-get st :start-xy) (posn-x-y end)
                     src-win dst-win exact-start cur)
                (plist-put st :dragged-p t)))
            (when (plist-get st :dragged-p)
              (let ((drop-dir (enhanced-dirvish-mouse--drop-dir
                               src-win dst-win end exact-start drop-marked)))
                (cond
                 (drop-dir
                  (enhanced-dirvish-mouse--stop-timer-field st :scroll-timer)
                  (when (and carry-marked-p (not (equal (car last-keys-cell) pre-keys)))
                    (setcar last-keys-cell pre-keys)
                    (enhanced-dirvish-mouse--apply-selection-keys order pre-keys nil))
                  (let ((n (length (enhanced-dirvish-mouse--drag-files exact-start drop-marked))))
                    (message "Drop %d item(s) into %s to copy/move"
                             n (abbreviate-file-name drop-dir))))
                 ((or (eq dst-win src-win) (null dst-win))
                  (when (and cur (eq dst-win src-win) (not carry-marked-p))
                    (enhanced-dirvish-mouse--sync-drag-range
                     order (plist-get st :base-keys) (plist-get st :anchor) cur
                     (plist-get st :rect-p) last-keys-cell last-hover-cell nil))
                  (enhanced-dirvish-mouse--update-scroll-timer st))
                 (t
                  (enhanced-dirvish-mouse--stop-timer-field st :scroll-timer)))
                (if (or carry-marked-p drop-dir)
                    (enhanced-dirvish-mouse--show-drag-feedback
                     st ev (enhanced-dirvish-mouse--drag-files exact-start drop-marked)
                     drop-dir)
                  (enhanced-dirvish-mouse--hide-drag-feedback st))))))))))

(defun enhanced-dirvish-mouse-down-entry (event)
  "Start native live drag-selection tracking on button-1 press in a pane."
  (interactive "e")
  (setq enhanced-dirvish-mouse--suppress-mouse-3-once nil)
  (when enhanced-dirvish-mouse--drag-state
    (if-let ((exit-fn (plist-get enhanced-dirvish-mouse--drag-state :exit-fn)))
        (funcall exit-fn)
      (enhanced-dirvish-mouse--on-drag-exit)))
  (when enhanced-dirvish-mouse--finished-drag-state
    (enhanced-dirvish-mouse--stop-timer-field enhanced-dirvish-mouse--finished-drag-state :cleanup-timer)
    (setq enhanced-dirvish-mouse--finished-drag-state nil))
  (let* ((start (event-start event))
         (src-win (posn-window start)))
    (unless (or (posn-area start)
                (not (window-live-p src-win))
                (not (with-current-buffer (window-buffer src-win)
                       (derived-mode-p 'dired-mode 'enhanced-dirvish-compact-mode 'enhanced-dirvish-icons-mode))))
      (select-window src-win)
      (when (fboundp 'enhanced-dirvish-panes--sync-active-pane-from-window)
        (enhanced-dirvish-panes--sync-active-pane-from-window src-win))
      (let* ((mods (event-modifiers event))
             (ctrl-p (memq 'control mods))
             (shift-p (memq 'shift mods))
             (start-xy (posn-x-y start))
             (order (enhanced-dirvish-view--entry-order))
             (exact-start (enhanced-dirvish-mouse--entry-at-posn start nil))
             (near-start (or exact-start (enhanced-dirvish-mouse--entry-at-posn start t)))
             (pre-marked (enhanced-dirvish-marked-files-only))
             (pre-keys (mapcar #'enhanced-dirvish--path-key pre-marked))
             (started-on-marked-p
              (and exact-start (member (enhanced-dirvish--path-key exact-start) pre-keys)))
             (carry-marked-p
              (and started-on-marked-p
                   (not ctrl-p)))
             (rect-p (derived-mode-p 'enhanced-dirvish-compact-mode 'enhanced-dirvish-icons-mode))
             (anchor (if shift-p
                         (or enhanced-dirvish--selection-anchor-entry near-start)
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
            (setq enhanced-dirvish-mouse--drag-state st
                  auto-hscroll-mode nil
                  scroll-margin 0
                  track-mouse 'drag-tracking)
            (plist-put st :exit-fn
                       (set-transient-map
                        (enhanced-dirvish-mouse--drag-keymap)
                        #'enhanced-dirvish-mouse--drag-keep-p
                        #'enhanced-dirvish-mouse--on-drag-exit))
            (plist-put st :watchdog-timer
                       (run-with-idle-timer 5 nil #'enhanced-dirvish-mouse--drag-watchdog st))))))))

(defun enhanced-dirvish-mouse--suppress-dir-double-click-p (event)
  "Return non-nil if EVENT is the trailing double-click after entering a folder."
  (when-let ((info enhanced-dirvish-mouse--recent-dir-open))
    (let* ((end (event-end event))
           (win (or (and (consp end) (posn-window end)) (selected-window)))
           (ts (or (and (consp end) (posn-timestamp end)) 0))
           (wall (float-time))
           (limit-ms (if (and (numberp double-click-time) (> double-click-time 0))
                         double-click-time
                       500))
           (old-ts (plist-get info :ts))
           (ts-ok (if (and (> ts 0) (> old-ts 0))
                      (<= (- ts old-ts) limit-ms)
                    (<= (- wall (plist-get info :wall))
                        (/ (float limit-ms) 1000.0)))))
      (and (eq win (plist-get info :window)) ts-ok))))

(defun enhanced-dirvish-mouse--run-click-action (event)
  "Execute single click for EVENT: open clicked dir, preview file, or clear."
  ;; Resolve the actual hit before mouse-set-point can clamp empty space
  ;; below the listing onto its final row.  Nearest-entry lookup is for
  ;; sweeping a drag range, never for an ordinary click.
  (let* ((end (event-end event))
         (compact-position (enhanced-dirvish-mouse--compact-position end))
         (p (enhanced-dirvish-mouse--entry-at-posn end)))
    (enhanced-dirvish-mouse--sync-event event)
    (if p
        (progn
          (setq enhanced-dirvish--empty-click-p nil enhanced-dirvish--empty-click-position nil)
          (enhanced-dirvish-clear-all-marks)
          (enhanced-dirvish-view--reset-selection-range p)
          (if (file-directory-p p)
              (progn
                (setq enhanced-dirvish-mouse--recent-dir-open
                      (list :window (selected-window)
                            :ts (or (and (consp end) (posn-timestamp end)) 0)
                            :wall (float-time)))
                (enhanced-dirvish-mouse--open-path p t))
            (setq enhanced-dirvish-mouse--recent-dir-open nil)
            (when (derived-mode-p 'enhanced-dirvish-icons-mode)
              (enhanced-dirvish-goto-file p))
            (enhanced-dirvish-view--sync-preview-on-move)))
      (setq enhanced-dirvish-mouse--recent-dir-open nil)
      (enhanced-dirvish-clear-all-marks)
      (enhanced-dirvish-mouse--clear-focus compact-position))))

(defun enhanced-dirvish-mouse--run-toggle-action (event)
  "Execute control-click for EVENT: toggle mark on clicked entry."
  (enhanced-dirvish-mouse--sync-event event)
  (when-let ((p (enhanced-dirvish-mouse--entry-at-point)))
    (let* ((key (enhanced-dirvish--path-key p))
           (marked (cl-some (lambda (e) (equal (enhanced-dirvish--path-key e) key))
                            (enhanced-dirvish-marked-files-only))))
      (enhanced-dirvish-view--reset-selection-range p)
      (enhanced-dirvish-view--set-entry-mark p (not marked) nil))))

(defun enhanced-dirvish-mouse--run-range-action (event &optional additive)
  "Execute shift-click for EVENT: select contiguous range from anchor."
  (let* ((ev-win (or (posn-window (event-start event)) (selected-window)))
         (prev-anchor (when (window-live-p ev-win)
                        (with-current-buffer (window-buffer ev-win)
                          (or enhanced-dirvish--selection-anchor-entry
                              (enhanced-dirvish-current-file))))))
    (enhanced-dirvish-mouse--sync-event event)
    (when-let ((target (enhanced-dirvish-mouse--entry-at-point)))
      (let ((anchor (or prev-anchor target)))
        (enhanced-dirvish-view--mark-range anchor target additive)))))

(defun enhanced-dirvish-mouse--run-activate-action (event)
  "Execute activation click for EVENT: open directory or edit file."
  (if (and (memq 'double (event-modifiers event))
           (enhanced-dirvish-mouse--suppress-dir-double-click-p event))
      (setq enhanced-dirvish-mouse--recent-dir-open nil)
    (setq enhanced-dirvish-mouse--recent-dir-open nil)
    (enhanced-dirvish-mouse--sync-event event)
    (when-let ((p (enhanced-dirvish-mouse--entry-at-point)))
      (enhanced-dirvish-mouse--open-path p nil))))

(defun enhanced-dirvish-mouse--finish-drag (st event &optional forced-mode)
  "Finalize drag ST on release EVENT, performing selection, drop, or click."
  (unless (plist-get st :cancelled-p)
    (let* ((src-win (plist-get st :src-win))
           (src-buf (plist-get st :src-buf))
           (end (event-end event))
           (dst-win (or (posn-window end) src-win))
           (end-mods (event-modifiers event))
           (cur (when (and (window-live-p src-win) (eq dst-win src-win))
                  (enhanced-dirvish-mouse--entry-at-posn end t))))
      (when (and (window-live-p src-win)
                 (buffer-live-p src-buf)
                 (eq (window-buffer src-win) src-buf))
        (unless (plist-get st :dragged-p)
          (when (enhanced-dirvish-mouse--drag-exceeded-p
                 (plist-get st :start-xy) (posn-x-y end)
                 src-win dst-win (plist-get st :exact-start) cur)
            (plist-put st :dragged-p t)))
        (if (not (plist-get st :dragged-p))
            (cond
             ((memq 'double end-mods) (enhanced-dirvish-mouse--run-activate-action event))
             ((and (or (memq 'control end-mods) (plist-get st :ctrl-p))
                   (or (memq 'shift end-mods) (plist-get st :shift-p)))
              (enhanced-dirvish-mouse--run-range-action event t))
             ((or (memq 'control end-mods) (plist-get st :ctrl-p))
              (enhanced-dirvish-mouse--run-toggle-action event))
             ((or (memq 'shift end-mods) (plist-get st :shift-p))
              (enhanced-dirvish-mouse--run-range-action event))
             (t (enhanced-dirvish-mouse--run-click-action event)))
          (select-window src-win)
          (when (fboundp 'enhanced-dirvish-panes--sync-active-pane-from-window)
            (enhanced-dirvish-panes--sync-active-pane-from-window src-win))
          (let* ((drop-marked (if (plist-get st :exact-start)
                                  (plist-get st :pre-marked)
                                (enhanced-dirvish-marked-files-only)))
                 (drop-dir (enhanced-dirvish-mouse--drop-dir
                            src-win dst-win end (plist-get st :exact-start)
                            drop-marked))
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
                    (enhanced-dirvish-mouse--apply-selection-keys (plist-get st :order) pre-keys nil))
                  (enhanced-dirvish-mouse--drag-drop-now
                   src-win dst-win (plist-get st :start) end
                   (plist-get st :exact-start)
                   drop-marked
                   effective-mode))
              (let ((anchor (plist-get st :anchor))
                    (hover (or cur (car (plist-get st :last-hover-cell)))))
                (when (and anchor hover (not carry-marked-p))
                  (setq-local enhanced-dirvish--selection-anchor-entry anchor)
                  (enhanced-dirvish-mouse--sync-drag-range
                   (plist-get st :order) (plist-get st :base-keys) anchor hover
                   (plist-get st :rect-p) (plist-get st :last-keys-cell)
                   (plist-get st :last-hover-cell) t)
                  (enhanced-dirvish-goto-file hover)
                  (message "Selected %d item(s)" (length (enhanced-dirvish-marked-files-only))))
                (enhanced-dirvish-view--sync-preview-on-move)))))))))

(defun enhanced-dirvish-mouse-toggle-select (event)
  "Toggle multi-selection mark on clicked entry (`C-<mouse-1>')."
  (interactive "e")
  (if-let ((st (enhanced-dirvish-mouse--take-finished-drag (event-start event))))
      (enhanced-dirvish-mouse--finish-drag st event)
    (enhanced-dirvish-mouse--run-toggle-action event)))

(defun enhanced-dirvish-mouse-range-select (event)
  "Select contiguous range of entries from anchor to EVENT (`S-<mouse-1>')."
  (interactive "e")
  (if-let ((st (enhanced-dirvish-mouse--take-finished-drag (event-start event))))
      (enhanced-dirvish-mouse--finish-drag st event)
    (enhanced-dirvish-mouse--run-range-action event)))

(defun enhanced-dirvish-mouse-add-range-select (event)
  "Add the range to EVENT to the current selection (`C-S-<mouse-1>')."
  (interactive "e")
  (if-let ((st (enhanced-dirvish-mouse--take-finished-drag (event-start event))))
      (enhanced-dirvish-mouse--finish-drag st event)
    (enhanced-dirvish-mouse--run-range-action event t)))

(defun enhanced-dirvish-mouse--drag-target-dir (dst-win end-posn &optional folder-only)
  "Resolve a drop folder in DST-WIN at END-POSN.
FOLDER-ONLY requires an actual folder entry rather than the pane background."
  (when (window-live-p dst-win)
    (cond
     ((eq dst-win (bound-and-true-p enhanced-dirvish-sidebar-window))
      (with-current-buffer (window-buffer dst-win)
        (let* ((pt (or (and (integerp (posn-point end-posn)) (posn-point end-posn))
                       (point)))
               (loc (or (get-text-property pt 'enhanced-dirvish-sidebar-loc)
                        (save-excursion
                          (goto-char (min pt (point-max)))
                          (get-text-property (line-beginning-position) 'enhanced-dirvish-sidebar-loc)))))
          (when (and (stringp loc) (file-directory-p loc))
            loc))))
     ((and (fboundp 'enhanced-dirvish-panes--valid-main-window-p)
           (enhanced-dirvish-panes--valid-main-window-p dst-win)
           (fboundp 'enhanced-dirvish-panes--window-dir))
      (let ((entry (enhanced-dirvish-mouse--entry-at-posn end-posn)))
        (if (and entry (file-directory-p entry))
            entry
          (unless folder-only (enhanced-dirvish-panes--window-dir dst-win))))))))

(defun enhanced-dirvish-mouse--drop-dir (src-win dst-win end entry marked)
  "Resolve END as a folder drop for the original ENTRY/MARKED payload.
Inside the source pane, blank-space drags keep selecting and a selected
folder cannot itself become the drop target."
  (let* ((same-pane (eq src-win dst-win))
         (files (enhanced-dirvish-mouse--drag-files entry marked))
         (dir (and (or (not same-pane) entry)
                   (enhanced-dirvish-mouse--drag-target-dir dst-win end same-pane))))
    (when (and dir
               (not (member (enhanced-dirvish--path-key dir)
                            (mapcar #'enhanced-dirvish--path-key files))))
      dir)))

(defun enhanced-dirvish-mouse--drag-drop-now (src-win dst-win _start end src-entry marked &optional forced-mode)
  "Copy or move MARKED/SRC-ENTRY dragged from SRC-WIN into DST-WIN."
  (let* ((files (enhanced-dirvish-mouse--drag-files src-entry marked))
         (dest-dir (enhanced-dirvish-mouse--drop-dir src-win dst-win end src-entry marked))
         (src-dir (and (fboundp 'enhanced-dirvish-panes--window-dir)
                       (enhanced-dirvish-panes--window-dir src-win))))
    (unless files
      (user-error "No file or folder selected to drag"))
    (unless (and dest-dir (file-directory-p dest-dir))
      (user-error "Drop onto a folder, another pane or a Places directory"))
    (when (and src-dir
               (equal (file-truename src-dir) (file-truename dest-dir)))
      (user-error "Source and destination folders are identical"))
    ;; Check the whole batch before transferring any item.
    (dolist (file files) (enhanced-dirvish--guard-not-self-contained file dest-dir))
    (let* ((mode (or forced-mode
                    (if (enhanced-dirvish-ui-mouse-p)
                        (enhanced-dirvish-ui-choice
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
          (enhanced-dirvish--transfer-files files dest-dir mode)
          (when (eq mode 'cut)
            (when (derived-mode-p 'dired-mode)
              (dired-unmark-all-marks))
            (when (boundp 'enhanced-dirvish-marked-entries)
              (setq enhanced-dirvish-marked-entries nil))
            (enhanced-dirvish-view--refresh-after-mark)))))))

(defun enhanced-dirvish-mouse-drag-drop (event &optional forced-mode)
  "Drag to select files, or drop files onto a folder or pane to copy/move."
  (interactive "e")
  (if-let ((st (enhanced-dirvish-mouse--take-finished-drag (event-start event))))
      (enhanced-dirvish-mouse--finish-drag st event forced-mode)
    (let* ((start (event-start event))
           (end (event-end event))
           (src-win (posn-window start))
           (dst-win (or (posn-window end) src-win)))
      (when (window-live-p src-win)
        (select-window src-win)
        (when (fboundp 'enhanced-dirvish-panes--sync-active-pane-from-window)
          (enhanced-dirvish-panes--sync-active-pane-from-window src-win))
        (let* ((src-entry (enhanced-dirvish-mouse--entry-at-posn start t))
               (marked (enhanced-dirvish-marked-files-only)))
          (cond
           ((enhanced-dirvish-mouse--drop-dir src-win dst-win end src-entry marked)
            (enhanced-dirvish-mouse--drag-drop-now
             src-win dst-win start end src-entry marked
             (or forced-mode
                 (cond ((memq 'control (event-modifiers event)) 'copy)
                       ((memq 'shift (event-modifiers event)) 'cut)))))
           ((eq src-win dst-win)
            (let ((end-entry (enhanced-dirvish-mouse--entry-at-posn end t)))
              (cond
               ((and src-entry end-entry
                     (not (equal (enhanced-dirvish--path-key src-entry)
                                 (enhanced-dirvish--path-key end-entry))))
                (let* ((order (enhanced-dirvish-view--entry-order))
                       (rect-p (derived-mode-p 'enhanced-dirvish-compact-mode 'enhanced-dirvish-icons-mode))
                       (mods (event-modifiers event))
                       (base-keys (when (or (memq 'control mods) (memq 'shift mods))
                                    (mapcar #'enhanced-dirvish--path-key marked)))
                       (range (enhanced-dirvish-mouse--range-entries order src-entry end-entry rect-p))
                       (keys (delete-dups (append (copy-sequence base-keys)
                                                  (mapcar #'enhanced-dirvish--path-key range)))))
                  (setq-local enhanced-dirvish--selection-anchor-entry src-entry)
                  (enhanced-dirvish-mouse--apply-selection-keys order keys t)
                  (enhanced-dirvish-goto-file end-entry)))
               (src-entry
                (setq-local enhanced-dirvish--selection-anchor-entry src-entry)
                (if (file-directory-p src-entry)
                    (enhanced-dirvish-mouse--open-path src-entry t)
                  (when (derived-mode-p 'enhanced-dirvish-icons-mode)
                    (enhanced-dirvish-goto-file src-entry))
                  (enhanced-dirvish-view--sync-preview-on-move))))))
           (t
            (enhanced-dirvish-mouse--drag-drop-now
             src-win dst-win start end src-entry marked
             (or forced-mode
                 (cond ((memq 'control (event-modifiers event)) 'copy)
                       ((memq 'shift (event-modifiers event)) 'cut)))))))))))

(defun enhanced-dirvish-mouse-drag-copy (event)
  "Drag files into a folder or pane and copy (`C-<drag-mouse-1>')."
  (interactive "e")
  (enhanced-dirvish-mouse-drag-drop event 'copy))

(defun enhanced-dirvish-mouse-drag-move (event)
  "Drag files into a folder or pane and move (`S-<drag-mouse-1>')."
  (interactive "e")
  (enhanced-dirvish-mouse-drag-drop event 'cut))

(defun enhanced-dirvish-mouse-click-entry (event)
  "Handle single `<mouse-1>' click: open clicked directory or preview file."
  (interactive "e")
  (if-let ((st (enhanced-dirvish-mouse--take-finished-drag (event-start event))))
      (enhanced-dirvish-mouse--finish-drag st event)
    (enhanced-dirvish-mouse--run-click-action event)))

(defun enhanced-dirvish-mouse-activate-at-event (event)
  "Handle `<mouse-2>' or `<double-mouse-1>' click: open directory or file."
  (interactive "e")
  (if-let ((st (and (not (eq (event-basic-type event) 'mouse-2))
                    (enhanced-dirvish-mouse--take-finished-drag (event-start event)))))
      (enhanced-dirvish-mouse--finish-drag st event)
    (enhanced-dirvish-mouse--run-activate-action event)))

(defun enhanced-dirvish-view-activate-at-point ()
  "Open directory in browser pane or edit file in preview pane."
  (interactive)
  (if (fboundp 'enhanced-dirvish-open-or-edit-at-point)
      (enhanced-dirvish-open-or-edit-at-point)
    (when-let ((f (enhanced-dirvish-current-file)))
      (if (file-directory-p f)
          (enhanced-dirvish-open-location f)
        (find-file f)))))

(defun enhanced-dirvish-view-up-directory ()
  "Navigate to parent directory from Compact or Icons view."
  (interactive)
  (let ((parent (file-name-directory (directory-file-name default-directory))))
    (when parent (enhanced-dirvish-open-location parent))))

;;;; View Mode Switcher & Appearance Toggles

(defun enhanced-dirvish-view--menu ()
  "Build the clickable layout menu with the current view checked."
  (easy-menu-create-menu
   "View…"
   '(["Columns" (enhanced-dirvish-view-menu-select 'columns)
      :style radio :selected (eq (enhanced-dirvish-view-current-mode) 'columns)]
     ["Icons" (enhanced-dirvish-view-menu-select 'icons)
      :style radio :selected (eq (enhanced-dirvish-view-current-mode) 'icons)]
     ["List / Tree" (enhanced-dirvish-view-menu-select 'list)
      :style radio :selected (eq (enhanced-dirvish-view-current-mode) 'list)]
     ["Compact" (enhanced-dirvish-view-menu-select 'compact)
      :style radio :selected (eq (enhanced-dirvish-view-current-mode) 'compact)])))

(defun enhanced-dirvish-view-menu (&optional event)
  "Show the clickable View menu for the directory at EVENT."
  (interactive (list (when (mouse-event-p last-input-event) last-input-event)))
  (enhanced-dirvish-header--select-browser event)
  (popup-menu (enhanced-dirvish-view--menu) event))

(defun enhanced-dirvish-view-menu-select (mode)
  "Switch to MODE from the View menu unless it is already displayed."
  (unless (eq (enhanced-dirvish-view-current-mode) mode)
    (enhanced-dirvish-switch-view-mode mode)))

(defun enhanced-dirvish-switch-view-mode (mode)
  "Switch active browser pane to view MODE (`columns', `icons', `list', `compact')."
  (interactive
   (list (intern (enhanced-dirvish-ui-completing-read "View mode: " '("columns" "icons" "list" "compact") nil t))))
  (let* ((p (enhanced-dirvish-prefs))
         (dir (or (bound-and-true-p enhanced-dirvish-view-directory)
                  (dirvish-prop :root)
                  default-directory))
         (cur (enhanced-dirvish-current-file)))
    (setf (enhanced-dirvish-prefs-browser-mode p) mode)
    (enhanced-dirvish-prefs-save)
    (pcase mode
      ('columns
       (when (fboundp 'enhanced-dirvish-preview--close-standalone)
         (enhanced-dirvish-preview--close-standalone))
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
       (when (fboundp 'enhanced-dirvish-sidebar-ensure)
         (enhanced-dirvish-sidebar-ensure))
       (when (derived-mode-p 'dired-mode)
         (dired-hide-details-mode 1)))
      ('list
       (when (fboundp 'enhanced-dirvish-preview--close-standalone)
         (enhanced-dirvish-preview--close-standalone))
       (unless (derived-mode-p 'dired-mode)
         (dirvish dir)
         (set-buffer (window-buffer (selected-window))))
       (when (fboundp 'enhanced-dirvish--flatten-layout)
         (enhanced-dirvish--flatten-layout))
       (set-buffer (window-buffer (selected-window)))
       (when (fboundp 'enhanced-dirvish-sidebar-ensure)
         (enhanced-dirvish-sidebar-ensure))
       (when (derived-mode-p 'dired-mode)
         (dired-hide-details-mode -1)))
      ('compact
       (when (fboundp 'enhanced-dirvish--flatten-layout)
         (enhanced-dirvish--flatten-layout))
       (when (fboundp 'enhanced-dirvish-sidebar-ensure)
         (enhanced-dirvish-sidebar-ensure))
       (let ((buf (enhanced-dirvish-view--buffer "Compact" dir)))
         (switch-to-buffer buf)
         (enhanced-dirvish-compact-mode)
         (setq-local enhanced-dirvish-local-view-mode 'compact)
         (enhanced-dirvish-compact-render dir)))
      ('icons
       (when (fboundp 'enhanced-dirvish--flatten-layout)
         (enhanced-dirvish--flatten-layout))
       (when (fboundp 'enhanced-dirvish-sidebar-ensure)
         (enhanced-dirvish-sidebar-ensure))
       (let ((buf (enhanced-dirvish-view--buffer "Icons" dir)))
         (switch-to-buffer buf)
         (enhanced-dirvish-icons-mode)
         (setq-local enhanced-dirvish-local-view-mode 'icons)
         (enhanced-dirvish-icons-render dir))))
    ;; Set this on the displayed buffer after switching.  Setting it on the
    ;; source buffer leaves stale labels when Dired is reused from another view.
    (setq-local enhanced-dirvish-local-view-mode mode)
    (when (fboundp 'enhanced-dirvish-panes--set-active-view)
      (enhanced-dirvish-panes--set-active-view (current-buffer) (selected-window)))
    (force-mode-line-update t)
    (when cur (enhanced-dirvish-goto-file cur))
    (enhanced-dirvish-folder-view-remember dir p)))

(defun enhanced-dirvish-view-columns () (interactive) (enhanced-dirvish-switch-view-mode 'columns))
(defun enhanced-dirvish-view-icons () (interactive) (enhanced-dirvish-switch-view-mode 'icons))
(defun enhanced-dirvish-view-list () (interactive) (enhanced-dirvish-switch-view-mode 'list))
(defun enhanced-dirvish-view-compact () (interactive) (enhanced-dirvish-switch-view-mode 'compact))

(defun enhanced-dirvish-toggle-hidden-files ()
  "Toggle visibility of hidden dot-files across Enhanced Dirvish views."
  (interactive)
  (let ((p (enhanced-dirvish-prefs)))
    (setf (enhanced-dirvish-prefs-show-hidden p) (not (enhanced-dirvish-prefs-show-hidden p)))
    (enhanced-dirvish-prefs-save)
    (cond ((derived-mode-p 'dired-mode) (enhanced-dirvish-apply-sort-to-dired))
          ((derived-mode-p 'enhanced-dirvish-compact-mode) (enhanced-dirvish-compact-refresh))
          ((derived-mode-p 'enhanced-dirvish-icons-mode) (enhanced-dirvish-icons-refresh)))
    (message "Hidden files %s" (if (enhanced-dirvish-prefs-show-hidden p) "shown" "hidden"))))

(defun enhanced-dirvish-toggle-compact-full-names ()
  "Toggle full filename display vs truncated columns in Compact view."
  (interactive)
  (let ((p (enhanced-dirvish-prefs)))
    (setf (enhanced-dirvish-prefs-compact-full-names p) (not (enhanced-dirvish-prefs-compact-full-names p)))
    (enhanced-dirvish-prefs-save)
    (when (derived-mode-p 'enhanced-dirvish-compact-mode) (enhanced-dirvish-compact-refresh))
    (message "Compact full names %s" (if (enhanced-dirvish-prefs-compact-full-names p) "ON" "OFF"))))

(defun enhanced-dirvish-toggle-expandable-tree ()
  "Toggle expandable folders (`dirvish-subtree') in List view."
  (interactive)
  (let ((p (enhanced-dirvish-prefs)))
    (setf (enhanced-dirvish-prefs-expandable-tree p) (not (enhanced-dirvish-prefs-expandable-tree p)))
    (enhanced-dirvish-prefs-save)
    (message "Expandable folders in List view: %s"
             (if (enhanced-dirvish-prefs-expandable-tree p) "ON" "OFF"))))

(defun enhanced-dirvish-tree-expand-or-open ()
  "Toggle Tree List subtree, move in Icons grid, or read preview (`<right>')."
  (interactive)
  (let* ((p (enhanced-dirvish-prefs))
         (f (enhanced-dirvish-current-file))
         (plain (or (derived-mode-p 'enhanced-dirvish-icons-mode)
                    (derived-mode-p 'enhanced-dirvish-computer-mode)))
         ;; one check, and on a mount that may hang a subprocess makes it
         (dir-p (and f (not plain) (enhanced-dirvish--directory-p-safe f))))
    (cond
     ((derived-mode-p 'enhanced-dirvish-icons-mode)
      (enhanced-dirvish-icons-next-cell))
     ((derived-mode-p 'enhanced-dirvish-computer-mode)
      (call-interactively #'enhanced-dirvish-computer-open-at-point))
     ((memq dir-p '(unresponsive cancelled))
      (message "%s %s" (abbreviate-file-name f)
               (if (eq dir-p 'cancelled) "-- cancelled" "is not responding -- not opened")))
     ((and (derived-mode-p 'dired-mode)
           (eq (enhanced-dirvish-prefs-browser-mode p) 'list)
           (enhanced-dirvish-prefs-expandable-tree p)
           f
           (eq dir-p t))
      (dirvish-subtree-toggle))
     ((and f (eq dir-p t))
      (if (fboundp 'enhanced-dirvish-open-or-edit-at-point)
          (enhanced-dirvish-open-or-edit-at-point)
        (if (derived-mode-p 'dired-mode)
            (dired-find-file)
          (enhanced-dirvish-open-location f t))))
     (f
      (if (fboundp 'enhanced-dirvish-preview-enter-at-point)
          (enhanced-dirvish-preview-enter-at-point)
        (if (fboundp 'enhanced-dirvish-preview-at-point)
            (enhanced-dirvish-preview-at-point)
          (user-error "Preview unavailable for %s" f))))
     (t
      (user-error "No entry at point")))))

(defun enhanced-dirvish-tree-collapse-or-up ()
  "Move left in Icons grid, collapse subtree in List view, or navigate up."
  (interactive)
  (cond
   ((derived-mode-p 'enhanced-dirvish-icons-mode)
    (enhanced-dirvish-icons-prev-cell))
   ((and (derived-mode-p 'dired-mode)
         (eq (enhanced-dirvish-prefs-browser-mode (enhanced-dirvish-prefs)) 'list)
         (enhanced-dirvish-prefs-expandable-tree (enhanced-dirvish-prefs))
         (dirvish-subtree--expanded-p))
    (dirvish-subtree-remove))
   ((derived-mode-p 'dired-mode)
    (dired-up-directory))
   (t
    (enhanced-dirvish-view-up-directory))))

(defun enhanced-dirvish-sort--menu ()
  "Build the clickable sort menu with current choices marked."
  (easy-menu-create-menu
   "Sort By…"
   '(["Name" (enhanced-dirvish-sort-set 'name (enhanced-dirvish-prefs-sort-direction (enhanced-dirvish-prefs)))
      :style radio :selected (eq (enhanced-dirvish-prefs-sort-key (enhanced-dirvish-prefs)) 'name)]
     ["Modification date" (enhanced-dirvish-sort-set 'modified (enhanced-dirvish-prefs-sort-direction (enhanced-dirvish-prefs)))
      :style radio :selected (eq (enhanced-dirvish-prefs-sort-key (enhanced-dirvish-prefs)) 'modified)]
     ["Size" (enhanced-dirvish-sort-set 'size (enhanced-dirvish-prefs-sort-direction (enhanced-dirvish-prefs)))
      :style radio :selected (eq (enhanced-dirvish-prefs-sort-key (enhanced-dirvish-prefs)) 'size)]
     ["Type / extension" (enhanced-dirvish-sort-set 'extension (enhanced-dirvish-prefs-sort-direction (enhanced-dirvish-prefs)))
      :style radio :selected (eq (enhanced-dirvish-prefs-sort-key (enhanced-dirvish-prefs)) 'extension)]
     ["Unsorted (directory order)" (enhanced-dirvish-sort-set 'unsorted 'asc)
      :style radio :selected (eq (enhanced-dirvish-prefs-sort-key (enhanced-dirvish-prefs)) 'unsorted)]
     "--"
     ["Ascending (A–Z, smallest, oldest)" enhanced-dirvish-sort-ascending
      :style radio :selected (eq (enhanced-dirvish-prefs-sort-direction (enhanced-dirvish-prefs)) 'asc)
      :enable (not (eq (enhanced-dirvish-prefs-sort-key (enhanced-dirvish-prefs)) 'unsorted))]
     ["Descending (Z–A, largest, newest)" enhanced-dirvish-sort-descending
      :style radio :selected (eq (enhanced-dirvish-prefs-sort-direction (enhanced-dirvish-prefs)) 'desc)
      :enable (not (eq (enhanced-dirvish-prefs-sort-key (enhanced-dirvish-prefs)) 'unsorted))]
     "--"
     ["Folders first" enhanced-dirvish-sort-toggle-folders-first
      :style toggle :selected (enhanced-dirvish-prefs-folders-first (enhanced-dirvish-prefs))
      :enable (not (eq (enhanced-dirvish-prefs-sort-key (enhanced-dirvish-prefs)) 'unsorted))]
     ["Natural names (file2 before file10)" enhanced-dirvish-sort-toggle-natural
      :style toggle :selected (enhanced-dirvish-prefs-natural-sort (enhanced-dirvish-prefs))
      :enable (eq (enhanced-dirvish-prefs-sort-key (enhanced-dirvish-prefs)) 'name)])))

(defun enhanced-dirvish-sort-menu (&optional event)
  "Show the clickable Sort By menu for the directory at EVENT."
  (interactive (list (when (mouse-event-p last-input-event) last-input-event)))
  (enhanced-dirvish-header--select-browser event)
  (popup-menu (enhanced-dirvish-sort--menu) event))

(defun enhanced-dirvish-sort-ascending ()
  "Sort the current directory in ascending order."
  (interactive)
  (enhanced-dirvish-sort-set (enhanced-dirvish-prefs-sort-key (enhanced-dirvish-prefs)) 'asc))

(defun enhanced-dirvish-sort-descending ()
  "Sort the current directory in descending order."
  (interactive)
  (enhanced-dirvish-sort-set (enhanced-dirvish-prefs-sort-key (enhanced-dirvish-prefs)) 'desc))

(defun enhanced-dirvish-sort-set (key &optional direction)
  "Sort the active browser by KEY.
KEY is `name', `modified', `size', `type', `extension', `created' or
`unsorted'.
With DIRECTION, set that order explicitly; otherwise selecting the already
active sort key toggles ascending/descending (the 10xer sort chord)."
  (interactive
   (list (intern (enhanced-dirvish-ui-completing-read "Sort by: "
                                  '("name" "modified" "size" "type" "extension" "created" "unsorted")
                                  nil t))))
  (let ((p (enhanced-dirvish-prefs)))
    (if direction
        (setf (enhanced-dirvish-prefs-sort-key p) key
              (enhanced-dirvish-prefs-sort-direction p) direction)
      (if (eq (enhanced-dirvish-prefs-sort-key p) key)
          (setf (enhanced-dirvish-prefs-sort-direction p)
                (if (eq (enhanced-dirvish-prefs-sort-direction p) 'asc) 'desc 'asc))
        (setf (enhanced-dirvish-prefs-sort-key p) key
              (enhanced-dirvish-prefs-sort-direction p) 'asc)))
    (enhanced-dirvish-prefs-save)
    (cond ((derived-mode-p 'dired-mode) (enhanced-dirvish-apply-sort-to-dired))
          ((derived-mode-p 'enhanced-dirvish-compact-mode) (enhanced-dirvish-compact-refresh))
          ((derived-mode-p 'enhanced-dirvish-icons-mode) (enhanced-dirvish-icons-refresh)))
    (force-mode-line-update t)
    (message "Sorted by %s (%s)" key (enhanced-dirvish-prefs-sort-direction p))))

(defun enhanced-dirvish-sort-toggle-folders-first ()
  "Toggle Folders First sorting while keeping sort key and direction."
  (interactive)
  (unless (enhanced-dirvish-location-virtual-p (dirvish-prop :root))
    (let ((p (enhanced-dirvish-prefs)))
      (setf (enhanced-dirvish-prefs-folders-first p) (not (enhanced-dirvish-prefs-folders-first p)))
      (enhanced-dirvish-prefs-save)
      (cond ((derived-mode-p 'dired-mode) (enhanced-dirvish-apply-sort-to-dired))
            ((derived-mode-p 'enhanced-dirvish-compact-mode) (enhanced-dirvish-compact-refresh))
            ((derived-mode-p 'enhanced-dirvish-icons-mode) (enhanced-dirvish-icons-refresh)))
      (message "Folders first: %s" (if (enhanced-dirvish-prefs-folders-first p) "ON" "OFF")))))

(defun enhanced-dirvish-sort-toggle-natural ()
  "Toggle Natural numeric sorting."
  (interactive)
  (let ((p (enhanced-dirvish-prefs)))
    (setf (enhanced-dirvish-prefs-natural-sort p) (not (enhanced-dirvish-prefs-natural-sort p)))
    (enhanced-dirvish-prefs-save)
    (cond ((derived-mode-p 'dired-mode) (enhanced-dirvish-apply-sort-to-dired))
          ((derived-mode-p 'enhanced-dirvish-compact-mode) (enhanced-dirvish-compact-refresh))
          ((derived-mode-p 'enhanced-dirvish-icons-mode) (enhanced-dirvish-icons-refresh)))
    (message "Natural sort: %s" (if (enhanced-dirvish-prefs-natural-sort p) "ON" "OFF"))))

(defun enhanced-dirvish-sort-toggle-direction ()
  "Toggle ascending / descending sort order."
  (interactive)
  (let ((p (enhanced-dirvish-prefs)))
    (setf (enhanced-dirvish-prefs-sort-direction p)
          (if (eq (enhanced-dirvish-prefs-sort-direction p) 'asc) 'desc 'asc))
    (enhanced-dirvish-prefs-save)
    (cond ((derived-mode-p 'dired-mode) (enhanced-dirvish-apply-sort-to-dired))
          ((derived-mode-p 'enhanced-dirvish-compact-mode) (enhanced-dirvish-compact-refresh))
          ((derived-mode-p 'enhanced-dirvish-icons-mode) (enhanced-dirvish-icons-refresh)))))

(defun enhanced-dirvish-toggle-group-by-type ()
  "Toggle Group by Type section grouping."
  (interactive)
  (let ((p (enhanced-dirvish-prefs)))
    (setf (enhanced-dirvish-prefs-group-by-type p) (not (enhanced-dirvish-prefs-group-by-type p)))
    (enhanced-dirvish-prefs-save)
    (when (require 'dirvish-emerge nil t)
      (setq-local dirvish-emerge-groups
                  '(("Folders" (predicate . directories))
                    ("Images" (extensions "png" "jpg" "jpeg" "gif" "webp" "svg" "cr2" "nef" "dng"))
                    ("Audio" (extensions "mp3" "flac" "wav" "ogg" "opus" "m4a" "aac"))
                    ("Video" (extensions "mp4" "mkv" "mov" "webm" "avi" "m4v"))
                    ("Documents" (extensions "pdf" "md" "org" "txt" "docx" "odt" "rtf" "csv" "xlsx"))
                    ("Archives" (extensions "zip" "7z" "tar" "gz" "tgz" "zst" "xz" "iso"))))
      (dirvish-emerge-mode (if (enhanced-dirvish-prefs-group-by-type p) 1 -1)))
    (cond ((derived-mode-p 'enhanced-dirvish-compact-mode) (enhanced-dirvish-compact-refresh))
          ((derived-mode-p 'enhanced-dirvish-icons-mode) (enhanced-dirvish-icons-refresh)))
    (message "Group by type: %s" (if (enhanced-dirvish-prefs-group-by-type p) "ON" "OFF"))))

(defun enhanced-dirvish-thumbnails-scale (&optional delta)
  "Adjust Icons view thumbnail size by DELTA px (0 or nil resets to 64px)."
  (interactive "P")
  (let* ((p (enhanced-dirvish-prefs))
         (step (cond ((null delta) 0)
                     ((numberp delta) delta)
                     (t (prefix-numeric-value delta))))
         (cur (enhanced-dirvish-prefs-icons-thumbnail-size p))
         (next (if (= step 0) 64 (max 32 (min 256 (+ cur step))))))
    (setf (enhanced-dirvish-prefs-icons-thumbnail-size p) next)
    (enhanced-dirvish-prefs-save)
    (when (derived-mode-p 'enhanced-dirvish-icons-mode) (enhanced-dirvish-icons-refresh))
    (message "Icon thumbnail size: %dpx" next)))

(defun enhanced-dirvish-make-first-column ()
  "Alt+Down (`columns'): descend or focus current folder as primary view."
  (interactive)
  (when-let ((f (enhanced-dirvish-current-file)))
    (if (file-directory-p f)
        (enhanced-dirvish-open-location f)
      (enhanced-dirvish-switch-view-mode 'list))))

(provide 'enhanced-dirvish-views)
;;; enhanced-dirvish-views.el ends here
