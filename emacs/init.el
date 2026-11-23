;;; init.el --- Standalone modular Emacs 31 entrypoint -*- lexical-binding: t; -*-

;;; Commentary:
;; Modular Emacs 31 configuration using Nix-provisioned packages, Vertico +
;; Orderless + Marginalia + Consult + Embark completion, Enhanced Dirvish,
;; lsp-bridge + envrc + native tree-sitter, scientific Org/LaTeX/Jupyter tools,
;; and AI coding assistants.  Does not load `scimax'.

;;; Code:

(setq custom-file (expand-file-name "custom.el" user-emacs-directory))
(when (file-readable-p custom-file)
  (load custom-file 'noerror 'nomessage))

(setq warning-minimum-level :error
      custom-safe-themes t)

(require 'use-package)
(setq use-package-always-ensure nil)

(eval-and-compile
  (defconst my/emacs-config-dir
    (file-name-directory
     (or load-file-name (bound-and-true-p byte-compile-current-file) buffer-file-name))
    "Root directory containing this modular Emacs configuration.")

  (dolist (rel '("lisp"
                 "vendor/ox-manuscript"
                 "vendor/org-show"
                 "enhanced-dirvish"))
    (let ((dir (expand-file-name rel my/emacs-config-dir)))
      (when (file-directory-p dir)
        (add-to-list 'load-path dir))))

  (dolist (mdir (list (expand-file-name "emacs-minder/lisp" (file-name-directory (directory-file-name my/emacs-config-dir)))
                      (expand-file-name "~/.emacs.d/modules/emacs-minder/share/emacs/site-lisp/emacs-minder")))
    (when (file-directory-p mdir)
      (add-to-list 'load-path mdir)))

  (defun my/add-optional-vc-package (name)
    "Append installed directory for optional VC package NAME to `load-path'.
Searches `~/.emacs.d/elpa-vc/' first, then legacy `~/.emacs.d/elpa/'.
Appends rather than prepends so Nix-built packages always take precedence."
    (let ((found nil))
      (dolist (root (list (expand-file-name "elpa-vc" user-emacs-directory)
                          (expand-file-name "elpa" user-emacs-directory)))
        (when (and (not found) (file-directory-p root))
          (dolist (cand (directory-files root t (concat "\\`" (regexp-quote name) "\\(-\\|\\'\\)")))
            (when (and (not found) (file-directory-p cand))
              (add-to-list 'load-path cand t)
              (setq found cand)))))
      found)))

(defun my/install-vc-packages ()
  "Install optional packages not yet in nixpkgs into `~/.emacs.d/elpa-vc/'."
  (interactive)
  (require 'package)
  (require 'package-vc)
  (let ((package-user-dir (expand-file-name "elpa-vc" user-emacs-directory)))
    (make-directory package-user-dir t)
    (unless (locate-library "org-pandoc-import")
      (package-vc-install
       '(org-pandoc-import :url "https://github.com/tecosaur/org-pandoc-import")))
    (unless (locate-library "claude-code-ide")
      (package-vc-install
       '(claude-code-ide :url "https://github.com/manzaltu/claude-code-ide.el")))))

(require 'init-core)
(require 'init-completion)
(require 'init-files-and-ui)
(require 'init-org-science)
(require 'init-programming)
(require 'init-documents)
(require 'init-ai)

(provide 'init)
;;; init.el ends here
