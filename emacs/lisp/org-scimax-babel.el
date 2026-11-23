;;; org-scimax-babel.el --- Jupyter-like Org-Babel cell commands & hydra -*- lexical-binding: t; -*-

;;; Commentary:
;; Standalone port of scimax-ob replacing `ivy-read' with `completing-read',
;; fixing block-jump names & `scimax-ob-merge-blocks', and keeping `RET' in src
;; blocks free for `my/org-src-return-mode'.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'ob-core)
(require 's)
(require 'dash)
(require 'avy)
(require 'hydra)

(defun scimax-ob-insert-src-block (&optional below)
  "Insert a src block above point, or BELOW with prefix arg.
Inside an existing src block, copies its language and header arguments."
  (interactive "P")
  (if (org-in-src-block-p)
      (let* ((src (org-element-context))
             (start (org-element-property :begin src))
             (end (org-element-property :end src))
             (lang (org-element-property :language src))
             (switches (or (org-element-property :switches src) ""))
             (parameters (or (org-element-property :parameters src) ""))
             (header (string-trim (format "%s %s %s" lang switches parameters))))
        (if below
            (let ((location (progn
                              (goto-char start)
                              (org-babel-where-is-src-block-result nil nil))))
              (if (not location)
                  (goto-char end)
                (goto-char location)
                (goto-char (org-element-property :end (org-element-context))))
              (insert (format "\n#+BEGIN_SRC %s\n\n#+END_SRC\n\n" header))
              (forward-line -3))
          (goto-char start)
          (insert (format "\n#+BEGIN_SRC %s\n\n#+END_SRC\n\n" header))
          (forward-line -3)))
    (beginning-of-line)
    (insert (format "\n#+BEGIN_SRC %s\n\n#+END_SRC\n"
                    (completing-read "Language: "
                                     (mapcar (lambda (p) (symbol-name (car p)))
                                             org-babel-load-languages))))
    (forward-line -1)))

(defun scimax-ob-split-src-block (&optional below)
  "Split current src block at point, leaving point in upper cell (or lower with BELOW)."
  (interactive "P")
  (let* ((el (org-element-context))
         (language (org-element-property :language el))
         (switches (or (org-element-property :switches el) ""))
         (parameters (or (org-element-property :parameters el) ""))
         (header (string-trim (format "%s %s %s" language switches parameters))))
    (beginning-of-line)
    (insert (format "#+END_SRC\n\n#+BEGIN_SRC %s\n" header))
    (unless below
      (beginning-of-line)
      (forward-line -3)
      (end-of-line))))

(defun scimax-ob-edit-up ()
  "Move up a line, or jump to the previous same-language block when at top."
  (interactive)
  (let ((first-code-line-p (save-excursion
                             (forward-line -1)
                             (beginning-of-line)
                             (looking-at-p "^[ \t]*#\\+BEGIN_SRC")))
        (lang (org-element-property :language (org-element-context))))
    (cond
     ((and (bolp) first-code-line-p)
      (ignore-errors
        (catch 'block
          (while (org-babel-previous-src-block)
            (when (string= lang (org-element-property :language (org-element-context)))
              (throw 'block t))))))
     (first-code-line-p
      (beginning-of-line))
     (t
      (forward-line -1)))))

(defun scimax-ob-edit-down ()
  "Move down a line, or jump to the next same-language block when at bottom."
  (interactive)
  (let ((last-code-line-p (save-excursion
                            (forward-line 1)
                            (beginning-of-line)
                            (looking-at-p "^[ \t]*#\\+END_SRC")))
        (lang (org-element-property :language (org-element-context))))
    (cond
     ((and (eolp) last-code-line-p)
      (ignore-errors
        (catch 'block
          (while (org-babel-next-src-block)
            (when (string= lang (org-element-property :language (org-element-context)))
              (throw 'block t))))))
     (last-code-line-p
      (end-of-line))
     (t
      (forward-line 1)))))

(defun scimax-ob-execute-and-next-block (&optional new)
  "Execute current block and jump to next same-language block, or insert one with NEW."
  (interactive "P")
  (org-babel-execute-src-block)
  (let* ((lang (car (org-babel-get-src-block-info t)))
         (next-block (ignore-errors
                       (save-excursion
                         (catch 'block
                           (while (org-babel-next-src-block)
                             (when (string= lang (org-element-property :language (org-element-context)))
                               (throw 'block (point)))))))))
    (if (or new (not next-block))
        (scimax-ob-insert-src-block t)
      (goto-char next-block))))

(defun scimax-ob-execute-to-point ()
  "Execute all src blocks starting before point."
  (interactive)
  (let ((p (point)))
    (save-excursion
      (goto-char (point-min))
      (while (and (ignore-errors (org-babel-next-src-block)) (< (point) p))
        (org-babel-execute-src-block)))))

(defun scimax-ob-jump-to-visible-src-block ()
  "Jump to a visible src block using `avy'."
  (interactive)
  (org-mark-ring-push)
  (avy-with scimax-ob-jump-to-visible-src-block
    (avy-jump "#\\+BEGIN_SRC" :window-flip nil :beg (point-min) :end (point-max))))

