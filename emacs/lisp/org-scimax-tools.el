;;; org-scimax-tools.el --- Editmarks, Journal, Notebook, Words, Ore & BibTeX hotkeys -*- lexical-binding: t; -*-

;;; Commentary:
;; Clean Vertico/Consult implementations of scimax productivity tools:
;; - Editmarks (`@@comment:...@@`, `@@insert:...@@`, `@@delete:...@@`, `@@typo:...@@`)
;; - Journal (`~/Projects/journal/`) and Notebook (`~/Projects/`)
;; - Words hydra, context-aware `ore` Org dispatcher, and BibTeX hotkeys.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'hydra)
(require 'avy)
(require 's)

;; ── Editmarks ───────────────────────────────────────────────────────────────

(defconst my/editmark-re
  "@@\\(comment\\|insert\\|delete\\|typo\\):\\(\\(?:.\\|\n\\)*?\\)@@"
  "Regexp matching Org inline editmarks.")

(defun my/editmark-wrap (kind &optional text)
  "Insert or wrap region with an Org editmark of KIND (`comment', `insert', `delete', `typo')."
  (let ((tag (symbol-name kind)))
    (cond
     ((region-active-p)
      (let* ((beg (region-beginning))
             (end (region-end))
             (body (buffer-substring-no-properties beg end)))
        (delete-region beg end)
        (goto-char beg)
        (insert (format "@@%s:%s@@" tag body))))
     (t
      (let ((content (or text (read-string (format "%s: " (capitalize tag))))))
        (insert (format "@@%s:%s@@" tag content)))))))

(defun my/em-comment () (interactive) (my/editmark-wrap 'comment))
(defun my/em-insert () (interactive) (my/editmark-wrap 'insert))
(defun my/em-delete () (interactive) (my/editmark-wrap 'delete))
(defun my/em-typo () (interactive) (my/editmark-wrap 'typo))

(defun my/em-next ()
  "Jump to the next editmark in the buffer."
  (interactive)
  (when (re-search-forward my/editmark-re nil t)
    (goto-char (match-beginning 0))))

(defun my/em-prev ()
  "Jump to the previous editmark in the buffer."
  (interactive)
  (when (re-search-backward my/editmark-re nil t)
    (goto-char (match-beginning 0))))

(defun my/em-accept-at-point ()
  "Accept the editmark at point (keep text for `insert', drop text for `delete'/`comment')."
  (interactive)
  (save-excursion
    (when (or (looking-at my/editmark-re)
              (re-search-backward "@@" (line-beginning-position 0) t))
      (when (looking-at my/editmark-re)
        (let ((kind (match-string 1))
              (body (match-string 2)))
          (replace-match (if (string= kind "insert") body "") t t))))))

(defun my/em-strip-all ()
  "Strip all resolved editmarks in the current buffer."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward my/editmark-re nil t)
      (let ((kind (match-string 1))
            (body (match-string 2)))
        (replace-match (if (string= kind "insert") body "") t t)))))

(defhydra my/editmarks-hydra (:color blue :hint nil)
  "
  Editmarks: _c_ comment  _i_ insert  _d_ delete  _t_ typo  |  _n_ next  _p_ prev  _a_ accept/drop  _X_ strip all
"
  ("c" my/em-comment)
  ("i" my/em-insert)
  ("d" my/em-delete)
  ("t" my/em-typo)
  ("n" my/em-next :color red)
  ("p" my/em-prev :color red)
  ("a" my/em-accept-at-point :color red)
  ("X" my/em-strip-all)
  ("q" nil))

(define-key org-mode-map (kbd "C-c E") #'my/editmarks-hydra/body)
(global-set-key (kbd "H-e") #'my/editmarks-hydra/body)

;; ── Journal & Notebooks ─────────────────────────────────────────────────────

(defcustom my/journal-root (expand-file-name "~/Projects/journal/")
  "Root directory for daily Org journal files."
  :type 'directory
  :group 'org)

(defcustom my/notebook-root (expand-file-name "~/Projects/")
  "Root directory searched for Org notebooks."
  :type 'directory
  :group 'org)

(defun my/journal-today ()
  "Open or create today's Org journal file under `my/journal-root'."
  (interactive)
  (let* ((rel (format-time-string "%Y/%m/%d/%Y-%m-%d.org"))
         (path (expand-file-name rel my/journal-root)))
    (make-directory (file-name-directory path) t)
    (find-file path)
    (when (= (buffer-size) 0)
      (insert (format "#+TITLE: Journal %s\n\n* " (format-time-string "%Y-%m-%d %a"))))))

(defun my/journal-open ()
  "Open an existing journal Org file via `completing-read'."
  (interactive)
  (unless (file-directory-p my/journal-root)
    (make-directory my/journal-root t))
  (let* ((files (directory-files-recursively my/journal-root "\\.org\\'"))
         (choices (mapcar (lambda (f) (cons (file-relative-name f my/journal-root) f))
                          (sort files #'string>)))
         (picked (if choices
                     (completing-read "Journal entry: " choices nil t)
                   nil)))
    (if picked
        (find-file (cdr (assoc picked choices)))
      (my/journal-today))))

(defun my/journal-search ()
  "Search journal files interactively using `consult-ripgrep'."
  (interactive)
  (unless (file-directory-p my/journal-root)
    (make-directory my/journal-root t))
  (consult-ripgrep my/journal-root))

(defun my/notebook-open ()
  "Open an Org file under `my/notebook-root' (`~/Projects/') via `completing-read'."
  (interactive)
  (let* ((default-directory my/notebook-root)
         (files (split-string
                 (shell-command-to-string
                  "rg --files -g '*.org' --max-depth 3 . 2>/dev/null")
                 "\n" t))
         (picked (completing-read "Notebook (.org): " files nil t)))
    (when picked
      (find-file (expand-file-name picked my/notebook-root)))))

(defun my/notebook-search ()
  "Search notes in `my/notebook-root' using `consult-ripgrep'."
  (interactive)
  (consult-ripgrep my/notebook-root))

(defhydra my/journal-hydra (:color blue :hint nil)
  "
  Journal & Notebooks: _t_ today  _o_ open entry  _s_ search journal  _n_ open notebook  _S_ search notebooks
"
  ("t" my/journal-today)
  ("o" my/journal-open)
  ("s" my/journal-search)
  ("n" my/notebook-open)
  ("S" my/notebook-search)
  ("q" nil))

(global-set-key (kbd "H-j") #'my/journal-hydra/body)
(global-set-key (kbd "C-c J") #'my/journal-hydra/body)

;; ── Words Hydra ─────────────────────────────────────────────────────────────

(defhydra words-hydra (:color blue :hint nil)
  "
  Words: _w_ count words  _j_ spellcheck (jinx)  _d_ dictionary  _l_ line multi  _r_ ripgrep
"
  ("w" count-words)
  ("j" jinx-correct)
  ("d" dictionary-search)
  ("l" consult-line-multi)
  ("r" consult-ripgrep)
  ("q" nil))

(global-set-key (kbd "H-w") #'words-hydra/body)

;; ── Ore (Org Context Dispatcher) ────────────────────────────────────────────

(defun ore ()
  "Open a context-sensitive action for the Org element at point."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an Org buffer"))
  (let ((el (org-element-context)))
    (pcase (org-element-type el)
      ('src-block (scimax-ob/body))
      ('table (call-interactively #'org-ctrl-c-ctrl-c))
      ('link (org-open-at-point))
      ((or 'latex-fragment 'latex-environment) (org-latex-preview))
      ('headline (call-interactively #'consult-org-heading))
      (_ (call-interactively #'embark-act)))))

(global-set-key (kbd "H-o") #'ore)

;; ── BibTeX Hotkeys ──────────────────────────────────────────────────────────

(defvar bibtex-hotkeys nil
  "Registered single-letter BibTeX hotkeys.")

(defun bibtex-in-entry-p ()
  "Return non-nil if point is strictly inside a BibTeX entry."
  (let ((p (point)))
    (save-excursion
      (bibtex-beginning-of-entry)
      (let ((b (point)))
        (bibtex-end-of-entry)
        (and (< b p) (< p (point)))))))

(defmacro bibtex-hotkey (key &rest body)
  "Bind KEY in `bibtex-mode-map' to execute BODY when at entry start (`@')."
  (let ((docstring (when (stringp (car body)) (car body)))
        (forms (if (stringp (car body)) (cdr body) body)))
    `(progn
       (setf (alist-get ,key bibtex-hotkeys nil nil #'string=) ,docstring)
       (with-eval-after-load 'bibtex
         (define-key bibtex-mode-map ,key
                     (lambda ()
                       ,@(when docstring (list docstring))
                       (interactive)
                       (if (or (looking-at-p "^@") (and (bolp) (not (bibtex-in-entry-p))))
                           (progn ,@forms)
                         (insert ,key))))))))

(with-eval-after-load 'bibtex
  (bibtex-hotkey "b" "Open in browser" (org-ref-open-in-browser))
  (bibtex-hotkey "c" "Copy entry"
                 (bibtex-kill-entry t)
                 (message (substitute-command-keys "\\[bibtex-yank] to paste.")))
  (bibtex-hotkey "f" "Copy formatted"
                 (kill-new
                  (org-ref-format-entry
                   (cdr (assoc "=key=" (bibtex-parse-entry t))))))
  (bibtex-hotkey "k" "Kill entry" (bibtex-kill-entry))
  (bibtex-hotkey "l" "Clean entry" (org-ref-clean-bibtex-entry))
  (bibtex-hotkey "I" "Inspect" (message "%s" (save-excursion (bibtex-parse-entry t))))
  (bibtex-hotkey "n" "Next entry" (org-ref-bibtex-next-entry))
  (bibtex-hotkey "p" "Previous entry" (org-ref-bibtex-previous-entry))
  (bibtex-hotkey "?" "Show hotkeys"
                 (message "%s"
                          (mapconcat (lambda (c) (format "%s: %s" (car c) (cdr c)))
                                     (sort (copy-sequence bibtex-hotkeys)
                                           (lambda (a b) (string< (car a) (car b))))
                                     "  |  ")))
  (bibtex-hotkey "q" "Jump to field"
                 (let* ((beg (point))
                        (e (save-excursion (bibtex-parse-entry)))
                        (end (save-excursion (bibtex-end-of-entry) (point)))
                        (regex (concat (regexp-opt (mapcar #'car e)) " +=")))
                   (avy-with bibtex-goto-field
                     (avy-jump regex nil avy-style beg end))))
  (bibtex-hotkey "S" "Sentence-case title" (org-ref-sentence-case))
  (bibtex-hotkey "T" "Title-case article" (org-ref-title-case))
  (bibtex-hotkey "U" "Update from DOI"
                 (doi-utils-update-bibtex-entry-from-doi (bibtex-autokey-get-field "doi")))
  (bibtex-hotkey "y" "Paste entry" (bibtex-yank)))

(provide 'org-scimax-tools)
;;; org-scimax-tools.el ends here
