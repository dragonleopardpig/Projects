;;; init-completion.el --- Modern Vertico/Orderless/Marginalia/Consult/Embark stack -*- lexical-binding: t; -*-

;;; Commentary:
;; Replaces Ivy/Counsel/Swiper/Smex with Vertico + Orderless + Marginalia +
;; Consult + Embark + Helpful, and configures Projectile with default
;; `completing-read' so project selection uses Vertico seamlessly.

;;; Code:

(require 'vertico)
(setq vertico-cycle t
      vertico-count 15)
(vertico-mode 1)

(when (require 'vertico-directory nil t)
  (define-key vertico-map (kbd "RET") #'vertico-directory-enter)
  (define-key vertico-map (kbd "DEL") #'vertico-directory-delete-char)
  (define-key vertico-map (kbd "M-DEL") #'vertico-directory-delete-word)
  (add-hook 'rfn-eshadow-update-overlay-hook #'vertico-directory-tidy))

(require 'orderless)
(setq completion-styles '(orderless basic)
      completion-category-defaults nil
      completion-category-overrides '((file (styles partial-completion))))

(require 'marginalia)
(marginalia-mode 1)

(defun my/enable-completion-icons (&optional frame)
  "Enable `nerd-icons-completion-mode' when running in a graphical FRAME."
  (when (display-graphic-p frame)
    (when (require 'nerd-icons-completion nil t)
      (nerd-icons-completion-mode 1)
      (add-hook 'marginalia-mode-hook #'nerd-icons-completion-marginalia-setup))))

(if (display-graphic-p)
    (my/enable-completion-icons)
  (add-hook 'after-make-frame-functions #'my/enable-completion-icons))

(require 'consult)
(global-set-key (kbd "C-s") #'consult-line)
(global-set-key (kbd "H-s") #'consult-line-multi)
(global-set-key (kbd "C-x b") #'consult-buffer)
(global-set-key (kbd "<f7>") #'consult-recent-file)
(global-set-key (kbd "C-x f") #'consult-recent-file)
(global-set-key (kbd "C-x C-M-f") #'find-file)
(global-set-key (kbd "M-y") #'consult-yank-pop)
(global-set-key (kbd "M-g i") #'consult-imenu)
(global-set-key (kbd "M-g o") #'consult-outline)
(global-set-key (kbd "M-s r") #'consult-ripgrep)
(global-set-key (kbd "M-s f") #'consult-find)

(with-eval-after-load 'org
  (define-key org-mode-map (kbd "C-c h") #'consult-org-heading)
  (define-key org-mode-map (kbd "M-g o") #'consult-org-heading))

(require 'embark)
(require 'embark-consult)
(global-set-key (kbd "C-;") #'embark-act)
(global-set-key (kbd "C-h B") #'embark-bindings)
(add-hook 'embark-collect-mode-hook #'consult-preview-at-point-mode)

(when (require 'helpful nil t)
  (global-set-key (kbd "C-h f") #'helpful-callable)
  (global-set-key (kbd "C-h v") #'helpful-variable)
  (global-set-key (kbd "C-h k") #'helpful-key)
  (global-set-key (kbd "C-h x") #'helpful-command))

;; Projectile (using Vertico via default completion-system)
(require 'projectile)
(setq projectile-completion-system 'default
      projectile-project-search-path '("~/Projects/")
      projectile-cleanup-known-projects nil)
(projectile-mode 1)
(diminish 'projectile-mode)
(define-key projectile-mode-map (kbd "H-p") 'projectile-command-map)
(global-set-key (kbd "C-c p p") #'projectile-switch-project)
(global-set-key (kbd "C-c p f") #'projectile-find-file)
(global-set-key (kbd "C-c p b") #'projectile-switch-to-buffer)
(global-set-key (kbd "C-c p d") #'projectile-find-dir)
(global-set-key (kbd "C-c p r") #'consult-ripgrep)
(global-set-key (kbd "C-c p k") #'projectile-kill-buffers)

(provide 'init-completion)
;;; init-completion.el ends here