(defun scimax-ob-jump-to-src-block (&optional n)
  "Jump to an Org src block via `completing-read' showing N context lines."
  (interactive "p")
  (when (= 1 n) (setq n 3))
  (let ((choices '()))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward org-babel-src-block-regexp nil t)
        (let* ((beg (match-beginning 0))
               (lnum (line-number-at-pos beg))
               (preview (save-excursion
                          (goto-char beg)
                          (forward-line n)
                          (replace-regexp-in-string
                           "\n+" " | "
                           (string-trim (buffer-substring-no-properties beg (point)))))))
          (push (cons (format "line %d: %s" lnum preview) lnum) choices))))
    (when choices
      (let* ((picked (completing-read "Src block: " (nreverse choices) nil t))
             (lnum (cdr (assoc picked choices))))
        (when lnum
          (org-mark-ring-push)
          (goto-char (point-min))
          (forward-line (1- lnum))
          (org-fold-show-entry)
          (recenter))))))

(defun scimax-ob-jump-to-inline-src ()
  "Jump to an inline src element in the buffer via `completing-read'."
  (interactive)
  (let ((choices
         (org-element-map (org-element-parse-buffer) 'inline-src-block
           (lambda (isrc)
             (cons (format "line %d: %s"
                           (line-number-at-pos (org-element-property :begin isrc))
                           (buffer-substring-no-properties
                            (org-element-property :begin isrc)
                            (org-element-property :end isrc)))
                   (org-element-property :begin isrc))))))
    (when choices
      (let* ((picked (completing-read "Inline src: " choices nil t))
             (pos (cdr (assoc picked choices))))
        (when pos
          (org-mark-ring-push)
          (goto-char pos)
          (recenter))))))

