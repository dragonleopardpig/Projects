;;; vterm-theme.el --- Follow Emacs themes in existing terminals -*- lexical-binding: t; -*-

;;; Commentary:
;; libvterm stores resolved colour strings in buffer face properties.  Retain
;; their palette references so old output can follow themes without clearing,
;; resizing or sending input to the shell.  Explicit RGB colours stay fixed.

;;; Code:

(require 'cl-lib)

(defvar my/vterm-theme--timer nil)
(defvar vterm-keymap-exceptions)
(defvar vterm-mode-map)
(declare-function vterm--get-color "vterm" (index &rest args))

(defun my/vterm-theme--color (original index &rest args)
  "Keep INDEX and ARGS on the theme colour returned by ORIGINAL."
  (let ((color (apply original index args)))
    (if (and (stringp color) (> (length color) 0))
        (propertize color 'my/vterm-palette-reference (cons index args))
      color)))

(defun my/vterm-theme--face (face)
  "Refresh palette colour references in FACE while preserving other attributes."
  (cond
   ((and (consp face) (keywordp (car face)))
    (let ((result (copy-sequence face)))
      (dolist (attribute '(:foreground :background))
        (let* ((color (plist-get face attribute))
               (reference (and (stringp color) (> (length color) 0)
                               (get-text-property 0 'my/vterm-palette-reference color))))
          (when reference
            (setq result (plist-put result attribute (apply #'vterm--get-color reference))))))
      result))
   ((consp face) (mapcar #'my/vterm-theme--face face))
   (t face)))

(defun my/vterm-refresh-theme (&rest _)
  "Refresh existing terminal output, including scrollback, for the current theme."
  (when (timerp my/vterm-theme--timer) (cancel-timer my/vterm-theme--timer))
  (setq my/vterm-theme--timer nil)
  (when (featurep 'vterm)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (derived-mode-p 'vterm-mode)
          (save-excursion
            (save-restriction
              (widen)
              (let ((inhibit-read-only t))
                (with-silent-modifications
                  (dolist (property '(face font-lock-face))
                    (let ((position (point-min)))
                      (while (< position (point-max))
                        (let* ((end (next-single-property-change position property nil (point-max)))
                               (face (get-text-property position property))
                               (updated (my/vterm-theme--face face)))
                          (unless (equal face updated)
                            (put-text-property position end property updated))
                          (setq position end))))))))))))))

(defun my/vterm-theme--queue-refresh (&rest _)
  "Coalesce the intermediate face changes involved in enabling a theme."
  (when (and (featurep 'vterm) (not my/vterm-theme--timer))
    (setq my/vterm-theme--timer (run-at-time 0 nil #'my/vterm-refresh-theme))))

(with-eval-after-load 'vterm
  ;; Let the user's global F4 theme binding work in normal and embedded vterm.
  (add-to-list 'vterm-keymap-exceptions "<f4>")
  (define-key vterm-mode-map (kbd "<f4>") nil)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'vterm-mode)
        ;; Embedded terminals use a buffer-local copy of vterm-mode-map.
        (local-unset-key (kbd "<f4>")))))
  (advice-add 'vterm--get-color :around #'my/vterm-theme--color))

(add-hook 'enable-theme-functions #'my/vterm-theme--queue-refresh)
(add-hook 'disable-theme-functions #'my/vterm-theme--queue-refresh)
(advice-add 'set-background-color :after #'my/vterm-theme--queue-refresh)
(with-eval-after-load 'heaven-and-hell
  (advice-add 'heaven-and-hell-clean-load-themes :after #'my/vterm-refresh-theme)
  (advice-add 'heaven-and-hell-load-default-theme :after #'my/vterm-theme--queue-refresh))

(provide 'vterm-theme)
;;; vterm-theme.el ends here
