;;; org-scimax-markup.el --- Standalone Org markup, entities, and helpers -*- lexical-binding: t; -*-

;;; Commentary:
;; Cherry-picked Org authoring helpers from scimax without Ivy dependencies:
;; smart `s-*' markup commands, completing-read Org entity insertion,
;; result table alignment, avy headline jump, and footnote hover tooltips.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-inlinetask)
(require 'org-id)
(require 'org-mouse)
(require 'avy)
(require 's)

;; Core editing / behavior defaults ported cleanly from scimax-org
(setq org-catch-invisible-edits 'smart
      org-list-allow-alphabetical t
      org-archive-location "archive/%s_archive::"
      org-use-speed-commands t
      org-id-link-to-org-use-id 'create-if-interactive
      org-link-search-must-match-exact-headline 'query-to-create
      org-log-done 'time
      org-startup-with-inline-images t
      org-image-actual-width nil
      org-todo-keywords '((sequence "TODO(t)" "|" "DONE(d)")))

(add-hook 'org-babel-after-execute-hook #'org-display-inline-images)

(defun scimax-align-result-table ()
  "Align Org tables in the current subtree after babel execution."
  (save-restriction
    (save-excursion
      (unless (org-before-first-heading-p)
        (org-narrow-to-subtree))
      (org-element-map (org-element-parse-buffer) 'table
        (lambda (tbl)
          (goto-char (org-element-property :post-affiliated tbl))
          (org-table-align))))))

(add-hook 'org-babel-after-execute-hook #'scimax-align-result-table)

;; Heading helpers & speed commands
(defun scimax-org-headline-to-inlinetask ()
  "Convert the Org heading at point to an inlinetask."
  (interactive)
  (let* ((hl (org-element-context))
         (c-beg (org-element-property :contents-begin hl))
         (c-end (org-element-property :contents-end hl))
         (body (if (and c-beg c-end)
                   (buffer-substring-no-properties c-beg c-end)
                 ""))
         (title (or (org-element-property :title hl) ""))
         (tags (or (nth 5 (org-heading-components)) ""))
         (beg (org-element-property :begin hl))
         (end (org-element-property :end hl))
         (inlinetask (with-temp-buffer
                       (org-mode)
                       (org-inlinetask-insert-task)
                       (insert (format "%s  %s\n%s" title tags body))
                       (concat (buffer-string) "\n\n"))))
    (delete-region beg end)
    (goto-char beg)
    (insert inlinetask)))

(defun scimax-org-kill-subtree ()
  "Kill current Org subtree."
  (interactive)
  (org-mark-subtree)
  (kill-region (region-beginning) (region-end)))

(defun scimax-avy-org-headline ()
  "Jump to a visible Org heading using `avy'."
  (interactive)
  (avy-with avy-goto-line
    (avy-jump org-heading-regexp)))

(defun avy-org-jump-to-visible-headline ()
  "Push `org-mark-ring' and jump to a visible headline in the buffer."
  (interactive)
  (org-mark-ring-push)
  (avy-with avy-goto-line
    (avy-jump org-heading-regexp nil)))

(setq org-speed-commands
      (append org-speed-commands
              '(("P" . org-set-property)
                ("d" . org-deadline)
                ("m" . org-mark-subtree)
                ("S" . widen)
                ("k" . scimax-org-kill-subtree)
                ("K" . scimax-org-headline-to-inlinetask)
                ("q" . scimax-avy-org-headline))))

