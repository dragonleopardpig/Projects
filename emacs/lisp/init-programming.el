;;; init-programming.el --- Envrc, Magit, LSP-Bridge, Languages & Jupyter -*- lexical-binding: t; -*-

;;; Commentary:
;; Programming environment configuration:
;; - direnv/envrc project isolation & `.devenv' discovery helpers
;; - Magit (<f5>, C-x g), git-messenger, yasnippet, imenu-list (C-c l)
;; - lsp-bridge + flymake-bridge with Nix/devenv Python discovery
;; - Python, Rust, Spice, Common Lisp (sbcl), and Org-Babel language loading
;; - emacs-jupyter, standalone scimax-jupyter kernel selection & REPL safety
;;   advices, `my/jupyter-org-hydra' (C-c j / s-j), `ipynb-to-markdown', `code-cells'

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defgroup my/programming nil
  "Programming tools, LSP, and computational notebook settings."
  :group 'programming)

;;;; Environment & Project PATH (`envrc` + `.devenv` helpers)

(use-package envrc
  :config
  (when (executable-find "direnv")
    (envrc-global-mode 1)))

(dolist (dir '("~/Projects/cpp/.devenv/profile/bin"
               "~/Projects/rust/.devenv/profile/bin"
               "~/Projects/python/.devenv/profile/bin"
               "~/Projects/Kraken-Optical-Simulator/.devenv/profile/bin"
               "~/Projects/org/.devenv/profile/bin"))
  (let ((expanded (expand-file-name dir)))
    (when (file-directory-p expanded)
      (add-to-list 'exec-path expanded)
      (unless (string-match-p (regexp-quote expanded) (or (getenv "PATH") ""))
        (setenv "PATH" (concat expanded path-separator (getenv "PATH")))))))

(defun my/devenv-bin-near (&optional dir)
  "Find the nearest `.devenv' bin directory walking up from DIR."
  (let* ((start (expand-file-name (or dir default-directory)))
         (root (locate-dominating-file
                start
                (lambda (parent)
                  (or (file-directory-p (expand-file-name ".devenv/state/venv/bin" parent))
                      (file-directory-p (expand-file-name ".devenv/profile/bin" parent)))))))
    (when root
      (or (let ((venv-bin (expand-file-name ".devenv/state/venv/bin" root)))
            (and (file-directory-p venv-bin) venv-bin))
          (let ((prof-bin (expand-file-name ".devenv/profile/bin" root)))
            (and (file-directory-p prof-bin) prof-bin))))))

(defun my/devenv-python-near (&optional dir)
  "Find the nearest `.devenv' Python executable walking up from DIR."
  (let* ((start (expand-file-name (or dir default-directory)))
         (root (locate-dominating-file
                start
                (lambda (parent)
                  (cl-some (lambda (rel)
                             (file-executable-p (expand-file-name rel parent)))
                           '(".devenv/state/venv/bin/python"
                             ".devenv/state/venv/bin/python3"
                             ".devenv/profile/bin/python"
                             ".devenv/profile/bin/python3"))))))
    (or (when root
          (cl-loop for rel in '(".devenv/state/venv/bin/python"
                                ".devenv/state/venv/bin/python3"
                                ".devenv/profile/bin/python"
                                ".devenv/profile/bin/python3")
                   for cand = (expand-file-name rel root)
                   when (file-executable-p cand)
                   return cand))
        (executable-find "python3")
        (executable-find "python"))))

;;;; Version Control & Code Navigation (`magit`, `git-messenger`, `imenu-list`, `rg`)

(use-package magit
  :bind (("C-x g" . magit-status)
         ("<f5>" . magit-status)
         ("C-x M-g" . magit-dispatch)
         ("C-c M-g" . magit-file-dispatch)))

(use-package git-messenger
  :bind (("C-x v p" . git-messenger:popup-message)))

