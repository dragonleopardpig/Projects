;;; heaven-and-hell.el --- easy toggle light/dark themes -*- lexical-binding: t; -*-

(defvar heaven-and-hell-themes
  '((light . nil)
    (dark . wombat))
  "Associate light and dark theme with this variable.
Theme can be the list.")

(defvar heaven-and-hell-theme-type 'light
  "Set default theme, either `light' or `dark'.")

(defvar heaven-and-hell-load-theme-no-confirm nil
  "Call `'load-theme with NO-CONFIRM if non-nil.")

(defun heaven-and-hell-themes-switch-to ()
  "Return themes which should be loaded according to current `heaven-and-hell-theme-type'."
  (cdr (assoc heaven-and-hell-theme-type heaven-and-hell-themes)))

(defun heaven-and-hell-clean-load-themes (theme-or-themes)
  "Load themes if they're not loaded yet and enable them cleanly.
Cleanly means that it disables all custom themes before enabling new ones.
THEME-OR-THEMES can be single theme or list of themes.
Themes will be loaded if they weren't loaded previously."
  (heaven-and-hell-load-default-theme)
  (when theme-or-themes
    (let ((themes
	   (if (listp theme-or-themes) theme-or-themes `(,theme-or-themes))))
      ;; ## ChuPL
      (if (eq heaven-and-hell-theme-type 'dark)
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
	     '(org-block-begin-line
	       ((t (
		    :underline t
		    :overline nil
		    :foreground "pink"
		    :background nil ;; "#232627"
		    :italic t
		    :bold t
		    :extend t))))
	     '(org-block-end-line
	       ((t (
		    :underline nil
		    :overline t
		    :foreground "pink"
		    :background nil ;; "#232627"
		    :italic t
		    :bold t
		    :extend t))))
	     '(org-level-1 ((t (:foreground "salmon" :italic t :bold t))))
	     ))
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
	   '(org-block-begin-line
	     ((t (
		  :underline t
		  :overline nil
		  :foreground "orange red"
		  :background "white"
		  :italic t
		  :bold t
		  :extend t))))
	   '(org-block-end-line
	     ((t (
		  :underline nil
		  :overline t
		  :foreground "orange red"
		  :background "white"
		  :italic t
		  :bold t
		  :extend t))))
	   '(org-level-1
	     ((t (
		  :foreground "red3"
		  :italic t))))
	   '(org-list-dt
	     ((t (
		  :foreground "#008080"
		  :bold t))))
	   )))
      ;; ##################################
      (dolist (theme themes)
	;; (when heaven-and-hell-load-theme-no-confirm
	(when heaven-and-hell-load-theme-no-confirm
	  (load-theme theme t t)))
      (custom-set-variables `(custom-enabled-themes (quote ,themes)))
      ;; ** ChuPL
      (if (eq heaven-and-hell-theme-type 'dark)
	  (progn (setq heaven-and-hell-theme-type 'dark)
		 (set-background-color "#232627"))
	(progn (setq heaven-and-hell-theme-type 'light)
	       (set-background-color "white")))
      (org-mode-restart)
      (outline-show-children)
      (outline-show-entry)
      ;; *********
      )))

;;;###autoload
(defun heaven-and-hell-toggle-theme ()
  "If `heaven-and-hell-theme-type' is `light' - load dark theme/s.
And vise-versa."
  (interactive)
  (if (eq heaven-and-hell-theme-type 'light)
      (setq heaven-and-hell-theme-type 'dark)
    (setq heaven-and-hell-theme-type 'light))
  (heaven-and-hell-clean-load-themes (heaven-and-hell-themes-switch-to)))

;;;###autoload
(defun heaven-and-hell-load-default-theme ()
  "Disable all custom themes e.g. load default Emacs theme."
  (interactive)
  (custom-set-variables '(custom-enabled-themes nil)))

;;;###autoload
(defun heaven-and-hell-init-hook ()
  "Add this to `after-init-hook' so it can load your theme/s of choice correctly."
  (interactive)
  (heaven-and-hell-clean-load-themes (heaven-and-hell-themes-switch-to)))

(provide 'heaven-and-hell)
;;; heaven-and-hell.el ends here
