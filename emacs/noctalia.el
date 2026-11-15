;;; noctalia.el --- Follow Noctalia's generated theme -*- lexical-binding: t; -*-

(require 'seq)

;; Match the official template's output-path.sh configuration-root order.
(defvar my/noctalia-theme-directory
  (expand-file-name
   "themes/"
   (or (seq-find #'file-directory-p
                 (list (expand-file-name "doom/" (or (getenv "XDG_CONFIG_HOME") "~/.config/"))
                       (expand-file-name "emacs/" (or (getenv "XDG_CONFIG_HOME") "~/.config/"))))
       user-emacs-directory)))

(add-to-list 'custom-theme-load-path my/noctalia-theme-directory)

(defun my/load-noctalia-theme ()
  "Use the generated Noctalia palette interactively when its template is available."
  (interactive)
  (when (file-readable-p (expand-file-name "noctalia-theme.el" my/noctalia-theme-directory))
    ;; load-theme's NO-CONFIRM argument does not disable other themes.
    (mapc #'disable-theme custom-enabled-themes)
    (load-theme 'noctalia t)))

(provide 'my-noctalia)
;;; noctalia.el ends here
