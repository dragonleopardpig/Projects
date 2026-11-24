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
(declare-function emacs-minder-core-drag-begin "emacs-minder-core" (handle kind node-id move-subtree w h rw rh))
(declare-function emacs-minder-core-drag-step "emacs-minder-core" (handle dx dy width w h rw rh))
(declare-function emacs-minder-core-drag-end "emacs-minder-core" (handle))
(declare-function emacs-minder-core-pan-fast "emacs-minder-core" (handle dx dy w h rw rh))
(declare-function emacs-minder-core-zoom-fast "emacs-minder-core" (handle factor anchor-x anchor-y w h rw rh))
(declare-function org-table-align "org-table" (&optional no-shrink))
(declare-function org-latex-preview "org" (&optional arg))

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

(defcustom emacs-minder-inline-edit-use-child-frame t
  "When non-nil in GUI Emacs, edit node text in a floating inline child frame."
  :type 'boolean
  :group 'emacs-minder)

(defcustom emacs-minder-drag-render-scale 'auto
  "Raster resolution factor during active mouse drags (`auto' or 0.35..1.0)."
  :type '(choice (const :tag "Auto (~0.8 MP adaptive)" auto)
                 (number :tag "Fixed scale (0.35..1.0)"))
  :group 'emacs-minder)

(defcustom emacs-minder-smooth-wheel t
  "When non-nil in GUI frames, interpolate wheel panning and settle to 1.0x."
  :type 'boolean
  :group 'emacs-minder)

(defcustom emacs-minder-wheel-step 90.0
  "Pixel pan delta per mouse wheel tick."
  :type 'number
  :group 'emacs-minder)

(defcustom emacs-minder-formula-ocr-command nil
  "Executable path or name for local formula image-to-LaTeX OCR.
When nil, check the `MINDER_FORMULA_OCR' environment variable and
then fall back to `formulaocr-offline' in `PATH'."
  :type '(choice (const :tag "Auto (MINDER_FORMULA_OCR or formulaocr-offline)" nil)
                 file
                 string)
  :group 'emacs-minder)

(defcustom emacs-minder-formula-ocr-use-worker t
  "Whether to keep a persistent `formulaocr-offline --worker' running.
Using a persistent worker avoids reloading the deep learning model on
each paste."
  :type '(choice (const :tag "Auto (when using formulaocr-offline)" t)
                 (const :tag "Always use --worker" force)
                 (const :tag "One-shot process per paste" nil))
  :group 'emacs-minder)

(defcustom emacs-minder-formula-ocr-timeout 180
  "Maximum seconds to wait for a single formula OCR request."
  :type 'number
  :group 'emacs-minder)

(defcustom emacs-minder-formula-delimiters 'auto
  "How recognized LaTeX equations are delimited upon insertion."
  :type '(choice (const :tag "Auto (\\(...\\) in Org, $$...$$ in Minder)" auto)
                 (const :tag "$$...$$" dollar-dollar)
                 (const :tag "\\(...\\)" paren)
                 (const :tag "Raw LaTeX (no delimiters)" none))
  :group 'emacs-minder)

(defvar emacs-minder--loaded nil)

(defvar emacs-minder--ocr-worker-proc nil)
(defvar emacs-minder--ocr-worker-cmd nil)
(defvar emacs-minder--ocr-worker-ready nil)
(defvar emacs-minder--ocr-worker-buf "")
(defvar emacs-minder--ocr-next-id 0)
(defvar emacs-minder--ocr-pending nil)
(defvar emacs-minder--ocr-queue nil)

(defvar-local emacs-minder--handle nil)
(defvar-local emacs-minder--file-path nil)
(put 'emacs-minder--file-path 'permanent-local t)
(defvar-local emacs-minder--state nil)
(defvar-local emacs-minder--timer nil)
(defvar-local emacs-minder--last-size nil)
(defvar-local emacs-minder--last-image nil)
(defvar-local emacs-minder--scroll-rem-x 0.0)
(defvar-local emacs-minder--scroll-rem-y 0.0)
(defvar-local emacs-minder--scroll-timer nil)
(defvar-local emacs-minder--settle-timer nil)
(defvar-local emacs-minder--render-in-progress nil)
(defvar-local emacs-minder--inline-frame nil)
(defvar-local emacs-minder--inline-buffer nil)

(defvar-local emacs-minder--source-buffer nil)
(defvar-local emacs-minder--target-node-id nil)
(defvar-local emacs-minder--inline-was-new nil)

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
  (emacs-minder--cancel-smooth-timers)
  (emacs-minder--cmd-raw alist)
  (emacs-minder--render t)
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

(defun emacs-minder--display-png (png &optional scale)
  "Display PNG bytes in the current canvas buffer and evict previous image."
  (let ((inhibit-read-only t)
        (img (create-image png 'png t :scale (or scale 1.0)))
        (prev emacs-minder--last-image))
    (setq emacs-minder--last-image img)
    (if (= (buffer-size) 1)
        (put-text-property (point-min) (point-max) 'display img)
      (erase-buffer)
      (insert (propertize " " 'display img 'pointer 'arrow)))
    (goto-char (point-min))
    (when (and prev (not (eq prev img)))
      (ignore-errors (image-flush prev)))))

(defun emacs-minder--render (&optional skip-state-refresh)
  "Render current canvas PNG bytes cleanly into the buffer.
When SKIP-STATE-REFRESH is non-nil, reuse `emacs-minder--state'."
  (when (and emacs-minder--handle (not emacs-minder--render-in-progress))
    (let ((emacs-minder--render-in-progress t))
      (pcase-let ((`(,w . ,h) (emacs-minder--viewport-pixels)))
        (setq emacs-minder--last-size (cons w h))
        (let* ((png (emacs-minder-core-render-png emacs-minder--handle w h))
               (st (if (and skip-state-refresh emacs-minder--state)
                       emacs-minder--state
                     (emacs-minder--parse-json (emacs-minder-core-state-json emacs-minder--handle)))))
          (setq emacs-minder--state st)
          (set-buffer-modified-p (and (alist-get 'dirty st) t))
          (emacs-minder--update-header)
          (emacs-minder--display-png png 1.0))))))

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

(defun emacs-minder--cancel-smooth-timers ()
  "Stop any active smooth-scroll or crisp-settle timers in the current buffer."
  (when (timerp emacs-minder--scroll-timer)
    (cancel-timer emacs-minder--scroll-timer)
    (setq emacs-minder--scroll-timer nil))
  (when (timerp emacs-minder--settle-timer)
    (cancel-timer emacs-minder--settle-timer)
    (setq emacs-minder--settle-timer nil))
  (setq emacs-minder--scroll-rem-x 0.0
        emacs-minder--scroll-rem-y 0.0))

(defun emacs-minder--cleanup-buffer ()
  "Stop buffer-local polling timer and close any inline edit frame."
  (emacs-minder--cancel-smooth-timers)
  (when (timerp emacs-minder--timer)
    (cancel-timer emacs-minder--timer)
    (setq emacs-minder--timer nil))
  (when (frame-live-p emacs-minder--inline-frame)
    (ignore-errors (delete-frame emacs-minder--inline-frame t))
    (setq emacs-minder--inline-frame nil))
  (when (buffer-live-p emacs-minder--inline-buffer)
    (ignore-errors (kill-buffer emacs-minder--inline-buffer))
    (setq emacs-minder--inline-buffer nil))
  (when emacs-minder--last-image
    (ignore-errors (image-flush emacs-minder--last-image))
    (setq emacs-minder--last-image nil)))

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

(defvar emacs-minder-inline-edit-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET")        #'emacs-minder-inline-edit-commit)
    (define-key m (kbd "<return>")   #'emacs-minder-inline-edit-commit)
    (define-key m (kbd "C-c C-c")    #'emacs-minder-inline-edit-commit)
    (define-key m (kbd "S-<return>") #'newline)
    (define-key m (kbd "M-RET")      #'newline)
    (define-key m (kbd "C-j")        #'newline)
    (define-key m (kbd "TAB")        #'emacs-minder-inline-edit-commit-and-add-child)
    (define-key m (kbd "<tab>")      #'emacs-minder-inline-edit-commit-and-add-child)
    (define-key m (kbd "<escape>")   #'emacs-minder-inline-edit-cancel)
    (define-key m (kbd "C-g")        #'emacs-minder-inline-edit-cancel)
    (define-key m (kbd "C-c C-k")    #'emacs-minder-inline-edit-cancel)
    (define-key m (kbd "C-M-v")      #'emacs-minder-paste-clipboard-latex)
    m)
  "Keymap for floating inline node text editing.")

(define-derived-mode emacs-minder-inline-edit-mode text-mode "MinderNode"
  "Major mode for inline floating node text editing in `emacs-minder'."
  :keymap emacs-minder-inline-edit-mode-map
  (setq-local mode-line-format nil
              header-line-format nil
              truncate-lines nil)
  (visual-line-mode 1))

(defun emacs-minder--node-screen-box ()
  "Compute floating editor `(LEFT TOP WIDTH HEIGHT)' in parent-frame pixels."
  (let* ((st emacs-minder--state)
         (sel (alist-get 'selected st))
         (win (or (get-buffer-window (current-buffer) 'visible)
                  (selected-window)))
         (edges (and (window-live-p win) (window-inside-pixel-edges win)))
         (wx0 (or (nth 0 edges) 0))
         (wy0 (or (nth 1 edges) 0))
         (wx1 (or (nth 2 edges) (+ wx0 1200)))
         (wy1 (or (nth 3 edges) (+ wy0 800)))
         (scale (or (alist-get 'scale st) 1.0))
         (ox (or (alist-get 'origin_x st) 0.0))
         (oy (or (alist-get 'origin_y st) 0.0))
         (nx (or (and sel (alist-get 'posx sel)) 0.0))
         (ny (or (and sel (alist-get 'posy sel)) 0.0))
         (nw (or (and sel (alist-get 'width sel)) 180.0))
         (nh (or (and sel (alist-get 'height sel)) 38.0))
         (sx (+ wx0 (round (* (- nx ox) scale))))
         (sy (+ wy0 (round (* (- ny oy) scale))))
         (sw (min 680 (max 280 (round (* nw scale)))))
         (sh (min 240 (max 42 (round (* nh scale)))))
         (left (max wx0 (min sx (- wx1 sw 12))))
         (top (max wy0 (min sy (- wy1 sh 12)))))
    (list left top sw sh)))

(defun emacs-minder--inline-close (&optional frame)
  "Close floating inline editor FRAME and restore focus to its source buffer."
  (let* ((src emacs-minder--source-buffer)
         (fr (or frame (selected-frame))))
    (when (and (buffer-live-p src))
      (with-current-buffer src
        (when (frame-live-p emacs-minder--inline-frame)
          (setq fr emacs-minder--inline-frame))
        (setq emacs-minder--inline-frame nil)
        (when (buffer-live-p emacs-minder--inline-buffer)
          (let ((b emacs-minder--inline-buffer))
            (setq emacs-minder--inline-buffer nil)
            (when (frame-live-p fr)
              (delete-frame fr t))
            (kill-buffer b)))
        (when-let* ((win (get-buffer-window src 'visible)))
          (let ((pf (window-frame win)))
            (select-window win)
            (when (frame-live-p pf)
              (select-frame-set-input-focus pf))))))
    (when (frame-live-p fr)
      (ignore-errors (delete-frame fr t)))))

(defun emacs-minder--inline-grow (&rest _ignored)
  "Grow floating child frame height gently as multi-line content changes."
  (when-let* ((src emacs-minder--source-buffer)
              (fr (and (buffer-live-p src)
                       (buffer-local-value 'emacs-minder--inline-frame src))))
    (when (frame-live-p fr)
      (let* ((lines (max 1 (min 8 (count-lines (point-min) (point-max)))))
             (want-h (max 42 (+ 14 (* lines (frame-char-height fr))))))
        (set-frame-height fr want-h nil t)))))

(defun emacs-minder-inline-edit-commit ()
  "Commit inline node text back into the mind map node and close editor."
  (interactive)
  (let* ((src emacs-minder--source-buffer)
         (nid emacs-minder--target-node-id)
         (was-new emacs-minder--inline-was-new)
         (raw (string-trim-right (buffer-substring-no-properties (point-min) (point-max))))
         (text (if (and was-new (string-empty-p raw)) "New Node" raw)))
    (emacs-minder--inline-close)
    (when (buffer-live-p src)
      (with-current-buffer src
        (when nid
          (emacs-minder--cmd `((op . "set_text") (id . ,nid) (text . ,text))))))))

(defun emacs-minder-inline-edit-commit-and-add-child ()
  "Commit current inline node text and immediately add/edit a child node."
  (interactive)
  (let ((src emacs-minder--source-buffer))
    (emacs-minder-inline-edit-commit)
    (when (buffer-live-p src)
      (with-current-buffer src
        (emacs-minder-add-child)))))

(defun emacs-minder-inline-edit-cancel ()
  "Cancel inline node text editing; discard newly created empty node if blank."
  (interactive)
  (let* ((src emacs-minder--source-buffer)
         (was-new emacs-minder--inline-was-new)
         (cur (string-trim (buffer-substring-no-properties (point-min) (point-max)))))
    (emacs-minder--inline-close)
    (when (and was-new (string-empty-p cur) (buffer-live-p src))
      (with-current-buffer src
        (emacs-minder--cmd '((op . "undo")))))))

(defun emacs-minder--open-inline-editor (node-id initial-text &optional is-new)
  "Open a floating child-frame editor over NODE-ID with INITIAL-TEXT.
When IS-NEW is non-nil, cancelling with empty text undoes the new node."
  (if (and emacs-minder-inline-edit-use-child-frame
           (display-graphic-p)
           (window-live-p (get-buffer-window (current-buffer) 'visible)))
      (pcase-let* ((src (current-buffer))
                   (win (get-buffer-window src 'visible))
                   (pf (window-frame win))
                   (`(,left ,top ,w ,h) (emacs-minder--node-screen-box))
                   (accent (emacs-minder--color-hex 'font-lock-keyword-face :foreground "#64baff"))
                   (bg (emacs-minder--color-hex 'default :background "#20242c"))
                   (fg (emacs-minder--color-hex 'default :foreground "#eceff4"))
                   (buf (get-buffer-create (format " *Minder Inline [%s]*" node-id))))
        (when (frame-live-p emacs-minder--inline-frame)
          (ignore-errors (delete-frame emacs-minder--inline-frame t))
          (setq emacs-minder--inline-frame nil))
        (with-current-buffer buf
          (erase-buffer)
          (insert (or initial-text ""))
          (emacs-minder-inline-edit-mode)
          (setq emacs-minder--source-buffer src
                emacs-minder--target-node-id node-id
                emacs-minder--inline-was-new is-new)
          (add-hook 'after-change-functions #'emacs-minder--inline-grow nil t)
          (goto-char (point-max)))
        (let ((fr (make-frame
                   `((parent-frame . ,pf)
                     (undecorated . t)
                     (minibuffer . nil)
                     (left . ,left)
                     (top . ,top)
                     (width . (text-pixels . ,w))
                     (height . (text-pixels . ,h))
                     (internal-border-width . 2)
                     (left-fringe . 4)
                     (right-fringe . 4)
                     (vertical-scroll-bars . nil)
                     (horizontal-scroll-bars . nil)
                     (menu-bar-lines . 0)
                     (tool-bar-lines . 0)
                     (tab-bar-lines . 0)
                     (cursor-type . bar)
                     (no-accept-focus . nil)))))
          (set-face-background 'internal-border accent fr)
          (set-frame-parameter fr 'background-color bg)
          (set-frame-parameter fr 'foreground-color fg)
          (let ((cwin (frame-selected-window fr)))
            (set-window-buffer cwin buf)
            (set-window-dedicated-p cwin t))
          (setq emacs-minder--inline-frame fr
                emacs-minder--inline-buffer buf)
          (select-frame-set-input-focus fr)))
    (let* ((prompt (if is-new "New node text (LaTeX OK): " "Node text (LaTeX OK): "))
           (updated (read-string prompt (or initial-text "")))
           (final (if (and is-new (string-empty-p updated)) "New Node" updated)))
      (emacs-minder--cmd `((op . "set_text") (id . ,node-id) (text . ,final))))))

(defun emacs-minder--add-node-and-edit (op fallback-text)
  "Create a new node with OP, render it, and open the inline editor."
  (if (and emacs-minder-inline-edit-use-child-frame
           (display-graphic-p)
           (window-live-p (get-buffer-window (current-buffer) 'visible)))
      (let* ((st (emacs-minder--cmd `((op . ,op) (text . ""))))
             (nid (alist-get 'selected_node st)))
        (when nid
          (emacs-minder--open-inline-editor nid "" t)))
    (let ((txt (read-string "Node text (LaTeX OK): ")))
      (emacs-minder--cmd `((op . ,op)
                           (text . ,(if (string-empty-p txt) fallback-text txt)))))))

(defun emacs-minder-add-child ()
  "Create a child node under the selected node and edit it in place."
  (interactive)
  (emacs-minder--add-node-and-edit "add_child" "New Node"))

(defun emacs-minder-add-sibling ()
  "Create a sibling node next to the selected node and edit it in place."
  (interactive)
  (emacs-minder--add-node-and-edit "add_sibling" "Sibling Node"))

(defun emacs-minder-add-parent ()
  "Insert a new parent wrapper node above selected node and edit in place."
  (interactive)
  (emacs-minder--add-node-and-edit "add_parent" "Parent Topic"))

(defun emacs-minder-add-root ()
  "Add a new root topic and edit it in place."
  (interactive)
  (emacs-minder--add-node-and-edit "add_root" "Main Idea"))

(defun emacs-minder-widen-node ()
  "Increase the selected node box width by 40 pixels."
  (interactive)
  (when-let* ((sel (alist-get 'selected emacs-minder--state))
              (nid (alist-get 'id sel))
              (cur-w (or (alist-get 'width sel) 180.0)))
    (emacs-minder--cmd `((op . "resize_node") (id . ,nid) (width . ,(min 1800.0 (+ cur-w 40.0)))))))

(defun emacs-minder-narrow-node ()
  "Decrease the selected node box width by 40 pixels."
  (interactive)
  (when-let* ((sel (alist-get 'selected emacs-minder--state))
              (nid (alist-get 'id sel))
              (cur-w (or (alist-get 'width sel) 180.0)))
    (emacs-minder--cmd `((op . "resize_node") (id . ,nid) (width . ,(max 68.0 (- cur-w 40.0)))))))

(defun emacs-minder-delete-selected ()
  "Delete the currently selected node subtree."
  (interactive)
  (emacs-minder--cmd '((op . "delete_selected"))))

(defun emacs-minder-edit-node-text ()
  "Edit the selected node title in place (supports LaTeX `$...$' and `\\(...\\)')."
  (interactive)
  (let* ((sel (alist-get 'selected emacs-minder--state))
         (nid (and sel (alist-get 'id sel)))
         (cur (or (and sel (alist-get 'text sel)) "")))
    (when nid
      (emacs-minder--open-inline-editor nid cur nil))))

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

;;; Formula Image OCR (LaTeX)

(defun emacs-minder--find-formula-ocr ()
  "Locate the configured formula OCR executable, or return nil."
  (let ((env-cmd (getenv "MINDER_FORMULA_OCR")))
    (cl-loop for cand in (list emacs-minder-formula-ocr-command
                               (and env-cmd (not (string-empty-p env-cmd)) env-cmd)
                               "formulaocr-offline")
             when (and (stringp cand) (not (string-empty-p cand)))
             for expanded = (expand-file-name cand)
             for resolved = (cond
                             ((file-executable-p expanded) expanded)
                             ((executable-find cand)))
             when resolved return resolved)))

(defun emacs-minder--formula-ocr-supports-worker-p (cmd)
  "Return non-nil if CMD should run as a persistent `--worker' daemon."
  (and cmd
       (or (eq emacs-minder-formula-ocr-use-worker 'force)
           (and emacs-minder-formula-ocr-use-worker
                (string-match-p "formulaocr-offline"
                                (file-name-nondirectory cmd))))))

(defun emacs-minder--strip-outer-math-delimiters (formula)
  "Strip a single outer `$$...$$', `\\(...\\)', or `\\[...\\]' pair from FORMULA."
  (let ((s (string-trim formula)))
    (cond
     ((and (>= (length s) 4)
           (string-prefix-p "$$" s)
           (string-suffix-p "$$" s)
           (not (string-match-p "\\$\\$" (substring s 2 -2))))
      (string-trim (substring s 2 -2)))
     ((and (>= (length s) 4)
           (string-prefix-p "\\(" s)
           (string-suffix-p "\\)" s)
           (not (string-match-p "\\\\)" (substring s 2 -2))))
      (string-trim (substring s 2 -2)))
     ((and (>= (length s) 4)
           (string-prefix-p "\\[" s)
           (string-suffix-p "\\]" s)
           (not (string-match-p "\\\\]" (substring s 2 -2))))
      (string-trim (substring s 2 -2)))
     (t s))))

(defun emacs-minder--format-formula (formula &optional backing-file)
  "Format recognized LaTeX FORMULA according to `emacs-minder-formula-delimiters'.
BACKING-FILE helps `'auto' distinguish `.org' from `.minder' buffers."
  (let ((raw (emacs-minder--strip-outer-math-delimiters formula)))
    (pcase emacs-minder-formula-delimiters
      ('none raw)
      ('paren (format "\\(%s\\)" raw))
      ('dollar-dollar (format "$$%s$$" raw))
      (_
       (if (or (derived-mode-p 'org-mode 'latex-mode 'LaTeX-mode 'tex-mode)
               (and (stringp backing-file)
                    (string-suffix-p ".org" (downcase backing-file))))
           (format "\\(%s\\)" raw)
         (format "$$%s$$" raw))))))

(defun emacs-minder--grab-clipboard-image-async (callback)
  "Asynchronously grab a clipboard image and invoke CALLBACK with (PATH ERR)."
  (let* ((wl (executable-find "wl-paste"))
         (xc (executable-find "xclip"))
         (use-wl (and wl (or (getenv "WAYLAND_DISPLAY") (not xc))))
         (backend (cond (use-wl "Wayland") (xc "X11"))))
    (if (not backend)
        (funcall callback nil "Neither wl-paste nor xclip found in PATH")
      (let* ((tmp (make-temp-file "minder-formula-" nil ".png"))
             (out-buf (generate-new-buffer " *emacs-minder-clip-mime*"))
             (list-cmd (if use-wl
                           "wl-paste --list-types"
                         "xclip -selection clipboard -t TARGETS -o"))
             (grab-cmd (if use-wl
                           "wl-paste --no-newline -t \"$m\""
                         "xclip -selection clipboard -t \"$m\" -o"))
             (script (format
                      (concat
                       "types=$(%s 2>/dev/null) || exit 2\n"
                       "for m in image/png image/jpeg image/webp image/bmp; do\n"
                       "  if printf '%%s\\n' \"$types\" | grep -Fxq \"$m\"; then\n"
                       "    %s > \"$1\" 2>/dev/null && [ -s \"$1\" ] && { printf '%%s\\n' \"$m\"; exit 0; }\n"
                       "  fi\n"
                       "done\n"
                       "exit 3\n")
                      list-cmd grab-cmd)))
        (make-process
         :name "emacs-minder-clip-image"
         :buffer out-buf
         :stderr nil
         :command (list "sh" "-c" script "_" tmp)
         :noquery t
         :sentinel
         (lambda (p _ev)
           (when (memq (process-status p) '(exit signal))
             (let ((mime (if (buffer-live-p out-buf)
                             (string-trim (with-current-buffer out-buf (buffer-string)))
                           "")))
               (when (buffer-live-p out-buf)
                 (kill-buffer out-buf))
               (if (and (eq (process-status p) 'exit)
                        (zerop (process-exit-status p))
                        (file-exists-p tmp)
                        (> (or (file-attribute-size (file-attributes tmp)) 0) 0))
                   (let* ((ext (pcase mime
                                 ("image/jpeg" ".jpg")
                                 ("image/webp" ".webp")
                                 ("image/bmp" ".bmp")
                                 (_ ".png")))
                          (dest (if (string= ext ".png")
                                    tmp
                                  (let ((renamed (concat (file-name-sans-extension tmp) ext)))
                                    (rename-file tmp renamed t)
                                    renamed))))
                     (funcall callback dest nil))
                 (ignore-errors (delete-file tmp))
                 (funcall callback nil (format "No image found in %s clipboard" backend)))))))))))

(defun emacs-minder--ocr-stderr-tail ()
  "Return the last non-empty stderr line from the OCR worker, or nil."
  (when-let* ((buf (get-buffer " *emacs-minder-formula-ocr-stderr*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((lines (split-string (buffer-string) "\n" t)))
          (when lines
            (string-trim (car (last lines)))))))))

(defun emacs-minder--ocr-finish-req (req result err)
  "Finalize OCR request REQ once with RESULT or ERR, cleaning up resources."
  (unless (plist-get req :done)
    (plist-put req :done t)
    (let ((id (plist-get req :id))
          (tm (plist-get req :timer))
          (img (plist-get req :image))
          (cb (plist-get req :callback)))
      (setq emacs-minder--ocr-queue (delq req emacs-minder--ocr-queue)
            emacs-minder--ocr-pending (assq-delete-all id emacs-minder--ocr-pending))
      (when (timerp tm)
        (cancel-timer tm))
      (plist-put req :timer nil)
      (when (and (stringp img) (file-exists-p img))
        (ignore-errors (delete-file img)))
      (when cb
        (funcall cb result err)))))

(defun emacs-minder--ocr-fail-all (err)
  "Fail all queued and pending OCR requests with ERR."
  (let ((reqs (append emacs-minder--ocr-queue
                      (mapcar #'cdr emacs-minder--ocr-pending))))
    (setq emacs-minder--ocr-queue nil
          emacs-minder--ocr-pending nil)
    (dolist (req reqs)
      (emacs-minder--ocr-finish-req req nil err))))

(defun emacs-minder--ocr-send-req (req)
  "Submit OCR request REQ to the active `--worker' process."
  (let ((id (plist-get req :id))
        (img (plist-get req :image)))
    (push (cons id req) emacs-minder--ocr-pending)
    (condition-case err
        (process-send-string
         emacs-minder--ocr-worker-proc
         (concat (json-encode `((id . ,id) (image . ,img))) "\n"))
      (error
       (emacs-minder--ocr-finish-req req nil (error-message-string err))))))

(defun emacs-minder--ocr-dispatch-queue ()
  "Send queued OCR requests if the `--worker' process is ready."
  (while (and emacs-minder--ocr-worker-ready
              (process-live-p emacs-minder--ocr-worker-proc)
              emacs-minder--ocr-queue)
    (let ((req (pop emacs-minder--ocr-queue)))
      (unless (plist-get req :done)
        (emacs-minder--ocr-send-req req)))))

(defun emacs-minder--ocr-worker-filter (proc chunk)
  "Parse NDJSON stdout CHUNK from the persistent OCR worker PROC."
  (when (eq proc emacs-minder--ocr-worker-proc)
    (setq emacs-minder--ocr-worker-buf (concat emacs-minder--ocr-worker-buf chunk))
    (let ((lines (split-string emacs-minder--ocr-worker-buf "\n")))
      (setq emacs-minder--ocr-worker-buf (car (last lines)))
      (dolist (line (butlast lines))
        (let* ((trimmed (string-trim line))
               (msg (and (not (string-empty-p trimmed))
                         (ignore-errors (emacs-minder--parse-json trimmed)))))
          (when msg
            (cond
             ((alist-get 'ready msg)
              (setq emacs-minder--ocr-worker-ready t)
              (unless emacs-minder--ocr-queue
                (message "Formula OCR worker ready"))
              (emacs-minder--ocr-dispatch-queue))
             ((alist-get 'id msg)
              (let* ((id (alist-get 'id msg))
                     (req (cdr (assq id emacs-minder--ocr-pending))))
                (when req
                  (if (alist-get 'ok msg)
                      (let ((tex (string-trim (or (alist-get 'formula msg) ""))))
                        (if (string-empty-p tex)
                            (emacs-minder--ocr-finish-req req nil "Formula OCR returned empty LaTeX")
                          (emacs-minder--ocr-finish-req req tex nil)))
                    (emacs-minder--ocr-finish-req
                     req nil (or (alist-get 'error msg) "Formula OCR failed")))))))))))))

(defun emacs-minder--ocr-worker-sentinel (proc _ev)
  "Handle exit or signal of the persistent OCR worker PROC."
  (when (and (eq proc emacs-minder--ocr-worker-proc)
             (memq (process-status proc) '(exit signal)))
    (setq emacs-minder--ocr-worker-proc nil
          emacs-minder--ocr-worker-cmd nil
          emacs-minder--ocr-worker-ready nil
          emacs-minder--ocr-worker-buf "")
    (when (or emacs-minder--ocr-queue emacs-minder--ocr-pending)
      (let ((tail (emacs-minder--ocr-stderr-tail)))
        (emacs-minder--ocr-fail-all
         (if (and tail (not (string-empty-p tail)))
             (format "Formula OCR worker exited (%s)" tail)
           (format "Formula OCR worker exited with status %s"
                   (process-exit-status proc))))))))

;;;###autoload
(defun emacs-minder-formula-ocr-stop-worker ()
  "Stop the background `formulaocr-offline' worker process, if running."
  (interactive)
  (let ((proc emacs-minder--ocr-worker-proc))
    (setq emacs-minder--ocr-worker-proc nil
          emacs-minder--ocr-worker-cmd nil
          emacs-minder--ocr-worker-ready nil
          emacs-minder--ocr-worker-buf "")
    (emacs-minder--ocr-fail-all "Formula OCR worker stopped")
    (when (process-live-p proc)
      (delete-process proc))
    (when (called-interactively-p 'any)
      (message (if proc "Formula OCR worker stopped" "Formula OCR worker was not running")))))

(add-hook 'kill-emacs-hook #'emacs-minder-formula-ocr-stop-worker)

(defun emacs-minder--ocr-ensure-worker (cmd)
  "Ensure a persistent `--worker' process for CMD is running and return it."
  (when (and (process-live-p emacs-minder--ocr-worker-proc)
             (not (equal emacs-minder--ocr-worker-cmd cmd)))
    (emacs-minder-formula-ocr-stop-worker))
  (unless (process-live-p emacs-minder--ocr-worker-proc)
    (let ((err-buf (get-buffer-create " *emacs-minder-formula-ocr-stderr*")))
      (with-current-buffer err-buf
        (erase-buffer))
      (setq emacs-minder--ocr-worker-ready nil
            emacs-minder--ocr-worker-buf ""
            emacs-minder--ocr-worker-cmd cmd
            emacs-minder--ocr-worker-proc
            (make-process
             :name "emacs-minder-formula-ocr-worker"
             :buffer nil
             :stderr err-buf
             :command (list cmd "--worker")
             :coding 'utf-8-unix
             :connection-type 'pipe
             :noquery t
             :filter #'emacs-minder--ocr-worker-filter
             :sentinel #'emacs-minder--ocr-worker-sentinel))))
  emacs-minder--ocr-worker-proc)

;;;###autoload
(defun emacs-minder-formula-ocr-warmup ()
  "Start and warm up the persistent `formulaocr-offline' worker in the background."
  (interactive)
  (let ((cmd (emacs-minder--find-formula-ocr)))
    (unless cmd
      (user-error "Formula OCR command not found (set MINDER_FORMULA_OCR or install formulaocr-offline)"))
    (unless (emacs-minder--formula-ocr-supports-worker-p cmd)
      (user-error "Worker mode is disabled or unsupported for %s" cmd))
    (if (and (process-live-p emacs-minder--ocr-worker-proc)
             (equal emacs-minder--ocr-worker-cmd cmd)
             emacs-minder--ocr-worker-ready)
        (message "Formula OCR worker already ready (%s)" (file-name-nondirectory cmd))
      (emacs-minder--ocr-ensure-worker cmd)
      (message "Warming up formula OCR worker (%s) in background..."
               (file-name-nondirectory cmd)))))

(defun emacs-minder--ocr-oneshot-async (cmd image-path no-classify callback)
  "Run one-shot OCR command CMD on IMAGE-PATH asynchronously.
Calls CALLBACK with (FORMULA ERR).  Passes `--no-classify' when NO-CLASSIFY
is non-nil and CMD supports it."
  (let* ((args (if (and no-classify
                        (string-match-p "formulaocr-offline" (file-name-nondirectory cmd)))
                   (list cmd "--no-classify" image-path)
                 (list cmd image-path)))
         (out-buf (generate-new-buffer " *emacs-minder-ocr-out*"))
         (err-buf (generate-new-buffer " *emacs-minder-ocr-err*"))
         (state (list :done nil :timer nil))
         (cleanup (lambda ()
                    (when (timerp (plist-get state :timer))
                      (cancel-timer (plist-get state :timer)))
                    (plist-put state :timer nil)
                    (when (and (stringp image-path) (file-exists-p image-path))
                      (ignore-errors (delete-file image-path)))
                    (when (buffer-live-p out-buf) (kill-buffer out-buf))
                    (when (buffer-live-p err-buf) (kill-buffer err-buf))))
         (proc (make-process
                :name "emacs-minder-formula-ocr"
                :buffer out-buf
                :stderr err-buf
                :command args
                :coding 'utf-8-unix
                :connection-type 'pipe
                :noquery t
                :sentinel
                (lambda (p _ev)
                  (when (and (memq (process-status p) '(exit signal))
                             (not (plist-get state :done)))
                    (plist-put state :done t)
                    (let* ((ok (and (eq (process-status p) 'exit)
                                    (zerop (process-exit-status p))))
                           (out (if (buffer-live-p out-buf)
                                    (string-trim (with-current-buffer out-buf (buffer-string)))
                                  ""))
                           (err-text (if (buffer-live-p err-buf)
                                         (string-trim (with-current-buffer err-buf (buffer-string)))
                                       ""))
                           (err-line (unless (string-empty-p err-text)
                                       (string-trim (car (last (split-string err-text "\n" t)))))))
                      (funcall cleanup)
                      (if (and ok (not (string-empty-p out)))
                          (funcall callback out nil)
                        (funcall callback nil
                                 (or (and err-line (not (string-empty-p err-line)) err-line)
                                     (format "Formula OCR exited with status %s"
                                             (process-exit-status p)))))))))))
    (when (and (numberp emacs-minder-formula-ocr-timeout)
               (> emacs-minder-formula-ocr-timeout 0))
      (plist-put state :timer
                 (run-with-timer
                  emacs-minder-formula-ocr-timeout nil
                  (lambda ()
                    (unless (plist-get state :done)
                      (plist-put state :done t)
                      (when (process-live-p proc)
                        (delete-process proc))
                      (funcall cleanup)
                      (funcall callback nil
                               (format "Formula OCR timed out after %ss"
                                       emacs-minder-formula-ocr-timeout)))))))))

(defun emacs-minder--recognize-formula-file-async (image-path no-classify callback)
  "Recognize formula in IMAGE-PATH and invoke CALLBACK with (FORMULA ERR).
When NO-CLASSIFY is non-nil, run one-shot mode passing `--no-classify'."
  (let ((cmd (emacs-minder--find-formula-ocr)))
    (cond
     ((not cmd)
      (when (and (stringp image-path) (file-exists-p image-path))
        (ignore-errors (delete-file image-path)))
      (funcall callback nil
               "Formula OCR command not found (set MINDER_FORMULA_OCR or install formulaocr-offline)"))
     ((and (not no-classify) (emacs-minder--formula-ocr-supports-worker-p cmd))
      (emacs-minder--ocr-ensure-worker cmd)
      (let* ((id (cl-incf emacs-minder--ocr-next-id))
             (req (list :id id
                        :image image-path
                        :callback callback
                        :timer nil
                        :done nil)))
        (when (and (numberp emacs-minder-formula-ocr-timeout)
                   (> emacs-minder-formula-ocr-timeout 0))
          (plist-put req :timer
                     (run-with-timer
                      emacs-minder-formula-ocr-timeout nil
                      (lambda ()
                        (emacs-minder--ocr-finish-req
                         req nil
                         (format "Formula OCR timed out after %ss"
                                 emacs-minder-formula-ocr-timeout))))))
        (if emacs-minder--ocr-worker-ready
            (emacs-minder--ocr-send-req req)
          (setq emacs-minder--ocr-queue (append emacs-minder--ocr-queue (list req))))))
     (t
      (emacs-minder--ocr-oneshot-async cmd image-path no-classify callback)))))

;;;###autoload
(defun emacs-minder-paste-clipboard-latex (&optional arg)
  "Recognize a math equation image from clipboard to LaTeX and insert it.
In `emacs-minder-mode':
  - Without prefix ARG, creates a new child node with recognized LaTeX.
  - With `\\[universal-argument]', appends the formula onto the selected node.
  - With `\\[universal-argument] \\[universal-argument]', bypasses the
    formula classifier (`--no-classify').

In `emacs-minder-inline-edit-mode', `org-mode', or other text buffers:
  - Inserts recognized LaTeX at point (previewed in GUI Org buffers).
  - With `\\[universal-argument]', bypasses the classifier (`--no-classify')."
  (interactive "P")
  (let ((cmd (emacs-minder--find-formula-ocr)))
    (unless cmd
      (user-error "Formula OCR command not found (set MINDER_FORMULA_OCR or install formulaocr-offline)"))
    (let* ((buf (current-buffer))
           (in-minder (and (derived-mode-p 'emacs-minder-mode) emacs-minder--handle))
           (in-inline (derived-mode-p 'emacs-minder-inline-edit-mode))
           (append-p (and in-minder (equal arg '(4))))
           (no-classify (if in-minder
                            (and (consp arg) (>= (car arg) 16))
                          (and arg t)))
           (target-node-id (and in-minder (alist-get 'selected_node emacs-minder--state)))
           (backing-file (cond
                          (in-minder (emacs-minder--backing-file))
                          (in-inline (and (buffer-live-p emacs-minder--source-buffer)
                                          (with-current-buffer emacs-minder--source-buffer
                                            (emacs-minder--backing-file))))
                          (t buffer-file-name)))
           (marker (unless in-minder
                     (let ((m (point-marker)))
                       (set-marker-insertion-type m nil)
                       m)))
           (will-warmup (and (not no-classify)
                             (emacs-minder--formula-ocr-supports-worker-p cmd)
                             (not emacs-minder--ocr-worker-ready))))
      (message "Recognizing clipboard formula via %s%s..."
               (file-name-nondirectory cmd)
               (if will-warmup " (warming up model on first run)" ""))
      (emacs-minder--grab-clipboard-image-async
       (lambda (img-path grab-err)
         (if grab-err
             (progn
               (when marker (set-marker marker nil))
               (message "%s" grab-err))
           (emacs-minder--recognize-formula-file-async
            img-path no-classify
            (lambda (formula ocr-err)
              (if ocr-err
                  (progn
                    (when marker (set-marker marker nil))
                    (message "Formula OCR failed: %s (use %s to bypass classifier%s)"
                             ocr-err
                             (if in-minder "C-u C-u" "C-u")
                             (if in-minder ", or M-y for raw image" "")))
                (if (not (buffer-live-p buf))
                    (when marker (set-marker marker nil))
                  (with-current-buffer buf
                    (let ((formatted (emacs-minder--format-formula formula backing-file)))
                      (cond
                       ((and in-minder emacs-minder--handle)
                        (when (and target-node-id
                                   (not (eql target-node-id
                                             (alist-get 'selected_node emacs-minder--state))))
                          (emacs-minder--cmd-raw `((op . "select_node") (id . ,target-node-id))))
                        (if (and append-p target-node-id)
                            (let* ((sel (alist-get 'selected emacs-minder--state))
                                   (cur (and sel
                                             (eql (alist-get 'id sel) target-node-id)
                                             (alist-get 'text sel)))
                                   (combined (if (or (null cur) (string-empty-p (string-trim cur)))
                                                 formatted
                                               (concat (string-trim-right cur) " " formatted))))
                              (emacs-minder--cmd
                               `((op . "set_text") (id . ,target-node-id) (text . ,combined))))
                          (if (alist-get 'selected_node emacs-minder--state)
                              (emacs-minder--cmd `((op . "add_child") (text . ,formatted)))
                            (emacs-minder--cmd `((op . "add_root") (text . ,formatted)))))
                        (message "Formula recognized: %s" formatted))
                       (t
                        (when (and marker (marker-buffer marker))
                          (goto-char (marker-position marker))
                          (set-marker marker nil))
                        (let ((beg (point)))
                          (insert formatted)
                          (when (and (derived-mode-p 'org-mode)
                                     (not noninteractive)
                                     (display-graphic-p)
                                     (fboundp 'org-latex-preview))
                            (save-excursion
                              (goto-char (min (point) (1+ beg)))
                              (ignore-errors (org-latex-preview)))))
                        (message "Formula recognized: %s" formatted)))))))))))))))

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
  (message "Drag node: move  Edge handle / C-S-←→: resize  Scroll: pan  C-Scroll: zoom  Mid-drag: pan  TAB: child  RET: inline edit  C-M-v/M-l: OCR LaTeX  C-x C-s: save"))

;;; Mouse interaction

(defun emacs-minder--coalesce-wheel (event)
  "Drain consecutive queued wheel events matching EVENT and return tick count."
  (let ((basic (event-basic-type event))
        (mods (event-modifiers event))
        (count 1)
        (coalesce t))
    (while coalesce
      (let ((next-ev (read-event nil nil 0)))
        (cond
         ((null next-ev)
          (setq coalesce nil))
         ((and (eq (event-basic-type next-ev) basic)
               (equal (event-modifiers next-ev) mods))
          (setq count (1+ count)))
         (t
          (push next-ev unread-command-events)
          (setq coalesce nil)))))
    count))

(defun emacs-minder--schedule-settle ()
  "Schedule a crisp 1.0x native render shortly after wheel scrolling or zooming."
  (when (timerp emacs-minder--settle-timer)
    (cancel-timer emacs-minder--settle-timer)
    (setq emacs-minder--settle-timer nil))
  (let ((buf (current-buffer)))
    (setq emacs-minder--settle-timer
          (run-with-timer
           0.09 nil
           (lambda ()
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (setq emacs-minder--settle-timer nil)
                 (when (and emacs-minder--handle
                            (get-buffer-window buf 'visible))
                   (setq emacs-minder--state
                         (emacs-minder--parse-json
                          (emacs-minder-core-state-json emacs-minder--handle)))
                   (emacs-minder--render t)))))))))

(defun emacs-minder--scroll-tick (buf)
  "Advance eased smooth wheel scrolling for BUF by one frame."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (if (or (not emacs-minder--handle)
              (and (not noninteractive) (not (get-buffer-window buf 'visible))))
          (emacs-minder--cancel-smooth-timers)
        (let ((rx emacs-minder--scroll-rem-x)
              (ry emacs-minder--scroll-rem-y))
          (if (and (< (abs rx) 0.5) (< (abs ry) 0.5))
              (progn
                (setq emacs-minder--scroll-rem-x 0.0
                      emacs-minder--scroll-rem-y 0.0)
                (when (timerp emacs-minder--scroll-timer)
                  (cancel-timer emacs-minder--scroll-timer)
                  (setq emacs-minder--scroll-timer nil))
                (emacs-minder--schedule-settle))
            (let* ((step-x (if (< (abs rx) 2.5) rx (* rx 0.38)))
                   (step-y (if (< (abs ry) 2.5) ry (* ry 0.38)))
                   (vp (emacs-minder--viewport-pixels))
                   (w (car vp))
                   (h (cdr vp)))
              (setq emacs-minder--scroll-rem-x (- rx step-x)
                    emacs-minder--scroll-rem-y (- ry step-y))
              (pcase-let ((`(,rw ,rh ,disp-scale) (emacs-minder--drag-dimensions w h)))
                (let ((png (emacs-minder-core-pan-fast
                            emacs-minder--handle step-x step-y w h rw rh)))
                  (emacs-minder--display-png png disp-scale))
                (when (and (not noninteractive) (display-graphic-p))
                  (redisplay)))
              (when (and (< (abs emacs-minder--scroll-rem-x) 0.5)
                         (< (abs emacs-minder--scroll-rem-y) 0.5))
                (setq emacs-minder--scroll-rem-x 0.0
                      emacs-minder--scroll-rem-y 0.0)
                (when (timerp emacs-minder--scroll-timer)
                  (cancel-timer emacs-minder--scroll-timer)
                  (setq emacs-minder--scroll-timer nil))
                (emacs-minder--schedule-settle)))))))))

(defun emacs-minder--wheel-pan (dx dy)
  "Pan by (DX, DY) using eased 60 FPS wheel interpolation in GUI frames."
  (when emacs-minder--handle
    (if (or noninteractive (not emacs-minder-smooth-wheel) (not (display-graphic-p)))
        (emacs-minder--cmd `((op . "pan") (dx . ,(float dx)) (dy . ,(float dy))))
      (when (timerp emacs-minder--settle-timer)
        (cancel-timer emacs-minder--settle-timer)
        (setq emacs-minder--settle-timer nil))
      (setq emacs-minder--scroll-rem-x (+ emacs-minder--scroll-rem-x (float dx))
            emacs-minder--scroll-rem-y (+ emacs-minder--scroll-rem-y (float dy)))
      (emacs-minder--scroll-tick (current-buffer))
      (when (and (not (timerp emacs-minder--scroll-timer))
                 (or (>= (abs emacs-minder--scroll-rem-x) 0.5)
                     (>= (abs emacs-minder--scroll-rem-y) 0.5)))
        (let ((buf (current-buffer)))
          (setq emacs-minder--scroll-timer
                (run-with-timer 0.016 0.016 #'emacs-minder--scroll-tick buf)))))))

(defun emacs-minder--wheel-zoom (event factor)
  "Zoom by FACTOR anchored at EVENT pointer, snapping crisply after settle."
  (when emacs-minder--handle
    (let* ((pos (event-start event))
           (xy (or (posn-object-x-y pos) (posn-x-y pos)))
           (ax (and xy (numberp (car xy)) (float (car xy))))
           (ay (and xy (numberp (cdr xy)) (float (cdr xy)))))
      (if (or noninteractive (not emacs-minder-smooth-wheel) (not (display-graphic-p)))
          (if (and ax ay)
              (emacs-minder--cmd `((op . "zoom")
                                   (factor . ,factor)
                                   (anchor_x . ,ax)
                                   (anchor_y . ,ay)))
            (emacs-minder--cmd `((op . "zoom") (factor . ,factor))))
        (when (timerp emacs-minder--scroll-timer)
          (cancel-timer emacs-minder--scroll-timer)
          (setq emacs-minder--scroll-timer nil))
        (setq emacs-minder--scroll-rem-x 0.0
              emacs-minder--scroll-rem-y 0.0)
        (let* ((vp (emacs-minder--viewport-pixels))
               (w (car vp))
               (h (cdr vp)))
          (pcase-let ((`(,rw ,rh ,disp-scale) (emacs-minder--drag-dimensions w h)))
            (let ((png (emacs-minder-core-zoom-fast
                        emacs-minder--handle factor ax ay w h rw rh)))
              (emacs-minder--display-png png disp-scale))
            (redisplay)
            (emacs-minder--schedule-settle)))))))

(defun emacs-minder-mouse-scroll-up (event)
  "Scroll/pan the mind map upward smoothly on mouse wheel EVENT."
  (interactive "e")
  (let ((n (emacs-minder--coalesce-wheel event)))
    (emacs-minder--wheel-pan 0.0 (* (- emacs-minder-wheel-step) n))))

(defun emacs-minder-mouse-scroll-down (event)
  "Scroll/pan the mind map downward smoothly on mouse wheel EVENT."
  (interactive "e")
  (let ((n (emacs-minder--coalesce-wheel event)))
    (emacs-minder--wheel-pan 0.0 (* emacs-minder-wheel-step n))))

(defun emacs-minder-mouse-scroll-left (event)
  "Scroll/pan the mind map left on horizontal/shift mouse wheel EVENT."
  (interactive "e")
  (let ((n (emacs-minder--coalesce-wheel event)))
    (emacs-minder--wheel-pan (* (- emacs-minder-wheel-step) n) 0.0)))

(defun emacs-minder-mouse-scroll-right (event)
  "Scroll/pan the mind map right on horizontal/shift mouse wheel EVENT."
  (interactive "e")
  (let ((n (emacs-minder--coalesce-wheel event)))
    (emacs-minder--wheel-pan (* emacs-minder-wheel-step n) 0.0)))

(defun emacs-minder-mouse-zoom-in (event)
  "Zoom in anchored at pointer position for Ctrl+wheel EVENT."
  (interactive "e")
  (let ((n (emacs-minder--coalesce-wheel event)))
    (emacs-minder--wheel-zoom event (expt 1.15 n))))

(defun emacs-minder-mouse-zoom-out (event)
  "Zoom out anchored at pointer position for Ctrl+wheel EVENT."
  (interactive "e")
  (let ((n (emacs-minder--coalesce-wheel event)))
    (emacs-minder--wheel-zoom event (expt 0.8695652 n))))

(defun emacs-minder--event-image-xy (event)
  "Extract pixel coordinates `(X . Y)' for mouse EVENT."
  (let ((pos (event-start event)))
    (or (posn-object-x-y pos)
        (posn-x-y pos))))

(defun emacs-minder--mouse-click (event)
  "Select/toggle node under mouse click EVENT."
  (interactive "e")
  (let ((xy (emacs-minder--event-image-xy event)))
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
          ((or "node" "resizer")
           (emacs-minder--cmd `((op . "select_node") (id . ,nid))))
          (_
           (emacs-minder--cmd '((op . "select_clear")))))))))

(defun emacs-minder--mouse-double-click (event)
  "Edit node under mouse double-click EVENT."
  (interactive "e")
  (let ((xy (emacs-minder--event-image-xy event)))
    (when (and xy emacs-minder--handle)
      (let* ((hit (emacs-minder--parse-json
                   (emacs-minder-core-hit-test emacs-minder--handle (car xy) (cdr xy))))
             (kind (alist-get 'kind hit))
             (nid (alist-get 'node_id hit)))
        (when (and nid (member kind '("node" "resizer")))
          (emacs-minder--cmd `((op . "select_node") (id . ,nid)))
          (emacs-minder-edit-node-text))))))

(defun emacs-minder--drag-dimensions (w h)
  "Return `(RW RH DISP-SCALE)' for interactive drag over logical W x H pixels."
  (let* ((area (float (max 1 (* w h))))
         (raw-scale (cond
                     ((eq emacs-minder-drag-render-scale 'auto)
                      (min 1.0 (max 0.35 (sqrt (/ 800000.0 area)))))
                     ((numberp emacs-minder-drag-render-scale)
                      (min 1.0 (max 0.35 (float emacs-minder-drag-render-scale))))
                     (t 1.0)))
         (rw (max 64 (round (* w raw-scale))))
         (exact (/ (float rw) (float (max 1 w))))
         (rh (max 64 (round (* h exact))))
         (disp-scale (/ (float (max 1 w)) (float rw))))
    (list rw rh disp-scale)))

(defun emacs-minder--run-drag-loop (kind nid move-subtree threshold &optional resize-init)
  "Run smooth layer-cached mouse drag for KIND on NID.
RESIZE-INIT is `(START-WIDTH . SIGN)' when KIND is \"resize\".
Return non-nil if any drag movement occurred."
  (when emacs-minder--handle
    (emacs-minder--cancel-smooth-timers)
    (let* ((p0 (cdr (mouse-pixel-position)))
           (start-x (and (consp p0) (numberp (car p0)) (car p0)))
           (start-y (and (consp p0) (numberp (cdr p0)) (cdr p0)))
           (last-x start-x)
           (last-y start-y)
           (scale (max 0.1 (or (alist-get 'scale emacs-minder--state) 1.0)))
           (vp (emacs-minder--viewport-pixels))
           (w (car vp))
           (h (cdr vp))
           (began nil)
           (dragging (and start-x start-y t)))
      (pcase-let ((`(,rw ,rh ,disp-scale) (emacs-minder--drag-dimensions w h)))
        (when dragging
          (let ((mouse-fine-grained-tracking t)
                (gc-cons-threshold (max gc-cons-threshold (* 128 1024 1024))))
            (unwind-protect
                (track-mouse
                  (setq track-mouse 'dragging)
                  (while dragging
                    (let ((ev (read-event)))
                      (if (mouse-movement-p ev)
                          (let ((coalesce t))
                            (while coalesce
                              (let ((next-ev (read-event nil nil 0)))
                                (cond
                                 ((null next-ev) (setq coalesce nil))
                                 ((mouse-movement-p next-ev) (setq ev next-ev))
                                 (t
                                  (push next-ev unread-command-events)
                                  (setq coalesce nil)))))
                            (let* ((cur (cdr (mouse-pixel-position)))
                                   (cx (and (consp cur) (car cur)))
                                   (cy (and (consp cur) (cdr cur))))
                              (when (and (numberp cx) (numberp cy)
                                         (or began
                                             (> (+ (abs (- cx start-x)) (abs (- cy start-y)))
                                                threshold)))
                                (let ((dx 0.0)
                                      (dy 0.0)
                                      (width 180.0)
                                      (changed nil))
                                  (cond
                                   ((equal kind "resize")
                                    (when (/= cx last-x)
                                      (let ((start-w (or (car resize-init) 180.0))
                                            (sign (or (cdr resize-init) 1.0)))
                                        (setq width
                                              (min 1800.0
                                                   (max 68.0
                                                        (+ start-w (* sign (/ (float (- cx start-x)) scale)))))
                                              changed t))))
                                   ((equal kind "pan")
                                    (setq dx (float (- last-x cx))
                                          dy (float (- last-y cy))
                                          changed (or (/= dx 0.0) (/= dy 0.0))))
                                   (t
                                    (setq dx (float (- cx last-x))
                                          dy (float (- cy last-y))
                                          changed (or (/= dx 0.0) (/= dy 0.0)))))
                                  (when changed
                                    (setq last-x cx
                                          last-y cy)
                                    (let ((frame-t0 (float-time)))
                                      (unless began
                                        (setq began t)
                                        (emacs-minder-core-drag-begin
                                         emacs-minder--handle kind nid move-subtree w h rw rh))
                                      (let ((png (emacs-minder-core-drag-step
                                                  emacs-minder--handle dx dy width w h rw rh)))
                                        (emacs-minder--display-png png disp-scale))
                                      (redisplay)
                                      (when (and (not noninteractive) (display-graphic-p))
                                        (let* ((elapsed (- (float-time) frame-t0))
                                               (wait (max 0.002 (- 0.015 elapsed))))
                                          (sleep-for wait)))))))))
                        (when (and (consp ev)
                                   (not (memq (event-basic-type ev)
                                              '(mouse-1 mouse-2 mouse-3 drag-mouse-1 drag-mouse-2))))
                          (push ev unread-command-events))
                        (setq dragging nil)))))
              (when (and began emacs-minder--handle)
                (setq emacs-minder--state
                      (emacs-minder--parse-json
                       (emacs-minder-core-drag-end emacs-minder--handle)))
                (emacs-minder--render t))))))
      began)))

(defun emacs-minder--mouse-down-1 (event)
  "Handle left mouse press: resize handle, toggle badge, free-move node, or pan."
  (interactive "e")
  (let* ((pos (event-start event))
         (win (posn-window pos))
         (xy (emacs-minder--event-image-xy event)))
    (when (and (window-live-p win) (not (eq win (selected-window))))
      (select-window win))
    (when (and xy emacs-minder--handle)
      (let* ((hit (emacs-minder--parse-json
                   (emacs-minder-core-hit-test emacs-minder--handle (car xy) (cdr xy))))
             (kind (alist-get 'kind hit))
             (nid (alist-get 'node_id hit))
             (shift-held (memq 'shift (event-modifiers event)))
             (clicks (event-click-count event)))
        (cond
         ((and (>= clicks 2) (member kind '("node" "resizer")) nid)
          (emacs-minder--cmd `((op . "select_node") (id . ,nid)))
          (emacs-minder-edit-node-text))
         ((equal kind "fold")
          (emacs-minder--cmd `((op . "select_node") (id . ,nid)))
          (emacs-minder--cmd `((op . "toggle_fold") (id . ,nid))))
         ((equal kind "task")
          (emacs-minder--cmd `((op . "select_node") (id . ,nid)))
          (emacs-minder--cmd `((op . "toggle_task") (id . ,nid))))
         ((equal kind "resizer")
          (let* ((sel (alist-get 'selected emacs-minder--state))
                 (start-w (or (and sel (alist-get 'width sel)) 180.0))
                 (on-left (and sel (alist-get 'resizer_on_left sel)))
                 (sign (if on-left -1.0 1.0)))
            (emacs-minder--run-drag-loop "resize" nid t 0 (cons start-w sign))))
         ((equal kind "node")
          (unless (eql nid (alist-get 'selected_node emacs-minder--state))
            (emacs-minder--cmd `((op . "select_node") (id . ,nid)))
            (redisplay))
          (emacs-minder--run-drag-loop "move" nid (not shift-held) 4))
         (t
          (unless (emacs-minder--run-drag-loop "pan" nil t 4)
            (emacs-minder--cmd '((op . "select_clear"))))))))))

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

(defun emacs-minder--mouse-pan-track (_event)
  "Live-pan the mind map scene while dragging with the middle mouse button."
  (interactive "e")
  (emacs-minder--run-drag-loop "pan" nil t 1))

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
    (define-key map (kbd "C-S-<up>")    #'emacs-minder-move-sibling-up)
    (define-key map (kbd "C-S-<down>")  #'emacs-minder-move-sibling-down)
    (define-key map (kbd "C-S-<right>") #'emacs-minder-widen-node)
    (define-key map (kbd "C-S-<left>")  #'emacs-minder-narrow-node)

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
    (define-key map (kbd "C-M-v") #'emacs-minder-paste-clipboard-latex)
    (define-key map (kbd "M-l")   #'emacs-minder-paste-clipboard-latex)

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
    (define-key map [down-mouse-1]        #'emacs-minder--mouse-down-1)
    (define-key map [mouse-1]             #'ignore)
    (define-key map [double-down-mouse-1] #'emacs-minder--mouse-double-click)
    (define-key map [double-mouse-1]      #'ignore)
    (define-key map [down-mouse-2]        #'emacs-minder--mouse-pan-track)
    (define-key map [mouse-2]        #'ignore)
    (define-key map [drag-mouse-2]   #'emacs-minder--mouse-drag-pan)
    (define-key map [wheel-up]       #'emacs-minder-mouse-scroll-up)
    (define-key map [wheel-down]     #'emacs-minder-mouse-scroll-down)
    (define-key map [mouse-4]        #'emacs-minder-mouse-scroll-up)
    (define-key map [mouse-5]        #'emacs-minder-mouse-scroll-down)
    (define-key map [wheel-left]     #'emacs-minder-mouse-scroll-left)
    (define-key map [wheel-right]    #'emacs-minder-mouse-scroll-right)
    (define-key map [mouse-6]        #'emacs-minder-mouse-scroll-left)
    (define-key map [mouse-7]        #'emacs-minder-mouse-scroll-right)
    (define-key map [S-wheel-up]     #'emacs-minder-mouse-scroll-left)
    (define-key map [S-wheel-down]   #'emacs-minder-mouse-scroll-right)
    (define-key map [S-mouse-4]      #'emacs-minder-mouse-scroll-left)
    (define-key map [S-mouse-5]      #'emacs-minder-mouse-scroll-right)
    (define-key map [C-wheel-up]     #'emacs-minder-mouse-zoom-in)
    (define-key map [C-wheel-down]   #'emacs-minder-mouse-zoom-out)
    (define-key map [C-mouse-4]      #'emacs-minder-mouse-zoom-in)
    (define-key map [C-mouse-5]      #'emacs-minder-mouse-zoom-out)
    map)
  "Keymap for `emacs-minder-mode'.")

;;;###autoload
(define-derived-mode emacs-minder-mode special-mode "Minder"
  "Native Cairo/LaTeX Mind Map major mode supporting `.minder' and `.org'."
  (emacs-minder-ensure-module)
  (setq buffer-read-only t
        truncate-lines t
        cursor-type nil)
  (setq-local show-trailing-whitespace nil
              buffer-undo-list t)
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
