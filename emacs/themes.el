;; * Dashboard
(use-package dashboard
  :ensure t
  :config 
  (setq dashboard-startup-banner "~/Projects/emacs/Emacs-logo.xpm") ;convert svg to xpm
  ;; Other dashboard configurations
  (dashboard-setup-startup-hook)
  (setq dashboard-items '((recents . 10)
			  (bookmarks . 10)
			  (projects . 5)
			  (agenda . 5)
			  (registers . 5)))
  (setq dashboard-set-navigator t)
  (setq dashboard-icon-type 'all-the-icons) ; use `all-the-icons' package
  (setq dashboard-set-heading-icons t)
  (setq dashboard-set-file-icons t)
  (setq dashboard-projects-backend 'projectile))
;; (require 'scimax-dashboard)

;; * Disable some defaults
(disable-theme 'smart-mode-line-light)
(google-this-mode -1)
(fringe-mode -1)

;; * Set Faces, etc...
(set-face-attribute 'default nil :height 105)
(setq leuven-scale-outline-headlines 1.1)
(setq text-scale-mode-step 1.05)
(setq org-indent-indentation-per-level 0)
(global-visual-line-mode t)
;; (global-display-fill-column-indicator-mode t)
;; (add-hook 'text-mode-hook 'turn-on-auto-fill)
;; (add-hook 'text-mode-hook
;; 	  (lambda() (set-fill-column 80)))
(column-number-mode)
;; (add-hook 'org-mode-hook 'org-indent-mode)
(add-hook 'prog-mode-hook #'display-fill-column-indicator-mode)
(setopt display-fill-column-indicator-column 80)

;; * Custom Keyboard Shortcut
(global-set-key (kbd "M-p") 'scroll-up-line)
(global-set-key (kbd "M-n") 'scroll-down-line)
(global-set-key (kbd "C-M-a") 'org-babel-mark-block)

;; * GUI Interface
(delete-selection-mode 1)
;; (desktop-save-mode 1)
(menu-bar-mode -1)
(scroll-bar-mode -1)
(tool-bar-mode -1)
(set-frame-parameter nil 'alpha-background 85) ; For current frame
(add-to-list 'default-frame-alist '(alpha-background . 85)) ; For all new frames henceforth


;; * Org Modern
(setq org-modern-list
      '((?+ . "▪")
        (?- . "•")))

(setq
 ;; Edit settings
 org-auto-align-tags nil
 org-tags-column 0
 org-catch-invisible-edits 'show-and-error
 org-special-ctrl-a/e t
 org-insert-heading-respect-content t

 ;; Org styling, hide markup etc.
 org-hide-emphasis-markers t
 org-pretty-entities t
 org-agenda-tags-column 0
 org-ellipsis "…")

;; Option 2: Globally
(with-eval-after-load 'org (global-org-modern-mode))

;; * Heaven and Hell
(use-package heaven-and-hell
  :ensure t
  :config
  (setq heaven-and-hell-theme-type 'light)
  (setq heaven-and-hell-themes
        '((light . (ef-spring doom-acario-light dichromacy doom-plain doom-fairy-floss))
	  (dark . (ef-cherie doom-fairy-floss))))
  (setq heaven-and-hell-load-theme-no-confirm t)
  ;; Load custom org-mode styling for theme switching
  (load "~/Projects/emacs/heaven-and-hell-custom.el")
  :hook (after-init . heaven-and-hell-init-hook)
  :bind (("C-c <f8>" . heaven-and-hell-load-default-theme)
         ("<f8>" . heaven-and-hell-toggle-theme)))
