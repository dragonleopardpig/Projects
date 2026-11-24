;;; emacs-config-tests.el --- Standalone Emacs 31 configuration ERT suite -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with:
;;   emacs --batch -Q -l /home/thinky/Projects/emacs/emacs-config-tests.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)

(defvar pdf-view-resize-factor)
(defvar pdf-view-use-scaling)
(defvar pdf-cache-prefetch-delay)
(defvar pdf-cache-image-limit)
(defvar pdf-cache-prefetch-pages-function)
(defvar pdf-cache--prefetch-pages)
(defvar save-place-alist)
(declare-function pdf-cache-number-of-pages "pdf-cache" ())
(declare-function pdf-cache--prefetch-stop "pdf-cache" ())
(declare-function pdf-cache-clear-data-of-pages "pdf-cache" (&rest pages))
(declare-function pdf-cache--data-get "pdf-cache" (key &optional page))
(declare-function pdf-info-getannots "pdf-info" (&optional pages file-or-buffer))
(declare-function my/pdf-prefetch-pages-forward "init-documents" ())
(declare-function my/study--open-right-window "init-study" ())
(declare-function my/study--root-columns "init-study" ())

(defconst my/test-emacs-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the standalone Emacs configuration.")

(eval-and-compile
  (unless (featurep 'init)
    (let ((early (expand-file-name "early-init.el" my/test-emacs-dir))
          (main (expand-file-name "init.el" my/test-emacs-dir)))
      (when (file-readable-p early)
        (load early nil 'nomessage))
      (load main nil 'nomessage))))

(ert-deftest my/test-clean-boot-and-core-features ()
  "Standalone config boots cleanly and loads all modular features."
  (dolist (feat '(init
                  init-core
                  init-completion
                  init-files-and-ui
                  init-org-science
                  init-programming
                  init-documents
                  init-ai
                  init-study
                  org-scimax-markup
                  org-scimax-latex
                  org-scimax-babel
                  org-scimax-tools
                  ox-manuscript
                  org-show))
    (should (featurep feat))))

(ert-deftest my/test-legacy-scimax-and-ivy-absent ()
  "Legacy scimax, Ivy/Counsel/Swiper/Smex, smart-mode-line, flycheck & old tree-sitter are absent."
  (dolist (feat '(scimax
                  scimax-org
                  scimax-ob
                  scimax-jupyter
                  ivy
                  counsel
                  swiper
                  smex
                  smart-mode-line
                  flycheck
                  tree-sitter))
    (should-not (featurep feat)))
  (should-not (cl-some (lambda (p) (string-match-p "/scimax\\(/\\|\\'\\)" p))
                       load-path)))

(ert-deftest my/test-modern-packages-present ()
  "Modernized Nix-provisioned completion, UI, dev, and scientific packages are active."
  (should (featurep 'vertico))
  (should (bound-and-true-p vertico-mode))
  (should (featurep 'orderless))
  (should (featurep 'marginalia))
  (should (bound-and-true-p marginalia-mode))
  (should (featurep 'consult))
  (should (featurep 'embark))
  (should (featurep 'dashboard))
  (should (featurep 'enhanced-dirvish))
  (should (featurep 'projectile))
  (should (bound-and-true-p projectile-mode))
  (should (featurep 'treesit))
  (should (locate-library "magit"))
  (should (featurep 'envrc))
  (should (locate-library "org-ref"))
  (should (featurep 'citar))
  (should (featurep 'ox-manuscript))
  (should (featurep 'org-show))
  (should (locate-library "jinx"))
  (when (file-directory-p (expand-file-name "lsp-bridge" user-emacs-directory))
    (should (featurep 'lsp-bridge)))
  (when (file-directory-p (expand-file-name "flymake-bridge" user-emacs-directory))
    (should (featurep 'flymake-bridge))))

(ert-deftest my/test-keybindings-non-colliding ()
  "Critical global and Org keybindings do not collide."
  (should (eq (key-binding (kbd "<f12>")) #'my/toggle-frame-transparency))
  (should (eq (key-binding (kbd "<f4>")) #'heaven-and-hell-toggle-theme))
  (should (eq (key-binding (kbd "C-s")) #'consult-line))
  (should (eq (key-binding (kbd "C-c d")) #'enhanced-dirvish-launch))
  (should (eq (key-binding (kbd "C-c j")) #'my/jupyter-org-hydra/body))
  (should (eq (key-binding (kbd "s-j")) #'my/jupyter-org-hydra/body))
  (should (eq (key-binding (kbd "C-c e")) 'my/agent-map))
  (should (eq (key-binding (kbd "C-c n")) 'my/study-map))
  (should (eq (key-binding (kbd "C-c n o")) #'my/study-open))
  (should (eq (key-binding (kbd "C-c n s")) #'my/study-send-region))
  (should (eq (key-binding (kbd "C-c n a")) #'my/study-ask))
  (should (eq (key-binding (kbd "C-c n t")) #'my/study-choose-target-org))
  (should (eq (key-binding (kbd "C-c n g")) #'my/study-select-agent))
  (should (eq (key-binding (kbd "C-c n h")) #'my/study-browse-sioyek-highlights))
  (should (eq (key-binding (kbd "C-c n b")) #'my/study-import-book-highlights))
  (with-temp-buffer
    (org-mode)
    (should (eq (key-binding (kbd "C-c E")) #'my/editmarks-hydra/body))
    (should (eq (key-binding (kbd "C-c b")) #'scimax-ob/body))
    (should (eq (key-binding (kbd "C-c M-v")) #'emacs-minder-paste-clipboard-latex))))

(ert-deftest my/test-pdf-tools-opens-pdf ()
  "Opening a PDF activates `pdf-view-mode' via `pdf-tools' instead of `doc-view'."
  (let ((pdf (expand-file-name "~/.local/share/sioyek/tutorial.pdf"))
        (buf nil))
    (should (locate-library "pdf-tools"))
    (should (fboundp 'pdf-loader-install))
    (when (file-exists-p pdf)
      (let ((save-place-alist nil))
        (unwind-protect
            (progn
              (setq buf (find-file-noselect pdf))
              (with-current-buffer buf
                (should (derived-mode-p 'pdf-view-mode))
                (should (eq (key-binding (kbd "d")) #'pdf-view-follow-minor-mode))
                (should (= (pdf-cache-number-of-pages) 6))
                (should (= pdf-view-resize-factor 1.02))
                (should (= pdf-cache-prefetch-delay 0.15))
                (should (= pdf-cache-image-limit 128))
                (should (eq pdf-cache-prefetch-pages-function
                            #'my/pdf-prefetch-pages-forward))
                (should (equal (my/pdf-prefetch-pages-forward) '(2 3 4 5 6)))
                (cl-letf (((symbol-function 'pdf-view-current-page)
                           (lambda (&optional _w) 3)))
                  (should (equal (my/pdf-prefetch-pages-forward) '(4 5 6 2))))
                (should-not (bound-and-true-p visual-line-mode))
                (should-not (bound-and-true-p undo-tree-mode))
                (pdf-info-getannots 1)
                (should (car (pdf-cache--data-get 'getannots 1)))
                (pdf-cache-clear-data-of-pages 1)
                (should-not (car (pdf-cache--data-get 'getannots 1)))
                (let ((pdf-cache--prefetch-pages '(4 5 6))
                      (this-command 'mwheel-scroll))
                  (pdf-cache--prefetch-stop)
                  (should (equal pdf-cache--prefetch-pages '(4 5 6)))
                  (setq this-command 'pdf-view-goto-page)
                  (pdf-cache--prefetch-stop)
                  (should-not pdf-cache--prefetch-pages))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest my/test-zero-arg-startup-dashboard ()
  "Running `dashboard-open' creates and displays `*dashboard*' cleanly."
  (should (memq #'my/dashboard-open-if-scratch emacs-startup-hook))
  (when (get-buffer "*dashboard*")
    (kill-buffer "*dashboard*"))
  (dashboard-open)
  (let ((buf (get-buffer "*dashboard*")))
    (should (buffer-live-p buf))
    (should (eq (my/dashboard-initial-buffer) buf))
    (with-current-buffer buf
      (should (derived-mode-p 'dashboard-mode)))))

(ert-deftest my/test-heaven-and-hell-loads-ef-spring ()
  "`heaven-and-hell-init-hook' loads and enables `ef-spring' without error."
  (let ((orig-themes (copy-sequence custom-enabled-themes))
        (orig-type heaven-and-hell-theme-type))
    (unwind-protect
        (progn
          (setq heaven-and-hell-theme-type 'light)
          (heaven-and-hell-init-hook)
          (should (memq 'ef-spring custom-enabled-themes)))
      (mapc #'disable-theme custom-enabled-themes)
      (mapc #'enable-theme (reverse orig-themes))
      (setq heaven-and-hell-theme-type orig-type))))

(ert-deftest my/test-org-markup-bold-and-math ()
  "Org smart markup commands wrap words cleanly without Ivy."
  (with-temp-buffer
    (org-mode)
    (insert "hello ")
    (goto-char 3)
    (org-bold-region-or-point)
    (should (equal (buffer-string) "*hello* "))
    (erase-buffer)
    (insert "alpha")
    (goto-char 2)
    (org-latex-math-region-or-point)
    (should (equal (buffer-string) "\\(alpha\\)"))))

(ert-deftest my/test-org-scimax-babel-insert-split-merge ()
  "Org Babel src block insert, split, and merge operate cleanly."
  (with-temp-buffer
    (org-mode)
    (insert "#+BEGIN_SRC emacs-lisp\n(+ 1 1)\n(+ 2 2)\n#+END_SRC\n")
    (goto-char (point-min))
    (search-forward "(+ 2 2)")
    (scimax-ob-split-src-block)
    (should (= (length (org-element-map (org-element-parse-buffer) 'src-block #'identity)) 2))
    (scimax-ob-insert-src-block t)
    (insert "(+ 3 3)")
    (should (= (length (org-element-map (org-element-parse-buffer) 'src-block #'identity)) 3))
    (scimax-ob-merge-blocks (point-min) (point-max))
    (let ((blocks (org-element-map (org-element-parse-buffer) 'src-block #'identity)))
      (should (= (length blocks) 1))
      (should (string-search "(+ 1 1)" (buffer-string)))
      (should (string-search "(+ 2 2)" (buffer-string)))
      (should (string-search "(+ 3 3)" (buffer-string))))))

(ert-deftest my/test-editmarks-wrap-and-strip ()
  "Org editmarks wrap text and strip accepted/rejected edits cleanly."
  (with-temp-buffer
    (org-mode)
    (my/editmark-wrap 'insert "new ")
    (my/editmark-wrap 'delete "old ")
    (insert "word")
    (should (equal (buffer-string) "@@insert:new @@@@delete:old @@word"))
    (my/em-strip-all)
    (should (equal (buffer-string) "new word"))))

(ert-deftest my/test-ox-manuscript-candidates ()
  "`ox-manuscript-candidates' discovers bundled manuscript templates."
  (let ((cands (ox-manuscript-candidates)))
    (should (listp cands))
    (should (> (length cands) 0))
    (let ((first-path (plist-get (cddr (car cands)) :filename)))
      (should (stringp first-path))
      (should (file-readable-p first-path)))))

(ert-deftest my/test-org-latex-transparent-currentcolor-svg ()
  "Org LaTeX previews use transparent `dvisvgm --currentcolor' without white rects."
  (should (equal (plist-get org-format-latex-options :foreground) "Black"))
  (should (equal (plist-get org-format-latex-options :background) "Transparent"))
  (let* ((dvisvgm-info (cdr (assq 'dvisvgm org-preview-latex-process-alist)))
         (conv (plist-get dvisvgm-info :image-converter)))
    (should (cl-some (lambda (cmd) (string-match-p "--currentcolor" cmd)) conv))
    (should (cl-some (lambda (cmd) (string-match-p "--bbox=1pt" cmd)) conv)))
  (when (and (executable-find "latex") (executable-find "dvisvgm"))
    (let* ((out (make-temp-file "org-math-currentcolor-" nil ".svg"))
           (opts org-format-latex-options))
      (unwind-protect
          (progn
            (org-create-formula-image "$E = mc^2$" out opts (current-buffer) 'dvisvgm)
            (let ((svg (with-temp-buffer
                         (insert-file-contents out)
                         (buffer-string))))
              (should (string-match-p "fill=['\"]currentColor['\"]" svg))
              (should-not (string-match-p "<rect\\b" svg)))
            (with-temp-buffer
              (org-mode)
              (insert "$E = mc^2$")
              (org--make-preview-overlay (point-min) (point-max) out "svg")
              (let* ((ov (cl-find-if (lambda (o)
                                       (eq (overlay-get o 'org-overlay-type)
                                           'org-latex-overlay))
                                     (overlays-at (point-min))))
                     (disp (and ov (overlay-get ov 'display))))
                (should ov)
                (should (eq (car-safe disp) 'image))
                (should (eq (plist-get (cdr disp) :mask) 'heuristic)))))
        (when (file-exists-p out)
          (delete-file out))))))

(ert-deftest my/test-org-inline-svg-transparent-css ()
  "`org--create-inline-image' injects transparent-rect CSS and mask only on SVG images."
  (let* ((tmp-dir (make-temp-file "org-inline-svg-" t))
         (svg-file (expand-file-name "sample.svg" tmp-dir))
         (png-file (expand-file-name "sample.png" tmp-dir)))
    (unwind-protect
        (progn
          (with-temp-file svg-file
            (insert "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'>"
                    "<rect width='100%' height='100%' fill='#ffffff'/></svg>"))
          (with-temp-file png-file
            (set-buffer-multibyte nil)
            (insert (base64-decode-string
                     "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")))
          (let* ((my/org-svg-strip-white-background t)
                 (svg-img (org--create-inline-image svg-file nil))
                 (png-img (org--create-inline-image png-file nil)))
            (should (eq (car-safe svg-img) 'image))
            (should (stringp (plist-get (cdr svg-img) :css)))
            (should (string-match-p "fill: transparent !important"
                                    (plist-get (cdr svg-img) :css)))
            (should (eq (plist-get (cdr svg-img) :mask) 'heuristic))
            (should (eq (car-safe png-img) 'image))
            (should-not (plist-get (cdr png-img) :css))
            (should-not (plist-get (cdr png-img) :mask))))
      (delete-directory tmp-dir t))))

(ert-deftest my/test-ipynb-to-markdown ()
  "`ipynb-to-markdown' converts an `.ipynb' JSON file to fenced Markdown."
  (let* ((tmp-dir (make-temp-file "ipynb-test-" t))
         (nb (expand-file-name "sample.ipynb" tmp-dir))
         (md (expand-file-name "sample.md" tmp-dir)))
    (unwind-protect
        (progn
          (with-temp-file nb
            (insert "{\"metadata\":{\"kernelspec\":{\"language\":\"python\"}},"
                    "\"cells\":[{\"cell_type\":\"markdown\",\"source\":[\"# Title\"]},"
                    "{\"cell_type\":\"code\",\"source\":[\"x = 1\"],"
                    "\"outputs\":[{\"text\":[\"1\"]}]}]}"))
          (ipynb-to-markdown nb md)
          (should (file-readable-p md))
          (let ((content (with-temp-buffer (insert-file-contents md) (buffer-string))))
            (should (string-match-p "# Title" content))
            (should (string-match-p "```python\nx = 1\n```" content))
            (should (string-match-p "```text\n1\n```" content))))
      (delete-directory tmp-dir t))))

(ert-deftest my/test-org-mode-no-jupyter-kernelspec-error ()
  "Activating `org-mode' without `jupyter' emits no kernelspec error."
  (require 'ob-jupyter)
  (let ((msgs nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (when (stringp fmt)
                   (push (apply #'format fmt args) msgs)))))
      (let ((default-directory temporary-file-directory)
            (exec-path nil))
        (should-not (my/jupyter-find-executable temporary-file-directory))
        (with-temp-buffer
          (org-mode))))
    (should-not (cl-some (lambda (m)
                           (string-match-p "Error retrieving kernelspecs" m))
                         msgs)))
  (let ((org-jup "/home/thinky/Projects/org/.devenv/state/venv/bin/jupyter"))
    (when (file-executable-p org-jup)
      (let ((exec-path nil))
        (should (equal (my/jupyter-find-executable "/home/thinky/Projects/org")
                       org-jup))))))

(ert-deftest my/test-study-sioyek-sqlite-and-org-insert ()
  "Study AI reads a Sioyek-shaped SQLite pair and files Org notes cleanly."
  (require 'org)
  (let* ((dir (make-temp-file "study-test-" t))
         (pdf (expand-file-name "book.pdf" dir))
         (org-file (expand-file-name "notes.org" dir))
         (buffer nil))
    (unwind-protect
        (progn
          (with-temp-file pdf (insert "%PDF-1.4\n"))
          (let ((db (sqlite-open (expand-file-name "local.db" dir))))
            (sqlite-execute db "CREATE TABLE document_hash (id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT, hash TEXT, UNIQUE(path, hash))")
            (sqlite-execute db "INSERT INTO document_hash (path, hash) VALUES (?, ?)"
                            (list "/gone/old-copy.pdf" "h1"))
            (sqlite-execute db "INSERT INTO document_hash (path, hash) VALUES (?, ?)"
                            (list pdf "h1"))
            (sqlite-close db))
          (let ((db (sqlite-open (expand-file-name "shared.db" dir))))
            (sqlite-execute db "CREATE TABLE highlights (id INTEGER PRIMARY KEY AUTOINCREMENT, document_path TEXT, desc TEXT, text_annot TEXT, type char, creation_time timestamp, begin_y real)")
            (sqlite-execute db "CREATE TABLE bookmarks (id INTEGER PRIMARY KEY AUTOINCREMENT, document_path TEXT, desc TEXT, creation_time timestamp, offset_y real)")
            (sqlite-execute db "INSERT INTO highlights (document_path, desc, text_annot, type, creation_time, begin_y) VALUES ('h1', 'Later  highlight', 'why?', 'a', '2026-01-01', 900.5)")
            (sqlite-execute db "INSERT INTO highlights (document_path, desc, text_annot, type, creation_time, begin_y) VALUES ('h1', 'Early highlight', '', 'b', '2026-01-02', 100)")
            (sqlite-execute db "INSERT INTO highlights (document_path, desc, text_annot, type, creation_time, begin_y) VALUES ('orphan', 'No such book', '', 'a', '2026-01-03', 5)")
            (sqlite-execute db "INSERT INTO bookmarks (document_path, desc, creation_time, offset_y) VALUES ('h1', 'My note', '2026-01-04', 500)")
            (sqlite-close db))
          (let ((entries (my/study-sioyek-read-entries dir)))
            (should (equal (mapcar (lambda (e) (plist-get e :text)) entries)
                           '("Early highlight" "My note" "Later  highlight")))
            (should (equal (plist-get (car entries) :file) pdf))
            (should (eq (plist-get (nth 1 entries) :kind) 'note))
            (should (equal (plist-get (nth 2 entries) :note) "why?"))
            (should (equal (my/study--entry-line (nth 2 entries) 7)
                           (format "- [[sioyek:%s::7][book.pdf · p.7]] Later highlight — why?\n"
                                   pdf))))
          ;; links
          (should (eq (org-link-get-parameter "sioyek" :follow)
                      #'my/study--follow-link))
          (let (opened)
            (cl-letf (((symbol-function 'my/study-open-in-sioyek)
                       (lambda (file &optional page) (setq opened (list file page)))))
              (my/study--follow-link "/x/y.pdf::42"))
            (should (equal opened '("/x/y.pdf" 42))))
          ;; heading shifting leaves non-headings alone
          (should (equal (my/study--shift-headings "* A\n** B\nx * y\n" 2)
                         "*** A\n**** B\nx * y\n"))
          ;; insertion: end of file when not visible, saved because buffer was clean
          (with-temp-file org-file
            (insert "* Chapter\n** Section\nbody\n* Other\n"))
          (my/study--insert-org-note org-file "* Note A\n:PROPERTIES:\n:X: 1\n:END:\ntext\n")
          (setq buffer (find-buffer-visiting org-file))
          (should (buffer-live-p buffer))
          (should-not (buffer-modified-p buffer))
          (should (string-suffix-p "* Other\n* Note A\n:PROPERTIES:\n:X: 1\n:END:\ntext\n"
                                   (with-temp-buffer
                                     (insert-file-contents org-file)
                                     (buffer-string))))
          ;; insertion as a child of the heading under the window cursor
          (save-window-excursion
            (switch-to-buffer buffer)
            (goto-char (point-min))
            (search-forward "body")
            (set-window-point (selected-window) (point))
            (my/study--insert-org-note org-file "* Note B\nmore\n"))
          (with-current-buffer buffer
            (let ((text (buffer-string)))
              (should (string-match-p "\\*\\* Section\nbody\n\\*\\*\\* Note B\nmore\n" text))
              (should (< (string-match "\\*\\*\\* Note B" text)
                         (string-match "^\\* Other" text)))
              (primitive-undo 1 buffer-undo-list)))
          )
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory dir t))))

(ert-deftest my/test-study-pane-preserves-two-pane-layout ()
  "Opening the Study AI pane adds a balanced rightmost column and dividers."
  (should (bound-and-true-p window-divider-mode))
  (should (>= window-divider-default-right-width 4))
  (save-window-excursion
    (set-frame-size (selected-frame) 180 40)
    (delete-other-windows)
    (let* ((left (selected-window))
           (right (split-window-right))
           (ai nil))
      (select-window left)
      (should (= (my/study--root-columns) 2))
      (setq ai (my/study--open-right-window))
      (should (window-live-p ai))
      (should (= (my/study--root-columns) 3))
      (should (<= 55 (window-total-width left) 65))
      (should (<= 55 (window-total-width right) 65))
      (should (<= 55 (window-total-width ai) 65))
      (should (< (nth 2 (window-edges right)) (nth 2 (window-edges ai))))
      (should (> (window-resizable left 10 t) 0))
      (should (< (window-resizable ai -10 t) 0)))))

(ert-deftest my/test-window-resize-pixelwise-enabled ()
  "Pixelwise window resizing stays enabled for smooth divider drags."
  (should (eq window-resize-pixelwise t)))

(ert-deftest my/test-study-drag-suspends-and-restores-xwidget ()
  "Dragging a divider suspends xwidget views for multi-step motion and restores on release."
  (save-window-excursion
    (set-frame-size (selected-frame) 180 40)
    (delete-other-windows)
    (let* ((left (selected-window))
           (right (split-window-right))
           (wb (generate-new-buffer " *test-xwidget*"))
           (deleted-views nil)
           (adjust-calls 0))
      (unwind-protect
          (progn
            (with-current-buffer wb
              (insert "stub-xwidget")
              (setq major-mode 'xwidget-webkit-mode))
            (set-window-buffer right wb)
            (select-window left)
            (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _f) t))
                      ((symbol-function 'get-buffer-xwidgets) (lambda (_b) '(fake-xw)))
                      ((symbol-function 'xwidget-view-lookup)
                       (lambda (_xw win) (list 'fake-view win)))
                      ((symbol-function 'delete-xwidget-view)
                       (lambda (v) (push v deleted-views)))
                      ((symbol-function 'xwidget-webkit-adjust-size-in-frame)
                       (lambda (_f) (setq adjust-calls (1+ adjust-calls))))
                      ((symbol-function 'mouse-position-for-drag-line)
                       (let ((xs '(700 704 716 740 772 800)))
                         (lambda (_tty)
                           (cons (or (pop xs) 800) 200)))))
              (let* ((w0-before (window-pixel-width left))
                     (ev-down `(down-mouse-1 (,left right-divider (700 . 200) 100 nil 1 (700 . 200) nil (700 . 200) (4 . 20))))
                     (ev-m1 `(mouse-movement (,left right-divider (704 . 200) 110 nil 1 (704 . 200) nil (704 . 200) (4 . 20))))
                     (ev-m2 `(mouse-movement (,right left-fringe (0 . 183) 120 nil 1 (0 . 183) nil (0 . 183) (1 . 20))))
                     (ev-m3 `(mouse-movement (,right 1 (24 . 183) 130 nil 1 (24 . 183) nil (24 . 183) (10 . 20))))
                     (ev-m4 `(mouse-movement (,right 1 (56 . 183) 140 nil 1 (56 . 183) nil (56 . 183) (10 . 20))))
                     (ev-up `(drag-mouse-1 (,left right-divider (700 . 200) 150 nil 1 (700 . 200) nil (700 . 200) (4 . 20)))))
                (mouse-drag-vertical-line ev-down)
                (should (eq (window-buffer right)
                            (get-buffer my/study--resize-placeholder-name)))
                (should (equal deleted-views `((fake-view ,right))))
                (setq unread-command-events (list ev-m1 ev-m2 ev-m3 ev-m4 ev-up))
                (dotimes (_ 5)
                  (let* ((key (read-key-sequence nil))
                         (cmd (key-binding key t)))
                    (when (commandp cmd)
                      (setq this-command cmd)
                      (run-hooks 'pre-command-hook)
                      (call-interactively cmd)
                      (run-hooks 'post-command-hook))))
                (should (null overriding-terminal-local-map))
                (should (null my/study--drag-suspended))
                (should (eq (window-buffer right) wb))
                (should (= adjust-calls 1))
                (should (> (- (window-pixel-width left) w0-before) 50)))))
        (setq my/study--drag-suspended nil)
        (when (buffer-live-p wb) (kill-buffer wb))))))

(ert-deftest my/test-study-mode-line-click-skips-xwidget-swap ()
  "Plain mode-line click without movement does not swap out xwidget buffer."
  (save-window-excursion
    (set-frame-size (selected-frame) 180 40)
    (delete-other-windows)
    (let* ((top (selected-window))
           (bottom (split-window-below))
           (wb (generate-new-buffer " *test-xwidget-ml*"))
           (suspend-calls 0))
      (unwind-protect
          (progn
            (with-current-buffer wb
              (insert "stub-xwidget")
              (setq major-mode 'xwidget-webkit-mode))
            (set-window-buffer bottom wb)
            (select-window top)
            (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _f) t))
                      ((symbol-function 'xwidget-webkit-adjust-size-in-frame) #'ignore)
                      ((symbol-function 'my/study--suspend-xwidgets)
                       (let ((orig (symbol-function 'my/study--suspend-xwidgets)))
                         (lambda (f)
                           (setq suspend-calls (1+ suspend-calls))
                           (funcall orig f)))))
              (let ((ev-down `(down-mouse-1 (,top mode-line (100 . 10) 100 nil 1 (100 . 10) nil (100 . 10) (4 . 20))))
                    (ev-click `(mouse-1 (,top mode-line (100 . 10) 110 nil 1 (100 . 10) nil (100 . 10) (4 . 20)))))
                (mouse-drag-mode-line ev-down)
                (should (eq (window-buffer bottom) wb))
                (should (= suspend-calls 0))
                (setq unread-command-events (list ev-click))
                (let* ((key (read-key-sequence nil))
                       (cmd (key-binding key t)))
                  (when (commandp cmd)
                    (setq this-command cmd)
                    (run-hooks 'pre-command-hook)
                    (call-interactively cmd)
                    (run-hooks 'post-command-hook)))
                (should (null overriding-terminal-local-map))
                (should (= suspend-calls 0))
                (should (eq (window-buffer bottom) wb)))))
        (setq my/study--drag-suspended nil)
        (when (buffer-live-p wb) (kill-buffer wb))))))

(ert-deftest my/test-study-focus-pane-selects-window-and-edit-mode ()
  "Clicking into the Study AI chat input selects its window and toggles edit mode."
  (save-window-excursion
    (set-frame-size (selected-frame) 180 40)
    (delete-other-windows)
    (let* ((left (selected-window))
           (right (split-window-right))
           (wb (generate-new-buffer " *test-study-focus*"))
           (my/study--webkit-buffer wb)
           (edit-state nil))
      (unwind-protect
          (progn
            (set-window-buffer right wb)
            (select-window left)
            (cl-letf (((symbol-function 'xwidget-webkit-edit-mode)
                       (lambda (&optional arg)
                         (setq edit-state (not (eql arg 0)))
                         (setq-local xwidget-webkit-edit-mode edit-state))))
              (my/study--handle-event '((event . "focus_pane") (select . t) (editing . t)))
              (should (eq (selected-window) right))
              (should (eq edit-state t))
              ;; Blur without select leaves left window selected when user switched away.
              (select-window left)
              (my/study--handle-event '((event . "focus_pane") (select) (editing)))
              (should (eq (selected-window) left))
              (should (eq edit-state nil))))
        (when (buffer-live-p wb) (kill-buffer wb))))))

(provide 'emacs-config-tests)
;;; emacs-config-tests.el ends here
