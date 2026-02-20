;;; lsp.el --- LSP + Rust + Org Babel setup -*- lexical-binding: t; -*-
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

;;;; ------------------------------------------------------------
;;;; lsp-bridge (for real files only)
;;;; ------------------------------------------------------------
;; * Rust
;; * lsp-bridge-mode
(add-to-list 'load-path "~/Projects/lsp-bridge")


(require 'lsp-bridge)
(global-lsp-bridge-mode)
(setq lsp-bridge-enable-completion-in-string nil)
(setq acm-enable-search-file-words nil)
(setq lsp-bridge-enable-org-babel nil)

;; * Rust
(require 'lsp-bridge-rust)

;;;; ------------------------------------------------------------
;;;; lsp-mode (ONLY for org-src buffers)
;;;; ------------------------------------------------------------

(use-package lsp-mode
  :ensure t
  :commands (lsp lsp-deferred)
  :init
  (setq lsp-enable-symbol-highlighting nil
        lsp-enable-on-type-formatting nil
        lsp-headerline-breadcrumb-enable nil
        lsp-modeline-code-actions-enable nil
        lsp-keymap-prefix "C-c l"))

(use-package lsp-org
  :after lsp-mode
  :ensure t)

;;;; Company (used by lsp-mode, NOT by lsp-bridge)
(use-package company
  :ensure t
  :init
  (setq company-idle-delay 0.15
        company-minimum-prefix-length 1
        company-tooltip-align-annotations t)
  :config
  (global-company-mode 1))


;;;; ------------------------------------------------------------
;;;; Rustic (Rust support for lsp-mode)
;;;; ------------------------------------------------------------

(use-package rustic
  :ensure t
  :after lsp-mode
  :init
  (setq rustic-lsp-client 'lsp-mode))


;;;; ------------------------------------------------------------
;;;; Org Babel (Rust)
;;;; ------------------------------------------------------------

(with-eval-after-load 'org
  ;; Enable Rust execution
  (org-babel-do-load-languages
   'org-babel-load-languages
   '((rust . t)))

  ;; No confirmation prompt
  (setq org-confirm-babel-evaluate nil)

  ;; Better src editing
  (setq org-src-preserve-indentation t
        org-src-tab-acts-natively t
        org-edit-src-content-indentation 0))


;;;; ------------------------------------------------------------
;;;; Critical glue logic: org-src + lsp-org
;;;; ------------------------------------------------------------

;; Disable lsp-bridge inside org-src buffers
(defun my/org-src-disable-lsp-bridge ()
  (when (bound-and-true-p lsp-bridge-mode)
    (lsp-bridge-mode -1)))

;; Enable lsp-mode (via lsp-org) for Rust blocks
(defun my/org-src-enable-lsp-org ()
  (when (derived-mode-p 'rust-mode)
    (company-mode 1)
    (lsp-deferred)))

(add-hook 'org-src-mode-hook #'my/org-src-disable-lsp-bridge)
(add-hook 'org-src-mode-hook #'my/org-src-enable-lsp-org)


;;;; ------------------------------------------------------------
;;;; Quality-of-life: avoid accidental lsp in org-mode
;;;; ------------------------------------------------------------

(defun my/disable-lsp-in-org-mode ()
  (when (derived-mode-p 'org-mode)
    (setq-local lsp-mode nil)))

(add-hook 'org-mode-hook #'my/disable-lsp-in-org-mode)

(provide 'lsp)
;;; lsp.el ends here