;; Smart markup commands
(defun org-markup-region-or-point (type beginning-marker end-marker)
  "Apply markup TYPE with BEGINNING-MARKER and END-MARKER to region, word, or point."
  (cond
   ((region-active-p)
    (let* ((start (min (region-beginning) (region-end)))
           (end (max (region-beginning) (region-end)))
           (lines))
      (unless (memq type '(subscript superscript))
        (save-excursion
          (goto-char start)
          (unless (looking-at " \\|\\<")
            (backward-word)
            (setq start (point)))
          (goto-char end)
          (unless (or (looking-at " \\|\\>")
                      (looking-back "\\>" 1))
            (forward-word)
            (setq end (point)))))
      (setq lines
            (s-join "\n"
                    (mapcar
                     (lambda (line)
                       (if (not (string= (s-trim line) ""))
                           (concat beginning-marker (s-trim line) end-marker)
                         line))
                     (split-string (buffer-substring start end) "\n"))))
      (delete-region start end)
      (goto-char start)
      (insert lines)))
   ((thing-at-point 'word)
    (cond
     ((looking-back " " 1)
      (insert beginning-marker)
      (re-search-forward "\\>")
      (insert end-marker))
     ((looking-back "\\>" 1)
      (insert beginning-marker end-marker)
      (backward-char (length end-marker)))
     ((and (memq type '(subscript superscript))
           (looking-back (regexp-quote end-marker) (length end-marker)))
      (delete-char (- (length end-marker)))
      (forward-char)
      (insert end-marker))
     ((memq type '(subscript superscript))
      (insert beginning-marker)
      (forward-char (1- (length beginning-marker)))
      (insert end-marker))
     (t
      (re-search-backward "\\<")
      (insert beginning-marker)
      (re-search-forward "\\>")
      (insert end-marker))))
   ((looking-back (regexp-quote end-marker) (length end-marker))
    (delete-char (- (length end-marker)))
    (forward-word)
    (insert end-marker))
   (t
    (insert beginning-marker end-marker)
    (backward-char (length end-marker)))))

(defun org-double-quote-region-or-point ()
  "Double quote the region, word, or point."
  (interactive)
  (org-markup-region-or-point 'italics "\"" "\""))

(defun org-single-quote-region-or-point ()
  "Single quote the region, word, or point."
  (interactive)
  (org-markup-region-or-point 'italics "'" "'"))

(defun org-italics-region-or-point ()
  "Italicize the region, word, or point."
  (interactive)
  (org-markup-region-or-point 'italics "/" "/"))

(defun org-bold-region-or-point ()
  "Bold the region, word, or point."
  (interactive)
  (org-markup-region-or-point 'bold "*" "*"))

(defun org-underline-region-or-point ()
  "Underline the region, word, or point."
  (interactive)
  (org-markup-region-or-point 'underline "_" "_"))

(defun org-code-region-or-point ()
  "Mark the region, word, or point as Org code (~...~)."
  (interactive)
  (org-markup-region-or-point 'underline "~" "~"))

(defun org-verbatim-region-or-point ()
  "Mark the region, word, or point as Org verbatim (=...=)."
  (interactive)
  (org-markup-region-or-point 'underline "=" "="))

(defun org-strikethrough-region-or-point ()
  "Mark the region, word, or point as strikethrough (+...+)."
  (interactive)
  (org-markup-region-or-point 'strikethrough "+" "+"))

(defun org-subscript-region-or-point ()
  "Mark the region, word, or point as a subscript (_{...})."
  (interactive)
  (org-markup-region-or-point 'subscript "_{" "}"))

(defun org-superscript-region-or-point ()
  "Mark the region, word, or point as a superscript (^{...})."
  (interactive)
  (org-markup-region-or-point 'superscript "^{" "}"))

(defun org-latex-math-region-or-point (&optional arg)
  "Wrap region/word in LaTeX math markup (`\\(\\)', `$$' with ARG, `@@latex:@@' with double prefix)."
  (interactive "P")
  (if (memq 'org-latex-and-related (ensure-list (get-char-property (point) 'face)))
      (goto-char (or (next-single-property-change (point) 'face) (line-end-position)))
    (let ((chars (cond
                  ((null arg) '("\\(" . "\\)"))
                  ((equal arg '(4)) '("$" . "$"))
                  ((equal arg '(16)) '("@@latex:" . "@@"))
                  (t '("\\(" . "\\)")))))
      (cond
       ((region-active-p)
        (let ((beg (region-beginning))
              (end (region-end)))
          (goto-char end)
          (insert (cdr chars))
          (goto-char beg)
          (insert (car chars))))
       ((thing-at-point 'word)
        (save-excursion
          (end-of-thing 'word)
          (insert (cdr chars)))
        (save-excursion
          (beginning-of-thing 'word)
          (insert (car chars)))
        (forward-char (length (car chars))))
       ((and (not (equal arg '(16)))
             (looking-back (regexp-quote (cdr chars)) (length (cdr chars))))
        (delete-char (- (length (cdr chars))))
        (forward-word)
        (insert (cdr chars)))
       (t
        (insert (car chars) (cdr chars))
        (backward-char (length (cdr chars))))))))

(defun my/insert-org-entity (&optional utf8-p)
  "Insert an Org entity via `completing-read'.
With prefix arg UTF8-P, insert the UTF-8 character instead of the LaTeX/Org name."
  (interactive "P")
  (let* ((candidates
          (cl-loop for el in (append org-entities org-entities-user)
                   when (and (listp el) (stringp (car el)))
                   collect (cons (format "%-18s | %-6s | %s"
                                         (nth 0 el) (or (nth 6 el) "") (or (nth 1 el) ""))
                                 el)))
         (choice (completing-read "Org Entity: " candidates nil t))
         (el (cdr (assoc choice candidates))))
    (when el
      (insert (if utf8-p (or (nth 6 el) (nth 1 el)) (concat "\\" (nth 0 el)))))))

(defalias 'ivy-insert-org-entity #'my/insert-org-entity)

;; Keybindings in org-mode-map
(dolist (pair '(("s--" . org-subscript-region-or-point)
                ("s-=" . org-superscript-region-or-point)
                ("s-i" . org-italics-region-or-point)
                ("s-b" . org-bold-region-or-point)
                ("s-v" . org-verbatim-region-or-point)
                ("s-c" . org-code-region-or-point)
                ("s-u" . org-underline-region-or-point)
                ("s-+" . org-strikethrough-region-or-point)
                ("s-4" . org-latex-math-region-or-point)
                ("s-e" . my/insert-org-entity)
                ("s-\"" . org-double-quote-region-or-point)
                ("s-'" . org-single-quote-region-or-point)))
  (define-key org-mode-map (kbd (car pair)) (cdr pair)))

;; Manpage org links
(defun org-man-store-link ()
  "Store an Org link to the current Man buffer."
  (when (memq major-mode '(Man-mode woman-mode))
    (let ((page (save-excursion
                  (goto-char (point-min))
                  (when (re-search-forward " " nil t)
                    (buffer-substring (point-min) (1- (point)))))))
      (when page
        (org-link-store-props
         :type "man"
         :link (concat "man:" page)
         :description (format "Manpage for %s" page))))))

(org-link-set-parameters
 "man"
 :follow (lambda (path) (man path))
 :store #'org-man-store-link)

;; Tooltip on Org footnotes
(defun scimax-footnote-reference-tooltip (_win _obj position)
  "Return footnote definition text for tooltip at POSITION."
  (save-excursion
    (goto-char position)
    (or (nth 3 (org-footnote-get-definition
                (org-element-property :label (org-element-context))))
        "No footnote content found.")))

(defun scimax-footnote-tooltip (limit)
  "Add tooltip text properties for Org footnotes up to LIMIT."
  (let ((fn (org-footnote-next-reference-or-definition limit)))
    (when fn
      (let* ((beg (nth 1 fn))
             (end (nth 2 fn))
             (label (car fn))
             (referencep (/= (line-beginning-position) beg)))
        (when (and referencep (nth 3 fn))
          (save-excursion
            (goto-char beg)
            (when (search-forward (or label "fn:") end t)
              (org-remove-flyspell-overlays-in beg (match-end 0)))))
        (add-text-properties
         beg end
         (list 'mouse-face 'highlight
               'keymap org-mouse-map
               'help-echo (if referencep
                              #'scimax-footnote-reference-tooltip
                            "Footnote definition")
               'font-lock-fontified t
               'font-lock-multiline t
               'face 'org-footnote))))))

(advice-add 'org-activate-footnote-links :override #'scimax-footnote-tooltip)

(provide 'org-scimax-markup)
;;; org-scimax-markup.el ends here
