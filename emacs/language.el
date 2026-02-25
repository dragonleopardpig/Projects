;; * direnv + lspbridge
(use-package envrc
  :ensure t
  :config
  (envrc-global-mode +1))

;; * General Setting (disable some lsp features)
(setq jinx-languages "en_US")
(setq lsp-ui-sideline-show-code-actions nil)
(setq lsp-ui-sideline-enable nil)
(setq lsp-completion-provider :none)
(setq lsp-completion-show-detail nil)
(setq lsp-completion-show-kind nil)

;; * lsp-bridge-mode
(add-to-list 'load-path "~/Projects/lsp-bridge")
(add-to-list 'load-path "~/Projects/flymake-bridge")

;; Set Python path for lsp-bridge - use the python devenv
(setq lsp-bridge-python-command "~/Projects/python/.devenv/state/venv/bin/python")

;; Add devenv profile bins to PATH so lsp-bridge can find LSP servers
;; (clangd, rust-analyzer, basedpyright, etc.)
(dolist (dir '("~/Projects/cpp/.devenv/profile/bin"
              "~/Projects/rust/.devenv/profile/bin"
              "~/Projects/python/.devenv/profile/bin"))
  (let ((expanded (expand-file-name dir)))
    (when (file-directory-p expanded)
      (add-to-list 'exec-path expanded)
      (setenv "PATH" (concat expanded ":" (getenv "PATH"))))))

(setq lsp-bridge-user-langserver-dir "~/.config/lsp-bridge/langserver")
(require 'lsp-bridge)
(with-eval-after-load 'envrc
  (global-lsp-bridge-mode))
(setq lsp-bridge-enable-completion-in-string nil)

;; lsp-bridge keybindings
(define-key lsp-bridge-mode-map (kbd "M-.") #'lsp-bridge-find-def)
(define-key lsp-bridge-mode-map (kbd "M-,") #'lsp-bridge-find-def-return)
(define-key lsp-bridge-mode-map (kbd "M-?") #'lsp-bridge-find-references)
(define-key lsp-bridge-mode-map (kbd "C-c d") #'lsp-bridge-popup-documentation)   ;; popup docs under cursor
(define-key lsp-bridge-mode-map (kbd "C-c p") #'lsp-bridge-peek)                  ;; peek definition inline
(define-key lsp-bridge-mode-map (kbd "C-c t") #'lsp-bridge-find-type-def)         ;; jump to type definition
(define-key lsp-bridge-mode-map (kbd "C-c i") #'lsp-bridge-incoming-call-hierarchy) ;; who calls this?
(define-key lsp-bridge-mode-map (kbd "C-c o") #'lsp-bridge-outgoing-call-hierarchy) ;; what does this call?
(define-key lsp-bridge-mode-map (kbd "C-c s") #'lsp-bridge-workspace-list-symbols) ;; search symbols across project

;; * Symbol browser sidebar
(use-package imenu-list
  :ensure t
  :bind ("C-c l" . imenu-list-smart-toggle)
  :config
  (setq imenu-list-focus-after-activation t)
  (setq imenu-list-auto-resize t))
(setq acm-enable-search-file-words nil)
(setq lsp-bridge-enable-org-babel t)
(setq acm-enable-yas nil)

;; * Yasnippet
;; Disable scimax's yasnippet config and use our own
(with-eval-after-load 'scimax-yas
  (yas-global-mode -1))

(require 'yasnippet)
(yas-global-mode 1)

(require 'flymake-bridge)
(add-hook 'lsp-bridge-mode-hook #'flymake-bridge-setup)

;; * Rust
(require 'lsp-bridge-rust)
(require 'ob-rust)
(add-to-list 'org-babel-load-languages '(rust . t))
(org-babel-do-load-languages 'org-babel-load-languages org-babel-load-languages)

;; * Python
(when (executable-find "ipython")
  (setq python-shell-interpreter "ipython"))

;; * lsp-bridge-mode for python
;; (add-hook 'python-mode-hook #'lsp-bridge-mode)
(setq lsp-bridge-python-lsp-server "basedpyright")
;; (setq lsp-bridge-python-lsp-server "ruff")
(setq lsp-bridge-python-multi-lsp-server "basedpyright_ruff")
