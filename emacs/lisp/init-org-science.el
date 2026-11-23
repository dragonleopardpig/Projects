;;; init-org-science.el --- Org-mode, scientific writing, citations, and scimax workflows -*- lexical-binding: t; -*-

;;; Commentary:
;; Standalone scientific Org-mode configuration modernized for Emacs 31 + Vertico.
;; Integrates org-modern, mixed-pitch, org-tempo templates, org-crypt, org-alert,
;; ox-pandoc, ox-clip, optional org-pandoc-import, org-ref (completing-read),
;; citar + citar-embark, plus standalone org-scimax-* modules, ox-manuscript,
;; and org-show.

;;; Code:

(require 'cl-lib)

(defgroup my/org-science nil
  "Personal and scientific Org-mode configuration."
  :group 'org)

;;;; Core Org defaults & Org-Modern visuals

(with-eval-after-load 'org
  (setq org-directory (expand-file-name "~/Projects/org")
        org-default-notes-file (expand-file-name "notes.org" org-directory)
        org-startup-folded t
        org-src-fontify-natively t
        org-src-tab-acts-natively t
        org-babel-min-lines-for-block-output 1000
        org-src-block-faces nil
        org-agenda-include-diary t
        org-auto-align-tags nil
        org-tags-column 0
        org-agenda-tags-column 0
        org-catch-invisible-edits 'smart
        org-special-ctrl-a/e t
        org-insert-heading-respect-content t
        org-hide-emphasis-markers t
        org-pretty-entities t
        org-ellipsis "…"
        mouse-1-click-follows-link t)

  (require 'org-tempo nil t)
  (when (boundp 'org-structure-template-alist)
    (add-to-list 'org-structure-template-alist '("r" . "src rust"))
    (add-to-list 'org-structure-template-alist '("jp" . "src jupyter-python")))

  (when (require 'org-modern nil t)
    (global-org-modern-mode 1)))

(with-eval-after-load 'org-modern
  (setq org-modern-list '((?+ . "▪") (?- . "•"))))

;;;; Mixed-pitch & Org block face remapping

(defun my/org-remap-block-delimiter-faces ()
  "Ensure Org block delimiters remain fixed-pitch and readable."
  (dolist (face '(org-block-begin-line org-block-end-line org-modern-block-name))
    (when (facep face)
      (face-remap-add-relative face '(:inherit fixed-pitch :weight bold)))))

(defun my/org-remap-src-code-faces ()
  "Ensure Org source blocks and inline code stay fixed-pitch under mixed-pitch."
  (dolist (face '(org-block org-code org-verbatim org-table org-meta-line))
    (when (facep face)
      (face-remap-add-relative face :inherit 'fixed-pitch))))

(defun my/org-enable-mixed-pitch ()
  "Enable `mixed-pitch-mode' and preserve fixed-pitch code/delimiter faces."
  (when (require 'mixed-pitch nil t)
    (mixed-pitch-mode 1))
  (my/org-remap-block-delimiter-faces)
  (my/org-remap-src-code-faces)
  (when (fboundp 'my/heaven-and-hell-apply-org-block-faces)
    (my/heaven-and-hell-apply-org-block-faces))
  (when (fboundp 'my/apply-org-block-faces)
    (my/apply-org-block-faces)))

(with-eval-after-load 'mixed-pitch
  (dolist (face '(org-block-begin-line org-block-end-line org-modern-block-name))
    (add-to-list 'mixed-pitch-fixed-pitch-faces face)))

(add-hook 'org-mode-hook #'my/org-enable-mixed-pitch)

;;;; Org-Tempo TAB expansion & DWIM Return inside Org src blocks

(defun my/org-tempo-tab ()
  "Expand `org-tempo' snippet before point if possible, else run `org-cycle'."
  (interactive)
  (if (and (fboundp 'org-tempo-complete-tag)
           (looking-back "<[[:alnum:]-]+" (line-beginning-position))
           (org-tempo-complete-tag))
      t
    (org-cycle)))

(defun my/org-src-return-dwim ()
  "Inside an Org source block insert a newline preserving block indentation."
  (interactive)
  (if (and (derived-mode-p 'org-mode)
           (fboundp 'org-in-src-block-p)
           (org-in-src-block-p))
      (newline-and-indent)
    (org-return)))

(defvar my/org-src-return-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'my/org-src-return-dwim)
    (define-key map (kbd "<return>") #'my/org-src-return-dwim)
    map)
  "Keymap for `my/org-src-return-mode'.")

(define-minor-mode my/org-src-return-mode
  "Minor mode making Return indent cleanly inside Org source blocks."
  :init-value nil
  :lighter nil
  :keymap my/org-src-return-mode-map)

(defun my/org-template-keybindings ()
  "Enable `my/org-src-return-mode' and `org-tempo' TAB hook in Org buffers."
  (my/org-src-return-mode 1)
  (add-hook 'org-tab-first-hook #'org-tempo-complete-tag nil t))

(add-hook 'org-mode-hook #'my/org-template-keybindings)

;;;; Security, Capture & Notifications

(with-eval-after-load 'org
  (when (require 'org-crypt nil t)
    (org-crypt-use-before-save-magic)
    (setq org-tags-exclude-from-inheritance
          (cl-adjoin "crypt" (or org-tags-exclude-from-inheritance nil) :test #'equal)
          org-crypt-key nil)))

(use-package org-alert
  :after org
  :custom
  (alert-default-style 'libnotify)
  (org-alert-interval 300)
  (org-alert-notify-cutoff 10)
  (org-alert-notify-after-event-cutoff 10)
  :config
  (when (and (not noninteractive) (fboundp 'org-alert-enable))
    (ignore-errors (org-alert-enable))))

;;;; Import / Export

(use-package ox-pandoc
  :after org)

(use-package ox-clip
  :after org)

(when (my/add-optional-vc-package "org-pandoc-import")
  (use-package org-pandoc-import
    :after org))

;;;; Citations & Bibliography (org-ref without ivy + citar + embark)

(setq bibtex-autokey-year-length 4
      bibtex-autokey-name-year-separator "-"
      bibtex-autokey-year-title-separator "-"
      bibtex-autokey-titleword-separator "-"
      bibtex-autokey-titlewords 2
      bibtex-autokey-titlewords-stretch 1
      bibtex-autokey-titleword-length 5)

(defun my/org-ref-insert-link-dwim ()
  "Insert an `org-ref' link using hydra if loaded, else `org-ref-insert-link'."
  (interactive)
  (if (fboundp 'org-ref-insert-link-hydra/body)
      (call-interactively #'org-ref-insert-link-hydra/body)
    (call-interactively #'org-ref-insert-link)))

(use-package org-ref
  :after org
  :init
  ;; Keep default completing-read completion (Vertico + Orderless) — never load org-ref-ivy.
  (with-eval-after-load 'org
    (define-key org-mode-map (kbd "C-c ]") #'org-ref-insert-link)
    (define-key org-mode-map (kbd "s-[") #'my/org-ref-insert-link-dwim))
  (with-eval-after-load 'bibtex
    (define-key bibtex-mode-map (kbd "H-b") #'org-ref-bibtex-hydra/body)))

(use-package citar
  :demand t
  :bind (("C-c b c" . citar-insert-citation)
         ("C-c b o" . citar-open)
         :map org-mode-map
         ("C-c b c" . citar-insert-citation)
         ("C-c b o" . citar-open))
  :config
  (with-eval-after-load 'oc
    (setq org-cite-insert-processor 'citar
          org-cite-follow-processor 'citar
          org-cite-activate-processor 'citar))
  (when (require 'citar-embark nil t)
    (citar-embark-mode 1)))

;;;; Standalone Scimax Scientific Modules & Vendored Packages

(require 'org-scimax-markup)
(require 'org-scimax-latex)
(require 'org-scimax-babel)
(require 'org-scimax-tools)
(require 'ox-manuscript)
(require 'org-show)

(provide 'init-org-science)
;;; init-org-science.el ends here
