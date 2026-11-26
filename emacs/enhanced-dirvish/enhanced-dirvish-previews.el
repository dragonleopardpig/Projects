;;; enhanced-dirvish-previews.el --- Rich previews, per-type zoom, media IPC, docs, 3D/GPX -*- lexical-binding: t; -*-

;; Copyright (C) 2026 dragonleopardpig
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.  It is part of Enhanced Dirvish;
;; see enhanced-dirvish.el for the full license notice.

;;; Commentary:
;; Implements Enhanced Dirvish's preview ecosystem inside Dirvish:
;; - Independent per-type zoom (text / image / pdf) via C-+/C--/C-0
;; - Rendered Markdown (with LaTeX/SVG/relative image support) & Source toggle
;; - Offline safe HTML, DOCX/ODT/RTF (pandoc), interactive CSV/TSV/XLSX tables
;; - PDF page preview & EXIF RAW/Image preview
;; - Audio/Video storyboard + headless mpv IPC playback controls & external handoff
;; - Browseable Archives, Fonts, 3D (STL/G-code) & GPS (GPX/KML) previews
;; - Folder Peek / Preview Drawer toggle (SPC / i)

;;; Code:

(defvar enhanced-dirvish-windows--changing)
(declare-function enhanced-dirvish-windows--delete "enhanced-dirvish-windows" (window))

