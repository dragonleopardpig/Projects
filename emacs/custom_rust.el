(setq jinx-languages "en_US")
(setq lsp-ui-sideline-show-code-actions nil)
(setq lsp-ui-sideline-enable nil)
(setq lsp-completion-provider :none)
(setq lsp-completion-show-detail nil)
(setq lsp-completion-show-kind nil)

(setenv "PATH" (concat (getenv "PATH") ":" "/home/thinky/Projects/rust/.devenv/profile/bin"))
(add-to-list 'exec-path "/home/thinky/Projects/rust/.devenv/profile/bin")

;; * lsp-bridge-mode
(add-to-list 'load-path "~/Projects/lsp-bridge")
(add-to-list 'load-path "~/Projects/flymake-bridge")

(require 'lsp-bridge)
(global-lsp-bridge-mode)

(require 'yasnippet)
(yas-global-mode 1)

(require 'flymake-bridge)
(add-hook 'lsp-bridge-mode-hook #'flymake-bridge-setup)

(add-hook 'rustic-mode-hook #'lsp-bridge-mode)
