;;; init-core.el --- Core editing, persistence, tree-sitter, and helpers -*- lexical-binding: t; -*-

;;; Commentary:
;; Base Emacs behavior, undo/backup hygiene, native Emacs 31 tree-sitter,
;; spell-checking (jinx), structural editing, and elisp path click-links.

;;; Code:

(require 'cl-lib)
(require 'diminish)
(require 'avy)
(require 'move-text)

(set-language-environment "UTF-8")

;; Keep backup, auto-save, and undo files out of project trees.
(let ((backup-dir (expand-file-name "backups" user-emacs-directory))
      (auto-saves-dir (expand-file-name "auto-saves" user-emacs-directory))
      (undo-dir (expand-file-name "undo" user-emacs-directory)))
  (dolist (dir (list backup-dir auto-saves-dir undo-dir))
    (unless (file-directory-p dir)
      (make-directory dir t)))
  (setq backup-directory-alist `(("." . ,backup-dir))
        auto-save-file-name-transforms `((".*" ,auto-saves-dir t))
        auto-save-list-file-prefix (expand-file-name ".saves-" auto-saves-dir)
        tramp-backup-directory-alist `((".*" . ,backup-dir))
        tramp-auto-save-directory auto-saves-dir
        undo-tree-history-directory-alist `(("." . ,undo-dir))))

(setq backup-by-copying t
      delete-old-versions t
      version-control t
      kept-new-versions 5
      kept-old-versions 2
      bookmark-save-flag 1)

;; Undo-tree
(require 'undo-tree)
(global-undo-tree-mode 1)
(diminish 'undo-tree-mode)

;; Recent files & cursor positions
(require 'recentf)
(setq recentf-exclude '("COMMIT_MSG" "COMMIT_EDITMSG" "github.*txt$"
                        ".*png$" "\\*message\\*" "auto-save-list\\*")
      recentf-max-saved-items 60)
(recentf-mode 1)
(save-place-mode 1)

;; Live file-system sync for buffers and Dired/Dirvish
(setq global-auto-revert-non-file-buffers t
      auto-revert-verbose nil
      auto-revert-use-notify t
      dired-auto-revert-buffer t)
(global-auto-revert-mode 1)

;; Editing defaults
(delete-selection-mode 1)
(column-number-mode 1)
(global-visual-line-mode 1)
(setq display-line-numbers-type 'relative)
(setopt display-fill-column-indicator-column 80)
(add-hook 'prog-mode-hook #'display-line-numbers-mode)
(add-hook 'prog-mode-hook #'display-fill-column-indicator-mode)
(move-text-default-bindings)

;; Keybinding hints
(require 'which-key)
(which-key-mode 1)

;; Config modes
(add-to-list 'auto-mode-alist '("\\.ini\\'" . conf-desktop-mode))

;; Native Emacs 31 tree-sitter (Nix grammars + custom ~/Projects/emacs/tree-sitter)
(when (and (fboundp 'treesit-available-p) (treesit-available-p))
  (require 'treesit)
  (let ((ts-dir (expand-file-name "~/Projects/emacs/tree-sitter")))
    (when (file-directory-p ts-dir)
      (add-to-list 'treesit-extra-load-path ts-dir)))
  (let ((nix-ts (expand-file-name "nix-tree-sitter.el" user-emacs-directory)))
    (when (file-exists-p nix-ts)
      (load nix-ts nil 'nomessage)))
  (setq major-mode-remap-alist
        '((python-mode . python-ts-mode)
          (json-mode . json-ts-mode)
          (css-mode . css-ts-mode)
          (html-mode . html-ts-mode)
          (bash-mode . bash-ts-mode))))

;; Delimiters, colors, whitespace, structural editing
(when (require 'rainbow-delimiters nil t)
  (add-hook 'prog-mode-hook #'rainbow-delimiters-mode))

(when (require 'ws-butler nil t)
  (add-hook 'prog-mode-hook #'ws-butler-mode))

(when (require 'smartparens-config nil t)
  (add-hook 'org-mode-hook #'smartparens-mode)
  (sp-pair "$" "$")
  (global-set-key (kbd "C-.") #'sp-rewrap-sexp))

(when (require 'lispy nil t)
  (dolist (hook '(emacs-lisp-mode-hook hy-mode-hook))
    (add-hook hook
              (lambda ()
                (lispy-mode 1)
                (eldoc-mode 1)))))

(when (require 'aggressive-indent nil t)
  (add-hook 'emacs-lisp-mode-hook #'aggressive-indent-mode))

;; Spell checking via jinx (enchant)
(setq jinx-languages "en_US"
      global-jinx-mode nil)
(when (require 'jinx nil t)
  (global-set-key (kbd "M-$") #'jinx-correct)
  (global-set-key (kbd "C-M-$") #'jinx-languages))

;; Scrolling & Org babel mark shortcuts
(global-set-key (kbd "M-p") #'scroll-up-line)
(global-set-key (kbd "M-n") #'scroll-down-line)
(global-set-key (kbd "C-M-a") #'org-babel-mark-block)

;; Clickable file paths in emacs-lisp-mode
(defun my/file-path-open-at-click (event)
  "Open the file path at the clicked EVENT position in the other window."
  (interactive "e")
  (let* ((pos (posn-point (event-end event)))
         (path (get-char-property pos 'my/file-path)))
    (when path
      (let ((expanded-path (expand-file-name path)))
        (when (= (count-windows) 1)
          (split-window-below))
        (other-window 1)
        (if (file-directory-p expanded-path)
            (dired expanded-path)
          (find-file expanded-path))
        (other-window -1)))))

(defvar my/file-path-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'my/file-path-open-at-click)
    map)
  "Keymap for clickable file paths.")

(defun my/add-file-path-overlays ()
  "Add overlays to quoted ~/... or /... file paths to make them clickable."
  (save-excursion
    (goto-char (point-min))
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (overlay-get ov 'my/file-path-overlay)
        (delete-overlay ov)))
    (while (re-search-forward "\"\\(~?/[^\"]*\\)\"" nil t)
      (let* ((beg (match-beginning 1))
             (end (match-end 1))
             (path (match-string-no-properties 1))
             (ov (make-overlay beg end)))
        (overlay-put ov 'my/file-path-overlay t)
        (overlay-put ov 'face '(:underline t))
        (overlay-put ov 'mouse-face 'highlight)
        (overlay-put ov 'pointer 'hand)
        (overlay-put ov 'my/file-path path)
        (overlay-put ov 'keymap my/file-path-keymap)
        (overlay-put ov 'help-echo (format "mouse-1: open %s" path))))))

(add-hook 'emacs-lisp-mode-hook
          (lambda ()
            (my/add-file-path-overlays)
            (add-hook 'after-save-hook #'my/add-file-path-overlays nil t)))

(provide 'init-core)
;;; init-core.el ends here
