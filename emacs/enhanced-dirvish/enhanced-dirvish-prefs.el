;;; enhanced-dirvish-prefs.el --- Preferences, TOML sync, and Noctalia theming -*- lexical-binding: t; -*-

;; Copyright (C) 2026 dragonleopardpig
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.  It is part of Enhanced Dirvish;
;; see enhanced-dirvish.el for the full license notice.

;;; Commentary:
;; Core state, preferences, formatting helpers, and theme-reactive faces for
;; Enhanced Dirvish inside Emacs.  Defaults may be seeded from
;; ~/.config/enhanced-dirvish/settings.toml; Emacs overrides persist in
;; `enhanced-dirvish-state-file'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'enhanced-dirvish-ui)

(defgroup enhanced-dirvish nil
  "A full file manager built on Dirvish."
  :group 'dirvish
  :prefix "enhanced-dirvish-")

(defcustom enhanced-dirvish-config-dir
  (expand-file-name "enhanced-dirvish" (or (getenv "XDG_CONFIG_HOME") "~/.config"))
  "XDG directory holding the TOML configuration (settings.toml, actions/)."
  :type 'directory
  :group 'enhanced-dirvish)

(defcustom enhanced-dirvish-state-dir
  (expand-file-name "dirvish/enhanced-dirvish/" user-emacs-directory)
  "Emacs state directory for Enhanced Dirvish persistent data."
  :type 'directory
  :group 'enhanced-dirvish)

(defcustom enhanced-dirvish-state-file
  (expand-file-name "prefs.eld" enhanced-dirvish-state-dir)
  "Persistent Emacs override file for `enhanced-dirvish'."
  :type 'file
  :group 'enhanced-dirvish)

