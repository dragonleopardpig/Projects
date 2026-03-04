;; * For SCIMAX starterkit, install scimax first.
(setq warning-minimum-level :emergency)
(setq package-enable-at-startup nil)

;; * Scimax
(setq scimax-journal-root-dir "~/Projects/journal/"
      nb-notebook-directory "~/Projects/")
;; (add-hook 'org-mode-hook 'scimax-autoformat-mode)

;; * Prevent undo tree files from polluting your git repo
(setq undo-tree-history-directory-alist '(("." . "~/.emacs.d/undo")))
;; Put backup files neatly away
(let ((backup-dir "~/.emacs.d/backups")
      (auto-saves-dir "~/.emacs.d/auto-saves"))
  (dolist (dir (list backup-dir auto-saves-dir))
    (when (not (file-directory-p dir))
      (make-directory dir t)))
  (setq backup-directory-alist `(("." . ,backup-dir))
        auto-save-file-name-transforms `((".*" ,auto-saves-dir t))
        auto-save-list-file-prefix (concat auto-saves-dir ".saves-")
        tramp-backup-directory-alist `((".*" . ,backup-dir))
        tramp-auto-save-directory auto-saves-dir))

(setq backup-by-copying t    ; Don't delink hardlinks
      delete-old-versions t  ; Clean up the backups
      version-control t      ; Use version numbers on backups,
      kept-new-versions 5    ; keep some new versions
      kept-old-versions 2)   ; and some old ones, too


;; * Treat all themes as safe
(setq custom-safe-themes t) 
(setq scimax-theme nil)

;;* Load MELPA
;; Note: scimax/init.el already sets up package archives and initializes package.el
;; This section is kept for reference but is redundant
;; (require 'package)
;; (setq package-archives ...)
;; (package-initialize)

(defun ensure-package (pkg)
  "Install PKG unless already installed."
  (unless (package-installed-p pkg)
    (package-install pkg)))

;; * Auto Install My Packages
(setq package-selected-packages
      '(material-theme
	gruvbox-theme
	doom-themes
	ef-themes
	pdf-tools
	async
        neotree
        all-the-icons
        rainbow-delimiters
        yaml-mode
        dockerfile-mode
        toml-mode
        json-mode
	prettier-js
	js2-refactor
	rjsx-mode
	tide
	web-mode
	emmet-mode
	rustic
	ox-rst
	alert
	org-fragtog
	ob-nix
	latex-preview-pane
	org-modern
	slime
	nix-mode
	geiser-mit
	pyvenv
	nov
	markdown-mode
	mixed-pitch
	smartparens
	spice-mode
	ob-spice
	saveplace-pdf-view
	rg
	ob-rust
	lua-mode
	direnv
	magik-mode
	treemacs
	airdermacs
        ;; org-pandoc-import
	))
(package-install-selected-packages)
;; (ensure-package 'org-pandoc-import)

;; * Pyvenv
(require 'pyvenv)
(pyvenv-activate "~/Projects/python/.devenv/state/venv/")

(setq global-jinx-mode nil)

;; * Claude
(use-package claude-code-ide
  :vc (:url "https://github.com/manzaltu/claude-code-ide.el" :rev :newest)
  :bind ("C-c C-'" . claude-code-ide-menu) ; Set your favorite keybinding
  :config
  (claude-code-ide-emacs-tools-setup)) ; Optionally enable Emacs MCP tools

;; * Aidermacs
(use-package aidermacs
  :bind (("C-c a" . aidermacs-transient-menu))
  :config
  (with-temp-buffer
    (when (file-readable-p "~/.config/secrets/claude-api-key")
      (insert-file-contents "~/.config/secrets/claude-api-key")
      (setenv "ANTHROPIC_API_KEY" (string-trim (buffer-string)))))
  :custom
  (aidermacs-default-chat-mode 'architect)
  (aidermacs-default-model"opus"))
(setq aider-program "~/.local/bin/aider")
