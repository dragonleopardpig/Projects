;;; heaven-and-hell-custom.el --- Custom org-mode styling for theme switching -*- lexical-binding: t; -*-

;; Custom function to apply org-mode faces based on theme type
(defun my/heaven-and-hell-apply-org-block-faces ()
  "Reapply Org block delimiter faces after theme and mode face remapping."
  (if (eq heaven-and-hell-theme-type 'dark)
      (progn
        (set-face-attribute 'org-block-begin-line nil
                            :inherit '(fixed-pitch)
                            :underline t
                            :overline nil
                            :foreground "pink"
                            :background nil
                            :extend t)
        (set-face-attribute 'org-block-end-line nil
                            :inherit '(fixed-pitch)
                            :underline nil
                            :overline t
                            :foreground "pink"
                            :background nil
                            :extend t)
        (when (facep 'org-modern-block-name)
          (set-face-attribute 'org-modern-block-name nil
                              :inherit '(fixed-pitch)
                              :foreground "pink"
                              :background nil)))
    (set-face-attribute 'org-block-begin-line nil
                        :inherit '(fixed-pitch)
                        :underline t
                        :overline nil
                        :foreground "orange red"
                        :background "white"
                        :extend t)
    (set-face-attribute 'org-block-end-line nil
                        :inherit '(fixed-pitch)
                        :underline nil
                        :overline t
                        :foreground "orange red"
                        :background "white"
                        :extend t)
    (when (facep 'org-modern-block-name)
      (set-face-attribute 'org-modern-block-name nil
                          :inherit '(fixed-pitch)
                          :foreground "orange red"
                          :background "white"))))

(defun my/heaven-and-hell-apply-org-faces ()
  "Apply custom org-mode faces when switching between light and dark themes."
  (if (eq heaven-and-hell-theme-type 'dark)
      ;; Dark theme org customizations
      (progn
        (setq org-src-block-faces
              '(("emacs-lisp" (:background "LightCyan1" :extend t))
                ("sh" (:background "#2C001E" :extend t))
                ("jupyter-python" (:background "#001f26" :extend t))
                ("ipython" (:background "HotPink4" :extend t))
                ("python" (:background "#1d2100" :extend t))
                ("sqlite" (:background "#a24224" :extend t))
                ("haskell" (:background "#4200a2" :extend t))
                ("nix" (:background "maroon" :extend t))
                ("lisp" (:background "#232627" :extend t))))
        (custom-set-faces
         '(org-level-1 ((t (:foreground "salmon" :italic t :bold t)))))
        (set-background-color "#232627"))

    ;; Light theme org customizations
    (progn
      (setq org-src-block-faces
            '(("emacs-lisp" (:background "LightCyan1" :extend t))
              ("sh" (:background "gray90" :extend t))
              ("jupyter-python" (:background "snow" :extend t))
              ("ipython" (:background "thistle1" :extend t))
              ("python" (:background "DarkSeaGreen1" :extend t))
              ("sqlite" (:background "#a24224" :extend t))
              ("haskell" (:background "#4200a2" :extend t))
              ("nix" (:background "light yellow" :extend t))
              ("lisp" (:background "honeydew" :extend t))))
      (custom-set-faces
       '(org-level-1
         ((t (:foreground "red3"
              :italic t))))
       '(org-list-dt
         ((t (:foreground "#008080"
              :bold t)))))
      (set-background-color "white")))

  (my/heaven-and-hell-apply-org-block-faces)

  ;; Refresh org-mode buffers if any are open
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (derived-mode-p 'org-mode)
        (org-mode-restart)
        (when (outline-on-heading-p)
          (outline-show-children)
          (outline-show-entry))))))

;; Add advice to heaven-and-hell-clean-load-themes to apply org customizations
(advice-add 'heaven-and-hell-clean-load-themes :after
            (lambda (&rest _args)
              (my/heaven-and-hell-apply-org-faces)))

(add-hook 'org-mode-hook #'my/heaven-and-hell-apply-org-block-faces)

(provide 'heaven-and-hell-custom)
;;; heaven-and-hell-custom.el ends here
