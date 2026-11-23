;;; org-scimax-latex.el --- Scientific LaTeX preview, numbering & export -*- lexical-binding: t; -*-

;;; Commentary:
;; Standalone integration of scimax-org-latex (tooltips, justification,
;; equation renumbering, pre/post LaTeX body injection, scientific default
;; packages, minted listings) paired with buffer-background baking into SVG
;; preview overlays and text-scale resizing.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'ox-latex)
(require 'ov)
(require 's)

(when (executable-find "dvisvgm")
  (setq org-preview-latex-default-process 'dvisvgm))

(with-eval-after-load 'org
  (when-let* ((entry (assq 'dvisvgm org-preview-latex-process-alist)))
    (plist-put (cdr entry) :image-size-adjust '(1.0 . 1.0))
    (plist-put (cdr entry) :image-converter
               '("dvisvgm %f --no-fonts --exact-bbox --currentcolor --scale=%S --output=%O"))))

(setq org-format-latex-options
      (let ((opts (copy-sequence org-format-latex-options)))
        (setq opts (plist-put opts :scale 2.0))
        (setq opts (plist-put opts :foreground "Black"))
        (setq opts (plist-put opts :background "Transparent"))
        opts)
      org-highlight-latex-and-related '(latex script entities)
      org-export-with-sub-superscripts '{}
      org-latex-hyperref-template nil
      org-latex-listings 'minted
      org-latex-minted-options '(("frame" "lines")
                                 ("fontsize" "\\scriptsize")
                                 ("linenos" ""))
      org-latex-title-command ""
      org-latex-prefer-user-labels t)

(when (facep 'org-latex-and-related)
  (set-face-attribute 'org-latex-and-related nil :background 'unspecified))

(setq org-latex-default-packages-alist
      '(("AUTO" "inputenc" t)
        ("" "lmodern" nil)
        ("T1" "fontenc" t)
        ("top=1in, bottom=1.in, left=1in, right=1in" "geometry" nil)
        ("" "graphicx" t)
        ("" "longtable" nil)
        ("" "float" nil)
        ("" "wrapfig" nil)
        ("" "rotating" nil)
        ("normalem" "ulem" t)
        ("" "amsmath" t)
        ("" "textcomp" t)
        ("" "marvosym" t)
        ("" "wasysym" t)
        ("" "amssymb" t)
        ("theorems, skins" "tcolorbox" t)
        ("version=3" "mhchem" t)
        ("numbers,super,sort&compress" "natbib" nil)
        ("" "natmove" nil)
        ("" "url" nil)
        ("cache=false" "minted" nil)
        ("strings" "underscore" nil)
        ("linktocpage,pdfstartview=FitH,colorlinks,linkcolor=blue,anchorcolor=blue,citecolor=blue,filecolor=blue,menucolor=blue,urlcolor=blue"
         "hyperref" nil)
        ("" "attachfile" nil)
        ("" "setspace" nil)))

(add-to-list 'org-latex-classes
             '("article-1"
               "\\documentclass{article}
\\usepackage[top=1in, bottom=1.in, left=1in, right=1in]{geometry}
 [PACKAGES]
 [EXTRA]"
               ("\\section{%s}" . "\\section*{%s}")
               ("\\subsection{%s}" . "\\subsection*{%s}")
               ("\\subsubsection{%s}" . "\\subsubsection*{%s}")
               ("\\paragraph{%s}" . "\\paragraph*{%s}")
               ("\\subparagraph{%s}" . "\\subparagraph*{%s}")))

(add-to-list 'org-latex-classes
             '("article-no-defaults"
               "\\documentclass{article}
 [NO-DEFAULT-PACKAGES]
 [PACKAGES]
 [EXTRA]"
               ("\\section{%s}" . "\\section*{%s}")
               ("\\subsection{%s}" . "\\subsection*{%s}")
               ("\\subsubsection{%s}" . "\\subsubsection*{%s}")
               ("\\paragraph{%s}" . "\\paragraph*{%s}")
               ("\\subparagraph{%s}" . "\\subparagraph*{%s}")))

;; Fragment hover tooltip & click-to-toggle
(defun scimax-org-latex-fragment-tooltip (beg end _image _imagetype)
  "Attach source tooltip and click-to-toggle keymap on fragment overlay at BEG..END."
  (when-let* ((ov (ov-at)))
    (overlay-put ov 'help-echo (concat (buffer-substring-no-properties beg end)
                                       "\nmouse-1 to toggle."))
    (overlay-put ov 'local-map
                 (let ((map (make-sparse-keymap)))
                   (define-key map (kbd "C-c C-x C-l") #'org-latex-preview)
                   (define-key map [mouse-1]
                     (lambda ()
                       (interactive)
                       (org-clear-latex-preview beg end)))
                   map))))

(defun scimax-toggle-org-latex-fragment-tooltip ()
  "Toggle hover tooltips on Org LaTeX preview fragments."
  (interactive)
  (if (not (get 'scimax-org-latex-fragment-tooltip 'enabled))
      (progn
        (advice-add 'org--make-preview-overlay :after #'scimax-org-latex-fragment-tooltip)
        (put 'scimax-org-latex-fragment-tooltip 'enabled t)
        (message "LaTeX fragment tooltips enabled"))
    (advice-remove 'org--make-preview-overlay #'scimax-org-latex-fragment-tooltip)
    (put 'scimax-org-latex-fragment-tooltip 'enabled nil)
    (message "LaTeX fragment tooltips disabled")))

;; Fragment justification (left / center / right)
(defun scimax-org-latex-fragment-justify (justification)
  "Justify the LaTeX preview overlay at point according to JUSTIFICATION."
  (interactive
   (list (intern (completing-read "Justification: " '("left" "center" "right") nil t nil nil "left"))))
  (when-let* ((ov (ov-at))
              (beg (ov-beg ov))
              (end (ov-end ov))
              (img (overlay-get ov 'display)))
    (let ((valid-img (and (consp img) (eq (car img) 'image)
                          (image-type-available-p (plist-get (cdr img) :type))
                          img))
          (shift (- beg (line-beginning-position))))
      (when (and valid-img
                 (= beg (line-beginning-position))
                 (or (string= "" (s-trim (buffer-substring-no-properties end (line-end-position))))
                     (eq 'latex-environment (car (org-element-context)))))
        (let* ((space-left (- (window-max-chars-per-line) (car (image-size valid-img))))
               (offset (floor (pcase justification
                                ('center (- (/ space-left 2.0) shift))
                                ('right (- space-left shift))
                                (_ 0)))))
          (when (>= offset 0)
            (overlay-put ov 'before-string (make-string offset ?\ ))))))))

(defun scimax-org-latex-fragment-justify-advice (_beg _end _image _imagetype)
  "Apply configured `:justify' alignment after preview overlay creation."
  (scimax-org-latex-fragment-justify (or (plist-get org-format-latex-options :justify) 'left)))

(defun scimax-toggle-latex-fragment-justification ()
  "Toggle automatic justification for Org LaTeX fragment overlays."
  (interactive)
  (if (not (get 'scimax-org-latex-fragment-justify-advice 'enabled))
      (progn
        (advice-add 'org--make-preview-overlay :after #'scimax-org-latex-fragment-justify-advice)
        (put 'scimax-org-latex-fragment-justify-advice 'enabled t)
        (message "LaTeX fragment justification enabled"))
    (advice-remove 'org--make-preview-overlay #'scimax-org-latex-fragment-justify-advice)
    (put 'scimax-org-latex-fragment-justify-advice 'enabled nil)
    (message "LaTeX fragment justification disabled")))

;; Automatic equation numbering across fragments
(defun scimax-org-renumber-environment (orig-func &rest args)
  "Inject accurate equation numbers when rendering LaTeX preview fragments."
  (let ((counter -1)
        (results nil))
    (setq results
          (cl-loop for (begin . env) in
                   (org-element-map (org-element-parse-buffer) 'latex-environment
                     (lambda (el)
                       (cons (org-element-property :begin el)
                             (org-element-property :value el))))
                   collect
                   (cond
                    ((and (string-match-p "\\\\begin{equation}" env)
                          (not (string-match-p "\\\\tag{" env)))
                     (cl-incf counter)
                     (cons begin counter))
                    ((string-match-p "\\\\begin{align}" env)
                     (prog2
                         (cl-incf counter)
                         (cons begin counter)
                       (with-temp-buffer
                         (insert env)
                         (goto-char (point-min))
                         (cl-incf counter (count-matches "\\\\$"))
                         (goto-char (point-min))
                         (cl-decf counter (count-matches "\\nonumber")))))
                    (t (cons begin nil)))))
    (when-let* ((numberp (cdr (assoc (point) results))))
      (setf (car args)
            (concat (format "\\setcounter{equation}{%s}\n" numberp)
                    (car args)))))
  (apply orig-func args))

(defun scimax-toggle-latex-equation-numbering ()
  "Toggle sequential equation numbering in Org LaTeX fragment previews."
  (interactive)
  (if (not (get 'scimax-org-renumber-environment 'enabled))
      (progn
        (advice-add 'org-create-formula-image :around #'scimax-org-renumber-environment)
        (put 'scimax-org-renumber-environment 'enabled t)
        (message "LaTeX equation numbering enabled"))
    (advice-remove 'org-create-formula-image #'scimax-org-renumber-environment)
    (put 'scimax-org-renumber-environment 'enabled nil)
    (message "LaTeX equation numbering disabled")))

;; Pre/post LaTeX fragment body injection
(defun scimax-org-inject-latex-fragment (orig-func &rest args)
  "Inject `:latex-fragment-pre-body' and `:latex-fragment-post-body' into fragments."
  (setf (car args)
        (concat (or (plist-get org-format-latex-options :latex-fragment-pre-body) "")
                (car args)
                (or (plist-get org-format-latex-options :latex-fragment-post-body) "")))
  (apply orig-func args))

(defun scimax-toggle-inject-latex ()
  "Toggle pre/post LaTeX fragment body injection."
  (interactive)
  (if (not (get 'scimax-org-inject-latex-fragment 'enabled))
      (progn
        (advice-add 'org-create-formula-image :around #'scimax-org-inject-latex-fragment)
        (put 'scimax-org-inject-latex-fragment 'enabled t)
        (message "Inject LaTeX enabled"))
    (advice-remove 'org-create-formula-image #'scimax-org-inject-latex-fragment)
    (put 'scimax-org-inject-latex-fragment 'enabled nil)
    (message "Inject LaTeX disabled")))

;; Transparent `currentColor' SVG previews: refresh image cache on theme switches
(defun my/org-refresh-svg-previews-on-theme-change (&rest _)
  "Clear image cache and redraw so `currentColor' SVGs follow the active theme."
  (when (display-graphic-p)
    (when (fboundp 'clear-image-cache)
      (clear-image-cache))
    (redraw-display)))

(advice-add 'load-theme :after #'my/org-refresh-svg-previews-on-theme-change)
(advice-add 'enable-theme :after #'my/org-refresh-svg-previews-on-theme-change)

;; Optional inline `.svg' white-canvas neutralization via Emacs 31 SVG `:css'
(defcustom my/org-svg-strip-white-background t
  "When non-nil, neutralize opaque white `<rect>' backdrops in inline Org SVGs."
  :type 'boolean
  :group 'org-latex)

(defconst my/org-inline-svg-transparent-css
  "rect[fill='#ffffff'], rect[fill='#FFFFFF'], rect[fill='#fff'], rect[fill='#FFF'], rect[fill='white'], rect[fill='rgb(100%,100%,100%)'], rect[fill='rgb(255,255,255)'] { fill: transparent !important; }"
  "CSS injected into inline Org SVG image descriptors to strip white backdrops.")

(defun my/org-inline-svg-transparent-bg (img)
  "Inject transparent-backdrop CSS into SVG image descriptors returned by `org--create-inline-image'."
  (if (and my/org-svg-strip-white-background
           (consp img)
           (eq (car img) 'image))
      (let* ((props (cdr img))
             (type (plist-get props :type))
             (file (plist-get props :file)))
        (if (and (or (eq type 'svg)
                     (and (stringp file)
                          (string-match-p "\\.svgz?\\'" file)))
                 (not (plist-get props :css)))
            (cons 'image
                  (plist-put (copy-sequence props) :css my/org-inline-svg-transparent-css))
          img))
    img))

(with-eval-after-load 'org
  (advice-add 'org--create-inline-image :filter-return #'my/org-inline-svg-transparent-bg))

;; Scale LaTeX fragments proportionally with buffer text-scale
(defun my/text-scale--resize-fragment (ov)
  "Scale LaTeX preview overlay OV proportionally to `text-scale-mode-amount'."
  (let ((display (overlay-get ov 'display))
        (amount (if (boundp 'text-scale-mode-amount) text-scale-mode-amount 0)))
    (when (eq (car-safe display) 'image)
      (overlay-put ov 'display
                   (cons 'image
                         (plist-put (copy-sequence (cdr display))
                                    :scale (max 0.1 (+ 1.0 (* 0.15 amount)))))))))

(defun my/text-scale-adjust-latex-previews ()
  "Resize LaTeX preview fragments when buffer text scale changes."
  (pcase major-mode
    ('latex-mode
     (dolist (ov (overlays-in (point-min) (point-max)))
       (when (eq (overlay-get ov 'category) 'preview-overlay)
         (my/text-scale--resize-fragment ov))))
    ('org-mode
     (dolist (ov (overlays-in (point-min) (point-max)))
       (when (eq (overlay-get ov 'org-overlay-type) 'org-latex-overlay)
         (my/text-scale--resize-fragment ov))))))

(add-hook 'text-scale-mode-hook #'my/text-scale-adjust-latex-previews)
(with-eval-after-load 'org-fragtog
  (advice-add 'org-fragtog--post-cmd :after #'my/text-scale-adjust-latex-previews))
(when (require 'org-fragtog nil t)
  (add-hook 'org-mode-hook #'org-fragtog-mode))

;; Enable scimax LaTeX enhancements cleanly
(scimax-toggle-org-latex-fragment-tooltip)
(scimax-toggle-latex-fragment-justification)
(scimax-toggle-latex-equation-numbering)
(scimax-toggle-inject-latex)

(provide 'org-scimax-latex)
;;; org-scimax-latex.el ends here