(require 'cl-lib)
(require 'dirvish)
(require 'face-remap)
(require 'json)
(require 'mwheel)
(require 'shr)
(require 'subr-x)
(require 'url-util)
(require 'enhanced-dirvish-prefs)
(require 'enhanced-dirvish-devices)

(declare-function enhanced-dirvish-current-file "enhanced-dirvish-views" ())
(declare-function enhanced-dirvish-open-location "enhanced-dirvish-panes" (loc &optional record-history))
(declare-function enhanced-dirvish-panes--main-window "enhanced-dirvish-panes" (&optional pane))
(declare-function enhanced-dirvish-computer--device-at-point "enhanced-dirvish-devices" ())
(declare-function enhanced-dirvish-computer-open-at-point "enhanced-dirvish-devices" ())
(declare-function enhanced-dirvish-trash-restore-at-point "enhanced-dirvish-devices" ())
(declare-function pdf-view-scroll-up-or-next-page "ext:pdf-view" (&optional arg))
(declare-function pdf-view-scroll-down-or-previous-page "ext:pdf-view" (&optional arg))
(declare-function doc-view-scroll-up-or-next-page "doc-view" (&optional arg))
(declare-function doc-view-scroll-down-or-previous-page "doc-view" (&optional arg))
(declare-function image-scroll-up "image-mode" (&optional n))
(declare-function image-scroll-down "image-mode" (&optional n))
(defvar enhanced-dirvish-sidebar-window)
(defvar enhanced-dirvish-thumbnail-dir)
(defvar enhanced-dirvish-preview--file)
(defvar enhanced-dirvish-preview--last-browser-context)
(defvar enhanced-dirvish-preview-read-mode)
(defvar dirvish--selected-window)
(defvar dirvish--timers)

(defvar enhanced-dirvish-preview-standalone-window nil
  "Reusable preview window for non-Columns or standalone browser modes.")

(defvar enhanced-dirvish-active-preview-kind 'other
  "Kind of item in preview: `text', `image', `pdf', `media', `archive', `dir'.")

(defvar enhanced-dirvish-active-preview-file nil
  "Path of file currently previewed in Dirvish.")

(defvar-local enhanced-dirvish-preview--pdf-state nil
  "File, page, and metadata of the PDF shown in this preview buffer.")

(defvar-local enhanced-dirvish-preview--image-scale nil
  "Scale at which the current image preview was rendered.")

(defvar-local enhanced-dirvish-preview--document-rendered nil
  "Whether a switchable document preview currently shows its rendered view.")

(defvar enhanced-dirvish-media-proc nil "Active headless mpv playback process.")
(defvar enhanced-dirvish-media-socket nil "Unix domain IPC socket for active mpv playback.")
(defvar enhanced-dirvish-media-file nil "Currently loaded media path.")
(defvar enhanced-dirvish-media-paused nil "Non-nil when media playback is paused.")
(defvar enhanced-dirvish-media-position 0.0 "Last known playback position in seconds.")

(defconst enhanced-dirvish-preview-max-bytes (* 512 1024)
  "Maximum bytes read directly for text/document previews.")

(defvar enhanced-dirvish-preview--force-update nil
  "Dynamically non-nil when a preview update is explicitly requested.")

(defvar enhanced-dirvish-preview--applying-text-zoom nil
  "Non-nil while restoring saved text zoom during preview rendering.")

(defcustom enhanced-dirvish-markdown-mathjax-directory
  (expand-file-name "enhanced-dirvish/mathjax"
                    (or (getenv "XDG_DATA_HOME") "~/.local/share"))
  "Directory of the local MathJax bundle used for Markdown equations."
  :type 'directory
  :group 'enhanced-dirvish)

(defconst enhanced-dirvish-preview--math-script
  (expand-file-name "enhanced-dirvish-math.cjs" (file-name-directory load-file-name)))

(defvar enhanced-dirvish-preview--math-cache nil
  "Last batch of Markdown formulas and their neutral-color SVGs.")

(defvar enhanced-dirvish-preview--markdown-directory nil)
(defvar enhanced-dirvish-preview--markdown-width nil)
(defvar enhanced-dirvish-preview--math-images nil)

(defconst enhanced-dirvish-preview--common-mode-specs
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
    ("\\.nix\\'"                             "probe.nix"       nix-ts-mode        nix        nix-mode)
    ("\\.\\(?:md\\|markdown\\|mdown\\|mkd\\)\\'" "probe.md" markdown-ts-mode (markdown markdown-inline) markdown-mode)
    ("\\.rs\\'"                              "probe.rs"        rust-ts-mode       rust       rust-mode))
  "Common filename mode specs: (RE PROBE-FILE TS-MODE LANGUAGES [FALLBACK]).")

(defconst enhanced-dirvish-preview--lang-filename-alist
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

(defun enhanced-dirvish-preview--ensure-common-auto-modes ()
  "Register available built-in `*-ts-mode' / fallback modes in `auto-mode-alist'.
Only binds extensions that are not already handled by a specific non-generic
major mode so user preferences in `init.el' remain untouched."
  (dolist (spec enhanced-dirvish-preview--common-mode-specs)
    (let* ((re (nth 0 spec))
           (probe-name (nth 1 spec))
           (ts-mode (nth 2 spec))
           (ts-lang (nth 3 spec))
           (fb-mode (nth 4 spec))
           (existing (assoc-default probe-name auto-mode-alist #'string-match-p))
           (ts-ok (and (or (fboundp ts-mode) (locate-library (symbol-name ts-mode)))
                       (fboundp 'treesit-language-available-p)
                       (cl-every #'treesit-language-available-p (ensure-list ts-lang))))
           (chosen (cond
                    (ts-ok
                     (ignore-errors (require ts-mode nil t))
                     (and (fboundp ts-mode) ts-mode))
                    ((and fb-mode (or (fboundp fb-mode)
                                      (and (ignore-errors (require fb-mode nil t))
                                           (fboundp fb-mode))))
                     fb-mode))))
      (when (and chosen
                 (or (null existing)
                     (memq existing '(fundamental-mode text-mode prog-mode))))
        (add-to-list 'auto-mode-alist (cons re chosen))))))

(defun enhanced-dirvish-preview--fontify-current-buffer (virtual-file)
  "Apply syntax highlighting in current buffer for VIRTUAL-FILE.
Returns fontified `buffer-string' with realized `face' text properties."
  (enhanced-dirvish-preview--ensure-common-auto-modes)
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
            (font-lock-ensure (point-min) (min (point-max) enhanced-dirvish-preview-max-bytes))))
        (buffer-string))
    ;; Never allow ephemeral preview buffer to match `find-buffer-visiting'.
    (setq buffer-file-name nil)))

(defun enhanced-dirvish-preview--fontify-string (text virtual-file)
  "Return TEXT syntax-highlighted according to VIRTUAL-FILE's major mode."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (enhanced-dirvish-preview--fontify-current-buffer virtual-file)))

(defun enhanced-dirvish-preview--preview-buffer-p (buf &optional dv)
  "Return non-nil when BUF is a preview or placeholder buffer."
  (when (buffer-live-p buf)
    (let ((nm (buffer-name buf)))
      (or (and dv (or (memq buf (dv-preview-buffers dv))
                      (memq buf (dv-special-buffers dv))))
          (string-prefix-p "PREVIEW :: " nm)
          (string-prefix-p " *Dirvish-preview-" nm)
          (string-prefix-p "*dirvish-preview@" nm)
          (string-prefix-p " *dirvish-preview@" nm)
          (string-prefix-p " *Enhanced-Dirvish-Preview" nm)
          (string-prefix-p " *preview-temp*" nm)
          (string= nm "*Enhanced Dirvish Preview*")))))

(defun enhanced-dirvish-preview--setup-dirvish-fontlock-h ()
  "Materialize font-lock faces immediately in Dirvish `PREVIEW ::' buffers."
  (when (or font-lock-defaults
            (and (fboundp 'treesit-parser-list) (treesit-parser-list)))
    (font-lock-mode 1)
    (ignore-errors
      (font-lock-ensure (point-min) (min (point-max) enhanced-dirvish-preview-max-bytes))))
  (when (eq enhanced-dirvish-active-preview-kind 'text)
    (enhanced-dirvish-preview--set-text-scale)))


(defun enhanced-dirvish--same-file-key (file)
  "A key to compare FILE with others: its truename, or on a mount that
may hang (cloud, network, removable) just its expanded name -- resolving
symlinks there is a call into the mount for every cursor move."
  (when (stringp file)
    (if (enhanced-dirvish-path-unsafe-probe-p file)
        (expand-file-name file)
      (ignore-errors (file-truename file)))))

(defun enhanced-dirvish-preview--guard-dirvish-update (orig-fn dv index)
  "Prevent background Dirvish preview updates from clobbering focused panes.
Also attaches `enhanced-dirvish-preview-read-mode' metadata to newly updated
previews."
  (let* ((ctx (when (enhanced-dirvish-preview--browser-window-p (selected-window))
                (enhanced-dirvish-preview--capture-browser-context (selected-window))))
         (pwin (and dv (dv-preview-window dv)))
         (pbuf (and (window-live-p pwin) (window-buffer pwin)))
         (pbuf-file (and (buffer-live-p pbuf)
                         (buffer-local-value 'buffer-file-name pbuf)))
         (pbuf-edit (and (buffer-live-p pbuf)
                         (buffer-local-value 'enhanced-dirvish-preview-edit-mode pbuf)))
         (pbuf-read (and (buffer-live-p pbuf)
                         (buffer-local-value 'enhanced-dirvish-preview-read-mode pbuf)))
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
               (not (equal (and pbuf-file (enhanced-dirvish--same-file-key pbuf-file))
                           (enhanced-dirvish--same-file-key index))))))
    (when (or enhanced-dirvish-preview--force-update
              (and (not preview-focused)
                   (or (not (buffer-live-p pbuf))
                       (enhanced-dirvish-preview--preview-buffer-p pbuf dv)
                       browser-browsing-other)))
      (when (and browser-browsing-other (buffer-live-p pbuf))
        (with-current-buffer pbuf
          (enhanced-dirvish-preview-edit-mode -1)))
      (funcall orig-fn dv index)
      (when-let ((nbuf (and (window-live-p pwin) (window-buffer pwin))))
        (enhanced-dirvish-preview--sync-read-buffer pwin nbuf ctx)))))

;;;; Independent Per-Type Zoom Controls (Text / Image / PDF)

(defun enhanced-dirvish-preview--refresh-now (&optional file)
  "Force immediate re-render of active preview, using FILE when supplied."
  (when-let* ((win (enhanced-dirvish-preview--active-window))
              (buf (window-buffer win)))
    (if-let* ((pdf (buffer-local-value 'enhanced-dirvish-preview--pdf-state buf)))
        (enhanced-dirvish-preview--render-pdf
         (plist-get pdf :file) win buf (plist-get pdf :page))
      (when-let* ((target (or file (buffer-local-value 'enhanced-dirvish-preview--file buf)
                             enhanced-dirvish-active-preview-file)))
        (enhanced-dirvish-preview--dispatch-dirvish-or-standalone
         (enhanced-dirvish-preview--session-for-window win) target win)))))

(defun enhanced-dirvish-preview--zoom-kind ()
  "Return the zoom kind of the visible preview."
  (if-let* ((win (enhanced-dirvish-preview--active-window)))
      (with-current-buffer (window-buffer win)
        (cond (enhanced-dirvish-preview--pdf-state 'pdf)
              (enhanced-dirvish-preview--image-scale 'image)
              (t 'text)))
    enhanced-dirvish-active-preview-kind))

(defun enhanced-dirvish-preview--zoom-percent ()
  "Return the current preview buffer's zoom as a percentage."
  (round (* 100 (or (plist-get enhanced-dirvish-preview--pdf-state :scale)
                    enhanced-dirvish-preview--image-scale
                    (if text-scale-mode
                        (expt text-scale-mode-step text-scale-mode-amount)
                      1)))))

(defun enhanced-dirvish-preview--zoom-menu (event)
  "Open zoom controls for the preview clicked by EVENT."
  (interactive "e")
  (with-selected-window (posn-window (event-start event))
    (popup-menu
     '("Preview Zoom"
       ["Zoom In" enhanced-dirvish-preview-zoom-in t]
       ["Zoom Out" enhanced-dirvish-preview-zoom-out t]
       ["Reset to 100%" enhanced-dirvish-preview-zoom-reset t])
     event)))

(defvar enhanced-dirvish-preview--zoom-header-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'enhanced-dirvish-preview--zoom-menu)
    map)
  "Mouse binding for the preview's zoom percentage.")

(defun enhanced-dirvish-preview--header ()
  "Show document controls and a right-aligned zoom percentage."
  (let* ((label (format " Zoom %d%% " (enhanced-dirvish-preview--zoom-percent)))
         (width (1+ (string-width label)))
         (room (max 0 (- (window-body-width (get-buffer-window)) width)))
         (document (when (local-variable-p 'enhanced-dirvish-preview--document-rendered)
                     (enhanced-dirvish-preview--document-controls room))))
    (concat document
            (propertize " " 'display `(space :align-to (- right ,width)))
            (propertize (string-replace "%" "%%" label)
                        'face 'enhanced-dirvish-header-accent
                        'mouse-face 'highlight
                        'pointer 'hand
                        'help-echo "Click for preview zoom controls"
                        'local-map enhanced-dirvish-preview--zoom-header-map))))

(defun enhanced-dirvish-preview-zoom-in ()
  "Zoom in ONLY the currently active preview type (`text', `image', or `pdf')."
  (interactive)
  (let ((p (enhanced-dirvish-prefs)))
    (pcase (enhanced-dirvish-preview--zoom-kind)
      ('image
       (let ((next (min 4.0 (* (enhanced-dirvish-prefs-preview-image-scale p) 1.2))))
         (setf (enhanced-dirvish-prefs-preview-image-scale p) next)
         (enhanced-dirvish-prefs-save)
         (enhanced-dirvish-preview--refresh-now)
         (message "Image preview zoom: %.0f%%" (* 100 next))))
      ('pdf
       (let ((next (min 3.0 (* (enhanced-dirvish-prefs-preview-pdf-scale p) 1.15))))
         (setf (enhanced-dirvish-prefs-preview-pdf-scale p) next)
         (enhanced-dirvish-prefs-save)
         (enhanced-dirvish-preview--refresh-now)
         (message "PDF preview zoom: %.0f%%" (* 100 next))))
      (_
       (let ((next (min 10 (1+ (enhanced-dirvish-prefs-preview-text-scale p)))))
         (setf (enhanced-dirvish-prefs-preview-text-scale p) next)
         (enhanced-dirvish-prefs-save)
         (enhanced-dirvish-preview--apply-text-zoom)
         (message "Text preview scale: %+d" next))))))

(defun enhanced-dirvish-preview-zoom-out ()
  "Zoom out ONLY the currently active preview type (`text', `image', or `pdf')."
  (interactive)
  (let ((p (enhanced-dirvish-prefs)))
    (pcase (enhanced-dirvish-preview--zoom-kind)
      ('image
       (let ((next (max 0.25 (/ (enhanced-dirvish-prefs-preview-image-scale p) 1.2))))
         (setf (enhanced-dirvish-prefs-preview-image-scale p) next)
         (enhanced-dirvish-prefs-save)
         (enhanced-dirvish-preview--refresh-now)
         (message "Image preview zoom: %.0f%%" (* 100 next))))
      ('pdf
       (let ((next (max 0.5 (/ (enhanced-dirvish-prefs-preview-pdf-scale p) 1.15))))
         (setf (enhanced-dirvish-prefs-preview-pdf-scale p) next)
         (enhanced-dirvish-prefs-save)
         (enhanced-dirvish-preview--refresh-now)
         (message "PDF preview zoom: %.0f%%" (* 100 next))))
      (_
       (let ((next (max -5 (1- (enhanced-dirvish-prefs-preview-text-scale p)))))
         (setf (enhanced-dirvish-prefs-preview-text-scale p) next)
         (enhanced-dirvish-prefs-save)
         (enhanced-dirvish-preview--apply-text-zoom)
         (message "Text preview scale: %+d" next))))))

(defun enhanced-dirvish-preview-zoom-reset ()
  "Reset zoom for the currently active preview type back to 100% / 0."
  (interactive)
  (let ((p (enhanced-dirvish-prefs)))
    (pcase (enhanced-dirvish-preview--zoom-kind)
      ('image
       (setf (enhanced-dirvish-prefs-preview-image-scale p) 1.0)
       (enhanced-dirvish-prefs-save)
       (enhanced-dirvish-preview--refresh-now)
       (message "Image preview zoom reset (100%%)"))
      ('pdf
       (setf (enhanced-dirvish-prefs-preview-pdf-scale p) 1.0)
       (enhanced-dirvish-prefs-save)
       (enhanced-dirvish-preview--refresh-now)
       (message "PDF preview zoom reset (100%%)"))
      (_
       (setf (enhanced-dirvish-prefs-preview-text-scale p) 0)
       (enhanced-dirvish-prefs-save)
       (enhanced-dirvish-preview--apply-text-zoom)
       (message "Text preview zoom reset (0)")))))

(defun enhanced-dirvish-preview--set-text-scale ()
  "Restore saved text zoom without treating rendering as a user zoom change."
  (let ((enhanced-dirvish-preview--applying-text-zoom t))
    (text-scale-set (enhanced-dirvish-prefs-preview-text-scale (enhanced-dirvish-prefs))))
  (enhanced-dirvish-preview--resize-markdown-images)
  (force-mode-line-update))

(defun enhanced-dirvish-preview--sync-text-scale ()
  "Give the current preview buffer the zoom its preview kind owns.
Image and PDF previews zoom by re-rendering at their own scale, so they
sit at text scale 0; every other kind uses the saved text zoom, as the
zoom commands do."
  (if (memq enhanced-dirvish-active-preview-kind '(image pdf))
      (let ((enhanced-dirvish-preview--applying-text-zoom t))
        (text-scale-set 0))
    (enhanced-dirvish-preview--set-text-scale)))

(defun enhanced-dirvish-preview--remember-text-scale ()
  "Persist native Emacs text zoom changes made inside a text preview."
  (when (and (not enhanced-dirvish-preview--applying-text-zoom)
             (eq enhanced-dirvish-active-preview-kind 'text)
             (or (bound-and-true-p enhanced-dirvish-preview-read-mode)
                 (bound-and-true-p enhanced-dirvish-preview-edit-mode)))
    (let* ((p (enhanced-dirvish-prefs))
           (scale (if text-scale-mode text-scale-mode-amount 0)))
      (unless (= scale (enhanced-dirvish-prefs-preview-text-scale p))
        (setf (enhanced-dirvish-prefs-preview-text-scale p) scale)
        (enhanced-dirvish-prefs-save))
      (enhanced-dirvish-preview--resize-markdown-images)
      (force-mode-line-update))))

(defun enhanced-dirvish-preview--bind-zoom-keys (map &optional plain)
  "Bind preview zoom controls in MAP, including plain keys when PLAIN."
  (dolist (binding '(("C-+" . enhanced-dirvish-preview-zoom-in)
                     ("C-=" . enhanced-dirvish-preview-zoom-in)
                     ("C--" . enhanced-dirvish-preview-zoom-out)
                     ("C-0" . enhanced-dirvish-preview-zoom-reset)))
    (define-key map (kbd (car binding)) (cdr binding)))
  (when plain
    (dolist (binding '(("+" . enhanced-dirvish-preview-zoom-in)
                       ("=" . enhanced-dirvish-preview-zoom-in)
                       ("-" . enhanced-dirvish-preview-zoom-out)
                       ("0" . enhanced-dirvish-preview-zoom-reset)))
      (define-key map (kbd (car binding)) (cdr binding)))))

(defun enhanced-dirvish-preview--apply-text-zoom ()
  "Apply independent `preview-text-scale' to the active preview window's buffer."
  (when-let* ((win (enhanced-dirvish-preview--active-window))
              (buf (window-buffer win)))
    (with-current-buffer buf
      (enhanced-dirvish-preview--set-text-scale)
      (setq-local truncate-lines (not (enhanced-dirvish-prefs-preview-text-wrap (enhanced-dirvish-prefs)))))))

(defun enhanced-dirvish-toggle-rendered-document ()
  "Switch between rendered and source previews (`M-v')."
  (interactive)
  (let* ((p (enhanced-dirvish-prefs))
         (win (enhanced-dirvish-preview--active-window))
         (buf (and win (window-buffer win)))
         (document (and buf (local-variable-p 'enhanced-dirvish-preview--document-rendered buf)))
         (rendered (if document
                       (buffer-local-value 'enhanced-dirvish-preview--document-rendered buf)
                     (enhanced-dirvish-prefs-render-documents-by-default p)))
         (file (and document (buffer-local-value 'enhanced-dirvish-preview--file buf))))
    (setf (enhanced-dirvish-prefs-render-documents-by-default p) (not rendered))
    (enhanced-dirvish-prefs-save)
    (enhanced-dirvish-preview--refresh-now file)
    (message "Document preview mode: %s"
             (if rendered "Source" "Rendered"))))

(defun enhanced-dirvish-preview--toggle-header (event)
  "Switch the document preview whose header received mouse EVENT."
  (interactive "e")
  (with-selected-window (posn-window (event-start event))
    (enhanced-dirvish-toggle-rendered-document)))

(defvar enhanced-dirvish-preview--document-header-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'enhanced-dirvish-preview--toggle-header)
    map)
  "Mouse binding for the document preview's Source/Rendered control.")

(defun enhanced-dirvish-preview--document-controls (room)
  "Show the document toggle and fit its labels in ROOM columns."
  (let* ((rendered enhanced-dirvish-preview--document-rendered)
         (mode (if rendered "  Rendered  " "  Source  "))
         (toggle (propertize (if rendered " Show Source " " Show Rendered ")
                             'face 'enhanced-dirvish-header-accent
                             'mouse-face 'highlight 'pointer 'hand
                             'help-echo "Switch document preview (M-v)"
                             'local-map enhanced-dirvish-preview--document-header-map))
         (hint (propertize " Alt+V (M-v)" 'face 'enhanced-dirvish-hint-desc))
         (with-hint (concat toggle hint)))
    (cond ((>= room (string-width (concat mode with-hint))) (concat mode with-hint))
          ((>= room (string-width with-hint)) with-hint)
          (t (truncate-string-to-width toggle room)))))

(defun enhanced-dirvish-preview--set-document-header (rendered)
  "Show the controls for a document currently displayed as RENDERED."
  (setq-local enhanced-dirvish-preview--document-rendered rendered
              header-line-format '(:eval (enhanced-dirvish-preview--header))))

(defun enhanced-dirvish-toggle-preview-wrap ()
  "Toggle soft line wrapping inside preview buffer (`W')."
  (interactive)
  (let ((p (enhanced-dirvish-prefs)))
    (setf (enhanced-dirvish-prefs-preview-text-wrap p) (not (enhanced-dirvish-prefs-preview-text-wrap p)))
    (enhanced-dirvish-prefs-save)
    (enhanced-dirvish-preview--apply-text-zoom)
    (message "Preview wrap: %s" (if (enhanced-dirvish-prefs-preview-text-wrap p) "ON" "OFF"))))

(defun enhanced-dirvish-preview--render-source-file (file out-buf &optional syntax-file)
  "Show literal FILE in OUT-BUF, using SYNTAX-FILE to select a highlighting mode."
  (let* ((ext (downcase (or (file-name-extension file) "")))
         (disabled (and (boundp 'dirvish-preview-disabled-exts)
                        (member ext dirvish-preview-disabled-exts)))
         (binary-ext (and (boundp 'dirvish-binary-exts)
                          (not (equal ext "svg"))
                          (member ext dirvish-binary-exts)))
         (attrs (ignore-errors (file-attributes file)))
         (size (and attrs (file-attribute-size attrs))))
    (setq enhanced-dirvish-active-preview-file file
          enhanced-dirvish-active-preview-kind 'text)
    (with-current-buffer out-buf
      (special-mode)
      (font-lock-mode -1)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (cond
         ((enhanced-dirvish-path-unsafe-probe-p file)
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
                        (insert-file-contents file nil 0 enhanced-dirvish-preview-max-bytes)
                        (buffer-string)))
                 (head (substring raw 0 (min 4096 (length raw)))))
            (if (string-match-p "\0" head)
                (insert (propertize
                         (format "  Binary file preview skipped: %s\n"
                                 (file-name-nondirectory file))
                         'face 'shadow))
              (insert (enhanced-dirvish-preview--fontify-string raw (or syntax-file file)))
              (when (and size (> size enhanced-dirvish-preview-max-bytes))
                (insert (propertize "\n\n  File truncated. End of partial preview.\n"
                                    'face 'shadow))))))
         (t
          (insert (propertize (format "  Unreadable file: %s\n" (file-name-nondirectory file))
                              'face 'shadow)))))
      (setq-local truncate-lines (not (enhanced-dirvish-prefs-preview-text-wrap (enhanced-dirvish-prefs))))
      (enhanced-dirvish-preview--set-text-scale)
      (goto-char (point-min)))))

(defun enhanced-dirvish-preview-update-standalone (file &optional window)
  "Render rich preview for FILE into `*Enhanced Dirvish Preview*' inside WINDOW."
  (let* ((ctx (if (enhanced-dirvish-preview--browser-window-p (selected-window))
                  (enhanced-dirvish-preview--capture-browser-context (selected-window))
                enhanced-dirvish-preview--last-browser-context))
         (ext (downcase (or (file-name-extension file) "")))
         (win (or window (get-buffer-window "*Enhanced Dirvish Preview*") (selected-window)))
         (res (or (dirvish-enhanced-dirvish-rich-image-dp file ext win nil)
                  (dirvish-enhanced-dirvish-rich-pdf-dp file ext win nil)
                  (dirvish-enhanced-dirvish-rich-document-dp file ext win nil)))
         (out-buf (get-buffer-create "*Enhanced Dirvish Preview*")))
    (pcase res
      (`(buffer . ,b)
       (setq enhanced-dirvish-active-preview-file file)
       (with-current-buffer out-buf
         (special-mode)
         (font-lock-mode -1)
         (let ((inhibit-read-only t))
           (erase-buffer)
           (insert-buffer-substring b))
         (when-let* ((pdf (buffer-local-value 'enhanced-dirvish-preview--pdf-state b)))
           (setq enhanced-dirvish-preview--pdf-state pdf)
           (enhanced-dirvish-preview-pdf-mode 1))
         (setq-local enhanced-dirvish-preview--image-scale
                     (buffer-local-value 'enhanced-dirvish-preview--image-scale b))
         (setq-local truncate-lines (not (enhanced-dirvish-prefs-preview-text-wrap (enhanced-dirvish-prefs))))
         (goto-char (point-min))))
      (`(shell . ,cmd)
       (setq enhanced-dirvish-active-preview-file file)
       (with-current-buffer out-buf
         (special-mode)
         (font-lock-mode -1)
         (let ((inhibit-read-only t))
           (erase-buffer)
           (apply #'process-file (car cmd) nil t nil (cdr cmd)))
         (goto-char (point-min))))
      (_
       (if (file-directory-p file)
           (progn
             (setq enhanced-dirvish-active-preview-file file
                   enhanced-dirvish-active-preview-kind 'dir)
             (with-current-buffer out-buf
               (special-mode)
               (font-lock-mode -1)
               (let ((inhibit-read-only t))
                 (erase-buffer)
                 (if (enhanced-dirvish-path-unsafe-probe-p file)
                     (insert (propertize (format "  Remote / Cloud / External mount: %s\n\n  Auto-preview skipped (press RET to open).\n"
                                                 (file-name-nondirectory (directory-file-name file)))
                                         'face 'shadow))
                   (let ((items (ignore-errors (directory-files file nil "\\`[^.]" t))))
                     (insert (concat "  "
                                     (enhanced-dirvish-icon-glyph 'folder 'enhanced-dirvish-header-accent)
                                     (propertize (format " %s (%d items)\n\n"
                                                         (file-name-nondirectory (directory-file-name file))
                                                         (length items))
                                                 'face 'enhanced-dirvish-header-accent)))
                     (dolist (it (seq-take items 60))
                       (let* ((sub (expand-file-name it file))
                              (dirp (file-directory-p sub))
                              (row (format "   %s  %s\n"
                                           (enhanced-dirvish-icon-glyph (if dirp 'folder 'file))
                                           it)))
                         (when dirp
                           (let ((km (make-sparse-keymap)))
                             (define-key km [mouse-1]
                                         (lambda (ev)
                                           (interactive "e")
                                           (when (fboundp 'enhanced-dirvish-open-location)
                                             (when (posn-window (event-end ev))
                                               (select-window (posn-window (event-end ev))))
                                             (enhanced-dirvish-open-location sub t))))
                             (enhanced-dirvish-add-row-properties
                              row (list 'mouse-face 'highlight
                                        'pointer 'hand
                                        'keymap km
                                        'help-echo sub))))
                         (insert row))))))
               (goto-char (point-min))))
         (enhanced-dirvish-preview--render-source-file file out-buf))))
    ;; `*Enhanced Dirvish Preview*' is shared by every kind: an image after a zoomed
    ;; text file must not inherit the text zoom, nor a text file after it 0.
    (with-current-buffer out-buf
      (setq-local enhanced-dirvish-preview--file file)
      (when (and (eq (car-safe res) 'buffer)
                 (local-variable-p 'enhanced-dirvish-preview--document-rendered (cdr res)))
        (enhanced-dirvish-preview--set-document-header
         (buffer-local-value 'enhanced-dirvish-preview--document-rendered (cdr res))))
      (enhanced-dirvish-preview--sync-text-scale))
    (when (window-live-p win)
      (set-window-buffer win out-buf)
      (enhanced-dirvish-preview--sync-read-buffer win out-buf ctx))))

(defun enhanced-dirvish-preview--active-window ()
  "Return the currently visible Dirvish or standalone preview window, or nil."
  (or (when (enhanced-dirvish-preview--preview-window-p (selected-window)) (selected-window))
      (when-let* ((dv (ignore-errors (dirvish-curr)))
                  (win (dv-preview-window dv)))
        (and (window-live-p win) win))
      (and (window-live-p enhanced-dirvish-preview-standalone-window)
           enhanced-dirvish-preview-standalone-window)
      (get-buffer-window "*Enhanced Dirvish Preview*")))

(defun enhanced-dirvish-preview--session-for-window (win)
  "Return the Dirvish session that owns preview WIN."
  (let ((current (ignore-errors (dirvish-curr))))
    (if (and current (eq win (dv-preview-window current)))
        current
      (when (and (boundp 'dirvish--sessions) (hash-table-p dirvish--sessions))
        (cl-loop for dv being the hash-values of dirvish--sessions
                 when (eq win (dv-preview-window dv)) return dv)))))

(defun enhanced-dirvish-preview--close-standalone ()
  "Close any open standalone `*Enhanced Dirvish Preview*' window cleanly."
  (when-let ((win (or (and (window-live-p enhanced-dirvish-preview-standalone-window)
                           enhanced-dirvish-preview-standalone-window)
                      (get-buffer-window "*Enhanced Dirvish Preview*"))))
    (when (and (window-live-p win) (not (one-window-p t)))
      (enhanced-dirvish-windows--delete win))
    (setq enhanced-dirvish-preview-standalone-window nil)))

(defun enhanced-dirvish-scroll-preview-down ()
  "Scroll preview window down (`J')."
  (interactive)
  (when-let* ((win (enhanced-dirvish-preview--active-window)))
    (if (buffer-local-value 'enhanced-dirvish-preview--pdf-state (window-buffer win))
        (enhanced-dirvish-pdf-page-step 1 win)
      (with-selected-window win (scroll-up-command 5)))))

(defun enhanced-dirvish-scroll-preview-up ()
  "Scroll preview window up (`K')."
  (interactive)
  (when-let* ((win (enhanced-dirvish-preview--active-window)))
    (if (buffer-local-value 'enhanced-dirvish-preview--pdf-state (window-buffer win))
        (enhanced-dirvish-pdf-page-step -1 win)
      (with-selected-window win (scroll-down-command 5)))))

(defun enhanced-dirvish-preview--split-standalone-window (main)
  "Create a normal (non-side) right preview window split from MAIN."
  (let* ((ignore-window-parameters t)
         (enhanced-dirvish-windows--changing t)
         (window-combination-limit t)
         (left-w (max 24 (round (* (window-total-width main) 0.58))))
         (pwin (split-window main left-w 'right)))
    (set-window-buffer pwin (get-buffer-create "*Enhanced Dirvish Preview*"))
    (setq enhanced-dirvish-preview-standalone-window pwin)
    pwin))

(defun enhanced-dirvish-preview--ensure-window (&optional allow-split)
  "Return active preview window without altering layout unless ALLOW-SPLIT."
  (let* ((dv (ignore-errors (dirvish-curr)))
         (sidebar (bound-and-true-p enhanced-dirvish-sidebar-window))
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
           (eq (enhanced-dirvish-prefs-browser-mode (enhanced-dirvish-prefs)) 'columns)
           (null (dv-curr-layout dv)))
      (dirvish-layout-toggle)
      (when (window-live-p cur)
        (select-window cur t))
      (let ((w (dv-preview-window dv)))
        (and (window-live-p w) w)))
     ((and (window-live-p enhanced-dirvish-preview-standalone-window)
           (not (eq enhanced-dirvish-preview-standalone-window cur))
           (not (eq enhanced-dirvish-preview-standalone-window sidebar)))
      enhanced-dirvish-preview-standalone-window)
     ((when-let ((w (get-buffer-window "*Enhanced Dirvish Preview*")))
        (when (and (window-live-p w)
                   (not (eq w cur))
                   (not (eq w sidebar)))
          (setq enhanced-dirvish-preview-standalone-window w))))
     (allow-split
      (enhanced-dirvish-preview--split-standalone-window cur)))))

(defun enhanced-dirvish-preview--cancel-delay ()
  "Cancel any pending Dirvish preview delay timer."
  (when (fboundp 'dirvish--run-with-delay)
    (dirvish--run-with-delay 'reset))
  (when (boundp 'dirvish--timers)
    (when-let ((rec (plist-get dirvish--timers :default)))
      (when (timerp (car rec))
        (cancel-timer (car rec))))))

(defun enhanced-dirvish-preview--dispatch-dirvish-or-standalone (dv file pwin)
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
          (enhanced-dirvish-preview--cancel-delay)
          (let ((enhanced-dirvish-preview--force-update t))
            (dirvish--preview-update dv file))
          ;; Fall back only if Dirvish left PWIN empty or on an initial placeholder.
          (let ((cur-pbuf (and (window-live-p pwin) (window-buffer pwin))))
            (when (or (not (buffer-live-p cur-pbuf))
                      (let ((nm (buffer-name cur-pbuf)))
                        (or (string-prefix-p "*dirvish-preview@" nm)
                            (string-prefix-p " *dirvish-preview@" nm))))
              (enhanced-dirvish-preview-update-standalone file pwin))))
      (enhanced-dirvish-preview-update-standalone file pwin))))

(defun enhanced-dirvish-preview--show-at-point (&optional focus-read-only)
  "Render item at point into the preview pane.
When FOCUS-READ-ONLY is non-nil, enter the preview pane in
`enhanced-dirvish-preview-read-mode' (`<right>').  Otherwise stay in the
browser (`SPC')."
  (let* ((f (or (enhanced-dirvish-current-file)
                (and (derived-mode-p 'enhanced-dirvish-computer-mode)
                     (let ((dev (ignore-errors (enhanced-dirvish-computer--device-at-point))))
                       (and dev (enhanced-dirvish-device-mounted-p dev)
                            (enhanced-dirvish-device-mountpoint dev))))))
         (dv (ignore-errors (dirvish-curr)))
         (cur (selected-window))
         (ctx (enhanced-dirvish-preview--capture-browser-context cur)))
    (unless f
      (user-error "No entry to preview at point"))
    (when-let ((pwin (enhanced-dirvish-preview--ensure-window t)))
      (let* ((pbuf (and (window-live-p pwin) (window-buffer pwin)))
             (already-editing
              (and focus-read-only
                   (buffer-live-p pbuf)
                   (buffer-local-value 'enhanced-dirvish-preview-edit-mode pbuf)
                   (buffer-modified-p pbuf)))
             (cur-file-p
              (and enhanced-dirvish-active-preview-file
                   (stringp f)
                   (equal (enhanced-dirvish--same-file-key enhanced-dirvish-active-preview-file)
                          (enhanced-dirvish--same-file-key f)))))
        (unless (and focus-read-only
                     (or already-editing
                         (and cur-file-p
                              (buffer-live-p pbuf)
                              (enhanced-dirvish-preview--preview-buffer-p pbuf dv)
                              (not (string-prefix-p "*dirvish-preview@" (buffer-name pbuf)))
                              (not (string-prefix-p " *dirvish-preview@" (buffer-name pbuf))))))
          (enhanced-dirvish-preview--dispatch-dirvish-or-standalone dv f pwin))
        (let ((target-buf (and (window-live-p pwin) (window-buffer pwin))))
          (when (and focus-read-only (buffer-live-p target-buf))
            (unless already-editing
              (with-current-buffer target-buf
                (when (bound-and-true-p enhanced-dirvish-preview-edit-mode)
                  (enhanced-dirvish-preview-edit-mode -1))
                (setq enhanced-dirvish-preview--file f))
              (enhanced-dirvish-preview--sync-read-buffer pwin target-buf ctx)))
          (if focus-read-only
              (when (window-live-p pwin)
                (select-window pwin)
                (message "Preview Read-Only: ↑↓/PgUp/PgDn scroll · C-<left> back to browser"))
            (when (window-live-p cur)
              (select-window cur t))))))))

(defun enhanced-dirvish-preview-at-point ()
  "Preview item at point inside the preview pane without closing it (`SPC')."
  (interactive)
  (enhanced-dirvish-preview--show-at-point nil))

(defvar enhanced-dirvish-preview--last-browser-context nil
  "Last captured browser window context (:win :buf :dir :view).")

(defvar-local enhanced-dirvish-preview--file nil
  "Source path associated with a preview buffer for browser restoration.")

(defvar-local enhanced-dirvish-preview-edit--browser-window nil
  "Browser window to return to when leaving preview-pane read/edit mode.")

(defvar-local enhanced-dirvish-preview-edit--browser-buffer nil
  "Browser buffer to restore when closing a maximized preview buffer.")

(defvar-local enhanced-dirvish-preview-edit--browser-dir nil
  "Browser directory to reopen when closing a maximized preview buffer.")

(defvar-local enhanced-dirvish-preview-edit--browser-view nil
  "Enhanced Dirvish browser view mode active before entering the preview pane.")

(defvar-local enhanced-dirvish-preview-edit--preview-window nil
  "Preview window hosting read-only preview or direct edit buffer.")

(defvar enhanced-dirvish-preview-edit--returning nil
  "Non-nil while programmatically leaving preview-pane read/edit mode.")

(defun enhanced-dirvish-preview--browser-window-p (&optional win)
  "Return non-nil when WIN is a browser pane (not preview/aux)."
  (let ((w (or win (selected-window))))
    (when (window-live-p w)
      (let ((buf (window-buffer w)))
        (and (buffer-live-p buf)
             (not (enhanced-dirvish-preview--preview-buffer-p buf))
             (not (eq w (bound-and-true-p enhanced-dirvish-sidebar-window)))
             (with-current-buffer buf
               (derived-mode-p 'dired-mode
                               'enhanced-dirvish-compact-mode
                               'enhanced-dirvish-icons-mode
                               'enhanced-dirvish-computer-mode
                               'enhanced-dirvish-trash-mode
                               'enhanced-dirvish-search-mode)))))))

(defun enhanced-dirvish-preview--preview-window-p (&optional win)
  "Return non-nil when WIN hosts an Enhanced Dirvish or Dirvish preview pane."
  (let ((w (or win (selected-window))))
    (when (window-live-p w)
      (let ((buf (window-buffer w)))
        (or (eq w (bound-and-true-p enhanced-dirvish-preview-standalone-window))
            (when-let ((dv (ignore-errors (dirvish-curr))))
              (eq w (dv-preview-window dv)))
            (and (boundp 'dirvish--sessions)
                 (hash-table-p dirvish--sessions)
                 (cl-loop for dv being the hash-values of dirvish--sessions
                          thereis (eq w (dv-preview-window dv))))
            (and (buffer-live-p buf)
                 (enhanced-dirvish-preview--preview-buffer-p buf)))))))

(defun enhanced-dirvish-preview--capture-browser-context (&optional win)
  "Capture browser window/buffer/directory/view context from WIN."
  (let ((w (or win (selected-window))))
    (when (enhanced-dirvish-preview--browser-window-p w)
      (let* ((bbuf (window-buffer w))
             (bdir (with-current-buffer bbuf
                     (or (bound-and-true-p enhanced-dirvish-view-directory)
                         (ignore-errors (dirvish-prop :root))
                         default-directory)))
             (bview (when (fboundp 'enhanced-dirvish-prefs)
                      (enhanced-dirvish-prefs-browser-mode (enhanced-dirvish-prefs))))
             (ctx (list :win w :buf bbuf :dir bdir :view bview)))
        (setq enhanced-dirvish-preview--last-browser-context ctx)
        ctx))))

(defun enhanced-dirvish-preview--apply-browser-context (buf ctx pwin)
  "Store browser context CTX and PWIN on preview buffer BUF."
  (let* ((resolved (or (and (window-live-p (plist-get ctx :win))
                            (not (eq (plist-get ctx :win) pwin))
                            ctx)
                       (and (window-live-p (plist-get enhanced-dirvish-preview--last-browser-context :win))
                            (not (eq (plist-get enhanced-dirvish-preview--last-browser-context :win) pwin))
                            enhanced-dirvish-preview--last-browser-context)
                       ctx))
         (bwin (plist-get resolved :win))
         (bbuf (plist-get resolved :buf))
         (bdir (plist-get resolved :dir))
         (bview (plist-get resolved :view)))
    (with-current-buffer buf
      (when (and (window-live-p bwin) (not (eq bwin pwin)))
        (setq enhanced-dirvish-preview-edit--browser-window bwin))
      (when (buffer-live-p bbuf)
        (setq enhanced-dirvish-preview-edit--browser-buffer bbuf))
      (when bdir
        (setq enhanced-dirvish-preview-edit--browser-dir bdir))
      (when bview
        (setq enhanced-dirvish-preview-edit--browser-view bview))
      (when (window-live-p pwin)
        (setq enhanced-dirvish-preview-edit--preview-window pwin)))))

(defun enhanced-dirvish-preview--read-buffer-eligible-p (buf &optional dv)
  "Non-nil if preview-pane BUF should use `enhanced-dirvish-preview-read-mode'."
  (and (buffer-live-p buf)
       (not (buffer-local-value 'enhanced-dirvish-preview-edit-mode buf))
       (or (buffer-local-value 'buffer-read-only buf)
           (enhanced-dirvish-preview--preview-buffer-p buf dv)
           (and dv (memq buf (dv-preview-buffers dv))))))

(defun enhanced-dirvish-preview--sync-read-buffer (pwin buf &optional ctx)
  "Give BUF in PWIN `enhanced-dirvish-preview-read-mode' and browser context."
  (when (and (window-live-p pwin) (buffer-live-p buf))
    (let ((dv (enhanced-dirvish-preview--session-for-window pwin)))
      (when (enhanced-dirvish-preview--read-buffer-eligible-p buf dv)
        (with-current-buffer buf
          (when (and enhanced-dirvish-active-preview-file (not enhanced-dirvish-preview--file))
            (setq enhanced-dirvish-preview--file enhanced-dirvish-active-preview-file))
          (unless enhanced-dirvish-preview-read-mode
            (enhanced-dirvish-preview-read-mode 1))
          (unless header-line-format
            (setq-local header-line-format '(:eval (enhanced-dirvish-preview--header))))
          (setq buffer-read-only t)
          (unless cursor-type
            (setq-local cursor-type t)))
        (enhanced-dirvish-preview--apply-browser-context buf ctx pwin)))))

(defun enhanced-dirvish-preview--on-window-selection-change (&optional frame)
  "Track browser context or enter read-only navigation when preview is selected."
  (let ((win (frame-selected-window frame)))
    (when (window-live-p win)
      (cond
       ((enhanced-dirvish-preview--browser-window-p win)
        (enhanced-dirvish-preview--capture-browser-context win))
       ((enhanced-dirvish-preview--preview-window-p win)
        (let ((buf (window-buffer win)))
          (when (and (buffer-live-p buf)
                     (not (buffer-local-value 'enhanced-dirvish-preview-edit-mode buf)))
            (enhanced-dirvish-preview--sync-read-buffer
             win buf enhanced-dirvish-preview--last-browser-context))))))))

(defun enhanced-dirvish-preview-read-scroll-down ()
  "Scroll read-only preview buffer forward (`SPC')."
  (interactive)
  (cond
   (enhanced-dirvish-preview--pdf-state (enhanced-dirvish-pdf-page-step 1 (selected-window)))
   ((derived-mode-p 'pdf-view-mode) (call-interactively #'pdf-view-scroll-up-or-next-page))
   ((derived-mode-p 'doc-view-mode) (call-interactively #'doc-view-scroll-up-or-next-page))
   ((derived-mode-p 'image-mode) (call-interactively #'image-scroll-up))
   (t (call-interactively #'scroll-up-command))))

(defun enhanced-dirvish-preview-read-scroll-up ()
  "Scroll read-only preview buffer backward (`DEL' / `S-SPC')."
  (interactive)
  (cond
   (enhanced-dirvish-preview--pdf-state (enhanced-dirvish-pdf-page-step -1 (selected-window)))
   ((derived-mode-p 'pdf-view-mode) (call-interactively #'pdf-view-scroll-down-or-previous-page))
   ((derived-mode-p 'doc-view-mode) (call-interactively #'doc-view-scroll-down-or-previous-page))
   ((derived-mode-p 'image-mode) (call-interactively #'image-scroll-down))
   (t (call-interactively #'scroll-down-command))))

(defun enhanced-dirvish-preview-read-leave ()
  "Leave read-only preview pane and return to the left browser window (`C-<left>')."
  (interactive)
  (enhanced-dirvish-preview--return-to-browser nil))

(defvar enhanced-dirvish-preview-read-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-<left>") #'enhanced-dirvish-preview-read-leave)
    (define-key map (kbd "C-<escape>") #'enhanced-dirvish-preview-read-leave)
    (define-key map (kbd "q") #'enhanced-dirvish-preview-read-leave)
    (define-key map (kbd "SPC") #'enhanced-dirvish-preview-read-scroll-down)
    (define-key map (kbd "S-SPC") #'enhanced-dirvish-preview-read-scroll-up)
    (define-key map (kbd "DEL") #'enhanced-dirvish-preview-read-scroll-up)
    (define-key map (kbd "<backspace>") #'enhanced-dirvish-preview-read-scroll-up)
    map)
  "Keymap active while navigating the preview pane in read-only mode.")

(enhanced-dirvish-preview--bind-zoom-keys enhanced-dirvish-preview-read-mode-map t)
(define-key enhanced-dirvish-preview-read-mode-map (kbd "M-v") #'enhanced-dirvish-toggle-rendered-document)

(define-minor-mode enhanced-dirvish-preview-read-mode
  "Minor mode active while reading/scrolling inside the preview pane.
Keeps the buffer strictly read-only, enables keyboard scrolling, and binds
`C-<left>' (`C-c q', `q') to return to the previous browser pane."
  :lighter " Preview-RO"
  :keymap enhanced-dirvish-preview-read-mode-map
  (if enhanced-dirvish-preview-read-mode
      (progn
        (setq-local buffer-read-only t)
        (unless cursor-type
          (setq-local cursor-type t))
        (add-hook 'kill-buffer-hook #'enhanced-dirvish-preview-edit--on-kill nil t)
        (add-hook 'text-scale-mode-hook #'enhanced-dirvish-preview--remember-text-scale nil t))
    (remove-hook 'kill-buffer-hook #'enhanced-dirvish-preview-edit--on-kill t)
    (remove-hook 'text-scale-mode-hook #'enhanced-dirvish-preview--remember-text-scale t)))

(defun enhanced-dirvish-preview-enter-at-point ()
  "Preview item at point and enter it read-only (`<right>')."
  (interactive)
  (enhanced-dirvish-preview--show-at-point t))

(defvar enhanced-dirvish-preview-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-<left>") #'enhanced-dirvish-preview-edit-leave)
    (define-key map (kbd "C-c C-c") #'enhanced-dirvish-preview-edit-exit)
    (define-key map (kbd "C-<escape>") #'enhanced-dirvish-preview-edit-exit)
    (define-key map (kbd "C-c C-k") #'enhanced-dirvish-preview-edit-abort)
    map)
  "Keymap active while direct-editing a file in Enhanced Dirvish's preview pane.")

(enhanced-dirvish-preview--bind-zoom-keys enhanced-dirvish-preview-edit-mode-map)

(defun enhanced-dirvish-preview-edit--restore-browser (win bbuf bdir view &optional file defer-preview)
  "Restore previous Enhanced Dirvish browser view in WIN for BBUF/BDIR in VIEW.
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
                   (fboundp 'enhanced-dirvish-sidebar-ensure))
          (enhanced-dirvish-sidebar-ensure))
        (setq restored t))
       ((and bdir (file-directory-p bdir)
             (fboundp 'enhanced-dirvish-open-location))
        (enhanced-dirvish-open-location bdir nil)
        (when (and view (fboundp 'enhanced-dirvish-switch-view-mode))
          (ignore-errors (enhanced-dirvish-switch-view-mode view)))
        (setq restored t)))
      (when restored
        (let ((target-buf (window-buffer (selected-window))))
          (with-current-buffer target-buf
            (when (and file (fboundp 'enhanced-dirvish-goto-file))
              (ignore-errors (enhanced-dirvish-goto-file file))))
          (when (and (eq view 'columns)
                     (fboundp 'enhanced-dirvish-preview-at-point))
            (let ((refresh
                   (lambda (b f)
                     (when (buffer-live-p b)
                       (when-let ((w (get-buffer-window b)))
                         (with-selected-window w
                           (when (and f (fboundp 'enhanced-dirvish-goto-file))
                             (ignore-errors (enhanced-dirvish-goto-file f)))
                           (when (ignore-errors (enhanced-dirvish-current-file))
                             (ignore-errors (enhanced-dirvish-preview-at-point)))))))))
              (if (and defer-preview (not noninteractive))
                  (run-at-time 0 nil refresh target-buf file)
                (funcall refresh target-buf file)))))))))

(defun enhanced-dirvish-preview-edit--on-kill ()
  "Restore previous Dirvish view when killing a maximized (`C-x 1') preview buffer."
  (when (and (or (bound-and-true-p enhanced-dirvish-preview-edit-mode)
                 (bound-and-true-p enhanced-dirvish-preview-read-mode))
             (not enhanced-dirvish-preview-edit--returning)
             (not (window-live-p enhanced-dirvish-preview-edit--browser-window))
             (one-window-p t))
    (let ((buf (current-buffer))
          (win (selected-window))
          (bbuf enhanced-dirvish-preview-edit--browser-buffer)
          (bdir enhanced-dirvish-preview-edit--browser-dir)
          (view enhanced-dirvish-preview-edit--browser-view)
          (file (or buffer-file-name enhanced-dirvish-preview--file)))
      (when (and (eq (window-buffer win) buf)
                 (or (buffer-live-p bbuf)
                     (and bdir (file-directory-p bdir))))
        (remove-hook 'kill-buffer-hook #'enhanced-dirvish-preview-edit--on-kill t)
        (let ((dv (and (buffer-live-p bbuf)
                       (with-current-buffer bbuf
                         (ignore-errors (dirvish-curr))))))
          (when file
            (enhanced-dirvish-preview--invalidate-cache dv file)))
        (enhanced-dirvish-preview-edit--restore-browser win bbuf bdir view file t)))))

(define-minor-mode enhanced-dirvish-preview-edit-mode
  "Minor mode active while direct-editing inside the preview pane.
Provides `C-<left>' (leave with save prompt), `C-c q' / `C-<escape>'
to return left, or `C-c k' to abort and discard edits."
  :lighter " Preview-Edit"
  :keymap enhanced-dirvish-preview-edit-mode-map
  (if enhanced-dirvish-preview-edit-mode
      (progn
        (add-hook 'kill-buffer-hook #'enhanced-dirvish-preview-edit--on-kill nil t)
        (add-hook 'text-scale-mode-hook #'enhanced-dirvish-preview--remember-text-scale nil t))
    (remove-hook 'kill-buffer-hook #'enhanced-dirvish-preview-edit--on-kill t)
    (remove-hook 'text-scale-mode-hook #'enhanced-dirvish-preview--remember-text-scale t)))

(defun enhanced-dirvish-preview--invalidate-cache (dv file &optional kill-visiting)
  "Drop cached preview text and throwaway preview buffers for FILE in DV.
When KILL-VISITING is non-nil, also kill any unmodified preview buffers
visiting FILE (including via symlinks or across Dirvish sessions)."
  (when (and dv file)
    (when (hash-table-p (dv-preview-hash dv))
      (remhash file (dv-preview-hash dv))
      (remhash (enhanced-dirvish--same-file-key file) (dv-preview-hash dv)))
    (when-let ((pbuf (get-buffer (format "PREVIEW :: %s :: %s"
                                         (dv-timestamp dv)
                                         (file-name-nondirectory file)))))
      (unless (buffer-modified-p pbuf)
        (setf (dv-preview-buffers dv) (delq pbuf (dv-preview-buffers dv)))
        (let (kill-buffer-query-functions)
          (kill-buffer pbuf)))))
  (when (and kill-visiting file)
    (let ((target-true (enhanced-dirvish--same-file-key (expand-file-name file)))
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
                                (equal (enhanced-dirvish--same-file-key (expand-file-name bfile))
                                       target-true))))
              (when dv
                (setf (dv-preview-buffers dv) (delq b (dv-preview-buffers dv))))
              (let (kill-buffer-query-functions)
                (kill-buffer b)))))))))

(defun enhanced-dirvish-preview--return-to-browser (&optional mode)
  "Exit preview-pane read/edit mode and return to the neighbor left browser window.
MODE may be:
- nil: leave immediately without prompting;
- `save': run Emacs's normal save prompt (`save-some-buffers') when modified;
- `discard': prompt to confirm discarding unsaved edits and revert."
  (let* ((buf (current-buffer))
         (was-edit (bound-and-true-p enhanced-dirvish-preview-edit-mode))
         (buf-file (or buffer-file-name enhanced-dirvish-preview--file))
         (bwin enhanced-dirvish-preview-edit--browser-window)
         (bbuf enhanced-dirvish-preview-edit--browser-buffer)
         (bdir enhanced-dirvish-preview-edit--browser-dir)
         (bview enhanced-dirvish-preview-edit--browser-view)
         (pwin (or enhanced-dirvish-preview-edit--preview-window (selected-window)))
         (target-win
          (or (and (window-live-p bwin)
                   (not (eq bwin pwin))
                   bwin)
              (let ((left (window-in-direction 'left pwin)))
                (and (window-live-p left)
                     (not (eq left (bound-and-true-p enhanced-dirvish-sidebar-window)))
                     left))
              (enhanced-dirvish-panes--main-window))))
    (when was-edit
      (pcase mode
        ('discard
         (when (buffer-modified-p buf)
           (unless (enhanced-dirvish-ui-y-or-n-p (format "Discard unsaved edits in %s and abort? "
                                     (buffer-name buf)))
             (user-error "Aborted"))
           (if (and buffer-file-name (file-exists-p buffer-file-name))
               (revert-buffer t t t)
             (set-buffer-modified-p nil))))
        ('save
         (when (buffer-modified-p buf)
           (if buf-file
               (save-some-buffers nil (lambda () (eq (current-buffer) buf)))
             (when (enhanced-dirvish-ui-y-or-n-p (format "Save buffer %s? " (buffer-name buf)))
               (save-buffer)))))))
    (when was-edit
      (enhanced-dirvish-preview-edit-mode -1))
    (when (bound-and-true-p enhanced-dirvish-preview-read-mode)
      (enhanced-dirvish-preview-read-mode -1))
    (setq enhanced-dirvish-preview-edit--browser-window nil
          enhanced-dirvish-preview-edit--browser-buffer nil
          enhanced-dirvish-preview-edit--browser-dir nil
          enhanced-dirvish-preview-edit--browser-view nil
          enhanced-dirvish-preview-edit--preview-window nil)
    (cond
     ((and (not (window-live-p bwin))
           (one-window-p t)
           (or (buffer-live-p bbuf)
               (and bdir (file-directory-p bdir))))
      (let ((enhanced-dirvish-preview-edit--returning t))
        (when (and was-edit buf-file (not (buffer-modified-p buf)))
          (let ((dv (and (buffer-live-p bbuf)
                         (with-current-buffer bbuf (ignore-errors (dirvish-curr))))))
            (enhanced-dirvish-preview--invalidate-cache dv buf-file)))
        (enhanced-dirvish-preview-edit--restore-browser
         (selected-window) bbuf bdir bview buf-file)))
     ((window-live-p target-win)
      (select-window target-win)
      (when (boundp 'dirvish--selected-window)
        (setq dirvish--selected-window target-win))
      (when was-edit
        (let ((dv (ignore-errors (dirvish-curr))))
          (when (and buf-file (not (buffer-modified-p buf)))
            (enhanced-dirvish-preview--invalidate-cache dv buf-file))
          (when-let ((cur-file (and (fboundp 'enhanced-dirvish-current-file) (enhanced-dirvish-current-file))))
            (when (and (equal cur-file buf-file) (not (buffer-modified-p buf)))
              (enhanced-dirvish-preview--invalidate-cache dv cur-file))
            (cond
             ((and dv (window-live-p (dv-preview-window dv)))
              (enhanced-dirvish-preview--dispatch-dirvish-or-standalone dv cur-file (dv-preview-window dv)))
             ((window-live-p pwin)
              (enhanced-dirvish-preview-update-standalone cur-file pwin))))))))))

(defun enhanced-dirvish-preview-edit-leave ()
  "Prompt to save changes and return to the left browser window (`C-<left>')."
  (interactive)
  (enhanced-dirvish-preview--return-to-browser 'save))

(defun enhanced-dirvish-preview-edit-exit ()
  "Leave preview-pane edit mode and return to the neighbor left browser window."
  (interactive)
  (enhanced-dirvish-preview--return-to-browser nil))

(defun enhanced-dirvish-preview-edit-abort ()
  "Discard edits (if modified) and return to the neighbor left browser window."
  (interactive)
  (enhanced-dirvish-preview--return-to-browser 'discard))

(defun enhanced-dirvish-preview-edit-file (file)
  "Edit FILE directly inside the preview pane without altering window layout."
  (enhanced-dirvish-preview--ensure-common-auto-modes)
  (let* ((dv (ignore-errors (dirvish-curr)))
         (bwin (selected-window))
         (ctx (enhanced-dirvish-preview--capture-browser-context bwin))
         (pwin (enhanced-dirvish-preview--ensure-window t)))
    ;; Never reuse a truncated/read-only Dirvish throwaway `PREVIEW :: ...' buffer.
    (enhanced-dirvish-preview--invalidate-cache dv file t)
    (let* ((delay-mode-hooks nil)
           (existing (find-buffer-visiting file))
           (was-preview (and existing
                             (or (and dv (memq existing (dv-preview-buffers dv)))
                                 (string-prefix-p "PREVIEW :: " (buffer-name existing)))))
           (was-read-preview (and existing
                                  (buffer-local-value 'enhanced-dirvish-preview-read-mode existing)))
           (buf (find-file-noselect file)))
      (enhanced-dirvish-preview--cancel-delay)
      (when dv
        (setf (dv-preview-buffers dv) (delq buf (dv-preview-buffers dv))))
      (with-current-buffer buf
        (setq-local delay-mode-hooks nil)
        (when (and (eq major-mode 'fundamental-mode)
                   (memq (assoc-default file auto-mode-alist #'string-match-p)
                         '(markdown-ts-mode markdown-mode)))
          ;; An existing buffer may have been opened before registration.
          (set-auto-mode t))
        (when (bound-and-true-p enhanced-dirvish-preview-read-mode)
          (enhanced-dirvish-preview-read-mode -1))
        (when (and (or was-preview was-read-preview)
                   (file-writable-p file)
                   buffer-read-only
                   (not (derived-mode-p 'image-mode 'pdf-view-mode 'doc-view-mode)))
          (read-only-mode -1))
        (when (and (or font-lock-defaults
                       (and (fboundp 'treesit-parser-list) (treesit-parser-list)))
                   (bound-and-true-p global-font-lock-mode))
          (font-lock-mode 1))
        (enhanced-dirvish-preview-edit-mode 1)
        ;; Editing text is a text preview: open at the saved text zoom, and
        ;; make zoom keys (C-+/C--, C-x C-+) act on and persist text zoom
        ;; even when the last preview was an image, PDF or folder.
        (unless (derived-mode-p 'image-mode 'pdf-view-mode 'doc-view-mode)
          (setq enhanced-dirvish-active-preview-file file
                enhanced-dirvish-active-preview-kind 'text)
          (enhanced-dirvish-preview--set-text-scale)))
      (enhanced-dirvish-preview--apply-browser-context buf ctx pwin)
      (if (window-live-p pwin)
          (progn
            (set-window-dedicated-p pwin nil)
            (set-window-buffer pwin buf)
            (select-window pwin)
            (message "%s" (substitute-command-keys "Preview Edit: \\[save-buffer] save · \\[enhanced-dirvish-preview-edit-leave] leave (prompt save) · \\[enhanced-dirvish-preview-edit-exit] back · \\[enhanced-dirvish-preview-edit-abort] abort"))
            buf)
        (pop-to-buffer-same-window buf)))))

(defun enhanced-dirvish-open-or-edit-at-point ()
  "Open folder in browser pane, or direct-edit file in preview pane (`RET')."
  (interactive)
  (cond
   ((derived-mode-p 'enhanced-dirvish-computer-mode)
    (call-interactively #'enhanced-dirvish-computer-open-at-point))
   ((derived-mode-p 'enhanced-dirvish-trash-mode)
    (call-interactively #'enhanced-dirvish-trash-restore-at-point))
   (t
    (let ((f (enhanced-dirvish-current-file)))
      (cond
       ((and f (file-directory-p f))
        (enhanced-dirvish-open-location f t))
       ((and f (file-exists-p f))
        (enhanced-dirvish-preview-edit-file f))
       ((derived-mode-p 'dired-mode)
        (dired-find-file))
       (t
        (user-error "No file or folder at point")))))))

(defun enhanced-dirvish-toggle-peek ()
  "Toggle preview drawer / peek panel (`i' / `M-i') across all 4 browser modes."
  (interactive)
  (cond
   ((or (derived-mode-p 'enhanced-dirvish-compact-mode)
        (derived-mode-p 'enhanced-dirvish-icons-mode)
        (not (dirvish-curr)))
    (if-let ((win (or (and (window-live-p enhanced-dirvish-preview-standalone-window)
                           enhanced-dirvish-preview-standalone-window)
                      (get-buffer-window "*Enhanced Dirvish Preview*"))))
        (progn
          (delete-window win)
          (when (eq win enhanced-dirvish-preview-standalone-window)
            (setq enhanced-dirvish-preview-standalone-window nil)))
      (when-let ((f (enhanced-dirvish-current-file)))
        (let ((pwin (enhanced-dirvish-preview--split-standalone-window (selected-window))))
          (enhanced-dirvish-preview-update-standalone f pwin)))))
   (t (dirvish-layout-toggle))))

(defun enhanced-dirvish-preview-find ()
  "Search text inside currently displayed Dirvish or standalone preview window."
  (interactive)
  (let ((win (enhanced-dirvish-preview--active-window)))
    (unless (window-live-p win)
      (user-error "Preview drawer is not visible"))
    (let ((pat (enhanced-dirvish-ui-read-string "Find in preview: ")))
      (when (and pat (not (string-empty-p pat)))
        (with-selected-window win
          (goto-char (point-min))
          (if (search-forward pat nil t)
              (recenter)
            (message "No match for %s in preview" pat)))))))

;;;; Preview Rendering Helpers

(defun enhanced-dirvish-preview--make-buffer (name &optional kind)
  "Create/clear clean read-only preview buffer NAME tagging Enhanced Dirvish KIND."
  (let ((buf (get-buffer-create name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer))
      (setq buffer-read-only t
            enhanced-dirvish-active-preview-kind (or kind 'text))
      (setq-local truncate-lines (not (enhanced-dirvish-prefs-preview-text-wrap (enhanced-dirvish-prefs))))
      (enhanced-dirvish-preview--sync-text-scale))
    buf))

(defun enhanced-dirvish-preview--safe-insert-markdown (file buf &optional window)
  "Render Markdown FILE in BUF at the width of preview WINDOW."
  (let* ((text (with-temp-buffer
                 (insert-file-contents file nil 0 enhanced-dirvish-preview-max-bytes)
                 (buffer-string)))
         (dom (enhanced-dirvish-preview--markdown-dom text)))
    (if (not dom)
        (enhanced-dirvish-preview--insert-basic-markdown file buf)
      (let* ((window (or window (selected-window)))
             (shr-width (max 12 (- (window-body-width window) 3)))
             (shr-use-fonts (display-graphic-p (window-frame window)))
             (shr-bullet "• ")
             (shr-hr-line ?─)
             (shr-inhibit-images t)
             (shr-blocked-images ".*")
             (shr-external-rendering-functions
              '((pre . enhanced-dirvish-preview--markdown-code)
                (img . enhanced-dirvish-preview--markdown-image)
                (dirvish-svg . enhanced-dirvish-preview--markdown-svg)
                (input . enhanced-dirvish-preview--markdown-checkbox)
                (span . enhanced-dirvish-preview--markdown-span)))
             (enhanced-dirvish-preview--markdown-directory (file-name-directory file))
             (enhanced-dirvish-preview--markdown-width (max 1 (window-body-width window t)))
             (enhanced-dirvish-preview--math-images
              (when (and (display-graphic-p) (image-type-available-p 'svg))
                (enhanced-dirvish-preview--markdown-math dom))))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (shr-insert-document dom)
            (enhanced-dirvish-preview--resize-markdown-images)
            (goto-char (point-min))))))))

(defun enhanced-dirvish-preview--markdown-dom (text)
  "Convert Markdown TEXT to an offline HTML document for shr."
  (when (and (executable-find "pandoc") (libxml-available-p))
    (with-temp-buffer
      (insert text)
      (let ((default-directory temporary-file-directory)
            (coding-system-for-read 'utf-8-unix)
            (coding-system-for-write 'utf-8-unix))
        (when (eq 0 (call-process-region
                     (point-min) (point-max) "timeout" t '(t nil) nil "3"
                     "pandoc" "--sandbox" "--from=markdown+tex_math_single_backslash-raw_tex-smart"
                     "--to=html5" "--wrap=none" "--katex" "--no-highlight"))
          (enhanced-dirvish-preview--protect-inline-svg)
          (libxml-parse-html-region (point-min) (point-max)))))))

(defun enhanced-dirvish-preview--protect-inline-svg ()
  "Keep SVG element and attribute spelling through the HTML parser."
  ;; Pandoc escapes SVG inside code fences. Only raw SVG reaches this scan.
  (let ((tag "<\\(/?\\)svg\\(?:[[:space:]]\\(?:[^\"'>]\\|\"[^\"]*\"\\|'[^']*'\\)*\\)?/?>")
        (case-fold-search t)
        (depth 0)
        start)
    (goto-char (point-min))
    (while (re-search-forward (concat "<!--\\(?:.\\|\n\\)*?-->\\|" tag) nil t)
      (when (match-beginning 1)
        (if (equal (match-string 1) "/")
            (setq depth (max 0 (1- depth)))
          (when (zerop depth) (setq start (match-beginning 0)))
          (unless (string-suffix-p "/>" (match-string 0)) (cl-incf depth)))
        (when (and start (zerop depth))
          (let ((svg (buffer-substring-no-properties start (point))))
            (delete-region start (point))
            (insert "<dirvish-svg data=\""
                    (base64-encode-string (encode-coding-string svg 'utf-8) t)
                    "\"></dirvish-svg>")
            (setq start nil)))))))

(defun enhanced-dirvish-preview--math-key (node)
  "Return (DISPLAY . TEX) for a Pandoc math span NODE."
  (let ((class (dom-attr node 'class)))
    (when (member class '("math inline" "math display"))
      (cons (equal class "math display") (dom-texts node "")))))

(defun enhanced-dirvish-preview--markdown-math (dom)
  "Return the SVG results for the TeX spans in DOM."
  (when-let* (((executable-find "node"))
              ((file-readable-p enhanced-dirvish-preview--math-script))
              ((file-readable-p (expand-file-name "tex-svg.js" enhanced-dirvish-markdown-mathjax-directory)))
              (keys (delete-dups (delq nil (mapcar #'enhanced-dirvish-preview--math-key
                                                  (dom-by-tag dom 'span))))))
    (if (equal keys (car enhanced-dirvish-preview--math-cache))
        (cdr enhanced-dirvish-preview--math-cache)
      (with-temp-buffer
        (insert (json-serialize
                 (vconcat (mapcar (lambda (key)
                                   `((tex . ,(cdr key)) (display . ,(or (car key) :false))))
                                 keys))))
        (let ((default-directory temporary-file-directory)
              (coding-system-for-read 'utf-8-unix)
              (coding-system-for-write 'utf-8-unix))
          (when (eq 0 (call-process-region
                       (point-min) (point-max) "timeout" t '(t nil) nil "3" "node"
                       enhanced-dirvish-preview--math-script
                       (expand-file-name enhanced-dirvish-markdown-mathjax-directory)))
            (goto-char (point-min))
            (when-let* ((results (ignore-errors (json-parse-buffer :object-type 'alist
                                                                   :array-type 'list :null-object nil))))
              (let ((images (make-hash-table :test #'equal)))
                (cl-mapc (lambda (key result) (puthash key result images)) keys results)
                (setq enhanced-dirvish-preview--math-cache (cons keys images))
                images))))))))

(defun enhanced-dirvish-preview--markdown-span (node)
  "Insert NODE, using a baseline-aligned SVG if it is a rendered formula."
  (if-let* ((key (enhanced-dirvish-preview--math-key node)))
      (let* ((result (and enhanced-dirvish-preview--math-images
                          (gethash key enhanced-dirvish-preview--math-images)))
             (svg (alist-get 'svg result))
             (foreground (or (face-foreground 'default nil t) "black"))
             (image (when svg
                      (let* ((background (face-background 'default nil t))
                             (rgb (and background (color-values background))))
                        ;; Emacs flattens SVGs against a background before
                        ;; drawing them. Mask that color so frame alpha shows.
                        (create-image
                         (string-replace "currentColor" foreground svg) 'svg t
                         :width (max 1 (round (* (frame-char-height) (alist-get 'ems result))))
                         :ascent (alist-get 'ascent result)
                         :background background
                         :mask (if rgb (list 'heuristic rgb) 'heuristic))))))
        (enhanced-dirvish-preview--insert-markdown-image image (cdr key) (car key)))
    (shr-tag-span node)))

(defun enhanced-dirvish-preview--markdown-code (node)
  "Show a fenced SVG or fontify the code inside NODE."
  (let* ((code (car (dom-by-tag node 'code)))
         (language (car (split-string (or (dom-attr node 'class) ""))))
         (raw (dom-texts (or code node) "")))
    (if (equal language "svg")
        (enhanced-dirvish-preview--insert-markdown-svg raw "[SVG diagram]" t)
      (let* ((syntax (alist-get (downcase (or language ""))
                                enhanced-dirvish-preview--lang-filename-alist nil nil #'string=))
             (styled (if syntax (enhanced-dirvish-preview--fontify-string raw syntax) raw)))
        (shr-ensure-newline)
        (add-face-text-property 0 (length styled) 'enhanced-dirvish-preview-code t styled)
        (insert styled)
        (shr-ensure-newline)))))

(defun enhanced-dirvish-preview--markdown-svg (node)
  "Insert raw inline SVG preserved in NODE."
  (let ((data (dom-attr node 'data)))
    (enhanced-dirvish-preview--insert-markdown-svg
     (and data (ignore-errors (decode-coding-string (base64-decode-string data) 'utf-8)))
     "[SVG diagram]" t)))

(defun enhanced-dirvish-preview--insert-markdown-svg (svg description &optional block)
  "Show self-contained SVG data or DESCRIPTION, on its own line if BLOCK."
  ;; Loading data without a base URI also keeps librsvg from opening files
  ;; referred to by a diagram.
  (enhanced-dirvish-preview--insert-markdown-image
   (when (and svg (display-graphic-p) (image-type-available-p 'svg))
     (ignore-errors
       (create-image svg 'svg t :max-width enhanced-dirvish-preview--markdown-width)))
   description block))

(defun enhanced-dirvish-preview--markdown-image (node)
  "Insert a local Markdown image from NODE, or show its description."
  (let* ((src (dom-attr node 'src))
         (alt (or (dom-attr node 'alt) "[Image]"))
         (path (and src (car (split-string src "[?#]" t))))
         (file (when (and path (not (string-match-p "\\`\\(?:[[:alpha:]][[:alnum:]+.-]*:\\|//\\)" src)))
                 (expand-file-name (url-unhex-string path)
                                   enhanced-dirvish-preview--markdown-directory))))
    (if (and (display-graphic-p) file
             (not (enhanced-dirvish-path-unsafe-probe-p file))
             (file-regular-p file) (file-readable-p file))
        (if (equal (downcase (or (file-name-extension file) "")) "svg")
            (enhanced-dirvish-preview--insert-markdown-svg
             (ignore-errors
               (with-temp-buffer
                 (insert-file-contents file nil 0 enhanced-dirvish-preview-max-bytes)
                 (buffer-string)))
             alt)
          (enhanced-dirvish-preview--insert-markdown-image
           (ignore-errors
             (create-image file nil nil :max-width enhanced-dirvish-preview--markdown-width))
           alt nil))
      (shr-insert alt))))

(defun enhanced-dirvish-preview--markdown-checkbox (node)
  "Show a task marker for a Pandoc checkbox NODE."
  (when (equal (dom-attr node 'type) "checkbox")
    (shr-insert (if (assq 'checked (dom-attributes node)) "☑ " "☐ "))))

(defun enhanced-dirvish-preview--insert-markdown-image (image alt block)
  "Insert IMAGE into shr output, or ALT if unavailable.  BLOCK breaks lines."
  (when block (shr-ensure-newline))
  (if-let* ((size (and image (ignore-errors (image-size image t)))))
      (shr-insert (propertize "￼" 'display image 'help-echo alt
                              'enhanced-dirvish-markdown-image (cons image (car size))))
    (shr-insert alt))
  (when block (shr-ensure-newline)))

(defun enhanced-dirvish-preview--resize-markdown-images ()
  "Scale embedded images to match the preview's current text size."
  (when (text-property-not-all (point-min) (point-max) 'enhanced-dirvish-markdown-image nil)
    (let ((scale (if text-scale-mode (expt text-scale-mode-step text-scale-mode-amount) 1))
          (inhibit-read-only t))
      (with-silent-modifications
        (save-excursion
          (goto-char (point-min))
          (while-let ((match (text-property-search-forward 'enhanced-dirvish-markdown-image)))
            (pcase-let* ((`(,original . ,width) (prop-match-value match))
                         (image (copy-tree original)))
              (setf (image-property image :max-width) nil
                    (image-property image :width) (max 1 (round (* scale width))))
              (put-text-property (prop-match-beginning match) (prop-match-end match)
                                 'display image))))))))

(defun enhanced-dirvish-preview--insert-basic-markdown (file buf)
  "Show headings and fenced code in FILE if the full renderer is unavailable."
  (let ((dir (file-name-directory file))
        (text (with-temp-buffer
                (insert-file-contents file nil 0 enhanced-dirvish-preview-max-bytes)
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
                        (virt (alist-get (downcase lang) enhanced-dirvish-preview--lang-filename-alist
                                         nil nil #'string=))
                        (styled (if virt
                                    (enhanced-dirvish-preview--fontify-string raw virt)
                                  raw))
                        (out-lines (split-string (string-remove-suffix "\n" styled) "\n")))
                   (with-current-buffer buf-target
                     (dolist (cl out-lines)
                       (let ((s (concat "  │ " cl "\n")))
                         (add-face-text-property 0 (length s) 'enhanced-dirvish-preview-code t s)
                         (insert s)))))))))
        (erase-buffer)
        (insert (concat "  "
                        (enhanced-dirvish-icon-glyph 'markdown 'enhanced-dirvish-hint-desc)
                        (propertize (format " Markdown — %s\n\n"
                                            (file-name-nondirectory file))
                                    'face 'enhanced-dirvish-hint-desc)))
        (dolist (line (split-string text "\n"))
          (cond
           ((string-match "\\````\\(.*\\)\\'" line)
            (if in-code
                (progn
                  (funcall flush-code buf code-lang code-lines)
                  (setq in-code nil code-lines nil)
                  (insert (propertize "  └─\n" 'face 'enhanced-dirvish-hint-desc)))
              (setq in-code t
                    code-lines nil
                    code-lang (string-trim (match-string 1 line)))
              (insert (propertize (format "  ┌─ %s\n" (if (string-empty-p code-lang) "code" code-lang))
                                  'face 'enhanced-dirvish-hint-desc))))
           (in-code
            (push line code-lines))
           ((string-match "\\`# \\(.+\\)\\'" line)
            (insert "\n" (propertize (match-string 1 line) 'face 'enhanced-dirvish-preview-heading-1) "\n"))
           ((string-match "\\`## \\(.+\\)\\'" line)
            (insert "\n" (propertize (match-string 1 line) 'face 'enhanced-dirvish-preview-heading-2) "\n"))
           ((string-match "\\`###+ \\(.+\\)\\'" line)
            (insert (propertize (match-string 1 line) 'face 'enhanced-dirvish-preview-heading-3) "\n"))
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
                (insert (concat "  " (enhanced-dirvish-icon-glyph 'pictures 'shadow)
                                (propertize (format " [%s -> %s]\n" alt rel) 'face 'shadow))))))
           (t
            (insert "  " line "\n"))))
        (when in-code
          (funcall flush-code buf code-lang code-lines))
        (goto-char (point-min))))))

(defun enhanced-dirvish-preview--safe-insert-html (file buf)
  "Render local HTML FILE cleanly via `shr' with remote requests disabled."
  (let ((shr-inhibit-images t)
        (shr-blocked-images ".*")
        (dom (with-temp-buffer
               (insert-file-contents file nil 0 enhanced-dirvish-preview-max-bytes)
               (when (fboundp 'libxml-parse-html-region)
                 (libxml-parse-html-region (point-min) (point-max))))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (concat "  "
                        (enhanced-dirvish-icon-glyph 'network 'enhanced-dirvish-hint-desc)
                        (propertize " HTML Document\n\n"
                                    'face 'enhanced-dirvish-hint-desc)))
        (if dom (shr-insert-document dom) (insert-file-contents file nil 0 enhanced-dirvish-preview-max-bytes))
        (goto-char (point-min))))))

(defun enhanced-dirvish-preview--render-tabular (file ext buf)
  "Render CSV/TSV/XLSX/ODS FILE (extension EXT) as aligned sortable columns in BUF."
  (let* ((sep (if (string= ext "tsv") "\t" ","))
         (raw
          (cond
           ((member ext '("csv" "tsv"))
            (with-temp-buffer
              (insert-file-contents file nil 0 enhanced-dirvish-preview-max-bytes)
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
                            'face 'enhanced-dirvish-header-accent))
        (dolist (r rows)
          (insert "  "
                  (mapconcat (lambda (c) (format "%-18s" (truncate-string-to-width (string-trim c) 18 nil nil "…")))
                             (seq-take r 12) " │ ")
                  "\n"))
        (goto-char (point-min))))))

(defun enhanced-dirvish-preview--pandoc (file buf label)
  "Convert document FILE cleanly via offline `pandoc' into BUF."
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize (format "  📃 %s (Rendered via pandoc · %s)\n\n"
                                  label (file-name-nondirectory file))
                          'face 'enhanced-dirvish-hint-desc))
      (if (executable-find "pandoc")
          (process-file "timeout" nil t nil "3" "pandoc" "--standalone=false" "-t" "plain" file)
        (insert "pandoc not found on PATH."))
      (goto-char (point-min)))))

(defun enhanced-dirvish-preview--media-info (file)
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

(defun enhanced-dirvish-preview--3d-or-route (file ext buf)
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
                        (enhanced-dirvish-icon-glyph 'file-3d 'enhanced-dirvish-header-accent)
                        (propertize (format "  %s Preview — %s\n\n"
                                            (upcase ext) (file-name-nondirectory file))
                                    'face 'enhanced-dirvish-header-accent)))
        (insert "  " summary "\n")
        (goto-char (point-min))))))

;;;; Dirvish Preview Dispatchers

(dirvish-define-preview enhanced-dirvish-mount-guard (file)
  "Prevent synchronous hover preview freezes on FUSE/cloud/remote/removable mounts."
  (when (and file (enhanced-dirvish-path-unsafe-probe-p file))
    (let ((kind (enhanced-dirvish-path-mount-kind file)))
      (when (or (not (eq kind 'removable))
                (file-directory-p file))
        `(info . ,(format "  %s mount: %s\n\n  Auto-preview skipped for instant startup/navigation (press RET to open)."
                          (capitalize (symbol-name (if (eq kind 'local) 'remote kind)))
                          (file-name-nondirectory (directory-file-name file))))))))

(dirvish-define-preview enhanced-dirvish-rich-image (file ext preview-window _dv)
  "Enhanced Dirvish Image & Camera RAW preview honoring independent `preview-image-scale' & EXIF."
  (when (and file (not (file-directory-p file))
             (member (downcase (or ext ""))
                     '("png" "jpg" "jpeg" "gif" "webp" "svg" "bmp" "tif" "tiff" "avif" "cr2" "nef" "arw" "dng"))
             (or (not (equal ext "svg"))
                 (enhanced-dirvish-prefs-render-documents-by-default (enhanced-dirvish-prefs))))
    (setq enhanced-dirvish-active-preview-file file
          enhanced-dirvish-active-preview-kind 'image)
    (let* ((scale (enhanced-dirvish-prefs-preview-image-scale (enhanced-dirvish-prefs)))
           (base-w (* (window-pixel-width preview-window) 0.9))
           (base-h (* (window-pixel-height preview-window) 0.78))
           (w (round (* base-w scale)))
           (h (round (* base-h scale)))
           (svg (equal ext "svg"))
           (native-svg (and svg (image-type-available-p 'svg)))
           (raw-p (member (downcase ext) '("cr2" "nef" "arw" "dng")))
           (tmp (expand-file-name (format "img-%s-%d.png" (md5 file) (round (* 100 scale)))
                                  enhanced-dirvish-thumbnail-dir))
           (buf (enhanced-dirvish-preview--make-buffer (format " *Dirvish-preview-img-%s*" (md5 file)) 'image)))
      (when (and (not native-svg) (not (file-exists-p tmp))
                 (executable-find (if raw-p "magick" "vipsthumbnail")))
        (make-directory enhanced-dirvish-thumbnail-dir t)
        (if raw-p
            (ignore-errors (process-file "timeout" nil nil nil "3" "magick" file "-auto-orient" "-resize" (format "%dx%d>" w h) tmp))
          (ignore-errors (process-file "timeout" nil nil nil "2" "vipsthumbnail" file "-s" (format "%dx%d" w h) "-o" tmp))))
      (with-current-buffer buf
        (setq-local enhanced-dirvish-preview--image-scale scale
                    enhanced-dirvish-preview--file file)
        (when svg
          (enhanced-dirvish-preview--set-document-header t))
        (let ((inhibit-read-only t)
              (img-src (if (and (not native-svg) (file-exists-p tmp)) tmp file)))
          (insert (concat "  "
                          (enhanced-dirvish-icon-glyph 'pictures 'enhanced-dirvish-header-accent)
                          (propertize (format "  %s\n\n" (file-name-nondirectory file))
                                      'face 'enhanced-dirvish-header-accent)))
          (when (and (display-graphic-p) (file-readable-p img-src))
            (when-let ((img (create-image img-src (and native-svg 'svg) nil :max-width w :max-height h)))
              (insert "  ")
              (insert-image img "[image]")
              (insert "\n\n")))
          (when (executable-find "exiftool")
            (insert (propertize "  Camera / EXIF\n" 'face 'enhanced-dirvish-section-heading))
            (process-file "timeout" nil t nil "2" "exiftool" "-s" "-s" "-ImageSize" "-Make" "-Model"
                          "-LensModel" "-FocalLength" "-FNumber" "-ExposureTime" "-ISO" "-GPSPosition" file))
          (goto-char (point-min))))
      `(buffer . ,buf))))

(defun enhanced-dirvish-preview--pdf-info (file)
  "Read Poppler's metadata for FILE."
  (when (executable-find "pdfinfo")
    (let ((process-environment (cons "LC_ALL=C" process-environment)))
      (with-temp-buffer
        (when (eq 0 (ignore-errors (process-file "timeout" nil t nil "2" "pdfinfo" file)))
          (buffer-string))))))

(defun enhanced-dirvish-preview--pdf-raster (file page size png)
  "Cache FILE's PAGE rendered at SIZE pixels, and return whether PNG exists."
  (or (file-exists-p png)
      (progn
        (make-directory enhanced-dirvish-thumbnail-dir t)
        (let* ((staging (make-temp-file
                         (expand-file-name ".pdf-" enhanced-dirvish-thumbnail-dir) t))
               (base (expand-file-name "page" staging)))
          (unwind-protect
              (when (and (eq 0 (ignore-errors
                                 (process-file "timeout" nil nil nil "3" "pdftoppm"
                                               "-png" "-singlefile" "-f" (number-to-string page)
                                               "-scale-to" (number-to-string size) file base)))
                         (file-exists-p (concat base ".png")))
                (rename-file (concat base ".png") png t)
                t)
            (delete-directory staging t))))))

(defun enhanced-dirvish-preview--render-pdf (file win buf page &optional turning)
  "Render PAGE of FILE for WIN into BUF.
When TURNING, retain the current page if Poppler cannot render the new one."
  (let* ((default-directory temporary-file-directory)
         (unsafe (enhanced-dirvish-path-unsafe-probe-p file))
         (attrs (unless unsafe (file-attributes file))))
    (when (or attrs (and unsafe (eq (enhanced-dirvish-path-mount-kind file) 'removable)))
      (let* ((old (buffer-local-value 'enhanced-dirvish-preview--pdf-state (window-buffer win)))
             (revision (when attrs
                         (list (file-attribute-modification-time attrs) (file-attribute-size attrs))))
             (info (if (and (equal file (plist-get old :file))
                            (equal revision (plist-get old :revision)))
                       (plist-get old :info)
                     (enhanced-dirvish-preview--pdf-info file)))
             (count (and info (string-match "^Pages:[ \t]+\\([1-9][0-9]*\\)" info)
                         (string-to-number (match-string 1 info))))
             (page (max 1 (if count (min page count) page)))
             (scale (enhanced-dirvish-prefs-preview-pdf-scale (enhanced-dirvish-prefs)))
             (size (max 1 (round (* (window-pixel-width win) 0.88 scale))))
             (png (expand-file-name (format "pdf-%s-%s-p%d-%d.png"
                                            (md5 file) (md5 (prin1-to-string revision)) page size)
                                    enhanced-dirvish-thumbnail-dir))
             (rendered (enhanced-dirvish-preview--pdf-raster file page size png)))
        (when (or rendered (not turning))
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert (propertize
                       (format "  %s PDF Page %d%s\n\n"
                               (enhanced-dirvish-icon-glyph 'file-pdf 'enhanced-dirvish-header-accent)
                               page (if count (format " of %d" count) ""))
                       'face 'enhanced-dirvish-header-accent))
              (if rendered
                  (when (display-graphic-p (window-frame win))
                    (when-let* ((img (create-image png 'png nil :max-width size)))
                      (insert "  ")
                      (insert-image img "[pdf page]")
                      (insert "\n\n")))
                (insert "  Could not render this PDF page.\n\n"))
              (when info (insert info))
              (setq enhanced-dirvish-preview--pdf-state
                    (list :file file :revision revision :info info :count count :page page :scale scale))
              (setq-local enhanced-dirvish-preview--file file
                          buffer-read-only t
                          truncate-lines (not (enhanced-dirvish-prefs-preview-text-wrap
                                               (enhanced-dirvish-prefs))))
              (enhanced-dirvish-preview-pdf-mode 1)
              (goto-char (point-min))
              (set-buffer-modified-p nil)
              (when (eq (window-buffer win) buf)
                (set-window-point win (point-min))
                (set-window-start win (point-min))
                (set-window-vscroll win 0))))
          t)))))

(dirvish-define-preview enhanced-dirvish-rich-pdf (file ext preview-window _dv)
  "Display FILE's PDF page and its metadata in PREVIEW-WINDOW."
  (when (and file (string= (downcase (or ext "")) "pdf") (executable-find "pdftoppm"))
    (let* ((old (buffer-local-value 'enhanced-dirvish-preview--pdf-state
                                    (window-buffer preview-window)))
           (page (if (equal file (plist-get old :file)) (plist-get old :page) 1))
           (buf (get-buffer-create (format " *Dirvish-preview-pdf-%s*" (md5 file)))))
      (when (enhanced-dirvish-preview--render-pdf file preview-window buf page)
        (setq enhanced-dirvish-active-preview-file file
              enhanced-dirvish-active-preview-kind 'pdf)
        (with-current-buffer buf
          (enhanced-dirvish-preview--sync-text-scale))
        `(buffer . ,buf)))))

(dirvish-define-preview enhanced-dirvish-rich-document (file ext preview-window dv)
  "Render Markdown, Org, HTML, DOCX, ODT, RTF, CSV, XLSX, Fonts, 3D/Routes & Archives."
  (when (and file (not (file-directory-p file)))
    (let* ((ext (downcase (or ext "")))
           (p (enhanced-dirvish-prefs))
           (rendered (enhanced-dirvish-prefs-render-documents-by-default p))
           (markdown (member ext '("md" "markdown" "mdown" "mkd")))
           (html (member ext '("html" "htm" "xhtml" "xht" "shtml"))))
      (cond
       ((or markdown html (and (not rendered) (equal ext "svg")))
        (setq enhanced-dirvish-active-preview-file file enhanced-dirvish-active-preview-kind 'text)
        (let ((buf (enhanced-dirvish-preview--make-buffer
                    (format " *Enhanced-Dirvish-Preview-Document-%s*"
                            (if dv (dv-timestamp dv) "standalone"))
                    'text)))
          (cond
           ((not rendered)
            (enhanced-dirvish-preview--render-source-file
             file buf (cond (markdown "preview.md") (html "preview.html") (t "preview.xml"))))
           (markdown (enhanced-dirvish-preview--safe-insert-markdown file buf preview-window))
           (html (enhanced-dirvish-preview--safe-insert-html file buf)))
          (with-current-buffer buf
            (setq-local enhanced-dirvish-preview--file file)
            (enhanced-dirvish-preview--set-document-header rendered))
          `(buffer . ,buf)))
       ((and rendered (member ext '("csv" "tsv" "xlsx" "ods")))
        (setq enhanced-dirvish-active-preview-file file enhanced-dirvish-active-preview-kind 'text)
        (let ((buf (enhanced-dirvish-preview--make-buffer " *Enhanced-Dirvish-Preview-Doc*" 'text)))
          (enhanced-dirvish-preview--render-tabular file ext buf)
          `(buffer . ,buf)))
       ((and rendered (member ext '("docx" "odt" "ott" "rtf")))
        (setq enhanced-dirvish-active-preview-file file enhanced-dirvish-active-preview-kind 'text)
        (let ((buf (enhanced-dirvish-preview--make-buffer " *Enhanced-Dirvish-Preview-Doc*" 'text)))
          (enhanced-dirvish-preview--pandoc file buf (upcase ext))
          `(buffer . ,buf)))
       ((member ext '("stl" "gcode" "gco" "gpx" "kml"))
        (setq enhanced-dirvish-active-preview-file file enhanced-dirvish-active-preview-kind 'other)
        (let ((buf (enhanced-dirvish-preview--make-buffer " *Enhanced-Dirvish-Preview-Doc*" 'other)))
          (enhanced-dirvish-preview--3d-or-route file ext buf)
          `(buffer . ,buf)))
       ((member ext '("ttf" "otf" "woff" "woff2"))
        (setq enhanced-dirvish-active-preview-file file enhanced-dirvish-active-preview-kind 'text)
        `(shell . ("sh" "-c" "fc-query \"$1\" | head -n 40" "_" ,file)))
       ((member ext '("zip" "7z" "tar" "gz" "tgz" "zst" "xz" "bz2" "iso"))
        (setq enhanced-dirvish-active-preview-file file enhanced-dirvish-active-preview-kind 'archive)
        `(shell . ("7z" "l" "-ba" ,file)))
       ((member ext '("mp3" "flac" "wav" "ogg" "opus" "m4a" "aac" "mp4" "mkv" "mov" "webm" "avi"))
        (setq enhanced-dirvish-active-preview-file file enhanced-dirvish-active-preview-kind 'media)
        (let* ((is-vid (member ext '("mp4" "mkv" "mov" "webm" "avi")))
               (thumb (expand-file-name (format "vid-%s.jpg" (md5 file)) enhanced-dirvish-thumbnail-dir))
               (buf (enhanced-dirvish-preview--make-buffer " *Enhanced-Dirvish-Preview-Media*" 'media)))
          (make-directory enhanced-dirvish-thumbnail-dir t)
          (when (and is-vid (not (file-exists-p thumb)) (executable-find "ffmpegthumbnailer"))
            (ignore-errors (process-file "timeout" nil nil nil "3" "ffmpegthumbnailer" "-i" file "-o" thumb "-s" "360" "-t" "15%")))
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (insert (concat "  "
                              (enhanced-dirvish-icon-glyph (if is-vid 'videos 'music) 'enhanced-dirvish-header-accent)
                              (propertize (format " %s   [C-M-SPC: Play/Pause · C-M-←/→: Seek · C-M-m: Mute · O: Open in Player]\n\n"
                                                  (file-name-nondirectory file))
                                          'face 'enhanced-dirvish-header-accent)))
              (when (and is-vid (display-graphic-p) (file-exists-p thumb))
                (when-let ((img (create-image thumb 'jpeg nil :max-width 420)))
                  (insert "  ")
                  (insert-image img "[video frame]")
                  (insert "\n\n")))
              (insert (or (enhanced-dirvish-preview--media-info file) "No media metadata found."))
              (goto-char (point-min))))
          `(buffer . ,buf)))
       (t
        (setq enhanced-dirvish-active-preview-file file enhanced-dirvish-active-preview-kind 'text)
        nil)))))

(defun enhanced-dirvish-pdf-page-step (delta &optional window)
  "Turn the PDF preview in WINDOW by DELTA pages."
  (interactive "p")
  (when-let* ((win (or window (enhanced-dirvish-preview--active-window)))
              (buf (and (window-live-p win) (window-buffer win)))
              (pdf (buffer-local-value 'enhanced-dirvish-preview--pdf-state buf)))
    (let* ((current (plist-get pdf :page))
           (count (plist-get pdf :count))
           (target (max 1 (+ current delta)))
           (page (if count (min count target) target)))
      (unless (= page current)
        (enhanced-dirvish-preview--render-pdf (plist-get pdf :file) win buf page t)))))

(defun enhanced-dirvish-preview--pdf-wheel (event)
  "Turn a PDF page at EVENT's window, or pan when zoomed in."
  (interactive "e")
  (let ((win (posn-window (event-start event))))
    (if (and (window-live-p win)
             (buffer-local-value 'enhanced-dirvish-preview--pdf-state (window-buffer win))
             (<= (enhanced-dirvish-prefs-preview-pdf-scale (enhanced-dirvish-prefs)) 1.0))
        (enhanced-dirvish-pdf-page-step
         (if (memq (event-basic-type event) '(wheel-up mouse-4)) -1 1) win)
      (let ((mouse-wheel-follow-mouse t))
        (mwheel-scroll event)))))

(defvar enhanced-dirvish-preview-pdf-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("<up>" "<prior>" "M-<prior>"))
      (define-key map (kbd key) (lambda () (interactive) (enhanced-dirvish-pdf-page-step -1))))
    (dolist (key '("<down>" "<next>" "M-<next>"))
      (define-key map (kbd key) (lambda () (interactive) (enhanced-dirvish-pdf-page-step 1))))
    (dolist (key '("<wheel-up>" "<wheel-down>" "<mouse-4>" "<mouse-5>"))
      (define-key map (kbd key) #'enhanced-dirvish-preview--pdf-wheel))
    map)
  "Page navigation bindings local to rasterized PDF previews.")

(define-minor-mode enhanced-dirvish-preview-pdf-mode
  "Turn pages in an Enhanced Dirvish PDF preview."
  :keymap enhanced-dirvish-preview-pdf-mode-map)

;;;; Headless MPV IPC Playback Controls for Audio & Video Previews

(defun enhanced-dirvish-media--ipc (json-cmd)
  "Send JSON-CMD alist to `enhanced-dirvish-media-socket' via netcat/python3."
  (when (and enhanced-dirvish-media-socket (file-exists-p enhanced-dirvish-media-socket)
             (process-live-p enhanced-dirvish-media-proc))
    (condition-case nil
        (let ((proc (make-network-process :name "enhanced-dirvish-mpv-ipc"
                                          :family 'local
                                          :service enhanced-dirvish-media-socket
                                          :noquery t)))
          (process-send-string proc (concat (json-encode json-cmd) "\n"))
          (delete-process proc))
      (error nil))))

(defun enhanced-dirvish-media-stop ()
  "Stop any running Enhanced Dirvish preview playback process."
  (interactive)
  (when (process-live-p enhanced-dirvish-media-proc)
    (delete-process enhanced-dirvish-media-proc))
  (setq enhanced-dirvish-media-proc nil
        enhanced-dirvish-media-paused nil)
  (when (and enhanced-dirvish-media-socket (file-exists-p enhanced-dirvish-media-socket))
    (ignore-errors (delete-file enhanced-dirvish-media-socket))))

(defun enhanced-dirvish-media-play-pause ()
  "Play/pause audio or video for current item using headless `mpv' (`C-M-SPC')."
  (interactive)
  (let ((f (or (enhanced-dirvish-current-file) enhanced-dirvish-active-preview-file)))
    (unless (and f (file-readable-p f))
      (user-error "No media file selected"))
    (if (and (process-live-p enhanced-dirvish-media-proc) (equal f enhanced-dirvish-media-file))
        (progn
          (setq enhanced-dirvish-media-paused (not enhanced-dirvish-media-paused))
          (enhanced-dirvish-media--ipc `((command . ["cycle" "pause"])))
          (message "Media %s: %s" (if enhanced-dirvish-media-paused "paused" "resumed")
                   (file-name-nondirectory f)))
      (unless (executable-find "mpv")
        (user-error "mpv is not installed"))
      (enhanced-dirvish-media-stop)
      (setq enhanced-dirvish-media-socket (expand-file-name (format "mpv-%d.sock" (emacs-pid))
                                                  temporary-file-directory)
            enhanced-dirvish-media-file f
            enhanced-dirvish-media-paused nil
            enhanced-dirvish-media-position 0.0)
      (setq enhanced-dirvish-media-proc
            (make-process
             :name "enhanced-dirvish-mpv"
             :noquery t
             :command (list "mpv" "--no-video" "--really-quiet"
                            (format "--volume=%d" (enhanced-dirvish-prefs-preview-volume (enhanced-dirvish-prefs)))
                            (if (enhanced-dirvish-prefs-preview-muted (enhanced-dirvish-prefs)) "--mute=yes" "--mute=no")
                            (format "--input-ipc-server=%s" enhanced-dirvish-media-socket)
                            f)))
      (message "Playing preview: %s" (file-name-nondirectory f)))))

(defun enhanced-dirvish-media-seek (seconds)
  "Seek active media playback by SECONDS (`C-M-left`/`C-M-right')."
  (interactive "nSeek seconds: ")
  (setq enhanced-dirvish-media-position (max 0.0 (+ enhanced-dirvish-media-position seconds)))
  (enhanced-dirvish-media--ipc `((command . ["seek" ,seconds "relative"])))
  (message "Seek %+ds" seconds))

(defun enhanced-dirvish-media-mute-toggle ()
  "Mute/unmute active Enhanced Dirvish media preview (`C-M-m` / `m')."
  (interactive)
  (let ((p (enhanced-dirvish-prefs)))
    (setf (enhanced-dirvish-prefs-preview-muted p) (not (enhanced-dirvish-prefs-preview-muted p)))
    (enhanced-dirvish-prefs-save)
    (enhanced-dirvish-media--ipc `((command . ["set_property" "mute" ,(if (enhanced-dirvish-prefs-preview-muted p) t :json-false)])))
    (message "Preview audio %s" (if (enhanced-dirvish-prefs-preview-muted p) "muted" "unmuted"))))

(defun enhanced-dirvish-media-volume-step (delta)
  "Adjust preview audio volume by DELTA (`C-M-up`/`C-M-down`)."
  (interactive "p")
  (let* ((p (enhanced-dirvish-prefs))
         (v (max 0 (min 150 (+ (enhanced-dirvish-prefs-preview-volume p) delta)))))
    (setf (enhanced-dirvish-prefs-preview-volume p) v)
    (enhanced-dirvish-prefs-save)
    (enhanced-dirvish-media--ipc `((command . ["set_property" "volume" ,v])))
    (message "Preview volume: %d%%" v)))

(defun enhanced-dirvish-media-open-external ()
  "Open video/audio file in external `mpv' at last playback position."
  (interactive)
  (let ((f (or (enhanced-dirvish-current-file) enhanced-dirvish-media-file)))
    (unless (and f (executable-find "mpv"))
      (user-error "Cannot launch mpv for %s" f))
    (let ((pos enhanced-dirvish-media-position))
      (enhanced-dirvish-media-stop)
      (make-process :name "enhanced-dirvish-mpv-ext" :noquery t
                    :command (list "mpv" (format "--start=%.1f" pos) f)))))

(provide 'enhanced-dirvish-previews)
;;; enhanced-dirvish-previews.el ends here
