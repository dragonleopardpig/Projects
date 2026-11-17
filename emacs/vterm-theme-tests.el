;;; vterm-theme-tests.el --- Terminal theme regression tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'vterm)
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'vterm-theme)
(load (expand-file-name "heaven-and-hell.el" (file-name-directory (or load-file-name buffer-file-name))))

(defmacro my/vterm-test--with-terminal (&rest body)
  "Create a quiet, isolated native terminal for BODY."
  (declare (indent 0) (debug t))
  `(let* ((buffer (generate-new-buffer " *vterm-theme-test*"))
          (vterm-shell (concat (executable-find "bash") " --noprofile --norc"))
          (process-environment (cons "PS1=test> " process-environment)))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer buffer)
           (vterm-mode)
           (accept-process-output (get-buffer-process buffer) 0.1)
           (vterm--write-input vterm--term "\e[2J\e[H")
           (vterm--write-input
            vterm--term
            (mapconcat (lambda (i) (format "DEFAULT-%02d \e[31mANSI\e[0m \e[38;2;18;52;86mRGB\e[0m\r\n" i))
                       (number-sequence 0 (+ (window-body-height) 10)) ""))
           (vterm--delayed-redraw buffer)
           ,@body)
       (when (buffer-live-p buffer)
         (when-let ((process (get-buffer-process buffer)))
           (set-process-query-on-exit-flag process nil)
           (delete-process process))
         (kill-buffer buffer)))))

(defun my/vterm-test--color (word attribute)
  "Return WORD's face colour ATTRIBUTE in the current terminal."
  (save-excursion
    (goto-char (point-min))
    (search-forward word)
    (plist-get (or (get-text-property (match-beginning 0) 'face)
                   (get-text-property (match-beginning 0) 'font-lock-face))
               attribute)))

(ert-deftest my-test-vterm-theme-preserves-text-process-and-truecolor ()
  "Recolour default and ANSI cells throughout scrollback without touching RGB."
  (let ((default-face (face-all-attributes 'default))
        (red-face (face-all-attributes 'vterm-color-red)))
    (unwind-protect
        (my/vterm-test--with-terminal
          (let* ((process (get-buffer-process buffer))
                 (text (buffer-substring-no-properties (point-min) (point-max)))
                 (rgb (my/vterm-test--color "RGB" :foreground))
                 (reference (get-text-property 0 'my/vterm-palette-reference
                                                (my/vterm-test--color "DEFAULT" :foreground)))
                 (point (point))
                 (start (window-start))
                 (modified (buffer-modified-p)))
            (should reference)
            (should-not (get-text-property 0 'my/vterm-palette-reference rgb))
            (set-face-attribute 'default nil :foreground "#112233" :background "#ddeeff")
            (set-face-attribute 'vterm-color-red nil :foreground "#bb2233")
            (my/vterm-refresh-theme)
            (should (equal (my/vterm-test--color "DEFAULT" :foreground) "#112233"))
            (should (equal (my/vterm-test--color "DEFAULT" :background) "#ddeeff"))
            (should (equal (my/vterm-test--color "ANSI" :foreground) "#bb2233"))
            (should (equal (my/vterm-test--color "RGB" :foreground) rgb))
            (should (equal text (buffer-substring-no-properties (point-min) (point-max))))
            (should (eq process (get-buffer-process buffer)))
            (should (process-live-p process))
            (should (= point (point)))
            (should (= start (window-start)))
            (should (eq modified (buffer-modified-p)))))
      (dolist (entry `((default . ,default-face) (vterm-color-red . ,red-face)))
        (apply #'set-face-attribute (car entry) nil
               (cl-loop for (attribute . value) in (cdr entry) append (list attribute value)))))))

(ert-deftest my-test-vterm-f4-switches-theme-in-terminal-and-local-map ()
  "F4 reaches the global switcher even in an embedded terminal's copied map."
  (let ((themes custom-enabled-themes)
        (global (lookup-key (current-global-map) (kbd "<f4>")))
        (heaven-and-hell-theme-type 'light)
        (heaven-and-hell-load-theme-no-confirm t)
        (heaven-and-hell-themes '((light . modus-operandi) (dark . modus-vivendi))))
    (unwind-protect
        (my/vterm-test--with-terminal
          (global-set-key (kbd "<f4>") #'heaven-and-hell-toggle-theme)
          (should (member "<f4>" vterm-keymap-exceptions))
          (should (eq (key-binding (kbd "<f4>")) #'heaven-and-hell-toggle-theme))
          (use-local-map (copy-keymap (current-local-map)))
          (dotimes (_ 2)
            (call-interactively (key-binding (kbd "<f4>")))
            (should (derived-mode-p 'vterm-mode))
            (should (equal (my/vterm-test--color "DEFAULT" :foreground)
                           (face-foreground 'default nil t)))
            (should (equal (my/vterm-test--color "DEFAULT" :background)
                           (face-background 'default nil t))))
          (should (eq heaven-and-hell-theme-type 'light)))
      (define-key (current-global-map) (kbd "<f4>") global)
      (mapc #'disable-theme custom-enabled-themes)
      (mapc #'enable-theme (reverse themes)))))

(provide 'vterm-theme-tests)
;;; vterm-theme-tests.el ends here
