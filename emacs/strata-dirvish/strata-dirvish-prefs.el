;;; strata-dirvish-prefs.el --- Preferences, TOML sync, and Noctalia theming -*- lexical-binding: t; -*-

;;; Commentary:
;; Core state, preferences, formatting helpers, and theme-reactive faces for
;; Strata-flavored Dirvish inside Emacs.  Settings interoperate cleanly with
;; ~/.config/strata/settings.toml and persist Emacs overrides in
;; `strata-dirvish-state-file'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup strata-dirvish nil
  "Strata file manager features blended into Dirvish."
  :group 'dirvish
  :prefix "strata-dirvish-")

(defcustom strata-dirvish-config-dir
  (expand-file-name "strata" (or (getenv "XDG_CONFIG_HOME") "~/.config"))
  "XDG directory containing Strata TOML configuration files."
  :type 'directory
  :group 'strata-dirvish)

(defcustom strata-dirvish-state-dir
  (expand-file-name "dirvish/strata/" user-emacs-directory)
  "Emacs state directory for Strata-Dirvish persistent data."
  :type 'directory
  :group 'strata-dirvish)

(defcustom strata-dirvish-state-file
  (expand-file-name "prefs.eld" strata-dirvish-state-dir)
  "Persistent Emacs override file for `strata-dirvish'."
  :type 'file
  :group 'strata-dirvish)