(defcustom enhanced-dirvish-desktop-cua-clipboard nil
  "When non-nil in Default mode, bind `C-c', `C-x', and `C-v' directly.
Left nil by default so Emacs prefix keys (`C-x' and `C-c') keep working
everywhere; copy/cut/paste remain bound cleanly to `C-c c', `C-c x', `C-c v',
`M-w', `C-w', and in 10xer mode to `y', `x', `p'."
  :type 'boolean
  :group 'enhanced-dirvish)

;;;; Preferences Struct & Defaults

;; Emacs 29 warns that its generated accessor docstrings ("Access slot ...")
;; are wider than 80 columns for the longer slot names; Emacs 30 does not.
(with-no-warnings
(cl-defstruct (enhanced-dirvish-prefs (:constructor enhanced-dirvish-prefs--create))
  (browser-mode 'columns)          ; columns | icons | list | compact
  (expandable-tree t)              ; expandable folders in list view
  (tenxer-mode nil)                ; Yazi/Vim modal file management
  (tenxer-delete-confirm t)        ; d d two-key trash confirmation in 10xer
  (type-to-search nil)             ; jump/filter on printable keys in default mode
  (arrow-navigation-scoped nil)    ; restrict arrows inside pane vs columns
  (show-keybinding-hints t)
  (reduce-motion nil)

  ;; Sort & appearance
  (sort-key 'name)                 ; name | modified | size | type | extension | created | unsorted
  (sort-direction 'asc)            ; asc | desc
  (folders-first t)
  (natural-sort t)
  (case-sensitive-sort nil)
  (group-by-type nil)
  (show-hidden nil)
  (date-format 'relative)          ; relative | iso | locale
  (unit-system 'metric)            ; metric | binary
  (compact-full-names t)
  (browser-density 'compact)       ; compact | default | comfortable
  (columns-mirror-selection t)
  (columns-show-sizes t)
  (folder-peeking nil)
  (single-click-previews t)

  ;; Previews & independent per-type zoom
  (browser-text-scale 0)           ; integer steps for directory views
  (icons-thumbnail-size 64)
  (show-thumbnails t)
  (render-documents-by-default t)
  (preview-text-wrap t)
  (preview-autoplay nil)
  (preview-muted nil)
  (preview-volume 100)
  (preview-text-scale 0)           ; integer steps (-5 .. +10)
  (preview-image-scale 1.0)        ; float factor (0.25 .. 4.0)
  (preview-pdf-scale 1.0)          ; float factor (0.5 .. 3.0)

  ;; Sidebar & layout
  (sidebar-expanded t)
  (sidebar-compact nil)
  (sidebar-show-home t)
  (sidebar-show-computer t)
  (sidebar-show-trash t)
  (sidebar-show-network t)
  (sidebar-show-recent t)
  (sidebar-show-desktop t)
  (sidebar-show-documents t)
  (sidebar-show-downloads t)
  (sidebar-show-music t)
  (sidebar-show-pictures t)
  (sidebar-show-videos t)
  (sidebar-order '("home" "computer" "trash" "network" "recent"
                   "desktop" "documents" "downloads" "music" "pictures" "videos"))
  (sidebar-pinned-collapsed nil)
  (sidebar-devices-collapsed nil)

  ;; Tabs, search & transfers
  (restore-tabs t)
  (remember-folder-views t)
  (default-directory nil)
  (search-open-files-directly nil)
  (search-exclusions '(".git" "node_modules" "target" "__pycache__" ".cache"))
  (search-time-limit 5)
  (search-entry-limit 5000)
  (filter-include-subfolders t)
  (cross-volume-drop-strategy 'ask)

  ;; Per-item metadata tables (alist / hash-like plists)
  (folder-colors nil)              ; alist ((PATH . COLOR-NAME) ...)
  (custom-icons nil)               ; alist ((PATH . ICON-STR) ...)
  (device-labels nil)              ; alist ((DEVICE-KEY . LABEL) ...)
  (send-to-recent-destinations nil) ; alist ((SRC-KEY . (DEST1 DEST2 ...)) ...)
  (marks nil)))                     ; alist ((?a . PATH) ...)

(defvar enhanced-dirvish-prefs-current nil
  "Active `enhanced-dirvish-prefs' instance for Enhanced Dirvish.")

(defvar enhanced-dirvish-folder-view-lru nil
  "LRU alist of per-folder view/sort state, capped at 128 entries.")

(defconst enhanced-dirvish-folder-view-lru-limit 128)

;;;; Lightweight TOML Subset Parser for ~/.config/enhanced-dirvish/*.toml

(defun enhanced-dirvish-toml--unquote (raw)
  "Trim whitespace and unquote TOML literal RAW."
  (let ((s (string-trim raw)))
    (cond
     ((and (>= (length s) 2) (string-prefix-p "\"" s) (string-suffix-p "\"" s))
      (replace-regexp-in-string
       "\\\\\"" "\""
       (replace-regexp-in-string
        "\\\\\\\\" "\\\\"
        (substring s 1 -1))))
     ((and (>= (length s) 2) (string-prefix-p "'" s) (string-suffix-p "'" s))
      (substring s 1 -1))
     (t s))))

(defun enhanced-dirvish-toml--strip-comment (line)
  "Strip unquoted # comment from TOML LINE."
  (let ((in-dq nil)
        (in-sq nil)
        (esc nil)
        (i 0)
        (len (length line))
        (cut nil))
    (while (and (< i len) (not cut))
      (let ((ch (aref line i)))
        (cond
         (esc (setq esc nil))
         ((and in-dq (= ch ?\\)) (setq esc t))
         ((and (not in-sq) (= ch ?\")) (setq in-dq (not in-dq)))
         ((and (not in-dq) (= ch ?')) (setq in-sq (not in-sq)))
         ((and (not in-dq) (not in-sq) (= ch ?#)) (setq cut i))))
      (setq i (1+ i)))
    (if cut (substring line 0 cut) line)))

(defun enhanced-dirvish-toml--parse-array (raw)
  "Parse a simple single-line TOML string array RAW into a list of strings."
  (let* ((inner (string-trim raw))
         (inner (if (and (string-prefix-p "[" inner) (string-suffix-p "]" inner))
                    (substring inner 1 -1)
                  inner)))
    (if (string-empty-p (string-trim inner))
        nil
      (mapcar #'enhanced-dirvish-toml--unquote
              (split-string inner "," t "[ \t\n\r]+")))))

(defun enhanced-dirvish-toml--parse-value (raw)
  "Parse scalar or simple array value RAW from TOML."
  (let ((s (string-trim raw)))
    (cond
     ((string= s "true") t)
     ((string= s "false") :false)
     ((string-prefix-p "[" s) (enhanced-dirvish-toml--parse-array s))
     ((string-match-p "\\`-?[0-9]+\\'" s) (string-to-number s))
     ((string-match-p "\\`-?[0-9]+\\.[0-9]+\\'" s) (string-to-number s))
     (t (enhanced-dirvish-toml--unquote s)))))

(defun enhanced-dirvish-toml-parse-file (file)
  "Parse key/value pairs and [section] tables from TOML FILE.
Returns an alist mapping section string (\"\" for root) to an alist of
\(KEY . VALUE)."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (let ((section "")
            (result nil)
            (lines (split-string (buffer-string) "\n")))
        (while lines
          (let* ((raw (enhanced-dirvish-toml--strip-comment (car lines)))
                 (line (string-trim raw)))
            (setq lines (cdr lines))
            (cond
             ((string-empty-p line))
             ((string-match "\\`\\[\\[?\\([^]]+\\)\\]\\]?\\'" line)
              (setq section (match-string 1 line)))
             ((string-match "\\`\\([^=]+\\)=\\(.*\\)\\'" line)
              (let ((k (enhanced-dirvish-toml--unquote (match-string 1 line)))
                    (v (string-trim (match-string 2 line))))
                ;; Join multi-line arrays when needed
                (while (and (string-prefix-p "[" v)
                            (not (string-suffix-p "]" v))
                            lines)
                  (setq v (concat v " " (string-trim (enhanced-dirvish-toml--strip-comment (car lines)))))
                  (setq lines (cdr lines)))
                (let* ((sec-cell (or (assoc section result)
                                     (car (push (cons section nil) result))))
                       (parsed (enhanced-dirvish-toml--parse-value v)))
                  (setf (cdr sec-cell)
                        (cons (cons k parsed)
                              (assoc-delete-all k (cdr sec-cell))))))))))
        (nreverse result)))))

(defun enhanced-dirvish-toml--bool (val default)
  "Convert parsed TOML value VAL to Elisp boolean with DEFAULT fallback."
  (cond ((eq val t) t)
        ((eq val :false) nil)
        (t default)))

(defun enhanced-dirvish-prefs-import-enhanced-dirvish-toml (&optional prefs)
  "Seed PREFS from existing ~/.config/enhanced-dirvish/settings.toml if present."
  (let* ((p (or prefs (enhanced-dirvish-prefs--create)))
         (toml-file (expand-file-name "settings.toml" enhanced-dirvish-config-dir))
         (parsed (enhanced-dirvish-toml-parse-file toml-file))
         (root (cdr (assoc "" parsed))))
    (when root
      (cl-labels ((getk (k) (cdr (assoc k root)))
                  (symk (k def)
                    (let ((v (getk k)))
                      (if (and (stringp v) (not (string-empty-p v)))
                          (intern (downcase v))
                        def))))
        (setf (enhanced-dirvish-prefs-browser-mode p) (symk "browser_mode" (enhanced-dirvish-prefs-browser-mode p)))
        (setf (enhanced-dirvish-prefs-expandable-tree p)
              (enhanced-dirvish-toml--bool (getk "expandable_folders_in_list")
                                 (enhanced-dirvish-prefs-expandable-tree p)))
        (setf (enhanced-dirvish-prefs-tenxer-mode p)
              (enhanced-dirvish-toml--bool (getk "tenxer_mode") (enhanced-dirvish-prefs-tenxer-mode p)))
        (setf (enhanced-dirvish-prefs-type-to-search p)
              (enhanced-dirvish-toml--bool (getk "type_to_search") (enhanced-dirvish-prefs-type-to-search p)))
        (setf (enhanced-dirvish-prefs-arrow-navigation-scoped p)
              (enhanced-dirvish-toml--bool (getk "arrow_navigation_scoped")
                                 (enhanced-dirvish-prefs-arrow-navigation-scoped p)))
        (setf (enhanced-dirvish-prefs-show-keybinding-hints p)
              (enhanced-dirvish-toml--bool (getk "show_keybinding_hints")
                                 (enhanced-dirvish-prefs-show-keybinding-hints p)))
        (setf (enhanced-dirvish-prefs-reduce-motion p)
              (enhanced-dirvish-toml--bool (getk "reduce_motion") (enhanced-dirvish-prefs-reduce-motion p)))
        (setf (enhanced-dirvish-prefs-sort-key p) (symk "sort_key" (enhanced-dirvish-prefs-sort-key p)))
        (let ((dir (getk "sort_direction")))
          (when (stringp dir)
            (setf (enhanced-dirvish-prefs-sort-direction p)
                  (if (string-prefix-p "desc" (downcase dir)) 'desc 'asc))))
        (setf (enhanced-dirvish-prefs-folders-first p)
              (enhanced-dirvish-toml--bool (getk "folders_first") (enhanced-dirvish-prefs-folders-first p)))
        (setf (enhanced-dirvish-prefs-natural-sort p)
              (enhanced-dirvish-toml--bool (getk "natural_sort") (enhanced-dirvish-prefs-natural-sort p)))
        (setf (enhanced-dirvish-prefs-case-sensitive-sort p)
              (enhanced-dirvish-toml--bool (getk "case_sensitive_sort")
                                 (enhanced-dirvish-prefs-case-sensitive-sort p)))
        (setf (enhanced-dirvish-prefs-group-by-type p)
              (enhanced-dirvish-toml--bool (getk "group_by_type") (enhanced-dirvish-prefs-group-by-type p)))
        (setf (enhanced-dirvish-prefs-show-hidden p)
              (enhanced-dirvish-toml--bool (getk "show_hidden") (enhanced-dirvish-prefs-show-hidden p)))
        (setf (enhanced-dirvish-prefs-date-format p) (symk "date_format" (enhanced-dirvish-prefs-date-format p)))
        (setf (enhanced-dirvish-prefs-unit-system p) (symk "unit_system" (enhanced-dirvish-prefs-unit-system p)))
        (setf (enhanced-dirvish-prefs-compact-full-names p)
              (enhanced-dirvish-toml--bool (getk "compact_full_names")
                                 (enhanced-dirvish-prefs-compact-full-names p)))
        (setf (enhanced-dirvish-prefs-columns-mirror-selection p)
              (enhanced-dirvish-toml--bool (getk "columns_mirror_selection")
                                 (enhanced-dirvish-prefs-columns-mirror-selection p)))
        (setf (enhanced-dirvish-prefs-columns-show-sizes p)
              (enhanced-dirvish-toml--bool (getk "columns_show_sizes")
                                 (enhanced-dirvish-prefs-columns-show-sizes p)))
        (setf (enhanced-dirvish-prefs-render-documents-by-default p)
              (enhanced-dirvish-toml--bool (getk "render_documents_by_default")
                                 (enhanced-dirvish-prefs-render-documents-by-default p)))
        (setf (enhanced-dirvish-prefs-preview-text-wrap p)
              (enhanced-dirvish-toml--bool (getk "preview_text_wrap")
                                 (enhanced-dirvish-prefs-preview-text-wrap p)))
        (setf (enhanced-dirvish-prefs-preview-autoplay p)
              (enhanced-dirvish-toml--bool (getk "preview_autoplay")
                                 (enhanced-dirvish-prefs-preview-autoplay p)))
        (setf (enhanced-dirvish-prefs-preview-muted p)
              (enhanced-dirvish-toml--bool (getk "preview_muted") (enhanced-dirvish-prefs-preview-muted p)))
        (when (numberp (getk "browser_text_scale"))
          (setf (enhanced-dirvish-prefs-browser-text-scale p) (getk "browser_text_scale")))
        (when (numberp (getk "icons_thumbnail_size"))
          (setf (enhanced-dirvish-prefs-icons-thumbnail-size p) (getk "icons_thumbnail_size")))
        (setf (enhanced-dirvish-prefs-show-thumbnails p)
              (enhanced-dirvish-toml--bool (getk "show_thumbnails") (enhanced-dirvish-prefs-show-thumbnails p)))
        (setf (enhanced-dirvish-prefs-restore-tabs p)
              (enhanced-dirvish-toml--bool (getk "restore_tabs") (enhanced-dirvish-prefs-restore-tabs p)))
        (setf (enhanced-dirvish-prefs-remember-folder-views p)
              (enhanced-dirvish-toml--bool (getk "remember_folder_views")
                                 (enhanced-dirvish-prefs-remember-folder-views p)))
        (setf (enhanced-dirvish-prefs-filter-include-subfolders p)
              (enhanced-dirvish-toml--bool (getk "filter_include_subfolders")
                                 (enhanced-dirvish-prefs-filter-include-subfolders p)))
        (when (listp (getk "search_exclusions"))
          (when-let ((ex (getk "search_exclusions")))
            (setf (enhanced-dirvish-prefs-search-exclusions p) ex)))
        (when (numberp (getk "search_time_limit"))
          (setf (enhanced-dirvish-prefs-search-time-limit p) (max 0 (getk "search_time_limit"))))
        (when (numberp (getk "search_entry_limit"))
          (setf (enhanced-dirvish-prefs-search-entry-limit p) (max 0 (getk "search_entry_limit")))))
      ;; Table sections
      (dolist (sec '(("folder_colors" . enhanced-dirvish-prefs-folder-colors)
                     ("custom_icons" . enhanced-dirvish-prefs-custom-icons)
                     ("device_labels" . enhanced-dirvish-prefs-device-labels)))
        (when-let ((entries (cdr (assoc (car sec) parsed))))
          (setf (cl-struct-slot-value 'enhanced-dirvish-prefs
                                      (intern (string-remove-prefix "enhanced-dirvish-prefs-"
                                                                    (symbol-name (cdr sec))))
                                      p)
                entries))))
    p))

(defun enhanced-dirvish-prefs-load ()
  "Load `enhanced-dirvish-prefs-current' from Emacs state and TOML defaults."
  (let ((base (enhanced-dirvish-prefs-import-enhanced-dirvish-toml)))
    (when (file-readable-p enhanced-dirvish-state-file)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents enhanced-dirvish-state-file)
            (let ((data (read (current-buffer))))
              (when (listp data)
                (dolist (kv data)
                  (when (consp kv)
                    (ignore-errors
                      (setf (cl-struct-slot-value 'enhanced-dirvish-prefs (car kv) base)
                            (cdr kv))))))))
        (error nil)))
    (setq enhanced-dirvish-prefs-current base)))

(defun enhanced-dirvish-prefs-save ()
  "Persist `enhanced-dirvish-prefs-current' to `enhanced-dirvish-state-file'."
  (when enhanced-dirvish-prefs-current
    (make-directory (file-name-directory enhanced-dirvish-state-file) t)
    (let ((alist
           (mapcar (lambda (slot)
                     (cons slot (cl-struct-slot-value 'enhanced-dirvish-prefs slot enhanced-dirvish-prefs-current)))
                   '(browser-mode expandable-tree tenxer-mode tenxer-delete-confirm
                     type-to-search arrow-navigation-scoped show-keybinding-hints reduce-motion
                     sort-key sort-direction folders-first natural-sort case-sensitive-sort
                     group-by-type show-hidden date-format unit-system compact-full-names
                     browser-density columns-mirror-selection columns-show-sizes
                     folder-peeking single-click-previews browser-text-scale
                     icons-thumbnail-size show-thumbnails
                     render-documents-by-default preview-text-wrap preview-autoplay
                     preview-muted preview-volume preview-text-scale preview-image-scale
                     preview-pdf-scale sidebar-expanded sidebar-compact
                     sidebar-show-home sidebar-show-computer sidebar-show-trash
                     sidebar-show-network sidebar-show-recent sidebar-show-desktop
                     sidebar-show-documents sidebar-show-downloads sidebar-show-music
                     sidebar-show-pictures sidebar-show-videos sidebar-order
                     sidebar-pinned-collapsed sidebar-devices-collapsed
                     restore-tabs remember-folder-views default-directory
                     search-open-files-directly search-exclusions search-time-limit
                     search-entry-limit filter-include-subfolders cross-volume-drop-strategy
                     folder-colors custom-icons device-labels send-to-recent-destinations marks))))
      (with-temp-file enhanced-dirvish-state-file
        (let ((print-length nil)
              (print-level nil))
          (prin1 alist (current-buffer))
          (insert "\n"))))))

(defun enhanced-dirvish-prefs ()
  "Return active `enhanced-dirvish-prefs' struct, loading lazily if needed."
  (or enhanced-dirvish-prefs-current (enhanced-dirvish-prefs-load)))

;;;; Formatting Helpers (Metric / Binary, Relative Dates, Drive Capacity Accuracy)

(defun enhanced-dirvish-format-bytes (bytes &optional unit-system decimals)
  "Format BYTES in human readable Metric (1000) or Binary (1024) units.
UNIT-SYSTEM overrides `(enhanced-dirvish-prefs-unit-system
(enhanced-dirvish-prefs))'."
  (let* ((bytes (max 0 (float (or bytes 0))))
         (sys (or unit-system (enhanced-dirvish-prefs-unit-system (enhanced-dirvish-prefs))))
         (base (if (eq sys 'binary) 1024.0 1000.0))
         (units (if (eq sys 'binary)
                    '("B" "KiB" "MiB" "GiB" "TiB" "PiB")
                  '("B" "kB" "MB" "GB" "TB" "PB")))
         (idx 0)
         (val bytes))
    (while (and (>= val base) (< idx (1- (length units))))
      (setq val (/ val base)
            idx (1+ idx)))
    (if (= idx 0)
        (format "%d B" (truncate val))
      (let* ((dec (or decimals 1))
             (fmt (format "%%.%df %%s" dec))
             (s (format fmt val (nth idx units))))
        ;; Trim trailing .0 for cleaner Enhanced Dirvish typography
        (replace-regexp-in-string "\\.0 \\([A-Za-z]+\\)\\'" " \\1" s)))))

(defun enhanced-dirvish-format-drive-free-size (free total &optional unit-system)
  "Format FREE bytes relative to TOTAL drive bytes cleanly.
Use GB from 1,000 MB upward, or GiB from 1,024 MiB in binary mode.
Keep larger free-space values in that unit too.  Add precision near TOTAL
to avoid rounding free space up to the drive's full capacity."
  (let* ((sys (or unit-system (enhanced-dirvish-prefs-unit-system (enhanced-dirvish-prefs))))
         (base (if (eq sys 'binary) 1024.0 1000.0))
         (units (if (eq sys 'binary)
                    '("B" "KiB" "MiB" "GiB" "TiB" "PiB")
                  '("B" "kB" "MB" "GB" "TB" "PB")))
         (def-free (enhanced-dirvish-format-bytes free sys))
         (def-total (enhanced-dirvish-format-bytes total sys)))
    (cond
     ((>= free (expt base 3))
      (let* ((scale (expt base 3))
             (value (/ (float free) scale))
             (decimals 1)
             (factor 10.0)
             (rounded (/ (fround (* value factor)) factor)))
        (while (and (< free total) (>= (* rounded scale) total) (< decimals 3))
          (setq decimals (1+ decimals)
                factor (* factor 10.0)
                rounded (/ (fround (* value factor)) factor)))
        (when (and (< free total) (>= (* rounded scale) total))
          (setq rounded (/ (floor (* value factor)) factor)))
        (replace-regexp-in-string
         "\\.0 \\([A-Za-z]+\\)\\'" " \\1"
         (format (format "%%.%df %%s" decimals) rounded (nth 3 units)))))
     ((or (>= free total) (not (string= def-free def-total))) def-free)
     (t
      (let* ((total-idx (let ((v (float total)) (i 0))
                          (while (and (>= v base) (< i (1- (length units))))
                            (setq v (/ v base) i (1+ i)))
                          i))
             (i (1- total-idx))
             (found nil))
        (while (and (>= i 0) (not found))
          (let* ((scale (expt base i))
                 (rounded (/ (fround (* (/ (float free) scale) 10.0)) 10.0)))
            (when (< (* rounded scale) (float total))
              (setq found
                    (replace-regexp-in-string
                     "\\.0 \\([A-Za-z]+\\)\\'" " \\1"
                     (format "%.1f %s" rounded (nth i units))))))
          (setq i (1- i)))
        (or found def-free))))))

(defun enhanced-dirvish-format-time (time &optional mode)
  "Format Emacs TIME according to MODE (`relative', `iso', or `locale')."
  (when time
    (let ((fmt (or mode (enhanced-dirvish-prefs-date-format (enhanced-dirvish-prefs)))))
      (pcase fmt
        ('iso (format-time-string "%Y-%m-%d %H:%M" time))
        ('locale (format-time-string "%b %e %Y %H:%M" time))
        (_
         (let ((diff (float-time (time-subtract (current-time) time))))
           (cond
            ((< diff 0) (format-time-string "%Y-%m-%d" time))
            ((< diff 60) "just now")
            ((< diff 3600) (format "%dm ago" (floor (/ diff 60))))
            ((< diff 86400) (format "%dh ago" (floor (/ diff 3600))))
            ((< diff (* 7 86400)) (format "%dd ago" (floor (/ diff 86400))))
            ((< diff (* 365 86400)) (format-time-string "%b %e" time))
            (t (format-time-string "%Y-%m-%d" time)))))))))

;;;; Theme-Reactive Faces (Noctalia / Ef / Modus / Custom Themes)

(defface enhanced-dirvish-header-accent
  '((t :inherit font-lock-keyword-face :weight bold))
  "Accent badge in the Enhanced Dirvish header."
  :group 'enhanced-dirvish)

(defface enhanced-dirvish-crumb-segment
  '((t :inherit dired-directory :weight medium))
  "Breadcrumb path segment face."
  :group 'enhanced-dirvish)

(defface enhanced-dirvish-crumb-separator
  '((t :inherit shadow))
  "Breadcrumb separator face."
  :group 'enhanced-dirvish)

(defface enhanced-dirvish-pill-10x
  '((t :inherit match :weight bold :box (:line-width (-1 . -1))))
  "10xer mode pill badge in footer."
  :group 'enhanced-dirvish)

(defface enhanced-dirvish-pill-chord
  '((t :inherit warning :weight bold :box (:line-width (-1 . -1))))
  "Active multi-key chord pill badge."
  :group 'enhanced-dirvish)

(defface enhanced-dirvish-pill-filter
  '((t :inherit isearch :weight bold :box (:line-width (-1 . -1))))
  "Active filter pill badge."
  :group 'enhanced-dirvish)

(defface enhanced-dirvish-hint-key
  '((t :inherit font-lock-constant-face :weight bold))
  "Keycap face inside shortcut footer and shortcut reference."
  :group 'enhanced-dirvish)

(defface enhanced-dirvish-hint-desc
  '((t :inherit shadow :height 0.92))
  "Key description face inside shortcut footer."
  :group 'enhanced-dirvish)

(defface enhanced-dirvish-bar-ok
  '((t :inherit success :weight bold))
  "Drive capacity bar normal usage (< 80%)."
  :group 'enhanced-dirvish)

(defface enhanced-dirvish-bar-warn
  '((t :inherit warning :weight bold))
  "Drive capacity bar warning usage (>= 80%)."
  :group 'enhanced-dirvish)

(defface enhanced-dirvish-bar-danger
  '((t :inherit error :weight bold))
  "Drive capacity bar critical usage (>= 90%)."
  :group 'enhanced-dirvish)

(defface enhanced-dirvish-section-heading
  '((t :inherit font-lock-type-face :weight bold :height 0.95))
  "Section heading in sidebar, computer:///, and settings."
  :group 'enhanced-dirvish)

(defface enhanced-dirvish-pane-active-badge
  '((t :inherit font-lock-function-name-face :weight bold))
  "Badge shown in the focused split pane header."
  :group 'enhanced-dirvish)

(defface enhanced-dirvish-pane-inactive-badge
  '((t :inherit shadow))
  "Badge shown in the unfocused split pane header."
  :group 'enhanced-dirvish)

(defface enhanced-dirvish-preview-heading-1
  '((t :inherit outline-1 :weight bold :height 1.35))
  "Rendered Markdown heading 1 in Enhanced Dirvish preview."
  :group 'enhanced-dirvish)

(defface enhanced-dirvish-preview-heading-2
  '((t :inherit outline-2 :weight bold :height 1.2))
  "Rendered Markdown heading 2 in Enhanced Dirvish preview."
  :group 'enhanced-dirvish)

(defface enhanced-dirvish-preview-heading-3
  '((t :inherit outline-3 :weight bold :height 1.08))
  "Rendered Markdown heading 3+ in Enhanced Dirvish preview."
  :group 'enhanced-dirvish)

(defface enhanced-dirvish-preview-code
  '((t :inherit font-lock-builtin-face :extend t))
  "Code block/inline code face in rendered preview."
  :group 'enhanced-dirvish)

(defface enhanced-dirvish-entry-selected
  '((t :inherit region :weight bold))
  "Face used to highlight the selected file or directory name across views."
  :group 'enhanced-dirvish)

(defface enhanced-dirvish-folder-red '((t :foreground "#f7768e" :weight bold)) "Folder badge red." :group 'enhanced-dirvish)
(defface enhanced-dirvish-folder-amber '((t :foreground "#e0af68" :weight bold)) "Folder badge amber." :group 'enhanced-dirvish)
(defface enhanced-dirvish-folder-green '((t :foreground "#9ece6a" :weight bold)) "Folder badge green." :group 'enhanced-dirvish)
(defface enhanced-dirvish-folder-cyan '((t :foreground "#7dcfff" :weight bold)) "Folder badge cyan." :group 'enhanced-dirvish)
(defface enhanced-dirvish-folder-blue '((t :foreground "#7aa2f7" :weight bold)) "Folder badge blue." :group 'enhanced-dirvish)
(defface enhanced-dirvish-folder-purple '((t :foreground "#bb9af7" :weight bold)) "Folder badge purple." :group 'enhanced-dirvish)

(defconst enhanced-dirvish-folder-color-alist
  '(("red" . enhanced-dirvish-folder-red)
    ("amber" . enhanced-dirvish-folder-amber)
    ("orange" . enhanced-dirvish-folder-amber)
    ("yellow" . enhanced-dirvish-folder-amber)
    ("green" . enhanced-dirvish-folder-green)
    ("teal" . enhanced-dirvish-folder-cyan)
    ("cyan" . enhanced-dirvish-folder-cyan)
    ("blue" . enhanced-dirvish-folder-blue)
    ("purple" . enhanced-dirvish-folder-purple)
    ("violet" . enhanced-dirvish-folder-purple))
  "Mapping from Enhanced Dirvish folder color names to faces.")

(defun enhanced-dirvish-theme--face-color (face attr fallback)
  "Resolve FACE's ATTR color safely, falling back to FALLBACK."
  (let ((c (ignore-errors (face-attribute face attr nil 'default))))
    (if (and (stringp c) (not (member c '("unspecified" "unspecified-fg" "unspecified-bg"))))
        c
      fallback)))

(defun enhanced-dirvish-sync-theme-faces (&rest _)
  "Synchronize faces to the active theme (Noctalia / Ef / etc.)."
  (let ((primary (enhanced-dirvish-theme--face-color 'dired-directory :foreground "#00f5c8"))
        (secondary (enhanced-dirvish-theme--face-color 'font-lock-type-face :foreground "#77f9e0"))
        (tertiary (enhanced-dirvish-theme--face-color 'font-lock-keyword-face :foreground "#61e8ff"))
        (err (enhanced-dirvish-theme--face-color 'error :foreground "#ff6b87"))
        (warn (enhanced-dirvish-theme--face-color 'warning :foreground "#ffb454"))
        (ok (enhanced-dirvish-theme--face-color 'success :foreground "#61e8ff"))
        (surface-hi (enhanced-dirvish-theme--face-color 'highlight :background "#18253d"))
        (sel-bg (enhanced-dirvish-theme--face-color 'region :background "#263c5e"))
        (sel-fg (enhanced-dirvish-theme--face-color 'region :foreground nil))
        (fg (enhanced-dirvish-theme--face-color 'default :foreground "#e9fff8")))
    (set-face-attribute 'enhanced-dirvish-header-accent nil :foreground primary :weight 'bold)
    (set-face-attribute 'enhanced-dirvish-crumb-segment nil :foreground primary :weight 'medium)
    (set-face-attribute 'enhanced-dirvish-pill-10x nil
                        :foreground fg :background surface-hi
                        :box `(:line-width (-1 . -1) :color ,primary) :weight 'bold)
    (set-face-attribute 'enhanced-dirvish-pill-chord nil
                        :foreground warn :background surface-hi
                        :box `(:line-width (-1 . -1) :color ,warn) :weight 'bold)
    (set-face-attribute 'enhanced-dirvish-pill-filter nil
                        :foreground tertiary :background surface-hi
                        :box `(:line-width (-1 . -1) :color ,tertiary) :weight 'bold)
    (set-face-attribute 'enhanced-dirvish-hint-key nil :foreground secondary :weight 'bold)
    (set-face-attribute 'enhanced-dirvish-section-heading nil :foreground secondary :weight 'bold)
    (set-face-attribute 'enhanced-dirvish-bar-ok nil :foreground ok)
    (set-face-attribute 'enhanced-dirvish-bar-warn nil :foreground warn)
    (set-face-attribute 'enhanced-dirvish-bar-danger nil :foreground err)
    (set-face-attribute 'enhanced-dirvish-preview-code nil :background surface-hi :extend t)
    (set-face-attribute 'enhanced-dirvish-entry-selected nil
                        :background (if (member sel-bg '("unspecified" "unspecified-bg" nil))
                                        surface-hi sel-bg)
                        :foreground (or sel-fg 'unspecified)
                        :weight 'bold)))

;;;; Verified Nerd Font Icon Engine

(defconst enhanced-dirvish-icon-table
  '((folder       #xf07b . "[+]")
    (folder-open  #xf07c . "[-]")
    (folder-git   #xe5fb . "[+]")
    (file         #xf15b . " · ")
    (file-text    #xf15c . " ≡ ")
    (file-code    #xf1c9 . " <>")
    (file-image   #xf1c5 . "[I]")
    (file-audio   #xf1c7 . "[A]")
    (file-video   #xf1c8 . "[V]")
    (file-pdf     #xf1c1 . "[P]")
    (file-zip     #xf1c6 . "[Z]")
    (file-table   #xf0ce . "[T]")
    (file-word    #xf1c2 . "[W]")
    (file-3d      #xf1b2 . "[3]")
    (symlink      #xf0c1 . "-> ")
    (home         #xf015 . "~")
    (desktop      #xf108 . "[D]")
    (documents    #xf15c . "[Doc]")
    (downloads    #xf019 . "[Dn]")
    (music        #xf001 . "[M]")
    (pictures     #xf03e . "[P]")
    (videos       #xf03d . "[V]")
    (computer     #xf108 . "[PC]")
    (trash        #xf1f8 . "[X]")
    (network      #xf0ac . "[Net]")
    (globe        #xf0ac . "[Net]")
    (recent       #xf017 . "[Rec]")
    (search       #xf002 . "[?]")
    (gear         #xf013 . "[*]")
    (hdd          #xf0a0 . "[HD]")
    (usb          #xf287 . "[USB]")
    (nvme         #xf0e7 . "[SSD]")
    (optical      #xf1c0 . "[CD]")
    (cloud        #xf0c2 . "☁")
    (gdrive       #xf02b6 . "▲")
    (proton       #xf219 . "◆")
    (lock         #xf023 . "[L]")
    (nixos        #xf313 . "❄")
    (linux        #xf17c . "🐧")
    (terminal     #xf120 . ">_")
    (keyboard     #xf11c . "[K]")
    (play         #xf04b . ">")
    (markdown     #xf48a . "MD")
    (elisp        #xe632 . "EL")
    (org          #xe633 . "ORG")
    (python       #xe73c . "PY")
    (rust         #xe7a8 . "RS")
    (nix          #xf313 . "NIX")
    (js           #xe781 . "JS")
    (ts           #xe628 . "TS")
    (c            #xe61e . "C")
    (cpp          #xe61d . "C++")
    (go           #xe627 . "GO")
    (lua          #xe620 . "LUA")
    (shell        #xe795 . "SH")
    (json         #xe60b . "{}")
    (yaml         #xe6a8 . "YML")
    (toml         #xe6b2 . "CFG")
    (html         #xf13b . "<>")
    (css          #xf13c . "#")
    (git          #xe702 . "git")
    (font         #xf031 . "Aa")
    (database     #xf1c0 . "DB")
    (bookmark     #xf02e . "*")
    (bolt         #xf0e7 . "*"))
  "Verified icon table mapping semantic symbols to (NERD-CP . TTY-FALLBACK).
All Nerd Font codepoints are verified across Symbols Nerd Font Mono,
CaskaydiaCove Nerd Font, and JetBrainsMono Nerd Font.")

(defvar enhanced-dirvish-icon--family-cache nil
  "Alist caching detected Nerd Font family per Emacs terminal.")

(defun enhanced-dirvish-icon--family ()
  "Return verified Nerd Font family name on GUI frames, or nil on TTY/batch."
  (when (display-graphic-p)
    (let* ((term (frame-terminal))
           (cached (assq term enhanced-dirvish-icon--family-cache)))
      (if cached
          (cdr cached)
        (let ((fam (cl-find-if
                    (lambda (f) (find-font (font-spec :family f)))
                    '("Symbols Nerd Font Mono"
                      "CaskaydiaCove Nerd Font"
                      "JetBrainsMono Nerd Font"))))
          (push (cons term fam) enhanced-dirvish-icon--family-cache)
          fam)))))

(defun enhanced-dirvish-icon-glyph (kind &optional face tty-override)
  "Return propertized crisp Nerd Font glyph for KIND tinted with optional FACE.
Falls back cleanly to TTY-OVERRIDE or safe table string when non-graphic."
  (let* ((spec (alist-get kind enhanced-dirvish-icon-table))
         (cp (car spec))
         (fallback (or tty-override (cdr spec) "·"))
         (fam (enhanced-dirvish-icon--family)))
    (if (and fam cp)
        (let* ((s (char-to-string cp))
               (fspec `(:family ,fam :height 1.05 ,@(when face (list :inherit face)))))
          (propertize s 'face fspec 'font-lock-face fspec 'rear-nonsticky t))
      (if face (propertize fallback 'face face) fallback))))

(defun enhanced-dirvish-icon--extract-family (fprop)
  "Return first `:family' string found inside face spec FPROP, or nil."
  (cond
   ((null fprop) nil)
   ((keywordp (car-safe fprop)) (plist-get fprop :family))
   ((listp fprop) (cl-some #'enhanced-dirvish-icon--extract-family fprop))))

(defun enhanced-dirvish-icon-tint (glyph face &optional append-p)
  "Return copy of GLYPH merged with FACE while keeping any span `:family' first."
  (let* ((s (copy-sequence glyph))
         (len (length s))
         (pos 0)
         (spans nil))
    (while (< pos len)
      (let* ((next (next-single-property-change pos 'face s len))
             (fam (enhanced-dirvish-icon--extract-family (get-text-property pos 'face s))))
        (when fam
          (push (list pos next fam) spans))
        (setq pos next)))
    (add-face-text-property 0 len face (if append-p t nil) s)
    (dolist (sp spans)
      (add-face-text-property (nth 0 sp) (nth 1 sp) (list :family (nth 2 sp)) nil s))
    (setq pos 0)
    (while (< pos len)
      (let* ((next (next-single-property-change pos 'face s len))
             (fp (get-text-property pos 'face s)))
        (when fp
          (put-text-property pos next 'font-lock-face fp s))
        (setq pos next)))
    s))

(defun enhanced-dirvish-add-row-properties (str props)
  "Apply row text PROPS to STR, keeping `mouse-face' off trailing newline.
Excluding the trailing newline prevents Emacs redisplay from merging
adjacent rows into one whole-group hover highlight."
  (let* ((len (length str))
         (hi-end (if (string-suffix-p "\n" str) (max 0 (1- len)) len))
         (mf (plist-get props 'mouse-face))
         (rest (if mf
                   (cl-loop for (k v) on props by #'cddr
                            unless (eq k 'mouse-face) append (list k v))
                 props)))
    (when (and rest (> len 0))
      (add-text-properties 0 len rest str))
    (when (and mf (> hi-end 0))
      (add-text-properties 0 hi-end (list 'mouse-face mf) str))
    str))

(provide 'enhanced-dirvish-prefs)
;;; enhanced-dirvish-prefs.el ends here
