;;; init-files-and-ui.el --- File managers, dashboard, fonts, themes & Noctalia -*- lexical-binding: t; -*-

;;; Commentary:
;; Enhanced Dirvish + Dired, Treemacs/Neotree, Emacs Dashboard, Heaven & Hell
;; light/dark switching, Noctalia theme integration, VTerm palette tracking,
;; transparent frame toggling, and theme-independent code/Org block faces.

;;; Code:

;; File browsers: Dired + Dirvish + Enhanced Dirvish
(add-hook 'dired-mode-hook #'dired-hide-details-mode)
(with-eval-after-load 'dired
  (define-key dired-mode-map (kbd "<left>") #'dired-up-directory)
  (define-key dired-mode-map (kbd "<right>") #'dired-find-file))

(require 'dirvish)
(dirvish-override-dired-mode 1)
(require 'enhanced-dirvish)
(setq enhanced-dirvish-file-manager-keys t)
(enhanced-dirvish-setup)
(when (fboundp 'enhanced-dirvish-watch-install)
  (enhanced-dirvish-watch-install))

(global-set-key (kbd "C-c d") #'enhanced-dirvish-launch)
(global-set-key (kbd "C-c D") #'enhanced-dirvish-sidebar-toggle)
(dolist (binding `(("a" . dirvish-quick-access)
                   ("f" . dirvish-file-info-menu)
                   ("y" . dirvish-yank-menu)
                   ("N" . dirvish-narrow)
                   ("h" . dired-up-directory)
                   ("l" . enhanced-dirvish-tree-expand-or-open)
                   ("<left>" . dired-up-directory)
                   ("<right>" . enhanced-dirvish-tree-expand-or-open)
                   ("TAB" . dirvish-toggle-subtree)
                   ("M-l" . dirvish-ls-switches-menu)
                   ("M-t" . dirvish-layout-toggle)))
  (define-key dirvish-mode-map (kbd (car binding)) (cdr binding)))

;; Sidebars: Treemacs & Neotree
(setq treemacs-width-is-initially-locked nil)
(global-set-key (kbd "<f6>") #'treemacs)

(with-eval-after-load 'neotree
  (setq neo-theme (if (display-graphic-p) 'icons 'arrow)
        neo-window-fixed-size nil
        neo-smart-open t))
(setq projectile-switch-project-action #'neotree-projectile-action)

;; Chrome & typography
(menu-bar-mode 1)
(scroll-bar-mode -1)
(tool-bar-mode -1)
(fringe-mode -1)
(setq window-divider-default-places t
      window-divider-default-right-width 4
      window-divider-default-bottom-width 4)
(window-divider-mode 1)

(setq leuven-scale-outline-headlines 1.1
      text-scale-mode-step 1.05)

(defun my/apply-gui-fonts (&optional frame)
  "Configure default and Nerd Font unicode fallback on GUI FRAME."
  (when (display-graphic-p frame)
    (with-selected-frame (or frame (selected-frame))
      (require 'all-the-icons nil t)
      (set-frame-font (font-spec :size 10.5) nil t)
      (set-fontset-font t 'unicode (font-spec :family "CaskaydiaCove Nerd Font") nil 'append))))

(if (display-graphic-p)
    (my/apply-gui-fonts)
  (add-hook 'after-make-frame-functions #'my/apply-gui-fonts))

;; Startup dashboard
(require 'dashboard)
(setq dashboard-startup-banner (expand-file-name "Emacs-logo.xpm" my/emacs-config-dir)
      dashboard-items '((recents . 10)
                        (bookmarks . 10)
                        (projects . 5)
                        (agenda . 5)
                        (registers . 5))
      dashboard-set-navigator t
      dashboard-icon-type 'all-the-icons
      dashboard-set-heading-icons t
      dashboard-set-file-icons t
      dashboard-projects-backend 'projectile)
(when (fboundp 'enhanced-dirvish-dashboard-install)
  (enhanced-dirvish-dashboard-install))
(dashboard-setup-startup-hook)

(defun my/dashboard-initial-buffer ()
  "Return the populated `*dashboard*' buffer for `initial-buffer-choice'."
  (unless (and (get-buffer dashboard-buffer-name)
               (with-current-buffer dashboard-buffer-name
                 (derived-mode-p 'dashboard-mode)))
    (dashboard-insert-startupify-lists t))
  (get-buffer-create dashboard-buffer-name))

(setq inhibit-startup-screen t)

(when (daemonp)
  (setq initial-buffer-choice #'my/dashboard-initial-buffer))

(defun my/dashboard-open-if-scratch ()
  "Show `*dashboard*' after startup if no file argument replaced `*scratch*'."
  (when (and (not noninteractive)
             (string-equal (buffer-name (window-buffer (selected-window))) "*scratch*"))
    (switch-to-buffer (my/dashboard-initial-buffer))))

(add-hook 'emacs-startup-hook #'my/dashboard-open-if-scratch 90)

;; VTerm dynamic theme tracking & Noctalia theme bridge
(load (expand-file-name "vterm-theme.el" my/emacs-config-dir) nil 'nomessage)
(load (expand-file-name "noctalia.el" my/emacs-config-dir) nil 'nomessage)

;; Frame opacity toggle (<f12>)
(defvar my/frame-transparency-enabled t
  "Whether frame transparency is enabled.")

(defvar my/frame-transparency-value 95
  "Background opacity when transparency is enabled (0-100).")

(defun my/toggle-frame-transparency ()
  "Toggle frame transparency."
  (interactive)
  (if my/frame-transparency-enabled
      (progn
        (set-frame-parameter nil 'alpha-background 100)
        (setq my/frame-transparency-enabled nil)
        (message "Transparency OFF"))
    (set-frame-parameter nil 'alpha-background my/frame-transparency-value)
    (setq my/frame-transparency-enabled t)
    (message "Transparency ON")))

(when (display-graphic-p)
  (set-frame-parameter nil 'alpha-background my/frame-transparency-value))
(add-to-list 'default-frame-alist `(alpha-background . ,my/frame-transparency-value))
(global-set-key (kbd "<f12>") #'my/toggle-frame-transparency)

;; Theme-independent code font-lock & Org block delimiter faces
(defun my/apply-code-font-lock-faces (&rest _)
  "Apply code face overrides independent of the active theme."
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
      (apply #'set-face-attribute (car spec) nil (cdr spec)))))

(defun my/apply-org-block-faces (&rest _)
  "Keep Org source block body highlighted but not its delimiter lines."
  (dolist (face '(org-block-begin-line org-block-end-line org-modern-block-name))
    (when (facep face)
      (set-face-attribute face nil :background 'unspecified))))

(advice-add 'load-theme :after #'my/apply-code-font-lock-faces)
(advice-add 'enable-theme :after #'my/apply-code-font-lock-faces)
(advice-add 'load-theme :after #'my/apply-org-block-faces)
(advice-add 'enable-theme :after #'my/apply-org-block-faces)
(add-hook 'after-init-hook #'my/apply-code-font-lock-faces)
(add-hook 'after-init-hook #'my/apply-org-block-faces)
(my/apply-code-font-lock-faces)

;; Heaven and Hell (light/dark ef-themes)
(require 'ef-themes nil t)
(require 'heaven-and-hell)
(setq heaven-and-hell-theme-type 'light
      heaven-and-hell-themes '((light . (ef-spring))
                               (dark . (ef-bio)))
      heaven-and-hell-load-theme-no-confirm t)
(add-hook 'after-init-hook #'heaven-and-hell-init-hook)
(global-set-key (kbd "C-c <f4>") #'heaven-and-hell-load-default-theme)
(global-set-key (kbd "<f4>") #'heaven-and-hell-toggle-theme)

(provide 'init-files-and-ui)
;;; init-files-and-ui.el ends here
