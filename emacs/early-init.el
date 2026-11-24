;;; early-init.el --- Fast standalone startup for Emacs 31 -*- lexical-binding: t; -*-

;;; Commentary:
;; Keeps GC quiet during init, disables imperative package.el startup so
;; Nix-provisioned packages on site-lisp cannot be shadowed by stale ELPA dirs,
;; and sets initial Wayland/PGTK frame geometry & transparency before mapping.

;;; Code:

(setq gc-cons-threshold (* 64 1024 1024))
(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold (* 64 1024 1024))))

;; Nix `emacsWithPackages' populates `load-path' via site-start.el.
(setq package-enable-at-startup nil)

;; Avoid costly frame resizes when setting fonts/chrome.
(setq frame-inhibit-implied-resize t)

(dolist (pair '((menu-bar-lines . 1)
                (tool-bar-lines . 0)
                (vertical-scroll-bars . nil)
                (alpha-background . 95)))
  (push pair default-frame-alist))

;; Precompiled native modules still call dlopen() and honor LD_LIBRARY_PATH
;; for system libraries outside Nix RPATHs.
(let* ((sys-lib "/run/current-system/sw/lib")
       (existing (or (getenv "LD_LIBRARY_PATH") "")))
  (when (file-directory-p sys-lib)
    (unless (string-match-p (regexp-quote sys-lib) existing)
      (setenv "LD_LIBRARY_PATH"
              (if (string-empty-p existing)
                  sys-lib
                (concat sys-lib ":" existing))))))

(provide 'early-init)
;;; early-init.el ends here
