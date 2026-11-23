;;; emacs-config-tests.el --- Standalone Emacs 31 configuration ERT suite -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with:
;;   emacs --batch -Q -l /home/thinky/Projects/emacs/emacs-config-tests.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)

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
  (with-temp-buffer
    (org-mode)
    (should (eq (key-binding (kbd "C-c E")) #'my/editmarks-hydra/body))
    (should (eq (key-binding (kbd "C-c b")) #'scimax-ob/body))))

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

(provide 'emacs-config-tests)
;;; emacs-config-tests.el ends here
