;; * Counsel Ivy
(defun my/ivy-insert-slash-literal ()
  "Insert a literal '/' in counsel-find-file without accepting any candidate."
  (interactive)
  (insert "/"))

(with-eval-after-load 'counsel
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

;; * Dirvish — Yazi-style miller-columns file manager built on Dired.
;; Layout numbers are (parent-width-cells current-ratio preview-ratio).
;; The leftmost pane is the parent directory (read-only context, like Yazi);
;; navigate inside the middle pane and use <left>/<right> to traverse.
(use-package dirvish
  :ensure t
  :init
  (dirvish-override-dired-mode)
  :bind
  (("C-c d" . dirvish)
   ("C-c D" . dirvish-side)
   :map dirvish-mode-map
   ("a"        . dirvish-quick-access)
   ("f"        . dirvish-file-info-menu)
   ("y"        . dirvish-yank-menu)
   ("N"        . dirvish-narrow)
   ("h"        . dired-up-directory)
   ("l"        . dired-find-file)
   ("<left>"   . dired-up-directory)
   ("<right>"  . dired-find-file)
   ("TAB"      . dirvish-toggle-subtree)
   ("M-l"      . dirvish-ls-switches-menu)
   ("M-t"      . dirvish-layout-toggle))
  :custom
  ;; ls flags: -l long, -a hidden, -h human sizes, -v natural sort, dirs first.
  (dired-listing-switches "-lahv --group-directories-first")
  (dirvish-default-layout '(1 0.11 0.5))
  (dirvish-attributes '(file-size vc-state subtree-state collapse))
  (dirvish-mode-line-format
   '(:left (sort symlink) :right (omit yank index)))
  (dirvish-preview-dispatchers
   '(image gif video audio epub pdf archive))
  (dirvish-use-header-line 'global))

;; Live refresh for Dired/Dirvish: watch dirs via inotify and re-read the
;; listing when the filesystem changes. Without this, dired-buffers (which
;; back Dirvish) only refresh on manual `g' / revert.
(setq global-auto-revert-non-file-buffers t
      auto-revert-verbose nil
      auto-revert-use-notify t
      ;; Re-list on each visit too — covers cases where the watcher missed an event.
      dired-auto-revert-buffer t)
(global-auto-revert-mode 1)

;; Same arrow keys when Dirvish isn't overriding (plain Dired buffers).
(with-eval-after-load 'dired
  (define-key dired-mode-map (kbd "<left>")  'dired-up-directory)
  (define-key dired-mode-map (kbd "<right>") 'dired-find-file))

;; * ripgrep
(require 'rg)
(rg-enable-default-bindings)

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
(setq org-src-fontify-natively t
      org-src-tab-acts-natively t
      mouse-1-click-follows-link t)
(with-eval-after-load 'mixed-pitch
  ;; Keep Org block delimiters on a monospaced face. Mixed-pitch also forces
  ;; fixed-pitch faces back to the default weight, so reapply bold afterwards.
  (dolist (face '(org-block-begin-line
                  org-block-end-line
                  org-modern-block-name))
    (add-to-list 'mixed-pitch-fixed-pitch-faces face)))

(defvar-local my/org-block-face-cookies nil)
(defvar-local my/org-src-code-face-cookies nil)

(defun my/org-remap-block-delimiter-faces ()
  "Force Org block delimiter faces to stay bold after mixed-pitch remapping."
  (mapc #'face-remap-remove-relative my/org-block-face-cookies)
  (setq my/org-block-face-cookies nil)
  (dolist (face '(org-block-begin-line
                  org-block-end-line
                  org-modern-block-name))
    (push (face-remap-add-relative face
                                   :weight 'bold
                                   :slant 'italic
                                   :background 'unspecified)
          my/org-block-face-cookies)))

(defun my/org-remap-src-code-faces ()
  "Apply the same code-face overrides inside Org source blocks."
  (mapc #'face-remap-remove-relative my/org-src-code-face-cookies)
  (setq my/org-src-code-face-cookies nil)
  (dolist (spec '((font-lock-keyword-face :weight bold :slant italic)
                  (font-lock-builtin-face :weight normal :slant italic)
                  (font-lock-type-face :weight bold :slant italic)
                  (font-lock-constant-face :weight bold :slant normal)
                  (font-lock-variable-name-face :weight bold :slant normal)
                  (font-lock-function-name-face :weight normal :slant italic)
                  (font-lock-function-call-face :weight normal :slant italic)
                  (treesit-font-lock-keyword-face :weight bold :slant italic)
                  (treesit-font-lock-type-face :weight bold :slant italic)
                  (treesit-font-lock-function-face :weight normal :slant italic)
                  (treesit-font-lock-function-call-face :weight normal :slant italic)
                  (treesit-font-lock-variable-face :weight bold :slant normal)
                  (treesit-font-lock-property-face :weight bold :slant normal)
                  (treesit-font-lock-constant-face :weight bold :slant normal)))
    (when (facep (car spec))
      (push (apply #'face-remap-add-relative spec)
            my/org-src-code-face-cookies))))

(defun my/org-enable-mixed-pitch ()
  "Enable mixed-pitch in Org and restore block delimiter emphasis."
  (mixed-pitch-mode 1)
  (when (fboundp 'my/heaven-and-hell-apply-org-block-faces)
    (my/heaven-and-hell-apply-org-block-faces))
  (my/org-remap-block-delimiter-faces)
  (my/org-remap-src-code-faces))

(add-hook 'org-mode-hook #'my/org-enable-mixed-pitch)
(add-hook 'org-mode-hook 'follow-mode)
(setq org-babel-min-lines-for-block-output 1000)

;; * Org Pandoc Import
(use-package org-pandoc-import
  :vc (:url "https://github.com/tecosaur/org-pandoc-import"
       :rev :newest
       :files ("*.el" "filters" "preprocessors"))
  :after org)

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

;; ;; * Electric Pair Mode - for non-org buffers
;; ;; Use electric-pair-mode in programming modes where smartparens isn't active
;; (add-hook 'prog-mode-hook
;;           (lambda ()
;;             (unless smartparens-mode
;;               (electric-pair-local-mode t))))
;; ;; Disable "<" pairing in org-mode to avoid conflicts with org syntax
;; (add-hook 'org-mode-hook
;;           (lambda ()
;;             (setq-local electric-pair-inhibit-predicate
;;                         `(lambda (c)
;;                            (if (char-equal c ?<) t (,electric-pair-inhibit-predicate c))))))


;; * Org Agenda
(setq org-agenda-include-diary t)

(defun my/org-tempo-tab ()
  "Expand Org tempo templates before other TAB handlers."
  (interactive)
  (if (and (derived-mode-p 'org-mode)
           (save-excursion
             (skip-chars-backward "A-Za-z")
             (eq (char-before) ?<))
           (org-tempo-complete-tag))
      t
    (org-cycle)))

(defun my/org-template-keybindings ()
  "Prefer Org tempo expansion for TAB in Org buffers."
  (local-set-key (kbd "TAB") #'my/org-tempo-tab)
  (local-set-key (kbd "<tab>") #'my/org-tempo-tab)
  (local-set-key (kbd "C-i") #'my/org-tempo-tab))

(with-eval-after-load 'org
  (require 'org-tempo)
  (add-to-list 'org-structure-template-alist '("r" . "src rust"))
  (add-to-list 'org-structure-template-alist '("jp" . "src jupyter-python")))

(add-hook 'org-mode-hook #'my/org-template-keybindings)


;; * Treemacs
;; adjust the size in increments with 'shift-<' and 'shift->'
;; '?' to see all shortcuts. 'M-H' move UP rootdir, 'M-L' move DOWN rootdir
(setq treemacs-width-is-initially-locked nil)
;; Changed from F7 to F6 to avoid conflict with counsel-recentf (scimax uses F7)
(global-set-key [f6] 'treemacs)

;; * Python
(setq python-indent-guess-indent-offset nil)

(defun my/python-project-root ()
  "Return the current Python project root."
  (or (when-let ((project (project-current nil)))
        (project-root project))
      (locate-dominating-file default-directory ".envrc")
      (locate-dominating-file default-directory "devenv.nix")
      default-directory))

(defun my/run-current-python-file ()
  "Run the current Python file from the project root via `compile'."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (unless (derived-mode-p 'python-mode 'python-ts-mode)
    (user-error "Current buffer is not a Python buffer"))
  (save-buffer)
  (let* ((project-root (expand-file-name (my/python-project-root)))
         (file (file-relative-name buffer-file-name project-root))
         (default-directory project-root)
         (venv-python (expand-file-name ".devenv/state/venv/bin/python" project-root))
         (command
          (cond
           ((file-executable-p venv-python)
            (format "%s %s"
                    (shell-quote-argument venv-python)
                    (shell-quote-argument file)))
           ((executable-find "direnv")
            (format "direnv exec %s python %s"
                    (shell-quote-argument project-root)
                    (shell-quote-argument file)))
           (t
            (format "python %s" (shell-quote-argument file))))))
    (compile command)))

(defun my/python-run-keybindings ()
  "Bind project-local Python run commands in the current buffer."
  (local-set-key (kbd "C-c C-r") #'my/run-current-python-file)
  (local-set-key (kbd "C-c C-k") #'my/run-current-python-file))

(add-hook 'python-mode-hook #'my/python-run-keybindings)
(add-hook 'python-ts-mode-hook #'my/python-run-keybindings)

;; * Rust / Org src indentation
(defun my/prog-ret-indents ()
  "Make RET insert a newline and indent in the current buffer."
  (local-set-key (kbd "RET") #'newline-and-indent))

(defun my/org-src-return-dwim ()
  "Use language-mode RET inside Org src blocks, else use normal Org return."
  (interactive)
  (if (org-in-src-block-p)
      (let* ((lang (org-element-property :language (org-element-at-point)))
             (indent-step (if (boundp 'rust-indent-offset) rust-indent-offset 4))
             (base-indent (save-excursion
                            (back-to-indentation)
                            (current-column)))
             (char-before-point (char-before))
             (char-after-point (char-after))
             (extra-indent
              (if (and (string= lang "rust")
                       (eq char-before-point ?{))
                  indent-step
                0)))
        (cond
         ((and (string= lang "rust")
               (eq char-before-point ?{)
               (eq char-after-point ?}))
          (newline)
          (indent-to (+ base-indent indent-step))
          (save-excursion
            (newline)
            (indent-to base-indent)))
         (t
         (newline)
          (indent-to (+ base-indent extra-indent)))))
    (cond
     ((button-at (point))
      (push-button (point)))
     ((org-in-regexp org-link-any-re 1)
      (org-open-at-point))
     (t
      (org-return nil)))))

(defvar my/org-src-return-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'my/org-src-return-dwim)
    (define-key map (kbd "<return>") #'my/org-src-return-dwim)
    (define-key map (kbd "C-m") #'my/org-src-return-dwim)
    (define-key map [return] #'my/org-src-return-dwim)
    map))

(define-minor-mode my/org-src-return-mode
  "Force RET handling for Org src blocks."
  :lighter ""
  :keymap my/org-src-return-mode-map)

(add-hook 'rust-mode-hook #'my/prog-ret-indents)
(add-hook 'rust-ts-mode-hook #'my/prog-ret-indents)
(add-hook 'org-src-mode-hook #'my/prog-ret-indents)
(add-hook 'org-mode-hook #'my/org-src-return-mode)

;; * active Babel languages
;; (setq haskell-process-type 'ghci)
(add-to-list 'org-src-lang-modes '("rust" . rust))
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

;; * Theme-independent code faces
(defun my/apply-code-font-lock-faces ()
  "Apply code face overrides independent of the active theme."
  (set-face-attribute 'font-lock-keyword-face nil
                      :weight 'bold :slant 'italic)
  (set-face-attribute 'font-lock-builtin-face nil
                      :weight 'normal :slant 'italic)
  (set-face-attribute 'font-lock-type-face nil
                      :weight 'bold :slant 'italic)
  (set-face-attribute 'font-lock-constant-face nil
                      :weight 'bold :slant 'normal)
  (set-face-attribute 'font-lock-variable-name-face nil
                      :weight 'bold :slant 'normal)
  (set-face-attribute 'font-lock-function-name-face nil
                      :weight 'normal :slant 'italic)
  (when (facep 'font-lock-function-call-face)
    (set-face-attribute 'font-lock-function-call-face nil
                        :weight 'normal :slant 'italic))
  (when (facep 'treesit-font-lock-keyword-face)
    (set-face-attribute 'treesit-font-lock-keyword-face nil
                        :weight 'bold :slant 'italic))
  (when (facep 'treesit-font-lock-type-face)
    (set-face-attribute 'treesit-font-lock-type-face nil
                        :weight 'bold :slant 'italic))
  (when (facep 'treesit-font-lock-function-face)
    (set-face-attribute 'treesit-font-lock-function-face nil
                        :weight 'normal :slant 'italic))
  (when (facep 'treesit-font-lock-function-call-face)
    (set-face-attribute 'treesit-font-lock-function-call-face nil
                        :weight 'normal :slant 'italic))
  (when (facep 'treesit-font-lock-variable-face)
    (set-face-attribute 'treesit-font-lock-variable-face nil
                        :weight 'bold :slant 'normal))
  (when (facep 'treesit-font-lock-property-face)
    (set-face-attribute 'treesit-font-lock-property-face nil
                        :weight 'bold :slant 'normal))
  (when (facep 'treesit-font-lock-constant-face)
    (set-face-attribute 'treesit-font-lock-constant-face nil
                        :weight 'bold :slant 'normal)))

(defun my/reapply-code-font-lock-faces (&rest _)
  "Reapply code face overrides after a theme change."
  (my/apply-code-font-lock-faces))

(defun my/apply-org-block-faces (&rest _)
  "Keep Org source block body highlighted but not its delimiter lines."
  (when (facep 'org-block-begin-line)
    (set-face-attribute 'org-block-begin-line nil :background 'unspecified))
  (when (facep 'org-block-end-line)
    (set-face-attribute 'org-block-end-line nil :background 'unspecified))
  (when (facep 'org-modern-block-name)
    (set-face-attribute 'org-modern-block-name nil :background 'unspecified)))

(advice-add 'load-theme :after #'my/reapply-code-font-lock-faces)
(advice-add 'enable-theme :after #'my/reapply-code-font-lock-faces)
(advice-add 'load-theme :after #'my/apply-org-block-faces)
(advice-add 'enable-theme :after #'my/apply-org-block-faces)
(add-hook 'after-init-hook #'my/apply-code-font-lock-faces)
(add-hook 'after-init-hook #'my/apply-org-block-faces)
(my/apply-code-font-lock-faces)
(my/apply-org-block-faces)

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

;; * Latex and preview pane
(with-eval-after-load 'org
  (setq org-preview-latex-default-process 'dvisvgm)
  (plist-put
   (cdr (assq 'dvisvgm org-preview-latex-process-alist))
   :image-size-adjust
   '(1.0 . 1.0)))

;; Also set legacy variable for compatibility
(setq org-format-latex-options
      (plist-put org-format-latex-options :background "Transparent"))

;; Ensure preview face has no background
(set-face-attribute 'org-latex-and-related nil :background 'unspecified)

;; * Org-fragtog
;; Auto preview Latex
(add-hook 'org-mode-hook 'org-fragtog-mode)

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
		      ))))
(add-hook 'text-scale-mode-hook #'my/text-scale-adjust-latex-previews)
(advice-add 'org-fragtog--post-cmd :after #'my/text-scale-adjust-latex-previews)
