;; * Counsel Ivy
(defun my/ivy-insert-slash-literal ()
  "Insert a literal '/' in counsel-find-file without accepting any candidate."
  (interactive)
  (insert "/"))

(with-eval-after-load 'ivy
  (define-key counsel-find-file-map (kbd "M-j")
	      #'my/ivy-insert-slash-literal))

(setq counsel-find-file-ignore-regexp nil
      counsel-find-file-at-point nil)

(global-set-key (kbd "C-x C-M-f") #'counsel-find-file)

;; * Conf-desktop-mode for ini files
;; Enable conf-mode for .ini files
(add-to-list 'auto-mode-alist '("\\.ini\\'" . conf-desktop-mode))

;; * Dired
(add-hook 'dired-mode-hook 'dired-hide-details-mode)

;; * ripgrep
(require 'rg)
(rg-enable-default-bindings)

;; * Org-fragtog
;; Auto preview Latex
(add-hook 'org-mode-hook 'org-fragtog-mode)

;; * Projectile
;; Note: Projectile is already configured in scimax/packages.el
;; This provides additional project-specific settings

;; Enable vertico (vertical completion UI)
(use-package vertico
  :ensure t
  :init
  (vertico-mode +1))

;; Enable which-key (shows available keybindings)
(use-package which-key
  :ensure t
  :config
  (which-key-mode +1))

;; Additional projectile configuration
(with-eval-after-load 'projectile
  (setq projectile-project-search-path '("~/Projects/"))
  (setq projectile-cleanup-known-projects nil))


;; * Org Mode Startup
(setq org-startup-folded t)
(add-hook 'org-mode-hook 'mixed-pitch-mode)
(add-hook 'org-mode-hook 'follow-mode)
(setq org-babel-min-lines-for-block-output 1000)

;; * Org Crypt
(require 'org-crypt)
(org-crypt-use-before-save-magic)
(setq org-tags-exclude-from-inheritance (quote ("crypt")))
;; GPG key to use for encryption
;; Either the Key ID or set to nil to use symmetric encryption.
(setq org-crypt-key nil)

;; * Org Capture
(setq org-directory "~/Projects/org")
(setq org-default-notes-file (concat org-directory "/tasks.org"))

;; * Org Alert
(require 'alert)
(use-package org-alert
  :ensure t)
(setq alert-default-style 'libnotify)
(setq org-alert-interval 300
      org-alert-notify-cutoff 10
      org-alert-notify-after-event-cutoff 10)

;; * All-the-icons
(when (display-graphic-p)
  (require 'all-the-icons))

;; * Neotree
(require 'neotree)
(global-set-key [f4] 'neotree-toggle)
(setq neo-theme (if (display-graphic-p) 'icons 'arrow))
(setq neo-window-fixed-size nil)
(setq neo-smart-open t)
(setq projectile-switch-project-action 'neotree-projectile-action)

;; * Smartparens
;; Smartparens provides advanced parenthesis handling
(require 'smartparens-config)
(add-hook 'org-mode-hook #'smartparens-mode)
(sp-pair "$" "$")  ; Pair dollar signs for LaTeX math
(global-set-key (kbd "C-.") 'sp-rewrap-sexp)

;; * Electric Pair Mode - for non-org buffers
;; Use electric-pair-mode in programming modes where smartparens isn't active
(add-hook 'prog-mode-hook
          (lambda ()
            (unless smartparens-mode
              (electric-pair-local-mode t))))
;; Disable "<" pairing in org-mode to avoid conflicts with org syntax
(add-hook 'org-mode-hook
          (lambda ()
            (setq-local electric-pair-inhibit-predicate
                        `(lambda (c)
                           (if (char-equal c ?<) t (,electric-pair-inhibit-predicate c))))))


;; * Org Agenda
(setq org-agenda-include-diary t)

;; * Treemacs
;; adjust the size in increments with 'shift-<' and 'shift->'
;; '?' to see all shortcuts. 'M-H' move UP rootdir, 'M-L' move DOWN rootdir
(setq treemacs-width-is-initially-locked nil)
;; Changed from F7 to F6 to avoid conflict with counsel-recentf (scimax uses F7)
(global-set-key [f6] 'treemacs)

;; * Python
(setq python-indent-guess-indent-offset nil)

;; * active Babel languages
;; (setq haskell-process-type 'ghci)
(org-babel-do-load-languages
 'org-babel-load-languages
 '(
   ;; (haskell . t)
   (lua . t)
   (julia . t)
   (latex . t)
   (lisp . t)
   (nix . t)
   (rust . t)
   (spice . t)
   ))

;; * Spice
(setq spice-simulator "Ngspice"
      spice-waveform-viewer "ngplot")
;; ngplot is a new custom viewer defined in elisp which uses gnuplot


;; * Latex and preview pane
(latex-preview-pane-enable)
(setq org-preview-latex-default-process 'dvisvgm)
;; ** Use current theme colors for LaTeX previews
(setq org-format-latex-options
      (plist-put org-format-latex-options :foreground 'default))
(setq org-format-latex-options
      (plist-put org-format-latex-options :background 'default))
;; Auto-clear LaTeX previews on theme switch so they regenerate with new colors
(add-hook 'enable-theme-functions
          (lambda (_theme)
            (dolist (buf (buffer-list))
              (with-current-buffer buf
                (when (derived-mode-p 'org-mode)
                  (org-clear-latex-preview))))))
;; ** Scale Latex Preview Size
(defun my/text-scale-adjust-latex-previews ()
  "Adjust the size of latex preview fragments when changing the
buffer's text scale."
  (pcase major-mode
    ('latex-mode
     (dolist (ov (overlays-in (point-min) (point-max)))
       (if (eq (overlay-get ov 'category)
               'preview-overlay)
           (my/text-scale--resize-fragment ov))))
    ('org-mode
     (dolist (ov (overlays-in (point-min) (point-max)))
       (if (eq (overlay-get ov 'org-overlay-type)
               'org-latex-overlay)
           (my/text-scale--resize-fragment ov))))))
(defun my/text-scale--resize-fragment (ov)
  (overlay-put ov 'display
	       (cons 'image
		     (plist-put
		      (cdr (overlay-get ov 'display))
		      :scale (+ 1.0 (* 0.15 text-scale-mode-amount))
		      ;; :scale  (* +org-latex-preview-scale (expt text-scale-mode-step text-scale-mode-amount))
		      ))))
(add-hook 'text-scale-mode-hook #'my/text-scale-adjust-latex-previews)
(advice-add 'org-fragtog--post-cmd :after #'my/text-scale-adjust-latex-previews)
;; ** Transparent Background
;; (eval-after-load 'org
;;   '(setf org-highlight-latex-and-related '(latex)))

;; * etc
;; (setq nb-notebook-directory "~/mountdir/Projects")
;; (org-babel-load-file "~/mountdir/emacs/scimax/scimax-notebook.org")
;; (setq org-image-actual-width 100)

(setq inferior-lisp-program "sbcl")
(setq org-src-block-faces 'nil)
(add-hook 'prog-mode-hook #'rainbow-delimiters-mode)

;; * epub reader
;; (setq nov-unzip-program (executable-find "bsdtar")
;; nov-unzip-args '("-xC" directory "-f" filename))
(add-to-list 'auto-mode-alist '("\\.epub\\'" . nov-mode))

;; ** epub reader
;; (use-package nov-xwidget
;;   :demand t
;;   :after nov
;;   :config
;;   (define-key nov-mode-map (kbd "o") 'nov-xwidget-view)
;;   (add-hook 'nov-mode-hook 'nov-xwidget-inject-all-files))
;; (add-to-list 'load-path "/home/thinky/.emacs.d/elpa/nov-xwidget/")
;; (require 'nov-xwidget)

;; * PDF Tools
;; Use pdf-loader-install for on-demand loading (faster startup)
(pdf-loader-install)
(setq pdf-view-resize-factor 1.02)
(setq pdf-view-continuous nil)

(require 'saveplace-pdf-view)
(save-place-mode 1)

;; * Magit
(keymap-global-set "C-x g" 'magit-status)
(keymap-global-set "C-x M-g" 'magit-dispatch)
(keymap-global-set "C-c M-g" 'magit-file-dispatch)

;; **************************************************

;; * Open ipynb
(require 'markdown-mode nil t)

(defun ipynb-to-markdown (file)
  (interactive "f")
  (let* ((data (with-temp-buffer
                 (insert-file-literally file)
                 (json-parse-string (buffer-string)
                                    :object-type 'alist
                                    :array-type 'list)))
         (metadata (alist-get 'metadata data))
         (kernelspec (alist-get 'kernelspec metadata))
         (language (alist-get 'language kernelspec)))
    (pop-to-buffer "ipynb-as-markdown")
    ;; (when (featurep 'markdown-mode)
    ;;   (markdown-mode))
    (dolist (c (alist-get 'cells data))
      (let* ((contents (alist-get 'source c))
             (outputs (alist-get 'outputs c)))
        (pcase (alist-get 'cell_type c)
          ("markdown"
           (when contents
             (mapcar #'insert contents)
             (insert "\n\n")))
          ("code"
           (when contents
             (insert "```")
             (insert language)
             (insert "\n")
             (mapcar #'insert contents)
             (insert "\n```\n\n")
             (dolist (x outputs)
               (when-let (text (alist-get 'text x))
                 (insert "```stdout\n")
                 (insert (mapconcat #'identity text ""))
                 (insert "\n```\n\n"))
               (when-let (data (alist-get 'data x))
                 (when-let (im64 (alist-get 'image/png data))
                   (let ((imdata (base64-decode-string im64)))
                     (insert-image (create-image imdata 'png t)))))
               (insert "\n\n")))))))))

;; * Convert ipynb to org
(setq code-cells-convert-ipynb-style '(
				       ("pandoc" "--to" "ipynb" "--from" "org")
				       ("pandoc" "--to" "org" "--from" "ipynb")
				       org-mode))

(set-fontset-font t 'unicode (font-spec :family "CaskaydiaCove Nerd Font") nil 'append)

;; * Clickable file paths in emacs-lisp-mode
(defun my/file-path-open-at-click (event)
  "Open the file path at the clicked position in the other window.
If only one window exists, split horizontally first."
  (interactive "e")
  (let* ((pos (posn-point (event-end event)))
         (path (get-char-property pos 'my/file-path)))
    (when path
      (let ((expanded-path (expand-file-name path)))
        (when (= (count-windows) 1)
          (split-window-below))
        (other-window 1)
        (if (file-directory-p expanded-path)
            (dired expanded-path)
          (find-file expanded-path))
        (other-window -1)))))

(defvar my/file-path-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'my/file-path-open-at-click)
    map)
  "Keymap for clickable file paths.")

(defun my/add-file-path-overlays ()
  "Add overlays to file paths in the current buffer to make them clickable."
  (save-excursion
    (goto-char (point-min))
    ;; Remove existing file-path overlays
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (overlay-get ov 'my/file-path-overlay)
        (delete-overlay ov)))
    ;; Find quoted file paths: "~/..." or "/..."
    (while (re-search-forward "\"\\(~?/[^\"]*\\)\"" nil t)
      (let* ((beg (match-beginning 1))
             (end (match-end 1))
             (path (match-string-no-properties 1))
             (ov (make-overlay beg end)))
        (overlay-put ov 'my/file-path-overlay t)
        (overlay-put ov 'face '(:underline t))
        (overlay-put ov 'mouse-face 'highlight)
        (overlay-put ov 'pointer 'hand)
        (overlay-put ov 'my/file-path path)
        (overlay-put ov 'keymap my/file-path-keymap)
        (overlay-put ov 'help-echo (format "mouse-1: open %s" path))))))

(add-hook 'emacs-lisp-mode-hook
          (lambda ()
            (my/add-file-path-overlays)
            (add-hook 'after-save-hook #'my/add-file-path-overlays nil t)))

