;;; strata-dirvish-previews.el --- Rich previews, per-type zoom, media IPC, docs, 3D/GPX -*- lexical-binding: t; -*-

;;; Commentary:
;; Implements Strata's preview ecosystem inside Dirvish:
;; - Independent per-type zoom (text / image / pdf) via C-+/C--/C-0
;; - Rendered Markdown (with Mermaid/LaTeX/relative image support) & Source toggle
;; - Offline safe HTML, DOCX/ODT/RTF (pandoc), interactive CSV/TSV/XLSX tables
;; - PDF page preview & EXIF RAW/Image preview
;; - Audio/Video storyboard + headless mpv IPC playback controls & external handoff
;; - Browseable Archives, Fonts, 3D (STL/G-code) & GPS (GPX/KML) previews
;; - Folder Peek / Preview Drawer toggle (SPC / i)

;;; Code:

(require 'cl-lib)
(require 'dirvish)
(require 'shr)
(require 'subr-x)
(require 'strata-dirvish-prefs)
(require 'strata-dirvish-devices)

(declare-function strata-current-file "strata-dirvish-views" ())
(declare-function strata-open-location "strata-dirvish-panes" (loc &optional record-history))
(declare-function strata-panes--main-window "strata-dirvish-panes" (&optional pane))
(declare-function strata-computer--device-at-point "strata-dirvish-devices" ())
(declare-function strata-computer-open-at-point "strata-dirvish-devices" ())
(declare-function strata-trash-restore-at-point "strata-dirvish-devices" ())
(declare-function pdf-view-scroll-up-or-next-page "pdf-view" (&optional arg))
(declare-function pdf-view-scroll-down-or-previous-page "pdf-view" (&optional arg))
(declare-function doc-view-scroll-up-or-next-page "doc-view" (&optional arg))
(declare-function doc-view-scroll-down-or-previous-page "doc-view" (&optional arg))
(defvar strata-sidebar-window)
(defvar dirvish--selected-window)
(defvar dirvish--timers)

(defvar strata-preview-standalone-window nil
  "Reusable preview window for non-Columns or standalone Strata browser modes.")

(defvar strata-active-preview-kind 'other
  "Kind of item in preview: `text', `image', `pdf', `media', `archive', `dir'.")

(defvar strata-active-preview-file nil
  "Path of file currently previewed in Dirvish.")

(defvar strata-preview-pdf-page 1
  "Current 1-based page displayed in PDF preview.")

(defvar strata-media-proc nil "Active headless mpv playback process.")
(defvar strata-media-socket nil "Unix domain IPC socket for active mpv playback.")
(defvar strata-media-file nil "Currently loaded media path.")
(defvar strata-media-paused nil "Non-nil when media playback is paused.")
(defvar strata-media-position 0.0 "Last known playback position in seconds.")

(defconst strata-preview-max-bytes (* 512 1024)
  "Maximum bytes read directly for text/document previews.")

(defvar strata-preview--force-update nil
  "Dynamically non-nil when preview update is explicitly requested by Strata.")

(defconst strata-preview--common-mode-specs
  '(("\\.ts\\'"                              "probe.ts"        typescript-ts-mode typescript)
    ("\\.[cm]ts\\'"                          "probe.mts"       typescript-ts-mode typescript)
    ("\\.tsx\\'"                             "probe.tsx"       tsx-ts-mode        tsx)
    ("\\.go\\'"                              "probe.go"        go-ts-mode         go)
    ("\\.[cm]js\\'"                          "probe.mjs"       js-ts-mode         javascript js-mode)
    ("\\.jsonc\\'"                           "probe.jsonc"     json-ts-mode       json       js-json-mode)
    ("\\(?:CMakeLists\\.txt\\|\\.cmake\\)\\'" "CMakeLists.txt" cmake-ts-mode      cmake)
    ("\\.php\\'"                             "probe.php"       php-ts-mode        php)
    ("\\.lua\\'"                             "probe.lua"       lua-ts-mode        lua        lua-mode)
    ("\\.exs?\\'"                            "probe.ex"        elixir-ts-mode     elixir)
    ("\\.rs\\'"                              "probe.rs"        rust-ts-mode       rust       rust-mode))
  "Common extension/filename mode specs: (RE PROBE-FILE TS-MODE LANG [FALLBACK]).")

(defconst strata-preview--lang-filename-alist
  '(("elisp" . "snippet.el") ("emacs-lisp" . "snippet.el")
    ("py" . "snippet.py") ("python" . "snippet.py")
    ("nix" . "snippet.nix")
    ("sh" . "snippet.sh") ("bash" . "snippet.sh") ("zsh" . "snippet.sh")
    ("shell" . "snippet.sh") ("fish" . "snippet.sh")
    ("js" . "snippet.js") ("javascript" . "snippet.js")
    ("mjs" . "snippet.mjs") ("cjs" . "snippet.cjs")
    ("ts" . "snippet.ts") ("typescript" . "snippet.ts") ("tsx" . "snippet.tsx")
    ("jsx" . "snippet.jsx")
    ("rs" . "snippet.rs") ("rust" . "snippet.rs")
    ("go" . "snippet.go") ("golang" . "snippet.go")
    ("c" . "snippet.c") ("h" . "snippet.h")
    ("cpp" . "snippet.cpp") ("c++" . "snippet.cpp") ("hpp" . "snippet.hpp")
    ("css" . "snippet.css") ("scss" . "snippet.scss")
    ("html" . "snippet.html") ("xml" . "snippet.xml")
    ("json" . "snippet.json") ("jsonc" . "snippet.jsonc")
    ("yaml" . "snippet.yaml") ("yml" . "snippet.yml") ("toml" . "snippet.toml")
    ("sql" . "snippet.sql") ("lua" . "snippet.lua")
    ("rb" . "snippet.rb") ("ruby" . "snippet.rb") ("java" . "snippet.java")
    ("php" . "snippet.php") ("cmake" . "snippet.cmake")
    ("dockerfile" . "Dockerfile") ("make" . "Makefile") ("makefile" . "Makefile")
    ("ini" . "snippet.ini") ("conf" . "snippet.conf") ("org" . "snippet.org"))
  "Map fenced-code language identifiers to representative filenames.")

(defun strata-preview--ensure-common-auto-modes ()
  "Register available built-in `*-ts-mode' / fallback modes in `auto-mode-alist'.
Only binds extensions that are not already handled by a specific non-generic
major mode so user preferences in `init.el' remain untouched."
  (dolist (spec strata-preview--common-mode-specs)
    (let* ((re (nth 0 spec))
           (probe-name (nth 1 spec))
           (ts-mode (nth 2 spec))
           (ts-lang (nth 3 spec))
           (fb-mode (nth 4 spec))
           (existing (assoc-default probe-name auto-mode-alist #'string-match-p))
           (ts-ok (and (or (fboundp ts-mode) (locate-library (symbol-name ts-mode)))
                       (fboundp 'treesit-language-available-p)
                       (treesit-language-available-p ts-lang)))
           (chosen (cond
                    (ts-ok
                     (ignore-errors (require ts-mode nil t))
                     (and (fboundp ts-mode) ts-mode))
                    ((and fb-mode (or (fboundp fb-mode) (locate-library (symbol-name fb-mode))))
                     fb-mode))))
      (when (and chosen
                 (or (null existing)
                     (memq existing '(fundamental-mode text-mode prog-mode))))
        (add-to-list 'auto-mode-alist (cons re chosen))))))

(defun strata-preview--fontify-current-buffer (virtual-file)
  "Apply syntax highlighting in current buffer for VIRTUAL-FILE.
Returns fontified `buffer-string' with realized `face' text properties."
  (strata-preview--ensure-common-auto-modes)
  (unwind-protect
      (let ((buffer-file-name virtual-file)
            (enable-dir-local-variables nil)
            (enable-local-variables :safe)
            (inhibit-message t)
            (delay-mode-hooks t)
            (vc-handled-backends nil))
        (setq-local delay-mode-hooks t)
        (ignore-errors (set-auto-mode t))
        (when (derived-mode-p 'fundamental-mode)
          ;; Retry with downcased extension in case filename had uppercase suffix.
          (let ((ext (file-name-extension virtual-file)))
            (when (and ext (not (string= ext (downcase ext))))
              (let ((buffer-file-name (concat (file-name-sans-extension virtual-file)
                                              "." (downcase ext))))
                (ignore-errors (set-auto-mode t))))))
        (when (or font-lock-defaults
                  (and (fboundp 'treesit-parser-list) (treesit-parser-list)))
          (font-lock-mode 1)
          (ignore-errors
            (font-lock-ensure (point-min) (min (point-max) strata-preview-max-bytes))))
        (buffer-string))
    ;; Never allow ephemeral preview buffer to match `find-buffer-visiting'.
    (setq buffer-file-name nil)))

(defun strata-preview--fontify-string (text virtual-file)
  "Return TEXT syntax-highlighted according to VIRTUAL-FILE's major mode."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (strata-preview--fontify-current-buffer virtual-file)))

(defun strata-preview--preview-buffer-p (buf &optional dv)
  "Return non-nil when BUF is a Strata/Dirvish preview or placeholder buffer."
  (when (buffer-live-p buf)
    (let ((nm (buffer-name buf)))
      (or (and dv (or (memq buf (dv-preview-buffers dv))
                      (memq buf (dv-special-buffers dv))))
          (string-prefix-p "PREVIEW :: " nm)
          (string-prefix-p " *Dirvish-preview-" nm)
          (string-prefix-p "*dirvish-preview@" nm)
          (string-prefix-p " *dirvish-preview@" nm)
          (string-prefix-p " *Strata-Preview" nm)
          (string-prefix-p " *preview-temp*" nm)
          (string= nm "*Strata Preview*")))))

(defun strata-preview--setup-dirvish-fontlock-h ()
  "Materialize font-lock faces immediately in Dirvish `PREVIEW ::' buffers."
  (when (or font-lock-defaults
            (and (fboundp 'treesit-parser-list) (treesit-parser-list)))
    (font-lock-mode 1)
    (ignore-errors
      (font-lock-ensure (point-min) (min (point-max) strata-preview-max-bytes)))))

(defun strata-preview--guard-dirvish-update (orig-fn dv index)
  "Prevent background Dirvish preview updates from clobbering focused panes.
Also attaches `strata-preview-read-mode' metadata to newly updated previews."
  (let* ((ctx (when (strata-preview--browser-window-p (selected-window))
                (strata-preview--capture-browser-context (selected-window))))
         (pwin (and dv (dv-preview-window dv)))
         (pbuf (and (window-live-p pwin) (window-buffer pwin)))
         (pbuf-file (and (buffer-live-p pbuf)
                         (buffer-local-value 'buffer-file-name pbuf)))
         (pbuf-edit (and (buffer-live-p pbuf)
                         (buffer-local-value 'strata-preview-edit-mode pbuf)))
         (pbuf-read (and (buffer-live-p pbuf)
                         (buffer-local-value 'strata-preview-read-mode pbuf)))
         (preview-focused
          (and (window-live-p pwin)
               (eq (selected-window) pwin)
               (buffer-live-p pbuf)
               (or pbuf-edit pbuf-read)))
         (browser-browsing-other
          (and (window-live-p pwin)
               (not (eq (selected-window) pwin))
               (eq (selected-window) (dv-root-window dv))
               pbuf-edit
               (stringp index)
               (not (equal (and pbuf-file (ignore-errors (file-truename pbuf-file)))
                           (ignore-errors (file-truename index)))))))
    (when (or strata-preview--force-update
              (and (not preview-focused)
                   (or (not (buffer-live-p pbuf))
                       (strata-preview--preview-buffer-p pbuf dv)
                       browser-browsing-other)))
      (when (and browser-browsing-other (buffer-live-p pbuf))
        (with-current-buffer pbuf
          (strata-preview-edit-mode -1)))
      (funcall orig-fn dv index)
      (when-let ((nbuf (and (window-live-p pwin) (window-buffer pwin))))
        (strata-preview--sync-read-buffer pwin nbuf ctx)))))

(strata-preview--ensure-common-auto-modes)
(add-hook 'dirvish-preview-setup-hook #'strata-preview--setup-dirvish-fontlock-h)
(when (fboundp 'dirvish--preview-update)
  (advice-add 'dirvish--preview-update :around #'strata-preview--guard-dirvish-update))

;;;; Independent Per-Type Zoom Controls (Text / Image / PDF)

(defun strata-preview--refresh-now ()
  "Force immediate re-render of active Dirvish preview buffer."
  (when-let ((dv (ignore-errors (dirvish-curr))))
    (when (and dv (window-live-p (dv-preview-window dv)) strata-active-preview-file)
      ;; Invalidate cached special preview buffers when zooming images/PDFs
      (when (memq strata-active-preview-kind '(image pdf))
        (dolist (b (buffer-list))
          (when (string-prefix-p " *Dirvish-preview-" (buffer-name b))
            (kill-buffer b))))
      (let ((strata-preview--force-update t))
        (dirvish--preview-update dv strata-active-preview-file)))))

(defun strata-preview-zoom-in ()
  "Zoom in ONLY the currently active preview type (`text', `image', or `pdf')."
  (interactive)
  (let ((p (strata-prefs)))
    (pcase strata-active-preview-kind
      ('image
       (let ((next (min 4.0 (* (strata-prefs-preview-image-scale p) 1.2))))
         (setf (strata-prefs-preview-image-scale p) next)
         (strata-prefs-save)
         (strata-preview--refresh-now)
         (message "Image preview zoom: %.0f%%" (* 100 next))))
      ('pdf
       (let ((next (min 3.0 (* (strata-prefs-preview-pdf-scale p) 1.15))))
         (setf (strata-prefs-preview-pdf-scale p) next)
         (strata-prefs-save)
         (strata-preview--refresh-now)
         (message "PDF preview zoom: %.0f%%" (* 100 next))))
      (_
       (let ((next (min 10 (1+ (strata-prefs-preview-text-scale p)))))
         (setf (strata-prefs-preview-text-scale p) next)
         (strata-prefs-save)
         (strata-preview--apply-text-zoom)
         (message "Text preview scale: %+d" next))))))

(defun strata-preview-zoom-out ()
  "Zoom out ONLY the currently active preview type (`text', `image', or `pdf')."
  (interactive)
  (let ((p (strata-prefs)))
    (pcase strata-active-preview-kind
      ('image
       (let ((next (max 0.25 (/ (strata-prefs-preview-image-scale p) 1.2))))
         (setf (strata-prefs-preview-image-scale p) next)
         (strata-prefs-save)
         (strata-preview--refresh-now)
         (message "Image preview zoom: %.0f%%" (* 100 next))))
      ('pdf
       (let ((next (max 0.5 (/ (strata-prefs-preview-pdf-scale p) 1.15))))
         (setf (strata-prefs-preview-pdf-scale p) next)
         (strata-prefs-save)
         (strata-preview--refresh-now)
         (message "PDF preview zoom: %.0f%%" (* 100 next))))
      (_
       (let ((next (max -5 (1- (strata-prefs-preview-text-scale p)))))
         (setf (strata-prefs-preview-text-scale p) next)
         (strata-prefs-save)
         (strata-preview--apply-text-zoom)
         (message "Text preview scale: %+d" next))))))

(defun strata-preview-zoom-reset ()
  "Reset zoom for the currently active preview type back to 100% / 0."
  (interactive)
  (let ((p (strata-prefs)))
    (pcase strata-active-preview-kind
      ('image
       (setf (strata-prefs-preview-image-scale p) 1.0)
       (strata-prefs-save)
       (strata-preview--refresh-now)
       (message "Image preview zoom reset (100%%)"))
      ('pdf
       (setf (strata-prefs-preview-pdf-scale p) 1.0)
       (strata-prefs-save)
       (strata-preview--refresh-now)
       (message "PDF preview zoom reset (100%%)"))
      (_
       (setf (strata-prefs-preview-text-scale p) 0)
       (strata-prefs-save)
       (strata-preview--apply-text-zoom)
       (message "Text preview zoom reset (0)")))))

(defun strata-preview--apply-text-zoom ()
  "Apply independent `preview-text-scale' to the active preview window's buffer."
  (when-let* ((dv (ignore-errors (dirvish-curr)))
              (win (and dv (dv-preview-window dv)))
              (buf (and (window-live-p win) (window-buffer win))))
    (with-current-buffer buf
      (when (fboundp 'text-scale-set)
        (text-scale-set (strata-prefs-preview-text-scale (strata-prefs))))
      (setq-local truncate-lines (not (strata-prefs-preview-text-wrap (strata-prefs)))))))

(defun strata-toggle-rendered-document ()
  "Toggle Rendered Document view vs Raw Source view (`V')."
  (interactive)
  (let ((p (strata-prefs)))
    (setf (strata-prefs-render-documents-by-default p)
          (not (strata-prefs-render-documents-by-default p)))
    (strata-prefs-save)
    (strata-preview--refresh-now)
    (message "Document preview mode: %s"
             (if (strata-prefs-render-documents-by-default p) "Rendered" "Source"))))

(defun strata-toggle-preview-wrap ()
  "Toggle soft line wrapping inside preview buffer (`W')."
  (interactive)
  (let ((p (strata-prefs)))
    (setf (strata-prefs-preview-text-wrap p) (not (strata-prefs-preview-text-wrap p)))
    (strata-prefs-save)
    (strata-preview--apply-text-zoom)
    (message "Preview wrap: %s" (if (strata-prefs-preview-text-wrap p) "ON" "OFF"))))

(defun strata-preview--render-source-file (file out-buf)
  "Render syntax-highlighted source/text FILE preview into OUT-BUF cleanly."
  (let* ((ext (downcase (or (file-name-extension file) "")))
         (disabled (and (boundp 'dirvish-preview-disabled-exts)
                        (member ext dirvish-preview-disabled-exts)))
         (binary-ext (and (boundp 'dirvish-binary-exts)
                          (member ext dirvish-binary-exts)))
         (attrs (ignore-errors (file-attributes file)))
         (size (and attrs (file-attribute-size attrs))))
    (setq strata-active-preview-file file
          strata-active-preview-kind 'text)
    (with-current-buffer out-buf
      (special-mode)
      (font-lock-mode -1)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (cond
         ((strata-path-unsafe-probe-p file)
          (insert (propertize
                   (format "  Remote / Cloud / External mount: %s\n\n  Auto-preview skipped (press RET to open).\n"
                           (file-name-nondirectory file))
                   'face 'shadow)))
         ((or disabled binary-ext)
          (insert (propertize
                   (format "  Preview skipped for binary/disabled filetype [.%s]: %s\n"
                           ext (file-name-nondirectory file))
                   'face 'shadow)))
         ((and size (> size (or large-file-warning-threshold 10000000)))
          (insert (propertize
                   (format "  File too large for preview (%s): press RET to open.\n"
                           (file-size-human-readable size))
                   'face 'shadow)))
         ((file-readable-p file)
          (let* ((raw (with-temp-buffer
                        (insert-file-contents file nil 0 strata-preview-max-bytes)
                        (buffer-string)))
                 (head (substring raw 0 (min 4096 (length raw)))))
            (if (string-match-p "\0" head)
                (insert (propertize
                         (format "  Binary file preview skipped: %s\n"
                                 (file-name-nondirectory file))
                         'face 'shadow))
              (insert (strata-preview--fontify-string raw file))
              (when (and size (> size strata-preview-max-bytes))
                (insert (propertize "\n\n  File truncated. End of partial preview.\n"
                                    'face 'shadow))))))
         (t
          (insert (propertize (format "  Unreadable file: %s\n" (file-name-nondirectory file))
                              'face 'shadow)))))
      (setq-local truncate-lines (not (strata-prefs-preview-text-wrap (strata-prefs))))
      (when (fboundp 'text-scale-set)
        (text-scale-set (strata-prefs-preview-text-scale (strata-prefs))))
      (goto-char (point-min)))))

(defun strata-preview-update-standalone (file &optional window)
  "Render rich preview for FILE into `*Strata Preview*' inside WINDOW."
  (let* ((ctx (when (strata-preview--browser-window-p (selected-window))
                (strata-preview--capture-browser-context (selected-window))))
         (ext (downcase (or (file-name-extension file) "")))
         (win (or window (get-buffer-window "*Strata Preview*") (selected-window)))
         (res (or (dirvish-strata-rich-image-dp file ext win nil)
                  (dirvish-strata-rich-pdf-dp file ext win nil)
                  (dirvish-strata-rich-document-dp file ext win nil)))
         (out-buf (get-buffer-create "*Strata Preview*")))
    (pcase res
      (`(buffer . ,b)
       (setq strata-active-preview-file file)
       (with-current-buffer out-buf
         (special-mode)
         (font-lock-mode -1)
         (let ((inhibit-read-only t))
           (erase-buffer)
           (insert-buffer-substring b))
         (setq-local truncate-lines (not (strata-prefs-preview-text-wrap (strata-prefs))))
         (when (fboundp 'text-scale-set)
           (text-scale-set (strata-prefs-preview-text-scale (strata-prefs))))
         (goto-char (point-min))))
      (`(shell . ,cmd)
       (setq strata-active-preview-file file)
       (with-current-buffer out-buf
         (special-mode)
         (font-lock-mode -1)
         (let ((inhibit-read-only t))
           (erase-buffer)
           (apply #'process-file (car cmd) nil t nil (cdr cmd)))
         (goto-char (point-min))))
      (_
       (if (file-directory-p file)
           (with-current-buffer out-buf
             (special-mode)
             (font-lock-mode -1)
             (let ((inhibit-read-only t))
               (erase-buffer)
               (if (strata-path-unsafe-probe-p file)
                   (insert (propertize (format "  Remote / Cloud / External mount: %s\n\n  Auto-preview skipped (press RET to open).\n"
                                               (file-name-nondirectory (directory-file-name file)))
                                       'face 'shadow))
                 (let ((items (ignore-errors (directory-files file nil "\\`[^.]" t))))
                   (insert (concat "  "
                                   (strata-icon-glyph 'folder 'strata-header-accent)
                                   (propertize (format " %s (%d items)\n\n"
                                                       (file-name-nondirectory (directory-file-name file))
                                                       (length items))
                                               'face 'strata-header-accent)))
                   (dolist (it (seq-take items 60))
                     (let* ((sub (expand-file-name it file))
                            (dirp (file-directory-p sub))
                            (row (format "   %s  %s\n"
                                         (strata-icon-glyph (if dirp 'folder 'file))
                                         it)))
                       (when dirp
                         (let ((km (make-sparse-keymap)))
                           (define-key km [mouse-1]
                                       (lambda (ev)
                                         (interactive "e")
                                         (when (fboundp 'strata-open-location)
                                           (when (posn-window (event-end ev))
                                             (select-window (posn-window (event-end ev))))
                                           (strata-open-location sub t))))
                           (strata-add-row-properties
                            row (list 'mouse-face 'highlight
                                      'pointer 'hand
                                      'keymap km
                                      'help-echo sub))))
                       (insert row))))))
             (goto-char (point-min)))
         (strata-preview--render-source-file file out-buf))))
    (when (window-live-p win)
      (set-window-buffer win out-buf)
      (strata-preview--sync-read-buffer win out-buf ctx))))

(defun strata-scroll-preview-down ()
  "Scroll preview window down (`J')."
  (interactive)
  (let ((win (or (when-let ((dv (ignore-errors (dirvish-curr)))) (dv-preview-window dv))
                 (get-buffer-window "*Strata Preview*"))))
    (when (window-live-p win)
      (with-selected-window win (scroll-up-command 5)))))

(defun strata-scroll-preview-up ()
  "Scroll preview window up (`K')."
  (interactive)
  (let ((win (or (when-let ((dv (ignore-errors (dirvish-curr)))) (dv-preview-window dv))
                 (get-buffer-window "*Strata Preview*"))))
    (when (window-live-p win)
      (with-selected-window win (scroll-down-command 5)))))

(defun strata-preview--split-standalone-window (main)
  "Create a normal (non-side) right preview window split from MAIN."
  (let* ((left-w (max 24 (round (* (window-total-width main) 0.58))))
         (pwin (split-window main left-w 'right)))
    (set-window-buffer pwin (get-buffer-create "*Strata Preview*"))
    (setq strata-preview-standalone-window pwin)
    pwin))

(defun strata-preview--ensure-window (&optional allow-split)
  "Return active preview window without altering layout unless ALLOW-SPLIT."
  (let* ((dv (ignore-errors (dirvish-curr)))
         (sidebar (bound-and-true-p strata-sidebar-window))
         (cur (selected-window))
         (dv-pwin (and dv (dv-preview-window dv))))
    (cond
     ((and (window-live-p dv-pwin)
           (not (eq dv-pwin cur))
           (not (eq dv-pwin sidebar)))
      dv-pwin)
     ((and allow-split
           dv
           (derived-mode-p 'dired-mode)
           (eq (strata-prefs-browser-mode (strata-prefs)) 'columns)
           (null (dv-curr-layout dv)))
      (dirvish-layout-toggle)
      (when (window-live-p cur)
        (select-window cur t))
      (let ((w (dv-preview-window dv)))
        (and (window-live-p w) w)))
     ((and (window-live-p strata-preview-standalone-window)
           (not (eq strata-preview-standalone-window cur))
           (not (eq strata-preview-standalone-window sidebar)))
      strata-preview-standalone-window)
     ((when-let ((w (get-buffer-window "*Strata Preview*")))
        (when (and (window-live-p w)
                   (not (eq w cur))
                   (not (eq w sidebar)))
          (setq strata-preview-standalone-window w))))
     (allow-split
      (strata-preview--split-standalone-window cur)))))

(defun strata-preview--cancel-delay ()
  "Cancel any pending Dirvish preview delay timer."
  (when (fboundp 'dirvish--run-with-delay)
    (dirvish--run-with-delay 'reset))
  (when (boundp 'dirvish--timers)
    (when-let ((rec (plist-get dirvish--timers :default)))
      (when (timerp (car rec))
        (cancel-timer (car rec))))))

(defun strata-preview--dispatch-dirvish-or-standalone (dv file pwin)
  "Update preview of FILE in PWIN via DV when live, else standalone previewer.
Never mistakes `dirvish--preview-update' (which returns nil from
`set-window-buffer') for failure."
  (let* ((root (and dv (cdr (dv-index dv))))
         (has-dps (and dv (eq pwin (dv-preview-window dv))
                       (buffer-live-p root)
                       (with-current-buffer root (dirvish-prop :preview-dps)))))
    (if has-dps
        (progn
          (with-current-buffer root
            (dirvish-prop :index file))
          (strata-preview--cancel-delay)
          (let ((strata-preview--force-update t))
            (dirvish--preview-update dv file))
          ;; Fall back only if Dirvish left PWIN empty or on an initial placeholder.
          (let ((cur-pbuf (and (window-live-p pwin) (window-buffer pwin))))
            (when (or (not (buffer-live-p cur-pbuf))
                      (let ((nm (buffer-name cur-pbuf)))
                        (or (string-prefix-p "*dirvish-preview@" nm)
                            (string-prefix-p " *dirvish-preview@" nm))))
              (strata-preview-update-standalone file pwin))))
      (strata-preview-update-standalone file pwin))))

(defun strata-preview--show-at-point (&optional focus-read-only)
  "Render item at point into the preview pane.
When FOCUS-READ-ONLY is non-nil, enter the preview pane in
`strata-preview-read-mode' (`<right>').  Otherwise stay in the browser (`SPC')."
  (let* ((f (or (strata-current-file)
                (and (derived-mode-p 'strata-computer-mode)
                     (let ((dev (ignore-errors (strata-computer--device-at-point))))
                       (and dev (strata-device-mounted-p dev)
                            (strata-device-mountpoint dev))))))
         (dv (ignore-errors (dirvish-curr)))
         (cur (selected-window))
         (ctx (strata-preview--capture-browser-context cur)))
    (unless f
      (user-error "No entry to preview at point"))
    (when-let ((pwin (strata-preview--ensure-window t)))
      (let* ((pbuf (and (window-live-p pwin) (window-buffer pwin)))
             (already-editing
              (and focus-read-only
                   (buffer-live-p pbuf)
                   (buffer-local-value 'strata-preview-edit-mode pbuf)
                   (buffer-modified-p pbuf)))
             (cur-file-p
              (and strata-active-preview-file
                   (stringp f)
                   (equal (ignore-errors (file-truename strata-active-preview-file))
                          (ignore-errors (file-truename f))))))
        (unless (and focus-read-only
                     (or already-editing
                         (and cur-file-p
                              (buffer-live-p pbuf)
                              (strata-preview--preview-buffer-p pbuf dv)
                              (not (string-prefix-p "*dirvish-preview@" (buffer-name pbuf)))
                              (not (string-prefix-p " *dirvish-preview@" (buffer-name pbuf))))))
          (strata-preview--dispatch-dirvish-or-standalone dv f pwin))
        (let ((target-buf (and (window-live-p pwin) (window-buffer pwin))))
          (when (and focus-read-only (buffer-live-p target-buf))
            (unless already-editing
              (with-current-buffer target-buf
                (when (bound-and-true-p strata-preview-edit-mode)
                  (strata-preview-edit-mode -1))
                (setq strata-preview--file f))
              (strata-preview--sync-read-buffer pwin target-buf ctx)))
          (if focus-read-only
              (when (window-live-p pwin)
                (select-window pwin)
                (message "Preview Read-Only: ↑↓/PgUp/PgDn scroll · C-<left> back to browser"))
            (when (window-live-p cur)
              (select-window cur t))))))))

(defun strata-preview-at-point ()
  "Preview item at point inside the preview pane without closing it (`SPC')."
  (interactive)
  (strata-preview--show-at-point nil))

(defvar strata-preview--last-browser-context nil
  "Last captured Strata browser window context (:win :buf :dir :view).")

(defvar-local strata-preview--file nil
  "Source path associated with a preview buffer for browser restoration.")

(defvar-local strata-preview-edit--browser-window nil
  "Browser window to return to when leaving preview-pane read/edit mode.")

(defvar-local strata-preview-edit--browser-buffer nil
  "Browser buffer to restore when closing a maximized preview buffer.")

(defvar-local strata-preview-edit--browser-dir nil
  "Browser directory to reopen when closing a maximized preview buffer.")

(defvar-local strata-preview-edit--browser-view nil
  "Strata browser view mode active before entering the preview pane.")

(defvar-local strata-preview-edit--preview-window nil
  "Preview window hosting read-only preview or direct edit buffer.")

(defvar strata-preview-edit--returning nil
  "Non-nil while programmatically leaving preview-pane read/edit mode.")

(defun strata-preview--browser-window-p (&optional win)
  "Return non-nil when WIN is a Strata/Dired browser pane (not preview/aux)."
  (let ((w (or win (selected-window))))
    (when (window-live-p w)
      (let ((buf (window-buffer w)))
        (and (buffer-live-p buf)
             (not (strata-preview--preview-buffer-p buf))
             (not (eq w (bound-and-true-p strata-sidebar-window)))
             (with-current-buffer buf
               (derived-mode-p 'dired-mode
                               'strata-compact-mode
                               'strata-icons-mode
                               'strata-computer-mode
                               'strata-trash-mode
                               'strata-search-mode)))))))

(defun strata-preview--preview-window-p (&optional win)
  "Return non-nil when WIN is hosting a Strata or Dirvish preview pane."
  (let ((w (or win (selected-window))))
    (when (window-live-p w)
      (let ((buf (window-buffer w)))
        (or (eq w (bound-and-true-p strata-preview-standalone-window))
            (when-let ((dv (ignore-errors (dirvish-curr))))
              (eq w (dv-preview-window dv)))
            (and (boundp 'dirvish--sessions)
                 (hash-table-p dirvish--sessions)
                 (cl-loop for dv being the hash-values of dirvish--sessions
                          thereis (eq w (dv-preview-window dv))))
            (and (buffer-live-p buf)
                 (strata-preview--preview-buffer-p buf)))))))

(defun strata-preview--capture-browser-context (&optional win)
  "Capture browser window/buffer/directory/view context from WIN."
  (let ((w (or win (selected-window))))
    (when (strata-preview--browser-window-p w)
      (let* ((bbuf (window-buffer w))
             (bdir (with-current-buffer bbuf
                     (or (bound-and-true-p strata-view-directory)
                         (ignore-errors (dirvish-prop :root))
                         default-directory)))
             (bview (when (fboundp 'strata-prefs)
                      (strata-prefs-browser-mode (strata-prefs))))
             (ctx (list :win w :buf bbuf :dir bdir :view bview)))
        (setq strata-preview--last-browser-context ctx)
        ctx))))

(defun strata-preview--apply-browser-context (buf ctx pwin)
  "Store browser context CTX and PWIN on preview buffer BUF."
  (let* ((resolved (or (and (window-live-p (plist-get ctx :win))
                            (not (eq (plist-get ctx :win) pwin))
                            ctx)
                       (and (window-live-p (plist-get strata-preview--last-browser-context :win))
                            (not (eq (plist-get strata-preview--last-browser-context :win) pwin))
                            strata-preview--last-browser-context)
                       ctx))
         (bwin (plist-get resolved :win))
         (bbuf (plist-get resolved :buf))
         (bdir (plist-get resolved :dir))
         (bview (plist-get resolved :view)))
    (with-current-buffer buf
      (when (and (window-live-p bwin) (not (eq bwin pwin)))
        (setq strata-preview-edit--browser-window bwin))
      (when (buffer-live-p bbuf)
        (setq strata-preview-edit--browser-buffer bbuf))
      (when bdir
        (setq strata-preview-edit--browser-dir bdir))
      (when bview
        (setq strata-preview-edit--browser-view bview))
      (when (window-live-p pwin)
        (setq strata-preview-edit--preview-window pwin)))))

(defun strata-preview--read-buffer-eligible-p (buf &optional dv)
  "Return non-nil if BUF in a preview pane should carry `strata-preview-read-mode'."
  (and (buffer-live-p buf)
       (not (buffer-local-value 'strata-preview-edit-mode buf))
       (or (buffer-local-value 'buffer-read-only buf)
           (strata-preview--preview-buffer-p buf dv)
           (and dv (memq buf (dv-preview-buffers dv))))))

(defun strata-preview--sync-read-buffer (pwin buf &optional ctx)
  "Attach `strata-preview-read-mode' and browser context onto BUF in PWIN."
  (when (and (window-live-p pwin) (buffer-live-p buf))
    (let ((dv (or (ignore-errors (dirvish-curr))
                  (and (boundp 'dirvish--sessions)
                       (hash-table-p dirvish--sessions)
                       (cl-loop for s being the hash-values of dirvish--sessions
                                when (eq pwin (dv-preview-window s))
                                return s)))))
      (when (strata-preview--read-buffer-eligible-p buf dv)
        (with-current-buffer buf
          (when (and strata-active-preview-file (not strata-preview--file))
            (setq strata-preview--file strata-active-preview-file))
          (unless strata-preview-read-mode
            (strata-preview-read-mode 1))
          (setq buffer-read-only t)
          (unless cursor-type
            (setq-local cursor-type t)))
        (strata-preview--apply-browser-context buf ctx pwin)))))

(defun strata-preview--on-window-selection-change (&optional frame)
  "Track browser context or enter read-only navigation when preview is selected."
  (let ((win (frame-selected-window frame)))
    (when (window-live-p win)
      (cond
       ((strata-preview--browser-window-p win)
        (strata-preview--capture-browser-context win))
       ((strata-preview--preview-window-p win)
        (let ((buf (window-buffer win)))
          (when (and (buffer-live-p buf)
                     (not (buffer-local-value 'strata-preview-edit-mode buf)))
            (strata-preview--sync-read-buffer
             win buf strata-preview--last-browser-context))))))))

(add-hook 'window-selection-change-functions #'strata-preview--on-window-selection-change)

(defun strata-preview-read-scroll-down ()
  "Scroll read-only preview buffer forward (`SPC')."
  (interactive)
  (cond
   ((derived-mode-p 'pdf-view-mode) (call-interactively #'pdf-view-scroll-up-or-next-page))
   ((derived-mode-p 'doc-view-mode) (call-interactively #'doc-view-scroll-up-or-next-page))
   ((derived-mode-p 'image-mode) (call-interactively #'image-scroll-up))
   (t (call-interactively #'scroll-up-command))))

(defun strata-preview-read-scroll-up ()
  "Scroll read-only preview buffer backward (`DEL' / `S-SPC')."
  (interactive)
  (cond
   ((derived-mode-p 'pdf-view-mode) (call-interactively #'pdf-view-scroll-down-or-previous-page))
   ((derived-mode-p 'doc-view-mode) (call-interactively #'doc-view-scroll-down-or-previous-page))
   ((derived-mode-p 'image-mode) (call-interactively #'image-scroll-down))
   (t (call-interactively #'scroll-down-command))))

(defun strata-preview-read-leave ()
  "Leave read-only preview pane and return to the left browser window (`C-<left>')."
  (interactive)
  (strata-preview--return-to-browser nil))

(defvar strata-preview-read-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-<left>") #'strata-preview-read-leave)
    (define-key map (kbd "C-c q") #'strata-preview-read-leave)
    (define-key map (kbd "C-<escape>") #'strata-preview-read-leave)
    (define-key map (kbd "q") #'strata-preview-read-leave)
    (define-key map (kbd "SPC") #'strata-preview-read-scroll-down)
    (define-key map (kbd "S-SPC") #'strata-preview-read-scroll-up)
    (define-key map (kbd "DEL") #'strata-preview-read-scroll-up)
    (define-key map (kbd "<backspace>") #'strata-preview-read-scroll-up)
    map)
  "Keymap active while navigating Strata's preview pane in read-only mode.")

(define-minor-mode strata-preview-read-mode
  "Minor mode active while reading/scrolling inside Strata's preview pane.
Keeps the buffer strictly read-only, enables keyboard scrolling, and binds
`C-<left>' (`C-c q', `q') to return to the previous browser pane."
  :lighter " Preview-RO"
  :keymap strata-preview-read-mode-map
  (if strata-preview-read-mode
      (progn
        (setq-local buffer-read-only t)
        (unless cursor-type
          (setq-local cursor-type t))
        (add-hook 'kill-buffer-hook #'strata-preview-edit--on-kill nil t))
    (remove-hook 'kill-buffer-hook #'strata-preview-edit--on-kill t)))

(defun strata-preview-enter-at-point ()
  "Preview item at point and enter it read-only (`<right>')."
  (interactive)
  (strata-preview--show-at-point t))

(defvar strata-preview-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-<left>") #'strata-preview-edit-leave)
    (define-key map (kbd "C-c q") #'strata-preview-edit-exit)
    (define-key map (kbd "C-<escape>") #'strata-preview-edit-exit)
    (define-key map (kbd "C-c k") #'strata-preview-edit-abort)
    map)
  "Keymap active while direct-editing a file in Strata's preview pane.")

(defun strata-preview-edit--restore-browser (win bbuf bdir view &optional file defer-preview)
  "Restore previous Strata browser view in WIN for BBUF/BDIR in VIEW.
When FILE is non-nil, move point back to FILE and refresh Columns preview.
When DEFER-PREVIEW is non-nil, refresh Columns preview on next tick after
buffer kill finishes."
  (when (window-live-p win)
    (select-window win)
    (let ((restored nil))
      (cond
       ((buffer-live-p bbuf)
        (switch-to-buffer bbuf)
        (when (and (memq view '(icons compact))
                   (fboundp 'strata-sidebar-ensure))
          (strata-sidebar-ensure))
        (setq restored t))
       ((and bdir (file-directory-p bdir)
             (fboundp 'strata-open-location))
        (strata-open-location bdir nil)
        (when (and view (fboundp 'strata-switch-view-mode))
          (ignore-errors (strata-switch-view-mode view)))
        (setq restored t)))
      (when restored
        (let ((target-buf (window-buffer (selected-window))))
          (with-current-buffer target-buf
            (when (and file (fboundp 'strata-goto-file))
              (ignore-errors (strata-goto-file file))))
          (when (and (eq view 'columns)
                     (fboundp 'strata-preview-at-point))
            (let ((refresh
                   (lambda (b f)
                     (when (buffer-live-p b)
                       (when-let ((w (get-buffer-window b)))
                         (with-selected-window w
                           (when (and f (fboundp 'strata-goto-file))
                             (ignore-errors (strata-goto-file f)))
                           (when (ignore-errors (strata-current-file))
                             (ignore-errors (strata-preview-at-point)))))))))
              (if (and defer-preview (not noninteractive))
                  (run-at-time 0 nil refresh target-buf file)
                (funcall refresh target-buf file)))))))))

(defun strata-preview-edit--on-kill ()
  "Restore previous Dirvish view when killing a maximized (`C-x 1') preview buffer."
  (when (and (or (bound-and-true-p strata-preview-edit-mode)
                 (bound-and-true-p strata-preview-read-mode))
             (not strata-preview-edit--returning)
             (not (window-live-p strata-preview-edit--browser-window))
             (one-window-p t))
    (let ((buf (current-buffer))
          (win (selected-window))
          (bbuf strata-preview-edit--browser-buffer)
          (bdir strata-preview-edit--browser-dir)
          (view strata-preview-edit--browser-view)
          (file (or buffer-file-name strata-preview--file)))
      (when (and (eq (window-buffer win) buf)
                 (or (buffer-live-p bbuf)
                     (and bdir (file-directory-p bdir))))
        (remove-hook 'kill-buffer-hook #'strata-preview-edit--on-kill t)
        (let ((dv (and (buffer-live-p bbuf)
                       (with-current-buffer bbuf
                         (ignore-errors (dirvish-curr))))))
          (when file
            (strata-preview--invalidate-cache dv file)))
        (strata-preview-edit--restore-browser win bbuf bdir view file t)))))

(define-minor-mode strata-preview-edit-mode
  "Minor mode active while direct-editing inside Strata's preview pane.
Provides `C-<left>' (leave with save prompt), `C-c q' / `C-<escape>'
to return left, or `C-c k' to abort and discard edits."
  :lighter " Preview-Edit"
  :keymap strata-preview-edit-mode-map
  (if strata-preview-edit-mode
      (add-hook 'kill-buffer-hook #'strata-preview-edit--on-kill nil t)
    (remove-hook 'kill-buffer-hook #'strata-preview-edit--on-kill t)))

(defun strata-preview--invalidate-cache (dv file &optional kill-visiting)
  "Drop cached preview text and throwaway preview buffers for FILE in DV.
When KILL-VISITING is non-nil, also kill any unmodified preview buffers
visiting FILE (including via symlinks or across Dirvish sessions)."
  (when (and dv file)
    (when (hash-table-p (dv-preview-hash dv))
      (remhash file (dv-preview-hash dv))
      (remhash (file-truename file) (dv-preview-hash dv)))
    (when-let ((pbuf (get-buffer (format "PREVIEW :: %s :: %s"
                                         (dv-timestamp dv)
                                         (file-name-nondirectory file)))))
      (unless (buffer-modified-p pbuf)
        (setf (dv-preview-buffers dv) (delq pbuf (dv-preview-buffers dv)))
        (let (kill-buffer-query-functions)
          (kill-buffer pbuf)))))
  (when (and kill-visiting file)
    (let ((target-true (ignore-errors (file-truename (expand-file-name file))))
          (target-abs (expand-file-name file)))
      (dolist (b (buffer-list))
        (when (buffer-live-p b)
          (let ((bfile (buffer-local-value 'buffer-file-name b)))
            (when (and bfile
                       (not (buffer-modified-p b))
                       (or (and dv (memq b (dv-preview-buffers dv)))
                           (string-prefix-p "PREVIEW :: " (buffer-name b))
                           (string-prefix-p " *preview-temp*" (buffer-name b)))
                       (or (equal (expand-file-name bfile) target-abs)
                           (and target-true
                                (equal (ignore-errors (file-truename (expand-file-name bfile)))
                                       target-true))))
              (when dv
                (setf (dv-preview-buffers dv) (delq b (dv-preview-buffers dv))))
              (let (kill-buffer-query-functions)
                (kill-buffer b)))))))))

(defun strata-preview--return-to-browser (&optional mode)
  "Exit preview-pane read/edit mode and return to the neighbor left browser window.
MODE may be:
- nil: leave immediately without prompting;
- `save': run Emacs's normal save prompt (`save-some-buffers') when modified;
- `discard': prompt to confirm discarding unsaved edits and revert."
  (let* ((buf (current-buffer))
         (was-edit (bound-and-true-p strata-preview-edit-mode))
         (buf-file (or buffer-file-name strata-preview--file))
         (bwin strata-preview-edit--browser-window)
         (bbuf strata-preview-edit--browser-buffer)
         (bdir strata-preview-edit--browser-dir)
         (bview strata-preview-edit--browser-view)
         (pwin (or strata-preview-edit--preview-window (selected-window)))
         (target-win
          (or (and (window-live-p bwin)
                   (not (eq bwin pwin))
                   bwin)
              (let ((left (window-in-direction 'left pwin)))
                (and (window-live-p left)
                     (not (eq left (bound-and-true-p strata-sidebar-window)))
                     left))
              (strata-panes--main-window))))
    (when was-edit
      (pcase mode
        ('discard
         (when (buffer-modified-p buf)
           (unless (y-or-n-p (format "Discard unsaved edits in %s and abort? "
                                     (buffer-name buf)))
             (user-error "Aborted"))
           (if (and buffer-file-name (file-exists-p buffer-file-name))
               (revert-buffer t t t)
             (set-buffer-modified-p nil))))
        ('save
         (when (buffer-modified-p buf)
           (if buf-file
               (save-some-buffers nil (lambda () (eq (current-buffer) buf)))
             (when (y-or-n-p (format "Save buffer %s? " (buffer-name buf)))
               (save-buffer)))))))
    (when was-edit
      (strata-preview-edit-mode -1))
    (when (bound-and-true-p strata-preview-read-mode)
      (strata-preview-read-mode -1))
    (setq strata-preview-edit--browser-window nil
          strata-preview-edit--browser-buffer nil
          strata-preview-edit--browser-dir nil
          strata-preview-edit--browser-view nil
          strata-preview-edit--preview-window nil)
    (cond
     ((and (not (window-live-p bwin))
           (one-window-p t)
           (or (buffer-live-p bbuf)
               (and bdir (file-directory-p bdir))))
      (let ((strata-preview-edit--returning t))
        (when (and was-edit buf-file (not (buffer-modified-p buf)))
          (let ((dv (and (buffer-live-p bbuf)
                         (with-current-buffer bbuf (ignore-errors (dirvish-curr))))))
            (strata-preview--invalidate-cache dv buf-file)))
        (strata-preview-edit--restore-browser
         (selected-window) bbuf bdir bview buf-file)))
     ((window-live-p target-win)
      (select-window target-win)
      (when (boundp 'dirvish--selected-window)
        (setq dirvish--selected-window target-win))
      (when was-edit
        (let ((dv (ignore-errors (dirvish-curr))))
          (when (and buf-file (not (buffer-modified-p buf)))
            (strata-preview--invalidate-cache dv buf-file))
          (when-let ((cur-file (and (fboundp 'strata-current-file) (strata-current-file))))
            (when (and (equal cur-file buf-file) (not (buffer-modified-p buf)))
              (strata-preview--invalidate-cache dv cur-file))
            (cond
             ((and dv (window-live-p (dv-preview-window dv)))
              (strata-preview--dispatch-dirvish-or-standalone dv cur-file (dv-preview-window dv)))
             ((window-live-p pwin)
              (strata-preview-update-standalone cur-file pwin))))))))))

(defun strata-preview-edit-leave ()
  "Prompt to save changes and return to the left browser window (`C-<left>')."
  (interactive)
  (strata-preview--return-to-browser 'save))

(defun strata-preview-edit-exit ()
  "Leave preview-pane edit mode and return to the neighbor left browser window."
  (interactive)
  (strata-preview--return-to-browser nil))

(defun strata-preview-edit-abort ()
  "Discard edits (if modified) and return to the neighbor left browser window."
  (interactive)
  (strata-preview--return-to-browser 'discard))

(defun strata-preview-edit-file (file)
  "Edit FILE directly inside the preview pane without altering window layout."
  (strata-preview--ensure-common-auto-modes)
  (let* ((dv (ignore-errors (dirvish-curr)))
         (bwin (selected-window))
         (ctx (strata-preview--capture-browser-context bwin))
         (pwin (strata-preview--ensure-window t)))
    ;; Never reuse a truncated/read-only Dirvish throwaway `PREVIEW :: ...' buffer.
    (strata-preview--invalidate-cache dv file t)
    (let* ((delay-mode-hooks nil)
           (existing (find-buffer-visiting file))
           (was-preview (and existing
                             (or (and dv (memq existing (dv-preview-buffers dv)))
                                 (string-prefix-p "PREVIEW :: " (buffer-name existing)))))
           (was-read-preview (and existing
                                  (buffer-local-value 'strata-preview-read-mode existing)))
           (buf (find-file-noselect file)))
      (strata-preview--cancel-delay)
      (when dv
        (setf (dv-preview-buffers dv) (delq buf (dv-preview-buffers dv))))
      (with-current-buffer buf
        (setq-local delay-mode-hooks nil)
        (when (bound-and-true-p strata-preview-read-mode)
          (strata-preview-read-mode -1))
        (when (and (or was-preview was-read-preview)
                   (file-writable-p file)
                   buffer-read-only
                   (not (derived-mode-p 'image-mode 'pdf-view-mode 'doc-view-mode)))
          (read-only-mode -1))
        (when (and (or font-lock-defaults
                       (and (fboundp 'treesit-parser-list) (treesit-parser-list)))
                   (bound-and-true-p global-font-lock-mode))
          (font-lock-mode 1))
        (strata-preview-edit-mode 1))
      (strata-preview--apply-browser-context buf ctx pwin)
      (if (window-live-p pwin)
          (progn
            (set-window-dedicated-p pwin nil)
            (set-window-buffer pwin buf)
            (select-window pwin)
            (message "Preview Edit: C-x C-s save · C-<left> leave (prompt save) · C-c q back · C-c k abort")
            buf)
        (pop-to-buffer-same-window buf)))))

(defun strata-open-or-edit-at-point ()
  "Open folder in browser pane, or direct-edit file in preview pane (`RET')."
  (interactive)
  (cond
   ((derived-mode-p 'strata-computer-mode)
    (call-interactively #'strata-computer-open-at-point))
   ((derived-mode-p 'strata-trash-mode)
    (call-interactively #'strata-trash-restore-at-point))
   (t
    (let ((f (strata-current-file)))
      (cond
       ((and f (file-directory-p f))
        (strata-open-location f t))
       ((and f (file-exists-p f))
        (strata-preview-edit-file f))
       ((derived-mode-p 'dired-mode)
        (dired-find-file))
       (t
        (user-error "No file or folder at point")))))))

(defun strata-toggle-peek ()
  "Toggle preview drawer / peek panel (`i' / `M-i') across all 4 browser modes."
  (interactive)
  (cond
   ((or (derived-mode-p 'strata-compact-mode)
        (derived-mode-p 'strata-icons-mode)
        (not (dirvish-curr)))
    (if-let ((win (or (and (window-live-p strata-preview-standalone-window)
                           strata-preview-standalone-window)
                      (get-buffer-window "*Strata Preview*"))))
        (progn
          (delete-window win)
          (when (eq win strata-preview-standalone-window)
            (setq strata-preview-standalone-window nil)))
      (when-let ((f (strata-current-file)))
        (let ((pwin (strata-preview--split-standalone-window (selected-window))))
          (strata-preview-update-standalone f pwin)))))
   (t (dirvish-layout-toggle))))

(defun strata-preview-find ()
  "Search text inside currently displayed Dirvish preview window."
  (interactive)
  (when-let* ((dv (ignore-errors (dirvish-curr)))
              (win (and dv (dv-preview-window dv))))
    (unless (window-live-p win)
      (user-error "Preview drawer is not visible"))
    (let ((pat (read-string "Find in preview: ")))
      (when (and pat (not (string-empty-p pat)))
        (with-selected-window win
          (goto-char (point-min))
          (if (search-forward pat nil t)
              (recenter)
            (message "No match for %s in preview" pat)))))))

;;;; Preview Rendering Helpers

(defun strata-preview--make-buffer (name &optional kind)
  "Create/clear clean read-only preview buffer NAME tagging Strata KIND."
  (let ((buf (get-buffer-create name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer))
      (setq buffer-read-only t
            strata-active-preview-kind (or kind 'text))
      (setq-local truncate-lines (not (strata-prefs-preview-text-wrap (strata-prefs))))
      (when (fboundp 'text-scale-set)
        (text-scale-set (strata-prefs-preview-text-scale (strata-prefs)))))
    buf))

(defun strata-preview--safe-insert-markdown (file buf)
  "Render Markdown FILE cleanly into BUF with headings, code blocks, math & images."
  (let ((dir (file-name-directory file))
        (text (with-temp-buffer
                (insert-file-contents file nil 0 strata-preview-max-bytes)
                (buffer-string))))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (in-code nil)
            (code-lang "")
            (code-lines nil)
            (flush-code
             (lambda (buf-target lang lines-rev)
               (when lines-rev
                 (let* ((raw (concat (mapconcat #'identity (nreverse lines-rev) "\n") "\n"))
                        (virt (alist-get (downcase lang) strata-preview--lang-filename-alist
                                         nil nil #'string=))
                        (styled (if virt
                                    (strata-preview--fontify-string raw virt)
                                  raw))
                        (out-lines (split-string (string-remove-suffix "\n" styled) "\n")))
                   (with-current-buffer buf-target
                     (dolist (cl out-lines)
                       (let ((s (concat "  │ " cl "\n")))
                         (add-face-text-property 0 (length s) 'strata-preview-code t s)
                         (insert s)))))))))
        (erase-buffer)
        (insert (concat "  "
                        (strata-icon-glyph 'markdown 'strata-hint-desc)
                        (propertize (format " Markdown (Rendered · toggle [V] for Source) — %s\n\n"
                                            (file-name-nondirectory file))
                                    'face 'strata-hint-desc)))
        (dolist (line (split-string text "\n"))
          (cond
           ((string-match "\\````\\(.*\\)\\'" line)
            (if in-code
                (progn
                  (funcall flush-code buf code-lang code-lines)
                  (setq in-code nil code-lines nil)
                  (insert (propertize "  └─\n" 'face 'strata-hint-desc)))
              (setq in-code t
                    code-lines nil
                    code-lang (string-trim (match-string 1 line)))
              (insert (propertize (format "  ┌─ %s\n" (if (string-empty-p code-lang) "code" code-lang))
                                  'face 'strata-hint-desc))))
           (in-code
            (push line code-lines))
           ((string-match "\\`# \\(.+\\)\\'" line)
            (insert "\n" (propertize (match-string 1 line) 'face 'strata-preview-heading-1) "\n"))
           ((string-match "\\`## \\(.+\\)\\'" line)
            (insert "\n" (propertize (match-string 1 line) 'face 'strata-preview-heading-2) "\n"))
           ((string-match "\\`###+ \\(.+\\)\\'" line)
            (insert (propertize (match-string 1 line) 'face 'strata-preview-heading-3) "\n"))
           ((string-match "\\`!\\[\\([^]]*\\)\\](\\([^)]+\\))\\'" line)
            (let* ((alt (match-string 1 line))
                   (rel (match-string 2 line))
                   (img-path (expand-file-name rel dir)))
              (if (and (display-graphic-p) (file-readable-p img-path)
                       (image-supported-file-p img-path))
                  (let ((img (create-image img-path nil nil :max-width 480 :max-height 320)))
                    (insert "  ")
                    (insert-image img (format "[Image: %s]" alt))
                    (insert "\n"))
                (insert (concat "  " (strata-icon-glyph 'pictures 'shadow)
                                (propertize (format " [%s -> %s]\n" alt rel) 'face 'shadow))))))
           (t
            (insert "  " line "\n"))))
        (when in-code
          (funcall flush-code buf code-lang code-lines))
        (goto-char (point-min))))))

(defun strata-preview--safe-insert-html (file buf)
  "Render local HTML FILE cleanly via `shr' with remote requests disabled."
  (let ((shr-inhibit-images t)
        (shr-blocked-images ".*")
        (dom (with-temp-buffer
               (insert-file-contents file nil 0 strata-preview-max-bytes)
               (when (fboundp 'libxml-parse-html-region)
                 (libxml-parse-html-region (point-min) (point-max))))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (concat "  "
                        (strata-icon-glyph 'network 'strata-hint-desc)
                        (propertize " HTML Document (Offline Rendered · [V] Source)\n\n"
                                    'face 'strata-hint-desc)))
        (if dom (shr-insert-document dom) (insert-file-contents file nil 0 strata-preview-max-bytes))
        (goto-char (point-min))))))

(defun strata-preview--render-tabular (file ext buf)
  "Render CSV/TSV/XLSX/ODS FILE (extension EXT) as aligned sortable columns in BUF."
  (let* ((sep (if (string= ext "tsv") "\t" ","))
         (raw
          (cond
           ((member ext '("csv" "tsv"))
            (with-temp-buffer
              (insert-file-contents file nil 0 strata-preview-max-bytes)
              (buffer-string)))
           ((and (executable-find "python3") (member ext '("xlsx" "ods")))
            (with-temp-buffer
              (process-file
               "timeout" nil t nil "2" "python3" "-c"
               "import sys,zipfile,xml.etree.ElementTree as ET
p=sys.argv[1]
try:
 z=zipfile.ZipFile(p)
 if p.endswith('.xlsx'):
  ss=[]; sroot=ET.fromstring(z.read('xl/sharedStrings.xml')) if 'xl/sharedStrings.xml' in z.namelist() else None
  if sroot is not None: ss=[''.join(si.itertext()) for si in sroot]
  sh=[n for n in z.namelist() if n.startswith('xl/worksheets/sheet')][0]
  root=ET.fromstring(z.read(sh))
  for r in root.iter('{http://schemas.openxmlformats.org/spreadsheetml/2006/main}row'):
   vals=[]
   for c in r:
    t=c.attrib.get('t',''); v=c.find('{http://schemas.openxmlformats.org/spreadsheetml/2006/main}v')
    val='' if v is None or v.text is None else v.text
    if t=='s' and val.isdigit() and int(val)<len(ss): val=ss[int(val)]
    vals.append(val.replace('\\t',' '))
   print('\\t'.join(vals))
 elif p.endswith('.ods'):
  root=ET.fromstring(z.read('content.xml'))
  for tr in root.iter('{urn:oasis:names:tc:opendocument:xmlns:table:1.0}table-row')[:200]:
   vals=[''.join(tc.itertext()).strip().replace('\\t',' ') for tc in tr]
   if any(vals): print('\\t'.join(vals))
except Exception as e:
 print('Error\\t'+str(e))"
               file)
              (buffer-string)))
           (t "")))
         (lines (seq-take (split-string raw "\n" t) 250))
         (rows (mapcar (lambda (l) (split-string l (if (member ext '("xlsx" "ods")) "\t" sep)))
                       lines)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "  📊 Spreadsheet (%s · %d rows)\n\n"
                                    (upcase ext) (length rows))
                            'face 'strata-header-accent))
        (dolist (r rows)
          (insert "  "
                  (mapconcat (lambda (c) (format "%-18s" (truncate-string-to-width (string-trim c) 18 nil nil "…")))
                             (seq-take r 12) " │ ")
                  "\n"))
        (goto-char (point-min))))))

(defun strata-preview--pandoc (file buf label)
  "Convert document FILE cleanly via offline `pandoc' into BUF."
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize (format "  📃 %s (Rendered via pandoc · %s)\n\n"
                                  label (file-name-nondirectory file))
                          'face 'strata-hint-desc))
      (if (executable-find "pandoc")
          (process-file "timeout" nil t nil "3" "pandoc" "--standalone=false" "-t" "plain" file)
        (insert "pandoc not found on PATH."))
      (goto-char (point-min)))))

(defun strata-preview--media-info (file)
  "Gather concise technical badges for audio/video FILE."
  (let ((exe (or (executable-find "mediainfo") (executable-find "ffprobe"))))
    (when exe
      (with-temp-buffer
        (if (string-suffix-p "mediainfo" exe)
            (process-file "timeout" nil t nil "2" exe file)
          (process-file "timeout" nil t nil "2" exe "-v" "error"
                        "-show_entries" "format=duration,bit_rate:stream=codec_type,codec_name,width,height,r_frame_rate"
                        "-of" "default=noprint_wrappers=1" file))
        (string-trim (buffer-string))))))

(defun strata-preview--3d-or-route (file ext buf)
  "Render STL, G-code, GPX, or KML geometric/route summary into BUF."
  (let ((summary
         (if (executable-find "python3")
             (with-temp-buffer
               (process-file
                "timeout" nil t nil "2" "python3" "-c"
                "import sys,os,struct,math,xml.etree.ElementTree as ET
p,ext=sys.argv[1],sys.argv[2].lower()
try:
 if ext=='stl':
  with open(p,'rb') as f:
   hdr=f.read(84)
   if hdr.startswith(b'solid') and b'facet' in f.read(512):
    f.seek(0); txt=f.read(2000000).decode('utf-8','ignore')
    print(f'ASCII STL | facets≈{txt.count(\"facet normal\")}')
   elif len(hdr)>=84:
    n=struct.unpack('<I',hdr[80:84])[0]
    print(f'Binary STL | triangles: {n:,} | header: {hdr[:80].split(b\"\\0\")[0].decode(\"ascii\",\"ignore\")}')
 elif ext in ('gcode','gco'):
  lines=open(p,'r',errors='ignore').read(500000).splitlines()
  layers=sum(1 for l in lines if l.startswith(';LAYER:'))
  print(f'G-code | sampled lines: {len(lines):,} | layers: {layers}')
 elif ext=='gpx':
  root=ET.parse(p).getroot(); pts=[]
  for trkpt in root.iter():
   if trkpt.tag.endswith('trkpt'):
    ele=next((float(c.text) for c in trkpt if c.tag.endswith('ele') and c.text), None)
    pts.append((float(trkpt.attrib['lat']),float(trkpt.attrib['lon']),ele))
  dist=sum(6371*math.acos(max(-1,min(1,math.sin(math.radians(a[0]))*math.sin(math.radians(b[0]))+math.cos(math.radians(a[0]))*math.cos(math.radians(b[0]))*math.cos(math.radians(b[1]-a[1]))))) for a,b in zip(pts,pts[1:]))
  eles=[x[2] for x in pts if x[2] is not None]
  print(f'GPX Track | points: {len(pts):,} | distance: {dist:.2f} km'+(f\" | elev: {min(eles):.0f}..{max(eles):.0f} m\" if eles else ''))
 elif ext=='kml':
  print('KML Route | file size:', os.path.getsize(p), 'bytes')
except Exception as e:
 print('Parse note:', e)"
                file ext)
               (string-trim (buffer-string)))
           "")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (concat "  "
                        (strata-icon-glyph 'file-3d 'strata-header-accent)
                        (propertize (format "  %s Preview — %s\n\n"
                                            (upcase ext) (file-name-nondirectory file))
                                    'face 'strata-header-accent)))
        (insert "  " summary "\n")
        (goto-char (point-min))))))

;;;; Dirvish Preview Dispatchers

(dirvish-define-preview strata-mount-guard (file)
  "Prevent synchronous hover preview freezes on FUSE/cloud/remote/removable mounts."
  (when (and file (strata-path-unsafe-probe-p file))
    (let ((kind (strata-path-mount-kind file)))
      (when (or (not (eq kind 'removable))
                (file-directory-p file))
        `(info . ,(format "  %s mount: %s\n\n  Auto-preview skipped for instant startup/navigation (press RET to open)."
                          (capitalize (symbol-name (if (eq kind 'local) 'remote kind)))
                          (file-name-nondirectory (directory-file-name file))))))))

(dirvish-define-preview strata-rich-image (file ext preview-window _dv)
  "Strata Image & Camera RAW preview honoring independent `preview-image-scale' & EXIF."
  (when (and file (not (file-directory-p file))
             (member (downcase (or ext ""))
                     '("png" "jpg" "jpeg" "gif" "webp" "svg" "bmp" "tif" "tiff" "avif" "cr2" "nef" "arw" "dng")))
    (setq strata-active-preview-file file
          strata-active-preview-kind 'image)
    (let* ((scale (strata-prefs-preview-image-scale (strata-prefs)))
           (base-w (* (window-pixel-width preview-window) 0.9))
           (base-h (* (window-pixel-height preview-window) 0.78))
           (w (round (* base-w scale)))
           (h (round (* base-h scale)))
           (raw-p (member (downcase ext) '("cr2" "nef" "arw" "dng")))
           (tmp (expand-file-name (format "img-%s-%d.png" (md5 file) (round (* 100 scale)))
                                  strata-thumbnail-dir))
           (buf (strata-preview--make-buffer (format " *Dirvish-preview-img-%s*" (md5 file)) 'image)))
      (make-directory strata-thumbnail-dir t)
      (when (and (not (file-exists-p tmp)) (executable-find (if raw-p "magick" "vipsthumbnail")))
        (if raw-p
            (ignore-errors (process-file "timeout" nil nil nil "3" "magick" file "-auto-orient" "-resize" (format "%dx%d>" w h) tmp))
          (ignore-errors (process-file "timeout" nil nil nil "2" "vipsthumbnail" file "-s" (format "%dx%d" w h) "-o" tmp))))
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (img-src (if (file-exists-p tmp) tmp file)))
          (insert (concat "  "
                          (strata-icon-glyph 'pictures 'strata-header-accent)
                          (propertize (format "  %s   Zoom: %.0f%%  ([C-+/C--/C-0])\n\n"
                                              (file-name-nondirectory file) (* 100 scale))
                                      'face 'strata-header-accent)))
          (when (and (display-graphic-p) (file-readable-p img-src))
            (when-let ((img (create-image img-src nil nil :max-width w :max-height h)))
              (insert "  ")
              (insert-image img "[image]")
              (insert "\n\n")))
          (when (executable-find "exiftool")
            (insert (propertize "  Camera / EXIF\n" 'face 'strata-section-heading))
            (process-file "timeout" nil t nil "2" "exiftool" "-s" "-s" "-ImageSize" "-Make" "-Model"
                          "-LensModel" "-FocalLength" "-FNumber" "-ExposureTime" "-ISO" "-GPSPosition" file))
          (goto-char (point-min))))
      `(buffer . ,buf))))

(dirvish-define-preview strata-rich-pdf (file ext preview-window _dv)
  "Strata PDF preview honoring independent `preview-pdf-scale' & page metadata."
  (when (and file (string= (downcase (or ext "")) "pdf") (executable-find "pdftoppm"))
    (setq strata-active-preview-file file
          strata-active-preview-kind 'pdf)
    (let* ((scale (strata-prefs-preview-pdf-scale (strata-prefs)))
           (base-w (round (* (window-pixel-width preview-window) 0.88 scale)))
           (base (expand-file-name (format "pdf-%s-p%d-%d" (md5 file) strata-preview-pdf-page (round (* 100 scale)))
                                   strata-thumbnail-dir))
           (png (concat base ".png"))
           (buf (strata-preview--make-buffer (format " *Dirvish-preview-pdf-%s*" (md5 file)) 'pdf)))
      (make-directory strata-thumbnail-dir t)
      (unless (file-exists-p png)
        (ignore-errors
          (process-file "timeout" nil nil nil "3" "pdftoppm" "-png" "-singlefile"
                        "-f" (number-to-string strata-preview-pdf-page)
                        "-scale-to" (number-to-string base-w)
                        file base)))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (insert (propertize (format "  %s PDF Page %d · Zoom %.0f%%  ([C-+/C--/C-0] · [M-PgUp/Dn] Page)\n\n"
                                      (strata-icon-glyph 'file-pdf 'strata-header-accent)
                                      strata-preview-pdf-page (* 100 scale))
                              'face 'strata-header-accent))
          (when (and (display-graphic-p) (file-exists-p png))
            (when-let ((img (create-image png 'png nil :max-width base-w)))
              (insert "  ")
              (insert-image img "[pdf page]")
              (insert "\n\n")))
          (when (executable-find "pdfinfo")
            (process-file "timeout" nil t nil "2" "pdfinfo" file))
          (goto-char (point-min))))
      `(buffer . ,buf))))

(dirvish-define-preview strata-rich-document (file ext _preview-window _dv)
  "Render Markdown, Org, HTML, DOCX, ODT, RTF, CSV, XLSX, Fonts, 3D/Routes & Archives."
  (when (and file (not (file-directory-p file)))
    (let* ((ext (downcase (or ext "")))
           (p (strata-prefs))
           (rendered (strata-prefs-render-documents-by-default p)))
      (cond
       ((and rendered (member ext '("md" "markdown")))
        (setq strata-active-preview-file file strata-active-preview-kind 'text)
        (let ((buf (strata-preview--make-buffer " *Strata-Preview-Doc*" 'text)))
          (strata-preview--safe-insert-markdown file buf)
          `(buffer . ,buf)))
       ((and rendered (member ext '("html" "htm" "xhtml")))
        (setq strata-active-preview-file file strata-active-preview-kind 'text)
        (let ((buf (strata-preview--make-buffer " *Strata-Preview-Doc*" 'text)))
          (strata-preview--safe-insert-html file buf)
          `(buffer . ,buf)))
       ((and rendered (member ext '("csv" "tsv" "xlsx" "ods")))
        (setq strata-active-preview-file file strata-active-preview-kind 'text)
        (let ((buf (strata-preview--make-buffer " *Strata-Preview-Doc*" 'text)))
          (strata-preview--render-tabular file ext buf)
          `(buffer . ,buf)))
       ((and rendered (member ext '("docx" "odt" "ott" "rtf")))
        (setq strata-active-preview-file file strata-active-preview-kind 'text)
        (let ((buf (strata-preview--make-buffer " *Strata-Preview-Doc*" 'text)))
          (strata-preview--pandoc file buf (upcase ext))
          `(buffer . ,buf)))
       ((member ext '("stl" "gcode" "gco" "gpx" "kml"))
        (setq strata-active-preview-file file strata-active-preview-kind 'other)
        (let ((buf (strata-preview--make-buffer " *Strata-Preview-Doc*" 'other)))
          (strata-preview--3d-or-route file ext buf)
          `(buffer . ,buf)))
       ((member ext '("ttf" "otf" "woff" "woff2"))
        (setq strata-active-preview-file file strata-active-preview-kind 'text)
        `(shell . ("sh" "-c" "fc-query \"$1\" | head -n 40" "_" ,file)))
       ((member ext '("zip" "7z" "tar" "gz" "tgz" "zst" "xz" "bz2" "iso"))
        (setq strata-active-preview-file file strata-active-preview-kind 'archive)
        `(shell . ("7z" "l" "-ba" ,file)))
       ((member ext '("mp3" "flac" "wav" "ogg" "opus" "m4a" "aac" "mp4" "mkv" "mov" "webm" "avi"))
        (setq strata-active-preview-file file strata-active-preview-kind 'media)
        (let* ((is-vid (member ext '("mp4" "mkv" "mov" "webm" "avi")))
               (thumb (expand-file-name (format "vid-%s.jpg" (md5 file)) strata-thumbnail-dir))
               (buf (strata-preview--make-buffer " *Strata-Preview-Media*" 'media)))
          (make-directory strata-thumbnail-dir t)
          (when (and is-vid (not (file-exists-p thumb)) (executable-find "ffmpegthumbnailer"))
            (ignore-errors (process-file "timeout" nil nil nil "3" "ffmpegthumbnailer" "-i" file "-o" thumb "-s" "360" "-t" "15%")))
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (insert (concat "  "
                              (strata-icon-glyph (if is-vid 'videos 'music) 'strata-header-accent)
                              (propertize (format " %s   [C-M-SPC: Play/Pause · C-M-←/→: Seek · C-M-m: Mute · O: Open in Player]\n\n"
                                                  (file-name-nondirectory file))
                                          'face 'strata-header-accent)))
              (when (and is-vid (display-graphic-p) (file-exists-p thumb))
                (when-let ((img (create-image thumb 'jpeg nil :max-width 420)))
                  (insert "  ")
                  (insert-image img "[video frame]")
                  (insert "\n\n")))
              (insert (or (strata-preview--media-info file) "No media metadata found."))
              (goto-char (point-min))))
          `(buffer . ,buf)))
       (t
        (setq strata-active-preview-file file strata-active-preview-kind 'text)
        nil)))))

(defun strata-pdf-page-step (delta)
  "Turn PDF preview page by DELTA."
  (interactive "p")
  (setq strata-preview-pdf-page (max 1 (+ strata-preview-pdf-page delta)))
  (strata-preview--refresh-now)
  (message "PDF preview page %d" strata-preview-pdf-page))

;;;; Headless MPV IPC Playback Controls for Audio & Video Previews

(defun strata-media--ipc (json-cmd)
  "Send JSON-CMD alist to active `strata-media-socket' via netcat/python3."
  (when (and strata-media-socket (file-exists-p strata-media-socket)
             (process-live-p strata-media-proc))
    (condition-case nil
        (let ((proc (make-network-process :name "strata-mpv-ipc"
                                          :family 'local
                                          :service strata-media-socket
                                          :noquery t)))
          (process-send-string proc (concat (json-encode json-cmd) "\n"))
          (delete-process proc))
      (error nil))))

(defun strata-media-stop ()
  "Stop any running Strata preview playback process."
  (interactive)
  (when (process-live-p strata-media-proc)
    (delete-process strata-media-proc))
  (setq strata-media-proc nil
        strata-media-paused nil)
  (when (and strata-media-socket (file-exists-p strata-media-socket))
    (ignore-errors (delete-file strata-media-socket))))

(defun strata-media-play-pause ()
  "Play/pause audio or video for current item using headless `mpv' (`C-M-SPC')."
  (interactive)
  (let ((f (or (strata-current-file) strata-active-preview-file)))
    (unless (and f (file-readable-p f))
      (user-error "No media file selected"))
    (if (and (process-live-p strata-media-proc) (equal f strata-media-file))
        (progn
          (setq strata-media-paused (not strata-media-paused))
          (strata-media--ipc `((command . ["cycle" "pause"])))
          (message "Media %s: %s" (if strata-media-paused "paused" "resumed")
                   (file-name-nondirectory f)))
      (unless (executable-find "mpv")
        (user-error "mpv is not installed"))
      (strata-media-stop)
      (setq strata-media-socket (expand-file-name (format "mpv-%d.sock" (emacs-pid))
                                                  temporary-file-directory)
            strata-media-file f
            strata-media-paused nil
            strata-media-position 0.0)
      (setq strata-media-proc
            (make-process
             :name "strata-mpv"
             :noquery t
             :command (list "mpv" "--no-video" "--really-quiet"
                            (format "--volume=%d" (strata-prefs-preview-volume (strata-prefs)))
                            (if (strata-prefs-preview-muted (strata-prefs)) "--mute=yes" "--mute=no")
                            (format "--input-ipc-server=%s" strata-media-socket)
                            f)))
      (message "Playing preview: %s" (file-name-nondirectory f)))))

(defun strata-media-seek (seconds)
  "Seek active media playback by SECONDS (`C-M-left`/`C-M-right')."
  (interactive "nSeek seconds: ")
  (setq strata-media-position (max 0.0 (+ strata-media-position seconds)))
  (strata-media--ipc `((command . ["seek" ,seconds "relative"])))
  (message "Seek %+ds" seconds))

(defun strata-media-mute-toggle ()
  "Mute/unmute active Strata media preview (`C-M-m` / `m')."
  (interactive)
  (let ((p (strata-prefs)))
    (setf (strata-prefs-preview-muted p) (not (strata-prefs-preview-muted p)))
    (strata-prefs-save)
    (strata-media--ipc `((command . ["set_property" "mute" ,(if (strata-prefs-preview-muted p) t :json-false)])))
    (message "Preview audio %s" (if (strata-prefs-preview-muted p) "muted" "unmuted"))))

(defun strata-media-volume-step (delta)
  "Adjust preview audio volume by DELTA (`C-M-up`/`C-M-down`)."
  (interactive "p")
  (let* ((p (strata-prefs))
         (v (max 0 (min 150 (+ (strata-prefs-preview-volume p) delta)))))
    (setf (strata-prefs-preview-volume p) v)
    (strata-prefs-save)
    (strata-media--ipc `((command . ["set_property" "volume" ,v])))
    (message "Preview volume: %d%%" v)))

(defun strata-media-open-external ()
  "Open video/audio file in external `mpv' at last playback position."
  (interactive)
  (let ((f (or (strata-current-file) strata-media-file)))
    (unless (and f (executable-find "mpv"))
      (user-error "Cannot launch mpv for %s" f))
    (let ((pos strata-media-position))
      (strata-media-stop)
      (make-process :name "strata-mpv-ext" :noquery t
                    :command (list "mpv" (format "--start=%.1f" pos) f)))))

(provide 'strata-dirvish-previews)
;;; strata-dirvish-previews.el ends here