(defcustom strata-dirvish-desktop-cua-clipboard nil
  "When non-nil in Default mode, bind `C-c', `C-x', and `C-v' directly.
Left nil by default so Emacs prefix keys (`C-x' and `C-c') keep working
everywhere; copy/cut/paste remain bound cleanly to `C-c c', `C-c x', `C-c v',
`M-w', `C-w', and in 10xer mode to `y', `x', `p'."
  :type 'boolean
  :group 'strata-dirvish)

;;;; Preferences Struct & Defaults

(cl-defstruct (strata-prefs (:constructor strata-prefs--create))
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
  (marks nil))                     ; alist ((?a . PATH) ...)

(defvar strata-prefs-current nil
  "Active `strata-prefs' instance for Strata-Dirvish.")

(defvar strata-folder-view-lru nil
  "LRU alist of per-folder view/sort state, capped at 128 entries.")

(defconst strata-folder-view-lru-limit 128)

;;;; Lightweight TOML Subset Parser for ~/.config/strata/*.toml

(defun strata-toml--unquote (raw)
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

(defun strata-toml--strip-comment (line)
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

(defun strata-toml--parse-array (raw)
  "Parse a simple single-line TOML string array RAW into a list of strings."
  (let* ((inner (string-trim raw))
         (inner (if (and (string-prefix-p "[" inner) (string-suffix-p "]" inner))
                    (substring inner 1 -1)
                  inner)))
    (if (string-empty-p (string-trim inner))
        nil
      (mapcar #'strata-toml--unquote
              (split-string inner "," t "[ \t\n\r]+")))))

(defun strata-toml--parse-value (raw)
  "Parse scalar or simple array value RAW from TOML."
  (let ((s (string-trim raw)))
    (cond
     ((string= s "true") t)
     ((string= s "false") :false)
     ((string-prefix-p "[" s) (strata-toml--parse-array s))
     ((string-match-p "\\`-?[0-9]+\\'" s) (string-to-number s))
     ((string-match-p "\\`-?[0-9]+\\.[0-9]+\\'" s) (string-to-number s))
     (t (strata-toml--unquote s)))))

(defun strata-toml-parse-file (file)
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
          (let* ((raw (strata-toml--strip-comment (car lines)))
                 (line (string-trim raw)))
            (setq lines (cdr lines))
            (cond
             ((string-empty-p line))
             ((string-match "\\`\\[\\[?\\([^]]+\\)\\]\\]?\\'" line)
              (setq section (match-string 1 line)))
             ((string-match "\\`\\([^=]+\\)=\\(.*\\)\\'" line)
              (let ((k (strata-toml--unquote (match-string 1 line)))
                    (v (string-trim (match-string 2 line))))
                ;; Join multi-line arrays when needed
                (while (and (string-prefix-p "[" v)
                            (not (string-suffix-p "]" v))
                            lines)
                  (setq v (concat v " " (string-trim (strata-toml--strip-comment (car lines)))))
                  (setq lines (cdr lines)))
                (let* ((sec-cell (or (assoc section result)
                                     (car (push (cons section nil) result))))
                       (parsed (strata-toml--parse-value v)))
                  (setf (cdr sec-cell)
                        (cons (cons k parsed)
                              (assoc-delete-all k (cdr sec-cell))))))))))
        (nreverse result)))))

(defun strata-toml--bool (val default)
  "Convert parsed TOML value VAL to Elisp boolean with DEFAULT fallback."
  (cond ((eq val t) t)
        ((eq val :false) nil)
        (t default)))

(defun strata-prefs-import-strata-toml (&optional prefs)
  "Seed PREFS from existing ~/.config/strata/settings.toml if present."
  (let* ((p (or prefs (strata-prefs--create)))
         (toml-file (expand-file-name "settings.toml" strata-dirvish-config-dir))
         (parsed (strata-toml-parse-file toml-file))
         (root (cdr (assoc "" parsed))))
    (when root
      (cl-labels ((getk (k) (cdr (assoc k root)))
                  (symk (k def)
                    (let ((v (getk k)))
                      (if (and (stringp v) (not (string-empty-p v)))
                          (intern (downcase v))
                        def))))
        (setf (strata-prefs-browser-mode p) (symk "browser_mode" (strata-prefs-browser-mode p)))
        (setf (strata-prefs-expandable-tree p)
              (strata-toml--bool (getk "expandable_folders_in_list")
                                 (strata-prefs-expandable-tree p)))
        (setf (strata-prefs-tenxer-mode p)
              (strata-toml--bool (getk "tenxer_mode") (strata-prefs-tenxer-mode p)))
        (setf (strata-prefs-type-to-search p)
              (strata-toml--bool (getk "type_to_search") (strata-prefs-type-to-search p)))
        (setf (strata-prefs-arrow-navigation-scoped p)
              (strata-toml--bool (getk "arrow_navigation_scoped")
                                 (strata-prefs-arrow-navigation-scoped p)))
        (setf (strata-prefs-show-keybinding-hints p)
              (strata-toml--bool (getk "show_keybinding_hints")
                                 (strata-prefs-show-keybinding-hints p)))
        (setf (strata-prefs-reduce-motion p)
              (strata-toml--bool (getk "reduce_motion") (strata-prefs-reduce-motion p)))
        (setf (strata-prefs-sort-key p) (symk "sort_key" (strata-prefs-sort-key p)))
        (let ((dir (getk "sort_direction")))
          (when (stringp dir)
            (setf (strata-prefs-sort-direction p)
                  (if (string-prefix-p "desc" (downcase dir)) 'desc 'asc))))
        (setf (strata-prefs-folders-first p)
              (strata-toml--bool (getk "folders_first") (strata-prefs-folders-first p)))
        (setf (strata-prefs-natural-sort p)
              (strata-toml--bool (getk "natural_sort") (strata-prefs-natural-sort p)))
        (setf (strata-prefs-case-sensitive-sort p)
              (strata-toml--bool (getk "case_sensitive_sort")
                                 (strata-prefs-case-sensitive-sort p)))
        (setf (strata-prefs-group-by-type p)
              (strata-toml--bool (getk "group_by_type") (strata-prefs-group-by-type p)))
        (setf (strata-prefs-show-hidden p)
              (strata-toml--bool (getk "show_hidden") (strata-prefs-show-hidden p)))
        (setf (strata-prefs-date-format p) (symk "date_format" (strata-prefs-date-format p)))
        (setf (strata-prefs-unit-system p) (symk "unit_system" (strata-prefs-unit-system p)))
        (setf (strata-prefs-compact-full-names p)
              (strata-toml--bool (getk "compact_full_names")
                                 (strata-prefs-compact-full-names p)))
        (setf (strata-prefs-columns-mirror-selection p)
              (strata-toml--bool (getk "columns_mirror_selection")
                                 (strata-prefs-columns-mirror-selection p)))
        (setf (strata-prefs-columns-show-sizes p)
              (strata-toml--bool (getk "columns_show_sizes")
                                 (strata-prefs-columns-show-sizes p)))
        (setf (strata-prefs-render-documents-by-default p)
              (strata-toml--bool (getk "render_documents_by_default")
                                 (strata-prefs-render-documents-by-default p)))
        (setf (strata-prefs-preview-text-wrap p)
              (strata-toml--bool (getk "preview_text_wrap")
                                 (strata-prefs-preview-text-wrap p)))
        (setf (strata-prefs-preview-autoplay p)
              (strata-toml--bool (getk "preview_autoplay")
                                 (strata-prefs-preview-autoplay p)))
        (setf (strata-prefs-preview-muted p)
              (strata-toml--bool (getk "preview_muted") (strata-prefs-preview-muted p)))
        (when (numberp (getk "icons_thumbnail_size"))
          (setf (strata-prefs-icons-thumbnail-size p) (getk "icons_thumbnail_size")))
        (setf (strata-prefs-show-thumbnails p)
              (strata-toml--bool (getk "show_thumbnails") (strata-prefs-show-thumbnails p)))
        (setf (strata-prefs-restore-tabs p)
              (strata-toml--bool (getk "restore_tabs") (strata-prefs-restore-tabs p)))
        (setf (strata-prefs-remember-folder-views p)
              (strata-toml--bool (getk "remember_folder_views")
                                 (strata-prefs-remember-folder-views p)))
        (setf (strata-prefs-filter-include-subfolders p)
              (strata-toml--bool (getk "filter_include_subfolders")
                                 (strata-prefs-filter-include-subfolders p)))
        (when (listp (getk "search_exclusions"))
          (when-let ((ex (getk "search_exclusions")))
            (setf (strata-prefs-search-exclusions p) ex)))
        (when (numberp (getk "search_time_limit"))
          (setf (strata-prefs-search-time-limit p) (max 0 (getk "search_time_limit"))))
        (when (numberp (getk "search_entry_limit"))
          (setf (strata-prefs-search-entry-limit p) (max 0 (getk "search_entry_limit")))))
      ;; Table sections
      (dolist (sec '(("folder_colors" . strata-prefs-folder-colors)
                     ("custom_icons" . strata-prefs-custom-icons)
                     ("device_labels" . strata-prefs-device-labels)))
        (when-let ((entries (cdr (assoc (car sec) parsed))))
          (setf (cl-struct-slot-value 'strata-prefs
                                      (intern (string-remove-prefix "strata-prefs-"
                                                                    (symbol-name (cdr sec))))
                                      p)
                entries))))
    p))

(defun strata-prefs-load ()
  "Load `strata-prefs-current' from Emacs state + Strata TOML defaults."
  (let ((base (strata-prefs-import-strata-toml)))
    (when (file-readable-p strata-dirvish-state-file)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents strata-dirvish-state-file)
            (let ((data (read (current-buffer))))
              (when (listp data)
                (dolist (kv data)
                  (when (consp kv)
                    (ignore-errors
                      (setf (cl-struct-slot-value 'strata-prefs (car kv) base)
                            (cdr kv))))))))
        (error nil)))
    (setq strata-prefs-current base)))

(defun strata-prefs-save ()
  "Persist `strata-prefs-current' to `strata-dirvish-state-file'."
  (when strata-prefs-current
    (make-directory (file-name-directory strata-dirvish-state-file) t)
    (let ((alist
           (mapcar (lambda (slot)
                     (cons slot (cl-struct-slot-value 'strata-prefs slot strata-prefs-current)))
                   '(browser-mode expandable-tree tenxer-mode tenxer-delete-confirm
                     type-to-search arrow-navigation-scoped show-keybinding-hints reduce-motion
                     sort-key sort-direction folders-first natural-sort case-sensitive-sort
                     group-by-type show-hidden date-format unit-system compact-full-names
                     browser-density columns-mirror-selection columns-show-sizes
                     folder-peeking single-click-previews icons-thumbnail-size show-thumbnails
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
      (with-temp-file strata-dirvish-state-file
        (let ((print-length nil)
              (print-level nil))
          (prin1 alist (current-buffer))
          (insert "\n"))))))

(defun strata-prefs ()
  "Return active `strata-prefs' struct, loading lazily if needed."
  (or strata-prefs-current (strata-prefs-load)))

;;;; Formatting Helpers (Metric / Binary, Relative Dates, Drive Capacity Accuracy)

(defun strata-format-bytes (bytes &optional unit-system decimals)
  "Format BYTES in human readable Metric (1000) or Binary (1024) units.
UNIT-SYSTEM overrides `(strata-prefs-unit-system (strata-prefs))'."
  (let* ((bytes (max 0 (float (or bytes 0))))
         (sys (or unit-system (strata-prefs-unit-system (strata-prefs))))
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
        ;; Trim trailing .0 for cleaner Strata typography
        (replace-regexp-in-string "\\.0 \\([A-Za-z]+\\)\\'" " \\1" s)))))

(defun strata-format-drive-free-size (free total &optional unit-system)
  "Format FREE bytes relative to TOTAL drive bytes cleanly.
When FREE < TOTAL would round to the exact same string as TOTAL in TOTAL's unit
\(e.g., 5.49 TB vs 5.5 TB), step down one unit so usage is never hidden."
  (let* ((sys (or unit-system (strata-prefs-unit-system (strata-prefs))))
         (base (if (eq sys 'binary) 1024.0 1000.0))
         (units (if (eq sys 'binary)
                    '("B" "KiB" "MiB" "GiB" "TiB" "PiB")
                  '("B" "kB" "MB" "GB" "TB" "PB")))
         (def-free (strata-format-bytes free sys))
         (def-total (strata-format-bytes total sys)))
    (if (or (>= free total) (not (string= def-free def-total)))
        def-free
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
        (or found def-free)))))

(defun strata-format-time (time &optional mode)
  "Format Emacs TIME according to MODE (`relative', `iso', or `locale')."
  (when time
    (let ((fmt (or mode (strata-prefs-date-format (strata-prefs)))))
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

(defface strata-header-accent
  '((t :inherit font-lock-keyword-face :weight bold))
  "Accent badge in Strata Dirvish header."
  :group 'strata-dirvish)

(defface strata-crumb-segment
  '((t :inherit dired-directory :weight medium))
  "Breadcrumb path segment face."
  :group 'strata-dirvish)

(defface strata-crumb-separator
  '((t :inherit shadow))
  "Breadcrumb separator face."
  :group 'strata-dirvish)

(defface strata-pill-10x
  '((t :inherit match :weight bold :box (:line-width (-1 . -1))))
  "10xer mode pill badge in footer."
  :group 'strata-dirvish)

(defface strata-pill-chord
  '((t :inherit warning :weight bold :box (:line-width (-1 . -1))))
  "Active multi-key chord pill badge."
  :group 'strata-dirvish)

(defface strata-pill-filter
  '((t :inherit isearch :weight bold :box (:line-width (-1 . -1))))
  "Active filter pill badge."
  :group 'strata-dirvish)

(defface strata-hint-key
  '((t :inherit font-lock-constant-face :weight bold))
  "Keycap face inside shortcut footer and shortcut reference."
  :group 'strata-dirvish)

(defface strata-hint-desc
  '((t :inherit shadow :height 0.92))
  "Key description face inside shortcut footer."
  :group 'strata-dirvish)

(defface strata-bar-ok
  '((t :inherit success :weight bold))
  "Drive capacity bar normal usage (< 80%)."
  :group 'strata-dirvish)

(defface strata-bar-warn
  '((t :inherit warning :weight bold))
  "Drive capacity bar warning usage (>= 80%)."
  :group 'strata-dirvish)

(defface strata-bar-danger
  '((t :inherit error :weight bold))
  "Drive capacity bar critical usage (>= 90%)."
  :group 'strata-dirvish)

(defface strata-section-heading
  '((t :inherit font-lock-type-face :weight bold :height 0.95))
  "Section heading in sidebar, computer:///, and settings."
  :group 'strata-dirvish)

(defface strata-pane-active-badge
  '((t :inherit font-lock-function-name-face :weight bold))
  "Badge shown in the focused split pane header."
  :group 'strata-dirvish)

(defface strata-pane-inactive-badge
  '((t :inherit shadow))
  "Badge shown in the unfocused split pane header."
  :group 'strata-dirvish)

(defface strata-preview-heading-1
  '((t :inherit outline-1 :weight bold :height 1.35))
  "Rendered Markdown heading 1 in Strata preview."
  :group 'strata-dirvish)

(defface strata-preview-heading-2
  '((t :inherit outline-2 :weight bold :height 1.2))
  "Rendered Markdown heading 2 in Strata preview."
  :group 'strata-dirvish)

(defface strata-preview-heading-3
  '((t :inherit outline-3 :weight bold :height 1.08))
  "Rendered Markdown heading 3+ in Strata preview."
  :group 'strata-dirvish)

(defface strata-preview-code
  '((t :inherit font-lock-builtin-face :extend t))
  "Code block/inline code face in rendered preview."
  :group 'strata-dirvish)

(defface strata-entry-selected
  '((t :inherit region :weight bold))
  "Face used to highlight the selected file or directory name across Strata views."
  :group 'strata-dirvish)

(defface strata-folder-red '((t :foreground "#f7768e" :weight bold)) "Folder badge red." :group 'strata-dirvish)
(defface strata-folder-amber '((t :foreground "#e0af68" :weight bold)) "Folder badge amber." :group 'strata-dirvish)
(defface strata-folder-green '((t :foreground "#9ece6a" :weight bold)) "Folder badge green." :group 'strata-dirvish)
(defface strata-folder-cyan '((t :foreground "#7dcfff" :weight bold)) "Folder badge cyan." :group 'strata-dirvish)
(defface strata-folder-blue '((t :foreground "#7aa2f7" :weight bold)) "Folder badge blue." :group 'strata-dirvish)
(defface strata-folder-purple '((t :foreground "#bb9af7" :weight bold)) "Folder badge purple." :group 'strata-dirvish)

(defconst strata-folder-color-alist
  '(("red" . strata-folder-red)
    ("amber" . strata-folder-amber)
    ("orange" . strata-folder-amber)
    ("yellow" . strata-folder-amber)
    ("green" . strata-folder-green)
    ("teal" . strata-folder-cyan)
    ("cyan" . strata-folder-cyan)
    ("blue" . strata-folder-blue)
    ("purple" . strata-folder-purple)
    ("violet" . strata-folder-purple))
  "Mapping from Strata folder color names to faces.")

(defun strata-theme--face-color (face attr fallback)
  "Resolve FACE's ATTR color safely, falling back to FALLBACK."
  (let ((c (ignore-errors (face-attribute face attr nil 'default))))
    (if (and (stringp c) (not (member c '("unspecified" "unspecified-fg" "unspecified-bg"))))
        c
      fallback)))

(defun strata-sync-theme-faces (&rest _)
  "Synchronize Strata faces to the active theme (Noctalia / Ef / etc.)."
  (let ((primary (strata-theme--face-color 'dired-directory :foreground "#00f5c8"))
        (secondary (strata-theme--face-color 'font-lock-type-face :foreground "#77f9e0"))
        (tertiary (strata-theme--face-color 'font-lock-keyword-face :foreground "#61e8ff"))
        (err (strata-theme--face-color 'error :foreground "#ff6b87"))
        (warn (strata-theme--face-color 'warning :foreground "#ffb454"))
        (ok (strata-theme--face-color 'success :foreground "#61e8ff"))
        (surface-hi (strata-theme--face-color 'highlight :background "#18253d"))
        (sel-bg (strata-theme--face-color 'region :background "#263c5e"))
        (sel-fg (strata-theme--face-color 'region :foreground nil))
        (fg (strata-theme--face-color 'default :foreground "#e9fff8")))
    (set-face-attribute 'strata-header-accent nil :foreground primary :weight 'bold)
    (set-face-attribute 'strata-crumb-segment nil :foreground primary :weight 'medium)
    (set-face-attribute 'strata-pill-10x nil
                        :foreground fg :background surface-hi
                        :box `(:line-width (-1 . -1) :color ,primary) :weight 'bold)
    (set-face-attribute 'strata-pill-chord nil
                        :foreground warn :background surface-hi
                        :box `(:line-width (-1 . -1) :color ,warn) :weight 'bold)
    (set-face-attribute 'strata-pill-filter nil
                        :foreground tertiary :background surface-hi
                        :box `(:line-width (-1 . -1) :color ,tertiary) :weight 'bold)
    (set-face-attribute 'strata-hint-key nil :foreground secondary :weight 'bold)
    (set-face-attribute 'strata-section-heading nil :foreground secondary :weight 'bold)
    (set-face-attribute 'strata-bar-ok nil :foreground ok)
    (set-face-attribute 'strata-bar-warn nil :foreground warn)
    (set-face-attribute 'strata-bar-danger nil :foreground err)
    (set-face-attribute 'strata-preview-code nil :background surface-hi :extend t)
    (set-face-attribute 'strata-entry-selected nil
                        :background (if (member sel-bg '("unspecified" "unspecified-bg" nil))
                                        surface-hi sel-bg)
                        :foreground (or sel-fg 'unspecified)
                        :weight 'bold)))

(with-eval-after-load 'emacs
  (strata-sync-theme-faces))
(add-hook 'enable-theme-functions #'strata-sync-theme-faces)
(strata-sync-theme-faces)

;;;; Verified Nerd Font Icon Engine

(defconst strata-icon-table
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

(defvar strata-icon--family-cache nil
  "Alist caching detected Nerd Font family per Emacs terminal.")

(defun strata-icon--family ()
  "Return verified Nerd Font family name on GUI frames, or nil on TTY/batch."
  (when (display-graphic-p)
    (let* ((term (frame-terminal))
           (cached (assq term strata-icon--family-cache)))
      (if cached
          (cdr cached)
        (let ((fam (cl-find-if
                    (lambda (f) (find-font (font-spec :family f)))
                    '("Symbols Nerd Font Mono"
                      "CaskaydiaCove Nerd Font"
                      "JetBrainsMono Nerd Font"))))
          (push (cons term fam) strata-icon--family-cache)
          fam)))))

(defun strata-icon-glyph (kind &optional face tty-override)
  "Return propertized crisp Nerd Font glyph for KIND tinted with optional FACE.
Falls back cleanly to TTY-OVERRIDE or safe table string when non-graphic."
  (let* ((spec (alist-get kind strata-icon-table))
         (cp (car spec))
         (fallback (or tty-override (cdr spec) "·"))
         (fam (strata-icon--family)))
    (if (and fam cp)
        (let* ((s (char-to-string cp))
               (fspec `(:family ,fam :height 1.05 ,@(when face (list :inherit face)))))
          (propertize s 'face fspec 'font-lock-face fspec 'rear-nonsticky t))
      (if face (propertize fallback 'face face) fallback))))

(defun strata-icon--extract-family (fprop)
  "Return first `:family' string found inside face spec FPROP, or nil."
  (cond
   ((null fprop) nil)
   ((keywordp (car-safe fprop)) (plist-get fprop :family))
   ((listp fprop) (cl-some #'strata-icon--extract-family fprop))))

(defun strata-icon-tint (glyph face &optional append-p)
  "Return copy of GLYPH merged with FACE while keeping any span `:family' first."
  (let* ((s (copy-sequence glyph))
         (len (length s))
         (pos 0)
         (spans nil))
    (while (< pos len)
      (let* ((next (next-single-property-change pos 'face s len))
             (fam (strata-icon--extract-family (get-text-property pos 'face s))))
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

(defun strata-add-row-properties (str props)
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

(provide 'strata-dirvish-prefs)
;;; strata-dirvish-prefs.el ends here
