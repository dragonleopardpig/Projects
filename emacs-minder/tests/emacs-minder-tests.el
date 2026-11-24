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

(ert-deftest emacs-minder-test-mouse-scroll-and-ctrl-zoom ()
  "Mouse wheel pans view; Ctrl+wheel zooms around pointer."
  (emacs-minder-ensure-module)
  (should (eq (lookup-key emacs-minder-mode-map [wheel-up])
              #'emacs-minder-mouse-scroll-up))
  (should (eq (lookup-key emacs-minder-mode-map [wheel-down])
              #'emacs-minder-mouse-scroll-down))
  (should (eq (lookup-key emacs-minder-mode-map [mouse-4])
              #'emacs-minder-mouse-scroll-up))
  (should (eq (lookup-key emacs-minder-mode-map [mouse-5])
              #'emacs-minder-mouse-scroll-down))
  (should (eq (lookup-key emacs-minder-mode-map [C-wheel-up])
              #'emacs-minder-mouse-zoom-in))
  (should (eq (lookup-key emacs-minder-mode-map [C-wheel-down])
              #'emacs-minder-mouse-zoom-out))
  (should (eq (lookup-key emacs-minder-mode-map [C-mouse-4])
              #'emacs-minder-mouse-zoom-in))
  (should (eq (lookup-key emacs-minder-mode-map [C-mouse-5])
              #'emacs-minder-mouse-zoom-out))
  (with-temp-buffer
    (setq emacs-minder--handle (emacs-minder-core-new "Scroll Zoom Test"))
    (setq emacs-minder--state (emacs-minder--parse-json
                               (emacs-minder-core-state-json emacs-minder--handle)))
    (let ((orig-y (alist-get 'origin_y emacs-minder--state))
          (orig-scale (alist-get 'scale emacs-minder--state))
          (ev-down (list 'wheel-down (list (selected-window) 1 '(200 . 200) 0)))
          (ev-ctrl-up (list 'C-wheel-up (list (selected-window) 1 '(300 . 250) 0))))
      (emacs-minder-mouse-scroll-down ev-down)
      (should (> (alist-get 'origin_y emacs-minder--state) orig-y))
      (should (< (abs (- (alist-get 'scale emacs-minder--state) orig-scale)) 1e-6))
      (emacs-minder-mouse-zoom-in ev-ctrl-up)
      (should (> (alist-get 'scale emacs-minder--state) orig-scale)))))

(ert-deftest emacs-minder-test-inline-edit-commit-and-cancel ()
  "Inline editor keymap binds RET/S-RET/TAB/ESC and updates handle text."
  (emacs-minder-ensure-module)
  (should (eq (lookup-key emacs-minder-inline-edit-mode-map (kbd "RET"))
              #'emacs-minder-inline-edit-commit))
  (should (eq (lookup-key emacs-minder-inline-edit-mode-map (kbd "S-<return>"))
              #'newline))
  (should (eq (lookup-key emacs-minder-inline-edit-mode-map (kbd "TAB"))
              #'emacs-minder-inline-edit-commit-and-add-child))
  (should (eq (lookup-key emacs-minder-inline-edit-mode-map (kbd "<escape>"))
              #'emacs-minder-inline-edit-cancel))
  (should (eq (lookup-key emacs-minder-inline-edit-mode-map (kbd "C-g"))
              #'emacs-minder-inline-edit-cancel))
  (let ((src (generate-new-buffer " *minder-inline-src*"))
        (edit (generate-new-buffer " *minder-inline-edit*")))
    (unwind-protect
        (progn
          (with-current-buffer src
            (setq emacs-minder--handle (emacs-minder-core-new "Initial Title"))
            (setq emacs-minder--state (emacs-minder--parse-json
                                       (emacs-minder-core-state-json emacs-minder--handle))))
          (with-current-buffer edit
            (insert "Updated $E=mc^2$")
            (emacs-minder-inline-edit-mode)
            (setq emacs-minder--source-buffer src
                  emacs-minder--target-node-id 0
                  emacs-minder--inline-was-new nil)
            (emacs-minder-inline-edit-commit))
          (with-current-buffer src
            (let ((sel (alist-get 'selected emacs-minder--state)))
              (should (equal (alist-get 'text sel) "Updated $E=mc^2$")))))
      (ignore-errors (kill-buffer src))
      (ignore-errors (kill-buffer edit)))))

(ert-deftest emacs-minder-test-drag-move-and-resize ()
  "Left-drag moves nodes freely and edge-handle drag resizes node width."
  (emacs-minder-ensure-module)
  (should (eq (lookup-key emacs-minder-mode-map [down-mouse-1])
              #'emacs-minder--mouse-down-1))
  (should (eq (lookup-key emacs-minder-mode-map [mouse-1])
              #'ignore))
  (should (eq (lookup-key emacs-minder-mode-map [double-down-mouse-1])
              #'emacs-minder--mouse-double-click))
  (should (eq (lookup-key emacs-minder-mode-map [double-mouse-1])
              #'ignore))
  (should (eq (lookup-key emacs-minder-mode-map (kbd "C-S-<left>"))
              #'emacs-minder-narrow-node))
  (should (eq (lookup-key emacs-minder-mode-map (kbd "C-S-<right>"))
              #'emacs-minder-widen-node))
  (with-temp-buffer
    (setq emacs-minder--handle (emacs-minder-core-new "Root"))
    (emacs-minder--cmd
     '((op . "add_child")
       (text . "A long optical sentence that wraps into multiple lines when the node width is narrow.")))
    (emacs-minder--cmd '((op . "zoom_reset")))
    (let* ((st0 emacs-minder--state)
           (sel0 (alist-get 'selected st0))
           (cid (alist-get 'id sel0))
           (ox (alist-get 'origin_x st0))
           (oy (alist-get 'origin_y st0))
           (scale (alist-get 'scale st0))
           (nx (alist-get 'posx sel0))
           (ny (alist-get 'posy sel0))
           (nw (alist-get 'width sel0))
           (nh (alist-get 'height sel0))
           ;; Click right on the outer edge resizer handle
           (edge-sx (round (* (- (+ nx nw) ox) scale)))
           (edge-sy (round (* (- (+ ny (/ nh 2.0)) oy) scale)))
           (positions-resize (list (cons nil (cons 200 200))
                                   (cons nil (cons 420 200))))
           (unread-resize
            (list (list 'mouse-movement (list (selected-window) 1 (cons 420 200) 0))
                  (list 'mouse-1 (list (selected-window) 1 (cons 420 200) 0)))))
      (let ((unread-command-events unread-resize))
        (cl-letf (((symbol-function 'mouse-pixel-position)
                   (lambda () (or (pop positions-resize) (cons nil (cons 420 200))))))
          (emacs-minder--mouse-down-1
           (list 'down-mouse-1 (list (selected-window) 1 (cons edge-sx edge-sy) 0)))))
      (let* ((sel1 (alist-get 'selected emacs-minder--state))
             (wide-w (alist-get 'width sel1))
             (wide-h (alist-get 'height sel1)))
        (should (> wide-w (+ nw 150.0)))
        (should (< wide-h nh))
        ;; Single undo reverts resize back to original size
        (emacs-minder-undo)
        (let ((sel-u (alist-get 'selected emacs-minder--state)))
          (should (< (abs (- (alist-get 'width sel-u) nw)) 1.0))))
      ;; Now drag node body free-move
      (emacs-minder--cmd '((op . "zoom_reset")))
      (let* ((st2 emacs-minder--state)
             (sel2 (alist-get 'selected st2))
             (ox2 (alist-get 'origin_x st2))
             (oy2 (alist-get 'origin_y st2))
             (sc2 (alist-get 'scale st2))
             (nx2 (alist-get 'posx sel2))
             (ny2 (alist-get 'posy sel2))
             (nw2 (alist-get 'width sel2))
             (nh2 (alist-get 'height sel2))
             (mid-sx (round (* (- (+ nx2 (/ nw2 2.0)) ox2) sc2)))
             (mid-sy (round (* (- (+ ny2 (/ nh2 2.0)) oy2) sc2)))
             (positions-move (list (cons nil (cons 300 300))
                                   (cons nil (cons 380 350))))
             (unread-move
              (list (list 'mouse-movement (list (selected-window) 1 (cons 380 350) 0))
                    (list 'mouse-1 (list (selected-window) 1 (cons 380 350) 0)))))
        (let ((unread-command-events unread-move))
          (cl-letf (((symbol-function 'mouse-pixel-position)
                     (lambda () (or (pop positions-move) (cons nil (cons 380 350))))))
            (emacs-minder--mouse-down-1
             (list 'down-mouse-1 (list (selected-window) 1 (cons mid-sx mid-sy) 0)))))
        (let* ((sel3 (alist-get 'selected emacs-minder--state))
               (moved-x (alist-get 'posx sel3))
               (moved-y (alist-get 'posy sel3)))
          (should (equal (alist-get 'id sel3) cid))
          (should (< (abs (- (- moved-x nx2) (/ 80.0 sc2))) 1.0))
          (should (< (abs (- (- moved-y ny2) (/ 50.0 sc2))) 1.0))
          ;; Single undo restores pre-drag position
          (emacs-minder-undo)
          (let ((sel4 (alist-get 'selected emacs-minder--state)))
            (should (< (abs (- (alist-get 'posx sel4) nx2)) 1.0))
            (should (< (abs (- (alist-get 'posy sel4) ny2)) 1.0))))))))

(ert-deftest emacs-minder-test-fast-drag-core-api ()
  "Fast layer-cached drag core subrs (`drag-begin/step/end') handle pan, move, resize."
  (emacs-minder-ensure-module)
  (should (fboundp 'emacs-minder-core-drag-begin))
  (should (fboundp 'emacs-minder-core-drag-step))
  (should (fboundp 'emacs-minder-core-drag-end))
  (pcase-let ((`(,rw ,rh ,dscale) (emacs-minder--drag-dimensions 1920 1080)))
    (should (< rw 1920))
    (should (< rh 1080))
    (should (> dscale 1.0)))
  (with-temp-buffer
    (setq emacs-minder--handle (emacs-minder-core-new "Drag Core"))
    (emacs-minder--cmd '((op . "add_child") (text . "Long draggable child box for smooth testing")))
    (emacs-minder--cmd '((op . "zoom_reset")))
    (let* ((st0 emacs-minder--state)
           (sel0 (alist-get 'selected st0))
           (cid (alist-get 'id sel0))
           (orig-x (alist-get 'posx sel0))
           (orig-w (alist-get 'width sel0)))
      ;; Pan via core drag subrs
      (should (emacs-minder-core-drag-begin emacs-minder--handle "pan" nil t 960 540 640 360))
      (let ((png (emacs-minder-core-drag-step emacs-minder--handle -40.0 20.0 0.0 960 540 640 360)))
        (should (string-prefix-p "\x89PNG\r\n\x1a\n" png)))
      (let ((st1 (emacs-minder--parse-json (emacs-minder-core-drag-end emacs-minder--handle))))
        (should (< (abs (- (alist-get 'origin_x st1) (- (alist-get 'origin_x st0) 40.0))) 1e-6)))
      ;; Move via core drag subrs + single-step undo
      (should (emacs-minder-core-drag-begin emacs-minder--handle "move" cid t 960 540 640 360))
      (let ((png (emacs-minder-core-drag-step emacs-minder--handle 75.0 30.0 0.0 960 540 640 360)))
        (should (string-prefix-p "\x89PNG\r\n\x1a\n" png)))
      (let ((st2 (emacs-minder--parse-json (emacs-minder-core-drag-end emacs-minder--handle))))
        (should (< (abs (- (alist-get 'posx (alist-get 'selected st2)) (+ orig-x 75.0))) 1e-6)))
      (emacs-minder-undo)
      (should (< (abs (- (alist-get 'posx (alist-get 'selected emacs-minder--state)) orig-x)) 1e-6))
      ;; Resize via core drag subrs + single-step undo
      (should (emacs-minder-core-drag-begin emacs-minder--handle "resize" cid t 960 540 640 360))
      (let ((png (emacs-minder-core-drag-step emacs-minder--handle 0.0 0.0 420.0 960 540 640 360)))
        (should (string-prefix-p "\x89PNG\r\n\x1a\n" png)))
      (let ((st3 (emacs-minder--parse-json (emacs-minder-core-drag-end emacs-minder--handle))))
        (should (> (alist-get 'width (alist-get 'selected st3)) 400.0)))
      (emacs-minder-undo)
      (should (< (abs (- (alist-get 'width (alist-get 'selected emacs-minder--state)) orig-w)) 1.0)))))

(ert-deftest emacs-minder-test-smooth-wheel-api ()
  "Fast wheel pan/zoom core subrs and eased scroll ticks work cleanly."
  (emacs-minder-ensure-module)
  (should (fboundp 'emacs-minder-core-pan-fast))
  (should (fboundp 'emacs-minder-core-zoom-fast))
  (with-temp-buffer
    (setq emacs-minder--handle (emacs-minder-core-new "Wheel Smooth"))
    (emacs-minder--cmd '((op . "add_child") (text . "Node A")))
    (emacs-minder--cmd '((op . "zoom_reset")))
    (unwind-protect
        (let* ((st0 emacs-minder--state)
               (ox0 (alist-get 'origin_x st0))
               (oy0 (alist-get 'origin_y st0))
               (sc0 (alist-get 'scale st0))
               (p-pan (emacs-minder-core-pan-fast emacs-minder--handle 0.0 90.0 960 540 640 360)))
          (should (string-prefix-p "\x89PNG\r\n\x1a\n" p-pan))
          (let ((st1 (emacs-minder--parse-json (emacs-minder-core-state-json emacs-minder--handle))))
            (should (< (abs (- (alist-get 'origin_y st1) (+ oy0 (/ 90.0 sc0)))) 1e-6))
            (should (< (abs (- (alist-get 'origin_x st1) ox0)) 1e-6)))
          (let ((p-zoom (emacs-minder-core-zoom-fast emacs-minder--handle 1.15 480.0 270.0 960 540 640 360)))
            (should (string-prefix-p "\x89PNG\r\n\x1a\n" p-zoom)))
          (let ((st2 (emacs-minder--parse-json (emacs-minder-core-state-json emacs-minder--handle))))
            (should (> (alist-get 'scale st2) sc0)))
          ;; Eased scroll tick decrements remaining delta and updates display image
          (setq emacs-minder--scroll-rem-x 0.0
                emacs-minder--scroll-rem-y 60.0)
          (emacs-minder--scroll-tick (current-buffer))
          (should (< emacs-minder--scroll-rem-y 60.0))
          (should (eq (car-safe (get-text-property (point-min) 'display)) 'image)))
      (emacs-minder--cancel-smooth-timers))))

(provide 'emacs-minder-tests)
;;; emacs-minder-tests.el ends here