(defun scimax-ob-jump-to-header ()
  "Jump to current src block header."
  (interactive)
  (org-mark-ring-push)
  (let ((src-info (org-babel-get-src-block-info 'light)))
    (goto-char (nth 5 src-info))))

(defun scimax-ob-jump-to-first-line ()
  "Move point to first line of current src block body."
  (interactive)
  (org-mark-ring-push)
  (org-edit-special)
  (goto-char (point-min))
  (org-edit-src-exit))

(defun scimax-ob-jump-to-end-line ()
  "Move point to end of last line in current src block body."
  (interactive)
  (org-mark-ring-push)
  (org-edit-special)
  (goto-char (point-max))
  (org-edit-src-exit))

(defun scimax-ob-jump-to-end ()
  "Jump to the end line of current src block."
  (interactive)
  (org-mark-ring-push)
  (let* ((src (org-element-context))
         (nlines (or (org-element-property :post-blank src) 0)))
    (goto-char (org-element-property :end src))
    (forward-line (- (1+ nlines)))
    (goto-char (line-end-position))))

(defun scimax-ob-kill-block-and-results ()
  "Kill the src block and its results."
  (interactive)
  (let* ((src (org-element-context))
         (result-start (org-babel-where-is-src-block-result))
         (end (if result-start
                  (save-excursion
                    (goto-char result-start)
                    (org-babel-result-end))
                (org-element-property :end src))))
    (kill-region (org-element-property :begin src) end)))

(defun scimax-ob-copy-block-and-results ()
  "Copy the src block and its results."
  (interactive)
  (let* ((src (org-element-context))
         (result-start (org-babel-where-is-src-block-result))
         (end (if result-start
                  (save-excursion
                    (goto-char result-start)
                    (org-babel-result-end))
                (org-element-property :end src))))
    (kill-new (buffer-substring-no-properties (org-element-property :begin src) end))))

(defun scimax-ob-clone-block (&optional below)
  "Clone the current src block (above, or BELOW with prefix arg)."
  (interactive "P")
  (let* ((src (org-element-context))
         (code (org-element-property :value src)))
    (scimax-ob-insert-src-block (not below))
    (insert code)
    (org-babel-previous-src-block)
    (org-babel-next-src-block)))

(defun scimax-ob-move-src-block-up ()
  "Move src block before previous one."
  (interactive)
  (let ((src (org-element-context)))
    (kill-region (org-element-property :begin src)
                 (org-element-property :end src)))
  (org-babel-previous-src-block)
  (org-yank))

(defun scimax-ob-move-src-block-down ()
  "Move src block after next one."
  (interactive)
  (let ((src (org-element-context)))
    (kill-region (org-element-property :begin src)
                 (org-element-property :end src)))
  (org-babel-next-src-block)
  (goto-char (org-element-property :end (org-element-context)))
  (forward-line 1)
  (org-yank))

(defun scimax-ob-merge-blocks (beg end)
  "Merge all Org src blocks falling between BEG and END into one block."
  (interactive "r")
  (let* ((start (min beg end))
         (stop (max beg end))
         (blocks
          (org-element-map (org-element-parse-buffer) 'src-block
            (lambda (blk)
              (let ((b (org-element-property :begin blk))
                    (e (org-element-property :end blk)))
                (when (and (<= b stop) (>= e start))
                  blk))))))
    (when (>= (length blocks) 2)
      (let* ((first (car blocks))
             (last-blk (car (last blocks)))
             (lang (org-element-property :language first))
             (switches (or (org-element-property :switches first) ""))
             (parameters (or (org-element-property :parameters first) ""))
             (header (string-trim (format "%s %s %s" lang switches parameters)))
             (body (mapconcat (lambda (b) (string-trim-right (or (org-element-property :value b) "")))
                              blocks "\n"))
             (ins-beg (org-element-property :begin first))
             (ins-end (org-element-property :end last-blk)))
        (delete-region ins-beg ins-end)
        (goto-char ins-beg)
        (insert (format "#+BEGIN_SRC %s\n%s\n#+END_SRC\n\n" header body))))))

(defun scimax-ob-merge-previous ()
  "Merge current src block with the previous same-language block."
  (interactive)
  (let ((p (point))
        (lang (org-element-property :language (org-element-context))))
    (org-babel-previous-src-block)
    (when (string= lang (org-element-property :language (org-element-context)))
      (scimax-ob-merge-blocks (point) p))))

(defun scimax-ob-merge-next ()
  "Merge current src block with the next same-language block."
  (interactive)
  (let ((p (point))
        (lang (org-element-property :language (org-element-context))))
    (org-babel-next-src-block)
    (when (string= lang (org-element-property :language (org-element-context)))
      (scimax-ob-merge-blocks p (point)))))

(defun scimax-ob-get-param (param)
  "Get PARAM value from current src block header."
  (unless (keywordp param)
    (error "%s should be a :keyword" param))
  (setq param (intern (substring (symbol-name param) 1)))
  (when (org-in-src-block-p)
    (save-excursion
      (goto-char (org-babel-where-is-src-block-head))
      (let ((header-line (thing-at-point 'line t))
            (case-fold-search t))
        (when (string-match "^\\([ \t]*#\\+begin_src[ \t]+\\([^ \t\n]+\\)\\)\\(.*\\)$" header-line)
          (let ((params (org-babel-parse-header-arguments (match-string 3 header-line))))
            (or (cdr (assoc param params))
                (when (assoc param params) t))))))))

(defun scimax-ob-update-param (param val)
  "Update PARAM to VAL in current src block header (or remove when VAL is nil)."
  (unless (keywordp param)
    (error "%s should be a :keyword" param))
  (setq param (intern (substring (symbol-name param) 1)))
  (when (org-in-src-block-p)
    (save-excursion
      (goto-char (org-babel-where-is-src-block-head))
      (let ((header-line (thing-at-point 'line t))
            (case-fold-search t))
        (when (string-match "^\\([ \t]*#\\+begin_src[ \t]+\\([^ \t\n]+\\)\\)\\(.*\\)$" header-line)
          (let* ((prefix (match-string 1 header-line))
                 (params (org-babel-parse-header-arguments (match-string 3 header-line)))
                 (updated (assq-delete-all param params)))
            (when val
              (push (cons param val) updated))
            (let ((new-params (mapconcat
                               (lambda (entry)
                                 (if (cdr entry)
                                     (format ":%s %s" (symbol-name (car entry)) (cdr entry))
                                   (format ":%s" (symbol-name (car entry)))))
                               updated " ")))
              (delete-region (line-beginning-position) (line-end-position))
              (insert prefix (if (string-empty-p new-params) "" (concat " " new-params))))))))))

(defun scimax-ob-delete-param (param)
  "Delete PARAM from current src block header."
  (scimax-ob-update-param param nil))

(defun scimax-ob-edit-header ()
  "Edit the current src-block header in the minibuffer."
  (interactive)
  (let* ((src-info (org-babel-get-src-block-info 'light))
         (header-start (nth 5 src-info))
         (header-end (save-excursion
                       (goto-char header-start)
                       (line-end-position)))
         (updated (read-string "Header: "
                               (buffer-substring-no-properties header-start header-end))))
    (delete-region header-start header-end)
    (goto-char header-start)
    (insert updated)))

(defun scimax-ob-create-header-string ()
  "Interactively construct an Org-Babel `:header value' string via `completing-read'."
  (interactive)
  (unless (org-in-src-block-p)
    (user-error "Not in a src block"))
  (let* ((lang (car (org-babel-get-src-block-info 'light)))
         (lang-headers (intern (concat "org-babel-header-args:" lang)))
         (header-vals (org-babel-combine-header-arg-lists
                       org-babel-common-header-args-w-values
                       (when (boundp lang-headers) (symbol-value lang-headers))))
         (headers (mapcar (lambda (h) (symbol-name (car h))) header-vals))
         (header (completing-read "Header arg: " headers nil t))
         (vals (cdr (assoc (intern-soft header) header-vals)))
         (prefix (concat ":" header " ")))
    (cond
     ((null vals) prefix)
     ((eq vals :any) (concat prefix (read-string "Value: ")))
     ((and (listp vals) (not (listp (car vals))))
      (concat prefix (completing-read "Value: " (mapcar #'symbol-name vals))))
     (t
      (concat prefix
              (s-join " "
                      (delq nil
                            (cl-loop for lst in vals
                                     for picked = (completing-read "Value (optional): "
                                                                   (cons "" (mapcar #'symbol-name lst)))
                                     collect (unless (string-empty-p picked) picked)))))))))

(defun scimax-ob-clear-all-results ()
  "Clear all src block results in the current buffer."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (ignore-errors (org-babel-next-src-block))
      (org-babel-remove-result))))

(defun scimax-ob-toggle-output ()
  "Toggle visibility of results for current src block."
  (interactive)
  (when-let* ((loc (org-babel-where-is-src-block-result)))
    (save-excursion
      (goto-char loc)
      (org-cycle))))

(defun scimax-ob-mark-code ()
  "Mark the body code of current src block."
  (interactive)
  (org-edit-special)
  (let ((p0 (point-min))
        (p1 (point-max)))
    (goto-char p0)
    (org-edit-src-exit)
    (set-mark (point))
    (goto-char (+ (point) (- p1 2)))))

(defvar-local scimax-ob-number-line-overlays nil
  "Overlays used for in-block src line numbering.")

(defun scimax-ob-remove-line-numbers ()
  "Remove in-block src line-number overlays."
  (mapc #'delete-overlay scimax-ob-number-line-overlays)
  (setq-local scimax-ob-number-line-overlays nil)
  (remove-hook 'post-command-hook #'scimax-ob-add-line-numbers t))

(defun scimax-ob-add-line-numbers ()
  "Display relative 1..N line numbers inside the active Org src block."
  (if (not (org-in-src-block-p))
      (scimax-ob-remove-line-numbers)
    (save-excursion
      (let* ((el (org-element-context))
             (beg (org-element-property :begin el))
             (end (org-element-property :end el))
             (nlines (count-lines beg end))
             (width (length (number-to-string nlines))))
        (mapc #'delete-overlay scimax-ob-number-line-overlays)
        (setq-local scimax-ob-number-line-overlays nil)
        (goto-char beg)
        (forward-line 1)
        (cl-loop for i from 1 to (max 1 (- nlines 2))
                 do (let ((ov (make-overlay (line-beginning-position) (line-beginning-position))))
                      (overlay-put ov 'before-string
                                   (propertize (format (format "%%%dd " width) i) 'face 'shadow))
                      (push ov scimax-ob-number-line-overlays))
                 (forward-line 1))))
    (add-hook 'post-command-hook #'scimax-ob-add-line-numbers nil t)))

(defun scimax-ob-toggle-line-numbers ()
  "Toggle line numbers inside the current Org src block."
  (interactive)
  (if scimax-ob-number-line-overlays
      (scimax-ob-remove-line-numbers)
    (scimax-ob-add-line-numbers)))

;; Hydra menu for src block operations
(defhydra scimax-ob (:color red :hint nil)
  "
  Execute                  Navigate                  Edit                    Misc
----------------------------------------------------------------------------------------------------------
  _<return>_: current      _i_: prev src             _w_: move up            _l_: clear result
  _S-<return>_: run+next   _k_: next src             _s_: move down          _L_: clear all results
  _M-<return>_: run+new    _q_: visible src          _x_: kill               _o_: toggle output
  _S-M-<return>_: to point _Q_: jump src             _n_: copy               _N_: line numbers
  _C-M-<return>_: buffer   _R_: to result            _c_: clone              _h_: edit header
  _r_: switch to REPL      _-_: split                _+_: insert above       _=_: insert below
  _mp_: merge prev         _mn_: merge next          _mm_: merge region      _q_ / _<return>_: exit
"
  ("o" scimax-ob-toggle-output :color red)
  ("<up>" scimax-ob-edit-up :color red)
  ("<down>" scimax-ob-edit-down :color red)
  ("C-<up>" scimax-ob-jump-to-first-line :color red)
  ("C-<down>" scimax-ob-jump-to-end-line :color red)
  ("<return>" org-ctrl-c-ctrl-c :color blue)
  ("S-<return>" scimax-ob-execute-and-next-block :color red)
  ("M-<return>" (lambda () (interactive) (scimax-ob-execute-and-next-block t)) :color red)
  ("S-M-<return>" scimax-ob-execute-to-point :color blue)
  ("C-M-<return>" org-babel-execute-buffer :color blue)
  ("r" org-babel-switch-to-session :color blue)
  ("N" scimax-ob-toggle-line-numbers)
  ("i" org-babel-previous-src-block :color red)
  ("k" org-babel-next-src-block :color red)
  ("q" scimax-ob-jump-to-visible-src-block :color blue)
  ("Q" scimax-ob-jump-to-src-block :color blue)
  ("R" (when-let* ((r (org-babel-where-is-src-block-result))) (goto-char r)) :color blue)
  ("w" scimax-ob-move-src-block-up :color red)
  ("s" scimax-ob-move-src-block-down :color red)
  ("x" scimax-ob-kill-block-and-results :color red)
  ("n" scimax-ob-copy-block-and-results :color red)
  ("c" scimax-ob-clone-block :color red)
  ("mm" scimax-ob-merge-blocks :color blue)
  ("mp" scimax-ob-merge-previous :color blue)
  ("mn" scimax-ob-merge-next :color blue)
  ("-" scimax-ob-split-src-block :color blue)
  ("+" scimax-ob-insert-src-block :color blue)
  ("=" (scimax-ob-insert-src-block t) :color blue)
  ("l" org-babel-remove-result)
  ("L" scimax-ob-clear-all-results)
  ("h" scimax-ob-edit-header)
  (";" org-comment-dwim :color red))

;; Context-aware keybindings in Org src blocks (keep RET free for `my/org-src-return-mode')
(dolist (pair '(("C-<return>" . org-ctrl-c-ctrl-c)
                ("S-<return>" . scimax-ob-execute-and-next-block)
                ("M-<return>" . (lambda () (interactive) (scimax-ob-execute-and-next-block t)))
                ("M-S-<return>" . scimax-ob-execute-to-point)
                ("C-M-<return>" . org-babel-execute-buffer)
                ("s-." . scimax-ob/body)))
  (let ((key (car pair))
        (fn (cdr pair)))
    (define-key org-mode-map (kbd key)
                `(menu-item ,(format "src-%s" key) nil
                            :filter ,(lambda (&optional _)
                                       (when (org-in-src-block-p) fn))))))

(define-key org-mode-map (kbd "C-c b") #'scimax-ob/body)

(provide 'org-scimax-babel)
;;; org-scimax-babel.el ends here
