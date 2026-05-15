;; * For SCIMAX starterkit, install scimax first.
(setq warning-minimum-level :emergency)
(setq package-enable-at-startup nil)

;; * Dynamic module dlopen on NixOS
;; Precompiled .so files from ELPA (jinx-mod.so, pdf-tools, vterm-module,
;; tree-sitter shared libs…) call dlopen() at module-load time and look
;; up libraries via LD_LIBRARY_PATH. nix-ld only intercepts execve, not
;; in-process dlopen, so we still need the path explicitly. Prepend the
;; system profile lib dir before anything that might (require 'jinx).
(let* ((sys-lib "/run/current-system/sw/lib")
       (existing (or (getenv "LD_LIBRARY_PATH") "")))
  (when (file-directory-p sys-lib)
    (unless (string-match-p (regexp-quote sys-lib) existing)
      (setenv "LD_LIBRARY_PATH"
              (if (string-empty-p existing)
                  sys-lib
                (concat sys-lib ":" existing))))))

;; Bake an rpath into jinx-mod.so on (re)compile so it always finds
;; libenchant-2.so.2 regardless of LD_LIBRARY_PATH.  ELPA ships a
;; prebuilt jinx-mod.so without an rpath; envrc/devenv buffers replace
;; LD_LIBRARY_PATH, so dlopen() then fails.  When the prebuilt is
;; missing (e.g. after `rm jinx-mod.so' or an ELPA upgrade), jinx
;; falls back to compiling from jinx-mod.c with these flags.  The
;; existing custom-compiled .so survives ELPA upgrades unless ELPA
;; itself overwrites it; if you see the libenchant error again after
;; an upgrade, `rm ~/.emacs.d/elpa/jinx-*/jinx-mod.so' and restart.
(with-eval-after-load 'jinx
  (setq jinx--compile-flags
        '("-I." "-O2" "-Wall" "-Wextra" "-fPIC" "-shared"
          "-Wl,-rpath,/run/current-system/sw/lib")))

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

;; * Pyvenv
;; envrc-global-mode (in language.el) sets up per-buffer PATH/VIRTUAL_ENV
;; from each project's .envrc, so we no longer hard-pin a single venv
;; here.  The previous activate'd ~/Projects/python/.devenv/state/venv/
;; which no longer exists.  Just load the package; activation happens
;; per-buffer via envrc.
(require 'pyvenv)

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
