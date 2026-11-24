;;; init-documents.el --- EPUB (`nov`) and PDF (`pdf-tools` + two-page spread) -*- lexical-binding: t; -*-

;;; Commentary:
;; Document reader configuration for EPUB and PDF files, including persistent
;; page memory via `saveplace-pdf-view' and two-page side-by-side spread
;; reading toggled with `d' inside `pdf-view-mode'.

;;; Code:

(require 'cl-lib)

(defvar pdf-view-resize-factor)
(defvar pdf-view-continuous)
(defvar pdf-view-use-scaling)
(defvar pdf-view-mode-map)
(defvar pdf-cache-prefetch-delay)
(defvar pdf-cache-image-limit)
(defvar pdf-cache-prefetch-pages-function)
(defvar pdf-cache--prefetch-pages)
(defvar pdf-info--queue)
(defvar pdf-info-asynchronous)
(defvar visual-line-mode)
(defvar undo-tree-mode)
(defvar org-mode-map)
(declare-function pdf-loader-install "pdf-loader"
                  (&optional no-query-p skip-dependencies-p no-error-p force-dependencies-p))
(declare-function pdf-cache--prefetch-pages "pdf-cache" (window image-width))
(declare-function pdf-cache-number-of-pages "pdf-cache" ())
(declare-function pdf-cache--data-get "pdf-cache" (key &optional page))
(declare-function pdf-cache--data-put "pdf-cache" (key value &optional page))
(declare-function pdf-view-current-page "pdf-view" (&optional window))
(declare-function pdf-view-goto-page "pdf-view" (page &optional window))
(declare-function pdf-view-desired-image-size "pdf-view" (&optional page window))
(declare-function pdf-util-pdf-buffer-p "pdf-util" (&optional buffer))
(declare-function tq-queue-empty "tq" (tq))
(declare-function visual-line-mode "simple" (&optional arg))
(declare-function undo-tree-mode "undo-tree" (&optional arg))
(declare-function emacs-minder-mode "emacs-minder" ())
(declare-function emacs-minder-new "emacs-minder" (&optional title))
(declare-function emacs-minder-open-org "emacs-minder" (&optional file))
(declare-function emacs-minder-paste-clipboard-latex "emacs-minder" (&optional arg))

;;;; EPUB Reader (`nov`)

(use-package nov
  :mode ("\\.epub\\'" . nov-mode))

;;;; PDF Reader (`pdf-tools` + `saveplace-pdf-view` + Two-Page Spread)

(when (locate-library "pdf-tools")
  (load "pdf-tools-autoloads" t t)
  (require 'pdf-loader nil t)
  (when (fboundp 'pdf-loader-install)
    (pdf-loader-install t t t)))

(unless noninteractive
  (require 'saveplace-pdf-view nil t))

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

(defconst my/pdf-scroll-commands
  '(mwheel-scroll
    mouse-wheel-scroll-up
    mouse-wheel-scroll-down
    pixel-scroll-precision
    pdf-view-scroll-up-or-next-page
    pdf-view-scroll-down-or-previous-page
    pdf-view-next-line-or-next-page
    pdf-view-previous-line-or-previous-page
    image-next-line
    image-previous-line
    image-scroll-up
    image-scroll-down
    image-forward-hscroll
    image-backward-hscroll
    image-bol
    image-eol
    scroll-up-line
    scroll-down-line
    pdf-roll-scroll-forward
    pdf-roll-scroll-backward)
  "Intra-page navigation commands that should not cancel background prefetching.")

(defvar-local my/pdf--prefetch-timer nil
  "One-shot timer starting async page prefetching after page changes.")

(defun my/pdf-prefetch-pages-forward ()
  "Return a forward-first look-ahead list of pages around the current page."
  (let ((page (or (pdf-view-current-page) 1))
        (total (pdf-cache-number-of-pages))
        pages)
    (dolist (offset '(1 2 3 4 5 -1))
      (let ((cand (+ page offset)))
        (when (and (>= cand 1) (<= cand total) (not (= cand page)))
          (push cand pages))))
    (nreverse pages)))

(defun my/pdf--prefetch-stop-around (orig-fn)
  "Keep `pdf-cache--prefetch-pages' alive across intra-page scrolling."
  (unless (and (derived-mode-p 'pdf-view-mode)
               (memq this-command my/pdf-scroll-commands))
    (funcall orig-fn)))

(defun my/pdf--cancel-prefetch ()
  "Cancel any pending look-ahead prefetch timer in the current PDF buffer."
  (when (timerp my/pdf--prefetch-timer)
    (cancel-timer my/pdf--prefetch-timer)
    (setq my/pdf--prefetch-timer nil)))

(defun my/pdf--kick-prefetch (buffer window)
  "Refresh BUFFER look-ahead queue in WINDOW and start if `epdfinfo' is idle."
  (when (and (buffer-live-p buffer)
             (window-live-p window)
             (eq (window-buffer window) buffer)
             (eq (selected-window) window))
    (with-current-buffer buffer
      (setq my/pdf--prefetch-timer nil)
      (when (and (bound-and-true-p pdf-cache-prefetch-minor-mode)
                 (derived-mode-p 'pdf-view-mode)
                 (not (bound-and-true-p isearch-mode))
                 (pdf-util-pdf-buffer-p)
                 (fboundp pdf-cache-prefetch-pages-function))
        (require 'tq nil t)
        (let ((pages (funcall pdf-cache-prefetch-pages-function)))
          (setq pdf-cache--prefetch-pages
                (butlast pages (max 0 (- (length pages)
                                         pdf-cache-image-limit)))))
        (when (and (boundp 'pdf-info--queue)
                   (consp pdf-info--queue)
                   (tq-queue-empty pdf-info--queue))
          (pdf-cache--prefetch-pages
           window (car (pdf-view-desired-image-size nil window))))))))

(defun my/pdf--schedule-prefetch (&rest _)
  "Schedule asynchronous look-ahead rendering 150ms after a page flip."
  (when (and (not noninteractive)
             (derived-mode-p 'pdf-view-mode)
             (eq (window-buffer (selected-window)) (current-buffer)))
    (my/pdf--cancel-prefetch)
    (setq my/pdf--prefetch-timer
          (run-with-timer 0.15 nil #'my/pdf--kick-prefetch
                          (current-buffer) (selected-window)))))

(defun my/pdf--sync-window-scaling (&optional win-or-frame)
  "Enable HiDPI scaling only in narrow split panes to avoid 3000px Cairo lag."
  (when (derived-mode-p 'pdf-view-mode)
    (let ((win (cond
                ((window-live-p win-or-frame) win-or-frame)
                ((and (consp win-or-frame) (window-live-p (car win-or-frame)))
                 (car win-or-frame))
                ((eq (window-buffer) (current-buffer)) (selected-window))
                (t (get-buffer-window (current-buffer))))))
      (when (window-live-p win)
        (let ((should-scale (< (window-body-width win t) 1100)))
          (unless (eq pdf-view-use-scaling should-scale)
            (setq-local pdf-view-use-scaling should-scale)))))))

(defun my/pdf--disable-text-minor-modes ()
  "Disable global text wrapping and undo-tree modes in binary PDF buffers."
  (when (derived-mode-p 'pdf-view-mode)
    (when (bound-and-true-p visual-line-mode)
      (visual-line-mode -1))
    (when (bound-and-true-p undo-tree-mode)
      (undo-tree-mode -1))))

(defun my/pdf--getannots-cached-around (orig-fn &optional pages file-or-buffer)
  "Cache single-page `pdf-info-getannots' calls so page flips skip RPC waits."
  (if (and (not pdf-info-asynchronous)
           (integerp pages)
           (derived-mode-p 'pdf-view-mode)
           (or (null file-or-buffer)
               (eq file-or-buffer (current-buffer)))
           (fboundp 'pdf-cache--data-get))
      (let ((hit (pdf-cache--data-get 'getannots pages)))
        (if (car hit)
            (cdr hit)
          (pdf-cache--data-put
           'getannots
           (funcall orig-fn pages file-or-buffer)
           pages)))
    (funcall orig-fn pages file-or-buffer)))

(defun my/pdf--setup-buffer ()
  "Configure smooth scrolling and fast async look-ahead for `pdf-view-mode'."
  (my/pdf--disable-text-minor-modes)
  (setq-local fast-but-imprecise-scrolling t
              redisplay-skip-fontification-on-input t)
  (my/pdf--sync-window-scaling)
  (add-hook 'after-change-major-mode-hook #'my/pdf--disable-text-minor-modes 90 t)
  (add-hook 'window-configuration-change-hook #'my/pdf--sync-window-scaling -50 t)
  (add-hook 'window-size-change-functions #'my/pdf--sync-window-scaling -50 t)
  (add-hook 'image-mode-new-window-functions #'my/pdf--sync-window-scaling -50 t)
  (add-hook 'pdf-view-after-change-page-hook #'my/pdf--schedule-prefetch nil t)
  (add-hook 'kill-buffer-hook #'my/pdf--cancel-prefetch nil t)
  (my/pdf--schedule-prefetch))

(with-eval-after-load 'pdf-cache
  (setq pdf-cache-image-limit 128
        pdf-cache-prefetch-delay 0.15
        pdf-cache-prefetch-pages-function #'my/pdf-prefetch-pages-forward)
  (advice-add 'pdf-cache--prefetch-stop :around #'my/pdf--prefetch-stop-around)
  (advice-add 'pdf-info-getannots :around #'my/pdf--getannots-cached-around))

(with-eval-after-load 'pdf-view
  (require 'pdf-cache nil t)
  (setq pdf-view-resize-factor 1.02
        pdf-view-continuous nil)
  (add-hook 'pdf-view-mode-hook #'my/pdf--setup-buffer 90)
  (define-key pdf-view-mode-map (kbd "d") #'pdf-view-follow-minor-mode))

;;;; Native Mind Mapping (`emacs-minder`)

(when (locate-library "emacs-minder")
  (autoload 'emacs-minder-mode "emacs-minder"
    "Native Cairo/LaTeX Mind Map major mode." t)
  (autoload 'emacs-minder-new "emacs-minder"
    "Create a fresh Mind Map buffer." t)
  (autoload 'emacs-minder-open-org "emacs-minder"
    "Open the current Org file as a native Mind Map." t)
  (autoload 'emacs-minder-paste-clipboard-latex "emacs-minder"
    "Recognize a clipboard formula image to LaTeX via formulaocr-offline." t)
  (autoload 'emacs-minder-formula-ocr-warmup "emacs-minder"
    "Start and warm up the persistent formulaocr-offline worker." t)
  (add-to-list 'auto-mode-alist '("\\.minder\\'" . emacs-minder-mode))
  (global-set-key (kbd "C-c M") #'emacs-minder-new)
  (with-eval-after-load 'org
    (define-key org-mode-map (kbd "C-c m") #'emacs-minder-open-org)
    (define-key org-mode-map (kbd "C-c M-v") #'emacs-minder-paste-clipboard-latex)))

(provide 'init-documents)
;;; init-documents.el ends here
