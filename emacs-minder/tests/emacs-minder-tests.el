;;; emacs-minder-tests.el --- ERT tests for emacs-minder -*- lexical-binding: t; -*-

(require 'ert)

(let* ((root (file-name-directory
              (directory-file-name
               (file-name-directory (or load-file-name buffer-file-name)))))
       (lisp-dir (expand-file-name "lisp" root)))
  (add-to-list 'load-path lisp-dir))

(require 'emacs-minder)

(ert-deftest emacs-minder-test-module-loads ()
  "Dynamic module loads and provides `emacs-minder-core'."
  (emacs-minder-ensure-module)
  (should (featurep 'emacs-minder-core))
  (should (fboundp 'emacs-minder-core-new))
  (should (fboundp 'emacs-minder-core-render-png)))

(ert-deftest emacs-minder-test-new-command-and-render ()
  "In-memory document commands and PNG rendering work cleanly."
  (emacs-minder-ensure-module)
  (let* ((h (emacs-minder-core-new "Optics Root"))
         (st1 (emacs-minder--parse-json
               (emacs-minder-core-command h (json-encode '((op . "add_child") (text . "Snell Law"))))))
         (png (emacs-minder-core-render-png h 640 420)))
    (should (= 2 (alist-get 'node_count st1)))
    (should (> (length png) 200))
    (should (string-prefix-p "\x89PNG\r\n\x1a\n" png))
    (should (equal (alist-get 'kind
                              (emacs-minder--parse-json
                               (emacs-minder-core-hit-test h 10 10)))
                   "none"))))

(ert-deftest emacs-minder-test-org-roundtrip ()
  "Opening, editing, saving, and reopening an Org file works natively."
  (emacs-minder-ensure-module)
  (let* ((tmp (make-temp-file "minder-test-" nil ".org"))
         (_ (with-temp-file tmp
              (insert "#+TITLE: Test Map\n\n* Alpha :physics:\n  - Wave :: \\(k = 2\\pi/\\lambda\\)\n* TODO Beta\n")))
         (h (emacs-minder-core-open-file tmp))
         (st (emacs-minder--parse-json (emacs-minder-core-state-json h)))
         (out-tmp (make-temp-file "minder-test-out-" nil ".org")))
    (unwind-protect
        (progn
          (should (>= (alist-get 'node_count st) 4))
          (emacs-minder-core-command h (json-encode '((op . "select_node") (id . 0))))
          (emacs-minder-core-command h (json-encode '((op . "add_child") (text . "Gamma"))))
          (should (emacs-minder-core-save-file h out-tmp))
          (with-temp-buffer
            (insert-file-contents out-tmp)
            (should (string-match-p "#\\+TITLE: Test Map" (buffer-string)))
            (should (string-match-p "\\* Alpha :physics:" (buffer-string)))
            (should (string-match-p "\\* TODO Beta" (buffer-string)))
            (should (string-match-p "\\* Gamma" (buffer-string)))))
      (ignore-errors (delete-file tmp))
      (ignore-errors (delete-file out-tmp)))))

(ert-deftest emacs-minder-test-real-fixtures-and-mode ()
  "Open real user Formula.minder and optics.org fixtures when present."
  (emacs-minder-ensure-module)
  (let ((formula "/home/thinky/Projects/Kraken-Optical-Simulator/attachment/Formula.minder")
        (optics "/home/thinky/Projects/org/optics.org"))
    (when (file-exists-p formula)
      (let* ((h (emacs-minder-core-open-file formula))
             (st (emacs-minder--parse-json (emacs-minder-core-state-json h)))
             (png (emacs-minder-core-render-png h 800 500)))
        (should (> (alist-get 'node_count st) 100))
        (should (string-prefix-p "\x89PNG\r\n\x1a\n" png))))
    (when (file-exists-p optics)
      (let* ((h (emacs-minder-core-open-file optics))
             (st (emacs-minder--parse-json (emacs-minder-core-state-json h)))
             (png (emacs-minder-core-render-png h 800 500)))
        (should (> (alist-get 'node_count st) 30))
        (should (string-prefix-p "\x89PNG\r\n\x1a\n" png))))))

(ert-deftest emacs-minder-test-middle-mouse-pan ()
  "Middle mouse button binds live panning and updates origin on drag."
  (emacs-minder-ensure-module)
  (should (eq (lookup-key emacs-minder-mode-map [down-mouse-2])
              #'emacs-minder--mouse-pan-track))
  (should (eq (lookup-key emacs-minder-mode-map [mouse-2])
              #'ignore))
  (should (eq (lookup-key emacs-minder-mode-map [drag-mouse-2])
              #'emacs-minder--mouse-drag-pan))
  (with-temp-buffer
    (setq emacs-minder--handle (emacs-minder-core-new "Pan Test"))
    (setq emacs-minder--state (emacs-minder--parse-json
                               (emacs-minder-core-state-json emacs-minder--handle)))
    (let* ((orig-x (alist-get 'origin_x emacs-minder--state))
           (orig-y (alist-get 'origin_y emacs-minder--state))
           (scale (alist-get 'scale emacs-minder--state))
           (positions (list (cons nil (cons 100 100))
                            (cons nil (cons 160 140))))
           (unread-command-events
            (list (list 'mouse-movement (list (selected-window) 1 '(160 . 140) 0))
                  (list 'mouse-2 (list (selected-window) 1 '(160 . 140) 0)))))
      (cl-letf (((symbol-function 'mouse-pixel-position)
                 (lambda () (or (pop positions) (cons nil (cons 160 140))))))
        (emacs-minder--mouse-pan-track
         (list 'down-mouse-2 (list (selected-window) 1 '(100 . 100) 0))))
      (let ((new-x (alist-get 'origin_x emacs-minder--state))
            (new-y (alist-get 'origin_y emacs-minder--state)))
        (should (< (abs (- (- new-x orig-x) (/ -60.0 scale))) 1e-6))
        (should (< (abs (- (- new-y orig-y) (/ -40.0 scale))) 1e-6))
        (should (null unread-command-events))))))

(provide 'emacs-minder-tests)
;;; emacs-minder-tests.el ends here