(when (locate-library "rg")
  (use-package rg
    :config
    (when (fboundp 'rg-enable-default-bindings)
      (rg-enable-default-bindings))))

(use-package yasnippet
  :config
  (yas-global-mode 1))

(use-package imenu-list
  :bind (("C-c l" . imenu-list-smart-toggle))
  :custom
  (imenu-list-focus-after-activation t)
  (imenu-list-auto-resize t))

;;;; `lsp-bridge' & `flymake-bridge'

(defconst my/lsp-bridge-python-modules
  '("epc" "orjson" "sexpdata" "six" "paramiko" "rapidfuzz" "watchdog" "packaging")
  "Python modules required by `lsp-bridge'.")

(defun my/lsp-bridge-python-valid-p (python-exe)
  "Return non-nil when PYTHON-EXE can import `my/lsp-bridge-python-modules'."
  (and python-exe
       (file-executable-p python-exe)
       (zerop (call-process python-exe nil nil nil
                            "-c" (format "import %s"
                                         (string-join my/lsp-bridge-python-modules ", "))))))

(defun my/lsp-bridge-find-python ()
  "Return a Python executable capable of running `lsp-bridge'."
  (let* ((user (or (getenv "USER") user-login-name))
         (candidates
          (delete-dups
           (delq nil
                 (list (executable-find "lsp-bridge-python")
                       (expand-file-name
                        (format "/etc/profiles/per-user/%s/bin/lsp-bridge-python" user))
                       (executable-find "python3")
                       (my/devenv-python-near)
                       "/run/current-system/sw/bin/python3"
                       (expand-file-name
                        (format "/etc/profiles/per-user/%s/bin/python3" user)))))))
    (or (cl-find-if #'my/lsp-bridge-python-valid-p candidates)
        (car candidates))))

(dolist (rel '("lsp-bridge" "flymake-bridge"))
  (let ((dir (expand-file-name rel user-emacs-directory)))
    (when (file-directory-p dir)
      (add-to-list 'load-path dir))))

(when (locate-library "lsp-bridge")
  (require 'lsp-bridge nil t)
  (when-let* ((py (my/lsp-bridge-find-python)))
    (setq lsp-bridge-python-command py))
  (setq lsp-bridge-enable-hover-diagnostic t
        acm-enable-yas t
        acm-enable-capf t)
  (when (require 'flymake-bridge nil t)
    (add-hook 'lsp-bridge-mode-hook #'flymake-bridge-setup))
  (unless noninteractive
    (when (and (boundp 'lsp-bridge-python-command)
               lsp-bridge-python-command
               (file-executable-p lsp-bridge-python-command)
               (fboundp 'global-lsp-bridge-mode))
      (global-lsp-bridge-mode 1))))

;;;; Languages: Python, Rust, Common Lisp, Spice & RET Indentation

(defun my/prog-ret-indents ()
  "Bind RET in `prog-mode' buffers to `newline-and-indent'."
  (local-set-key (kbd "RET") #'newline-and-indent))

(add-hook 'prog-mode-hook #'my/prog-ret-indents)

(setq inferior-lisp-program "sbcl"
      python-indent-guess-indent-offset nil)

(defun my/python-project-root ()
  "Determine the project root directory for the current Python buffer."
  (expand-file-name
   (or (locate-dominating-file default-directory "pyproject.toml")
       (locate-dominating-file default-directory ".devenv")
       (locate-dominating-file default-directory ".git")
       default-directory)))

(defun my/run-current-python-file ()
  "Run the current Python buffer inside its `.devenv' or `direnv' environment."
  (interactive)
  (unless buffer-file-name
    (user-error "Buffer is not visiting a file"))
  (when (buffer-modified-p)
    (save-buffer))
  (let* ((root (my/python-project-root))
         (file (shell-quote-argument (expand-file-name buffer-file-name)))
         (venv-py (expand-file-name ".devenv/state/venv/bin/python" root))
         (prof-py (expand-file-name ".devenv/profile/bin/python" root))
         (cmd (cond
               ((file-executable-p venv-py)
                (format "%s %s" (shell-quote-argument venv-py) file))
               ((and (executable-find "direnv")
                     (or (file-exists-p (expand-file-name ".envrc" root))
                         (file-directory-p (expand-file-name ".devenv" root))))
                (format "direnv exec %s python %s"
                        (shell-quote-argument root) file))
               ((file-executable-p prof-py)
                (format "%s %s" (shell-quote-argument prof-py) file))
               (t
                (format "%s %s"
                        (shell-quote-argument
                         (or (executable-find "python3") "python"))
                        file))))
         (default-directory root))
    (compile cmd)))

(with-eval-after-load 'python
  (define-key python-mode-map (kbd "C-c C-r") #'my/run-current-python-file)
  (define-key python-mode-map (kbd "C-c C-k") #'my/run-current-python-file)
  (when (boundp 'python-ts-mode-map)
    (define-key python-ts-mode-map (kbd "C-c C-r") #'my/run-current-python-file)
    (define-key python-ts-mode-map (kbd "C-c C-k") #'my/run-current-python-file)))

(when (locate-library "spice-mode")
  (autoload 'spice-mode "spice-mode" "Major mode for SPICE netlists." t)
  (add-to-list 'auto-mode-alist '("\\.\\(cir\\|sp\\|spi\\|spice\\)\\'" . spice-mode)))

;;;; Org-Babel Languages & Jupyter Integration

(defconst my/org-babel-desired-languages
  '((emacs-lisp . t)
    (python . t)
    (shell . t)
    (C . t)
    (lua . t)
    (julia . t)
    (latex . t)
    (lisp . t)
    (nix . t)
    (rust . t)
    (spice . t)
    (jupyter . t))
  "Org-Babel languages loaded automatically when available on `load-path'.")

(with-eval-after-load 'org
  (add-to-list 'org-src-lang-modes
               (cons "rust" (if (fboundp 'rust-ts-mode) 'rust-ts 'rust)))
  (let ((available
         (cl-remove-if-not
          (lambda (pair)
            (or (eq (car pair) 'emacs-lisp)
                (locate-library (format "ob-%s" (car pair)))))
          my/org-babel-desired-languages)))
    (org-babel-do-load-languages 'org-babel-load-languages available)))

;; Jupyter safety advices, `.devenv' kernel selection & scimax-jupyter conveniences
(with-eval-after-load 'jupyter-repl
  (defun my/jupyter-repl-guard-ret (orig-fn &rest args)
    "Prevent errors when pressing RET in empty or unready Jupyter REPL cells."
    (condition-case err
        (apply orig-fn args)
      (user-error (message "%s" (error-message-string err)))
      (error (message "Jupyter REPL warning: %s" (error-message-string err)))))

  (when (fboundp 'jupyter-repl-ret)
    (advice-add 'jupyter-repl-ret :around #'my/jupyter-repl-guard-ret))

  (defun my/jupyter-repl-guard-send (orig-fn &rest args)
    "Guard `jupyter-repl--send-input' if kernel connection is closed."
    (when (and (boundp 'jupyter-current-client) jupyter-current-client)
      (condition-case err
          (apply orig-fn args)
        (error (message "Jupyter send aborted: %s" (error-message-string err))))))

  (when (fboundp 'jupyter-repl--send-input)
    (advice-add 'jupyter-repl--send-input :around #'my/jupyter-repl-guard-send)))

(defvar jupyter-executable)

(defun my/jupyter-find-executable (&optional dir)
  "Locate `jupyter' from `exec-path' or a nearby `.devenv'/`.venv' under DIR."
  (or (executable-find (if (and (boundp 'jupyter-executable)
                                (stringp jupyter-executable))
                           jupyter-executable
                         "jupyter"))
      (let* ((start (expand-file-name (or dir default-directory)))
             (rels '(".devenv/state/venv/bin/jupyter"
                     ".devenv/profile/bin/jupyter"
                     ".venv/bin/jupyter"))
             (root (and (not (file-remote-p start))
                        (locate-dominating-file
                         start
                         (lambda (parent)
                           (cl-some (lambda (rel)
                                      (file-executable-p (expand-file-name rel parent)))
                                    rels))))))
        (when root
          (cl-loop for rel in rels
                   for cand = (expand-file-name rel root)
                   when (file-executable-p cand)
                   return cand)))))

(defun my/jupyter-find-devenv-kernels (&optional dir)
  "Return an alist of available Jupyter kernels from `.devenv' or `jupyter'."
  (let* ((start (expand-file-name (or dir default-directory)))
         (root (locate-dominating-file start ".devenv"))
         (specs nil))
    (when root
      (dolist (rel '(".devenv/state/venv/share/jupyter/kernels"
                     ".devenv/profile/share/jupyter/kernels"))
        (let ((kdir (expand-file-name rel root)))
          (when (file-directory-p kdir)
            (dolist (entry (directory-files kdir t "\\`[^.]"))
              (when (file-directory-p entry)
                (push (cons (file-name-nondirectory entry) entry) specs)))))))
    (when-let* ((jup (my/jupyter-find-executable start)))
      (ignore-errors
        (let* ((out (with-output-to-string
                      (with-current-buffer standard-output
                        (call-process jup nil t nil "kernelspec" "list" "--json"))))
               (parsed (json-parse-string out :object-type 'alist))
               (ks (alist-get 'kernelspecs parsed)))
          (dolist (item ks)
            (let ((name (format "%s" (car item)))
                  (resource (alist-get 'resource_dir (cdr item))))
              (unless (assoc name specs)
                (push (cons name resource) specs)))))))
    (nreverse specs)))

(with-eval-after-load 'ob-jupyter
  (defun my/ob-jupyter-guard-make-local-aliases (orig-fn &rest args)
    "Skip `org-babel-jupyter-make-local-aliases' unless `jupyter' exists."
    (if (file-remote-p default-directory)
        (apply orig-fn args)
      (when-let* ((jup (my/jupyter-find-executable default-directory)))
        (let ((jupyter-executable jup))
          (apply orig-fn args)))))

  (when (fboundp 'org-babel-jupyter-make-local-aliases)
    (advice-add 'org-babel-jupyter-make-local-aliases
                :around #'my/ob-jupyter-guard-make-local-aliases))

  (defun my/ob-jupyter-guard-aliases-from-kernelspecs (orig-fn &optional refresh specs)
    "Skip `jupyter kernelspec' queries when no `jupyter' executable is available."
    (if (or specs (file-remote-p default-directory))
        (funcall orig-fn refresh specs)
      (when-let* ((jup (my/jupyter-find-executable default-directory)))
        (let ((jupyter-executable jup))
          (funcall orig-fn refresh specs)))))

  (when (fboundp 'org-babel-jupyter-aliases-from-kernelspecs)
    (advice-add 'org-babel-jupyter-aliases-from-kernelspecs
                :around #'my/ob-jupyter-guard-aliases-from-kernelspecs))

  (defun my/ob-jupyter-guard-setup-export (orig-fn backend)
    "Skip `org-babel-jupyter-setup-export' when no `jupyter' executable exists."
    (if (file-remote-p default-directory)
        (funcall orig-fn backend)
      (when-let* ((jup (my/jupyter-find-executable default-directory)))
        (let ((jupyter-executable jup))
          (funcall orig-fn backend)))))

  (when (fboundp 'org-babel-jupyter-setup-export)
    (advice-add 'org-babel-jupyter-setup-export
                :around #'my/ob-jupyter-guard-setup-export)))

(with-eval-after-load 'envrc
  (defun my/envrc-refresh-jupyter-aliases (buf result)
    "Refresh `ob-jupyter' aliases in Org buffers once `envrc' activates."
    (when (and (listp result) (buffer-live-p buf))
      (with-current-buffer buf
        (when (and (derived-mode-p 'org-mode)
                   (featurep 'ob-jupyter)
                   (fboundp 'org-babel-jupyter-aliases-from-kernelspecs)
                   (executable-find (if (and (boundp 'jupyter-executable)
                                             (stringp jupyter-executable))
                                        jupyter-executable
                                      "jupyter")))
          (org-babel-jupyter-aliases-from-kernelspecs)))))

  (when (fboundp 'envrc--apply)
    (advice-add 'envrc--apply :after #'my/envrc-refresh-jupyter-aliases)))

(defun my/jupyter-select-kernel ()
  "Select a Jupyter kernel via `completing-read' for the current Org src block."
  (interactive)
  (let* ((kernels (my/jupyter-find-devenv-kernels))
         (names (or (mapcar #'car kernels) '("python3")))
         (choice (completing-read "Jupyter kernel: " names nil nil)))
    (if (and (derived-mode-p 'org-mode)
             (fboundp 'org-in-src-block-p)
             (org-in-src-block-p))
        (save-excursion
          (org-babel-goto-src-block-head)
          (if (re-search-forward ":kernel[ \t]+\\([^ \t\n]+\\)" (line-end-position) t)
              (replace-match choice t t nil 1)
            (goto-char (line-end-position))
            (insert (format " :kernel %s" choice)))
          (message "Set block :kernel to %s" choice))
      (message "Selected kernel: %s (move into an Org src block to apply :kernel)" choice))))

(defun my/jupyter-inspect-at-point ()
  "Inspect symbol at point using `jupyter-inspect-at-point' when available."
  (interactive)
  (if (fboundp 'jupyter-inspect-at-point)
      (call-interactively #'jupyter-inspect-at-point)
    (user-error "`jupyter-inspect-at-point' is not loaded")))

(defun my/jupyter-clear-all-results ()
  "Remove all Org-Babel block results in the current buffer."
  (interactive)
  (if (fboundp 'scimax-ob-clear-all-results)
      (scimax-ob-clear-all-results)
    (org-babel-map-src-blocks nil
      (org-babel-remove-result))))

;;;; Notebook Conversion (`ipynb-to-markdown` & `code-cells`)

(defun ipynb-to-markdown (ipynb-file &optional output-file)
  "Convert Jupyter notebook IPYNB-FILE to Markdown at OUTPUT-FILE."
  (interactive "fNotebook (.ipynb): ")
  (let* ((abs-in (expand-file-name ipynb-file))
         (out (or output-file
                  (concat (file-name-sans-extension abs-in) ".md")))
         (parsed (with-temp-buffer
                   (insert-file-contents abs-in)
                   (goto-char (point-min))
                   (json-parse-buffer :object-type 'alist :array-type 'list)))
         (meta (alist-get 'metadata parsed))
         (lang (or (alist-get 'language (alist-get 'kernelspec meta))
                   (alist-get 'name (alist-get 'language_info meta))
                   "python"))
         (cells (alist-get 'cells parsed))
         (chunks nil))
    (dolist (cell cells)
      (let* ((ctype (alist-get 'cell_type cell))
             (src-raw (alist-get 'source cell))
             (src (if (listp src-raw) (string-join src-raw "") (or src-raw ""))))
        (pcase ctype
          ("markdown"
           (push (string-trim-right src) chunks))
          ("code"
           (push (format "```%s\n%s\n```" lang (string-trim-right src)) chunks)
           (dolist (out-item (alist-get 'outputs cell))
             (let* ((txt-raw (or (alist-get 'text out-item)
                                 (alist-get 'text/plain (alist-get 'data out-item))))
                    (txt (if (listp txt-raw) (string-join txt-raw "") txt-raw)))
               (when (and (stringp txt) (not (string-empty-p (string-trim txt))))
                 (push (format "```text\n%s\n```" (string-trim-right txt)) chunks)))))
          (_
           (push (string-trim-right src) chunks)))))
    (with-temp-file out
      (insert (string-join (nreverse chunks) "\n\n") "\n"))
    (when (called-interactively-p 'interactive)
      (find-file out))
    out))

(use-package code-cells
  :defer t
  :hook ((python-mode . code-cells-mode-maybe)
         (python-ts-mode . code-cells-mode-maybe))
  :config
  (setq code-cells-convert-ipynb-style
        '(("jupytext" "--to" "ipynb")
          ("jupytext" "--to" "py:percent")
          org-mode)))

;;;; Jupyter Hydra (`C-c j` / `s-j` — keeping `<f12>` free for frame transparency)

(with-eval-after-load 'hydra
  (defhydra my/jupyter-org-hydra (:color red :hint nil)
    "
  Jupyter: _e_ exec  _n_ exec+next  _k_ select kernel  _i_ inspect  _r_ REPL  _R_ restart  _I_ interrupt  _c_ clear all  _m_ ipynb->md
"
    ("e" org-ctrl-c-ctrl-c :color blue)
    ("n" scimax-ob-execute-and-next-block)
    ("k" my/jupyter-select-kernel :color blue)
    ("i" my/jupyter-inspect-at-point :color blue)
    ("r" org-babel-switch-to-session :color blue)
    ("R" (when (fboundp 'jupyter-org-restart-kernel)
           (call-interactively #'jupyter-org-restart-kernel)) :color blue)
    ("I" (when (fboundp 'jupyter-org-interrupt-kernel)
           (call-interactively #'jupyter-org-interrupt-kernel)) :color blue)
    ("c" my/jupyter-clear-all-results :color blue)
    ("m" ipynb-to-markdown :color blue)
    ("q" nil))

  (global-set-key (kbd "C-c j") #'my/jupyter-org-hydra/body)
  (global-set-key (kbd "s-j") #'my/jupyter-org-hydra/body))

(provide 'init-programming)
;;; init-programming.el ends here
