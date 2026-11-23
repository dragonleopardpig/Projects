;;; init-documents.el --- EPUB (`nov`) and PDF (`pdf-tools` + two-page spread) -*- lexical-binding: t; -*-

;;; Commentary:
;; Document reader configuration for EPUB and PDF files, including persistent
;; page memory via `saveplace-pdf-view' and two-page side-by-side spread
;; reading toggled with `d' inside `pdf-view-mode'.

;;; Code:

(require 'cl-lib)

;;;; EPUB Reader (`nov`)

(use-package nov
  :mode ("\\.epub\\'" . nov-mode))

;;;; PDF Reader (`pdf-tools` + `saveplace-pdf-view` + Two-Page Spread)

(when (locate-library "pdf-tools")
  (require 'pdf-tools nil t)
  (when (and (not noninteractive) (fboundp 'pdf-loader-install))
    (ignore-errors (pdf-loader-install t)))
  (setq pdf-view-resize-factor 1.02
        pdf-view-continuous nil))

(require 'saveplace-pdf-view nil t)

(defvar-local my/pdf-follow-partner-window nil
  "Partner window paired with the current window during two-page PDF spread.")

(defun my/pdf--partner-sync (&optional _arg)
  "Keep side-by-side partner window one page ahead in `pdf-view-follow-minor-mode'."
  (when (and (bound-and-true-p pdf-view-follow-minor-mode)
             (window-live-p my/pdf-follow-partner-window)
             (eq (window-buffer my/pdf-follow-partner-window) (current-buffer))
             (fboundp 'pdf-view-current-page)
             (fboundp 'pdf-view-goto-page)
             (fboundp 'pdf-cache-number-of-pages))
    (let* ((left-win (selected-window))
           (right-win my/pdf-follow-partner-window)
           (total (pdf-cache-number-of-pages))
           (page (pdf-view-current-page left-win))
           (next-page (min total (1+ page))))
      (when (and (window-live-p right-win)
                 (not (eq left-win right-win)))
        (with-selected-window right-win
          (unless (= (pdf-view-current-page right-win) next-page)
            (pdf-view-goto-page next-page right-win)))))))

(define-minor-mode pdf-view-follow-minor-mode
  "Minor mode enabling synced two-page side-by-side PDF viewing."
  :lighter " 2Page"
  (if pdf-view-follow-minor-mode
      (progn
        (when (one-window-p t)
          (setq my/pdf-follow-partner-window (split-window-right)))
        (unless (window-live-p my/pdf-follow-partner-window)
          (setq my/pdf-follow-partner-window (next-window)))
        (set-window-buffer my/pdf-follow-partner-window (current-buffer))
        (add-hook 'pdf-view-after-change-page-hook #'my/pdf--partner-sync nil t)
        (my/pdf--partner-sync))
    (remove-hook 'pdf-view-after-change-page-hook #'my/pdf--partner-sync t)
    (when (and (window-live-p my/pdf-follow-partner-window)
               (not (eq my/pdf-follow-partner-window (selected-window)))
               (eq (window-buffer my/pdf-follow-partner-window) (current-buffer)))
      (delete-window my/pdf-follow-partner-window))
    (setq my/pdf-follow-partner-window nil)))

(with-eval-after-load 'pdf-view
  (define-key pdf-view-mode-map (kbd "d") #'pdf-view-follow-minor-mode))

(provide 'init-documents)
;;; init-documents.el ends here
