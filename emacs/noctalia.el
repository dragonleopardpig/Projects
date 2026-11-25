;;; noctalia.el --- Opt-in Noctalia generated theme support -*- lexical-binding: t; -*-

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

(defvar my/noctalia--explicit-load nil
  "Non-nil while `my/load-noctalia-theme' is intentionally loading `noctalia'.")

(defun my/noctalia--guard-load-theme (orig-fn theme &optional no-confirm no-enable)
  "Ignore unsolicited background `load-theme' of `noctalia' unless opted in.
Noctalia's built-in Emacs template runs `emacsclient -e' with
`(load-theme \\='noctalia t)' on config reloads, which would otherwise stack the
dark Noctalia theme over `ef-spring'/`ef-bio' whenever Emacs runs a server
\(e.g. for Sioyek Study AI).
Allow loading `noctalia' when called via `my/load-noctalia-theme', interactively
via `load-theme', with NO-ENABLE non-nil, or when `noctalia' is already enabled."
  (if (and (eq theme 'noctalia)
           (not no-enable)
           (not my/noctalia--explicit-load)
           (not (eq this-command 'load-theme))
           (not (custom-theme-enabled-p 'noctalia)))
      nil
    (funcall orig-fn theme no-confirm no-enable)))

(advice-add 'load-theme :around #'my/noctalia--guard-load-theme)

(defun my/load-noctalia-theme ()
  "Use the generated Noctalia palette interactively when its template is available."
  (interactive)
  (when (file-readable-p (expand-file-name "noctalia-theme.el" my/noctalia-theme-directory))
    ;; load-theme's NO-CONFIRM argument does not disable other themes.
    (mapc #'disable-theme custom-enabled-themes)
    (let ((my/noctalia--explicit-load t))
      (load-theme 'noctalia t))))

(provide 'my-noctalia)
;;; noctalia.el ends here
