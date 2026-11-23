;;; init-ai.el --- AI coding assistants (`ai-agent`, `aidermacs`, `claude-code-ide`) -*- lexical-binding: t; -*-

;;; Commentary:
;; Loads Antigravity live buffer integration (`ai-agent.el', bound to `C-c e'),
;; configures `aidermacs' (`C-c a'), and activates optional `claude-code-ide'
;; (`C-c C-'') when present in `~/.emacs.d/elpa-vc/' or `~/.emacs.d/elpa/'.

;;; Code:

(require 'subr-x)

;; Antigravity MCP agent-shell integration (C-c e)
(load (expand-file-name "ai-agent.el" my/emacs-config-dir) nil 'nomessage)

;; Aidermacs (C-c a) with Anthropic API key read from secrets if unset
(defun my/aidermacs-ensure-api-key (&rest _)
  "Populate `ANTHROPIC_API_KEY' from `~/.config/secrets/claude-api-key' if unset."
  (when (string-empty-p (or (getenv "ANTHROPIC_API_KEY") ""))
    (let ((secret-file (expand-file-name "~/.config/secrets/claude-api-key")))
      (when (file-readable-p secret-file)
        (let ((key (string-trim (with-temp-buffer
                                  (insert-file-contents secret-file)
                                  (buffer-string)))))
          (unless (string-empty-p key)
            (setenv "ANTHROPIC_API_KEY" key)))))))

(use-package aidermacs
  :bind (("C-c a" . aidermacs-transient-menu))
  :init
  (setq aidermacs-default-chat-mode 'architect
        aidermacs-default-model "opus"
        aidermacs-program (expand-file-name "~/.local/bin/aider"))
  :config
  (advice-add 'aidermacs-transient-menu :before #'my/aidermacs-ensure-api-key))

;; Optional VC package: claude-code-ide (C-c C-')
(when (my/add-optional-vc-package "claude-code-ide")
  (use-package claude-code-ide
    :bind (("C-c C-'" . claude-code-ide-menu))
    :config
    (when (fboundp 'claude-code-ide-emacs-tools-setup)
      (claude-code-ide-emacs-tools-setup))))

(provide 'init-ai)
;;; init-ai.el ends here
