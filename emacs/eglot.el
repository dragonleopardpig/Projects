;;; eglot.el --- Eglot + Rust + Org Babel -*- lexical-binding: t; -*-
;;;; ------------------------------------------------------------
;;;; envrc (direnv / devenv)
;;;; ------------------------------------------------------------

(use-package envrc
  :config
  (envrc-global-mode))

;; * General Setting (disable some lsp features)
(setq jinx-languages "en_US")

(setenv "PATH" (concat (getenv "PATH") ":" "~/Projects/rust/.devenv/profile/bin"))
(add-to-list 'exec-path "~/Projects/rust/.devenv/profile/bin")

(with-eval-after-load 'scimax-yas
  (yas-global-mode -1))

(advice-add 'require :before
            (lambda (feature &rest _)
              (when (eq feature 'lsp-mode)
                (error "lsp-mode is forbidden"))))

(with-eval-after-load 'rustic
  (setq rustic-lsp-client 'eglot))

;; Hard-disable lsp-mode
(setq lsp-mode nil)

;; eglot.el — minimal & safe

(require 'eglot)

(add-hook 'rust-mode-hook #'eglot-ensure)
(add-hook 'rust-ts-mode-hook #'eglot-ensure)

(setq eglot-autoshutdown t
      eglot-events-buffer-size 0)


;;;; ------------------------------------------------------------
;;;; Completion frontend (use company or corfu)
;;;; ------------------------------------------------------------

(use-package corfu
  :ensure t
  :init
  (global-corfu-mode)
  :config
  (setq corfu-auto t
        corfu-cycle t))

;;;; ------------------------------------------------------------
;;;; Optional: Flymake tuning
;;;; ------------------------------------------------------------

(setq flymake-no-changes-timeout 0.3
      flymake-start-on-save-buffer t)

(provide 'eglot)
;;; eglot.el ends here
