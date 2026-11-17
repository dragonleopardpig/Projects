;;; strata-dirvish-windows.el --- Contain browser layouts in Emacs windows -*- lexical-binding: t; -*-

;;; Commentary:
;; A browser is an atomic window subtree: ordinary Emacs splits operate beside
;; the whole browser.  Dirvish's internal splits and rebuilds stay inside it.
;; Window roles survive window-state restoration, including transpose-frame.

;;; Code:

(require 'cl-lib)
(require 'dirvish)
(require 'strata-dirvish-panes)

(defvar strata-preview-standalone-window)

(cl-defstruct (strata-windows--group (:constructor strata-windows--new))
  dv directory)

(defvar strata-windows--changing nil)
(defvar strata-windows--building nil)
(defvar strata-windows--build-width nil)
(defvar strata-windows--transposing nil)

(defun strata-windows--leaves (&optional root)
  "Return live leaves below ROOT, defaulting to this frame's root."
  (let ((node (or root (frame-root-window))))
    (if (window-live-p node) (list node)
      (cl-loop for child = (window-child node) then (window-next-sibling child)
               while child append (strata-windows--leaves child)))))

(defun strata-windows--owned (group &optional frame)
  "Return windows belonging to GROUP on FRAME."
  (cl-remove-if-not
   (lambda (w) (eq (window-parameter w 'strata-window-group) group))
   (window-list frame 'nomini)))

(defun strata-windows--ancestor-p (ancestor window)
  "Whether ANCESTOR contains WINDOW."
  (while (and window (not (eq ancestor window)))
    (setq window (window-parent window)))
  (eq ancestor window))

(defun strata-windows--root (windows)
  "Return the smallest window subtree containing WINDOWS."
  (let ((root (car windows)))
    (dolist (w (cdr windows))
      (while (and root (not (strata-windows--ancestor-p root w)))
        (setq root (window-parent root))))
    root))

(defun strata-windows--unatom (node)
  "Clear atomic grouping throughout NODE."
  (when (window-valid-p node)
    (set-window-parameter node 'window-atom nil)
    (cl-loop for child = (window-child node) then (window-next-sibling child)
             while child do (strata-windows--unatom child))))

(defun strata-windows--tag (window group role &optional pane)
  "Record GROUP, ROLE and PANE on WINDOW."
  (set-window-parameter window 'strata-window-group group)
  (set-window-parameter window 'strata-window-role role)
  (set-window-parameter window 'strata-window-pane pane))

(defun strata-windows--pane (window)
  "Find the browser pane associated with WINDOW without creating tabs."
  (or (window-parameter window 'strata-window-pane)
      (cl-loop for tab in strata-workspace-tabs
               thereis (cl-find-if
                        (lambda (p) (and p (eq (strata-pane-state-window p) window)))
                        (list (strata-tab-state-pane1 tab)
                              (strata-tab-state-pane2 tab))))))

(defun strata-windows--session-group (dv)
  "Find DV's visible group on this frame."
  (cl-loop for w in (window-list nil 'nomini)
           for g = (window-parameter w 'strata-window-group)
           when (and g (eq (strata-windows--group-dv g) dv)) return g))

(defun strata-windows--browser-p (window)
  "Whether WINDOW displays a main browser buffer."
  (with-current-buffer (window-buffer window)
    (derived-mode-p 'dired-mode 'strata-compact-mode 'strata-icons-mode
                    'strata-computer-mode 'strata-trash-mode 'strata-recent-mode
                    'strata-network-mode)))

(defun strata-windows--register (&rest _)
  "Register the active browser and any standalone preview."
  (unless strata-windows--changing
    (let ((w (selected-window)))
      (when (strata-windows--browser-p w)
        (let* ((g (or (window-parameter w 'strata-window-group)
                      (strata-windows--new :dv (dirvish-curr))))
               (pane (strata-windows--pane w)))
          (strata-windows--tag w g 'index pane)
          (when (and (boundp 'strata-preview-standalone-window)
                     (window-live-p strata-preview-standalone-window))
            (strata-windows--tag strata-preview-standalone-window g 'standalone-preview pane))
          (strata-windows--reconcile))))))

(defun strata-windows--reconcile (&optional frame)
  "Refresh window references and atomic groups after changes on FRAME."
  (unless strata-windows--changing
    (with-selected-frame (or frame (selected-frame))
      (let* ((strata-windows--changing t)
             (windows (window-list nil 'nomini))
             (groups (delq nil (cl-delete-duplicates
                               (mapcar (lambda (w) (window-parameter w 'strata-window-group))
                                       windows) :test #'eq))))
        (dolist (g groups)
          (let* ((owned (strata-windows--owned g))
                 (root (strata-windows--root owned))
                 (dv (strata-windows--group-dv g)))
            (strata-windows--unatom root)
            (unless (cl-some (lambda (w) (and (eq (window-parameter w 'strata-window-role) 'index)
                                             (strata-windows--browser-p w))) owned)
              ;; C-x b in the main browser window returns it to normal editing.
              (let ((ignore-window-parameters t))
                (strata-windows--cleanup g t))
              (dolist (w (strata-windows--owned g)) (strata-windows--tag w nil nil))
              (when dv
                (setf (dv-curr-layout dv) nil (dv-winconf dv) nil (dv-preview-window dv) nil))
              (setq owned nil root nil))
            ;; Never include an unrelated editor in the browser's atom.
            (when (and root (not (window-live-p root))
                       (equal (length owned) (length (strata-windows--leaves root))))
              (window-make-atom root))
            (dolist (w owned)
              (let ((pane (window-parameter w 'strata-window-pane)))
                (pcase (window-parameter w 'strata-window-role)
                  ('index
                   (when dv (setf (dv-root-window dv) w (dv-winconf dv) nil))
                   (when pane
                     (setf (strata-pane-state-window pane) w
                           (strata-pane-state-buffer pane) (window-buffer w))))
                  ('preview (when dv (setf (dv-preview-window dv) w)))
                  ('standalone-preview (setq strata-preview-standalone-window w))
                  ('sidebar (setq strata-sidebar-window w))
                  ('terminal
                   (when pane
                     (setf (strata-pane-state-terminal-buf pane) (window-buffer w)
                           (strata-pane-state-terminal-open pane) t))))))))
        (dolist (tab strata-workspace-tabs)
          (dolist (pane (list (strata-tab-state-pane1 tab) (strata-tab-state-pane2 tab)))
            (when pane
              (setf (strata-pane-state-terminal-open pane)
                    (and (buffer-live-p (strata-pane-state-terminal-buf pane))
                         (not (null (get-buffer-window (strata-pane-state-terminal-buf pane) t))))))))))))

(defun strata-windows--delete (window)
  "Delete just WINDOW, preserving other members of its browser group."
  (let ((ignore-window-parameters t)
        (strata-windows--changing t))
    (delete-window window))
  (strata-windows--reconcile))

(defun strata-windows--cleanup (group &optional all)
  "Remove GROUP's layout chrome, or all auxiliaries if ALL is non-nil."
  (dolist (w (strata-windows--owned group))
    (when (memq (window-parameter w 'strata-window-role)
                (if all '(parent preview header footer sidebar terminal standalone-preview)
                  '(parent preview header footer)))
      (delete-window w))))

(defun strata-windows--build (original dv)
  "Build DV with ORIGINAL inside the current browser's subtree."
  (let* ((window (selected-window))
         (existing (strata-windows--session-group dv))
         (group (or (window-parameter window 'strata-window-group)
                    existing (strata-windows--new :dv dv))))
    ;; A standard split initially shows the same buffer in the new editor.
    ;; That clone must not take ownership of the original browser's session.
    (unless (and existing (not (eq (window-parameter window 'strata-window-group) existing)))
      (let ((strata-windows--changing t)
            (ignore-window-parameters t)
            (window-combination-limit t))
        (strata-windows--unatom (strata-windows--root (strata-windows--owned group)))
        (strata-windows--cleanup group)
        (setf (strata-windows--group-dv group) dv)
        (strata-windows--tag window group 'index (strata-windows--pane window))
        (let ((before (window-list nil 'nomini))
              (strata-windows--building group)
              (strata-windows--build-width (window-total-width window)))
          (unwind-protect
              (funcall original dv)
            (setf (dv-winconf dv) nil (dv-root-window dv) window)
            (set-window-dedicated-p window nil)
            (dolist (w (cl-set-difference (window-list nil 'nomini) before))
              (strata-windows--tag
               w group (cond ((eq w (dv-preview-window dv)) 'preview)
                             ((with-current-buffer (window-buffer w)
                                (derived-mode-p 'dirvish-directory-view-mode)) 'parent)
                             ((string-match-p "header" (buffer-name (window-buffer w))) 'header)
                             (t 'footer)))))
          (setf (strata-windows--group-directory group) default-directory)))
      (strata-windows--reconcile))))

(defun strata-windows--delete-others (original &optional window)
  "Scope internal Dirvish cleanup without changing ordinary Emacs behavior."
  (unless strata-windows--building
    (let* ((w (or window (selected-window)))
           (group (window-parameter w 'strata-window-group))
           (atom (and group (window-atom-root w))))
      (if (and (window-live-p w)
               (with-current-buffer (window-buffer w)
                 (or (bound-and-true-p strata-preview-edit-mode)
                     (bound-and-true-p strata-preview-read-mode))))
          ;; A file being read or edited can still be maximized with C-x 1.
          (let ((ignore-window-parameters t) (strata-windows--changing t))
            (strata-windows--unatom (frame-root-window (window-frame w)))
            (funcall original window)
            (strata-windows--tag w nil nil)
            (when-let ((dv (and group (strata-windows--group-dv group))))
              (setf (dv-curr-layout dv) nil (dv-winconf dv) nil (dv-preview-window dv) nil)))
        (unless (eq atom (frame-root-window (window-frame w)))
          (funcall original window))))))

(defun strata-windows--display (original buffer alist)
  "Scale Dirvish BUFFER's ALIST to the browser width, using ORIGINAL."
  (when strata-windows--building
    (setq alist (copy-tree alist))
    (setf (alist-get 'window-width alist)
          (* (- (or (alist-get 'window-width alist) 0.5))
             (/ (float strata-windows--build-width) (frame-width)))))
  (funcall original buffer alist))

(defun strata-windows--redisplay (original window)
  "Keep an unowned clone WINDOW from taking over a Dirvish session."
  (let* ((dv (dirvish-curr))
         (g (and dv (strata-windows--session-group dv))))
    (unless (or strata-windows--changing
                (and g (not (and (eq (window-parameter window 'strata-window-group) g)
                                  (eq (window-parameter window 'strata-window-role) 'index)))))
      (funcall original window))))

(defun strata-windows--buffer-change (original window)
  "Rebuild only owned browser WINDOW when its directory actually changes."
  (unless strata-windows--changing
    (with-selected-window window
      (let* ((dv (dirvish-curr))
             (g (and dv (strata-windows--session-group dv))))
        (unless (and g
                     (or (not (eq (window-parameter window 'strata-window-group) g))
                         (equal (strata-windows--group-directory g) default-directory)))
          (funcall original window))))))

(defun strata-windows--layout-toggle (original)
  "Toggle the managed layout without restoring a frame-wide configuration."
  (let* ((dv (dirvish-curr))
         (g (and dv (strata-windows--session-group dv))))
    (if (not g) (funcall original)
      (setf (dv-curr-layout dv) (unless (dv-curr-layout dv) (dv-ff-layout dv))
            (dv-preview-hash dv) (dirvish--ht) (dv-parent-hash dv) (dirvish--ht))
      (with-selected-window (dv-root-window dv)
        (dirvish--build-layout dv)))))

(defun strata-windows--clear (original dv &rest args)
  "Clear DV's own windows while keeping surrounding Emacs editors."
  (when-let ((g (strata-windows--session-group dv)))
    (let ((strata-windows--changing t) (ignore-window-parameters t))
      (strata-windows--unatom (strata-windows--root (strata-windows--owned g)))
      (strata-windows--cleanup g t)
      (dolist (w (strata-windows--owned g))
        (strata-windows--tag w nil nil)))
    (setf (dv-winconf dv) nil (dv-curr-layout dv) nil (dv-preview-window dv) nil))
  (apply original dv args))

(defun strata-windows--split (original &rest args)
  "Let standard splits create a normal editor beside the atomic browser."
  (let* ((w (or (car args) (selected-window)))
         (managed (and (not strata-windows--changing)
                       (not ignore-window-parameters)
                       (window-parameter w 'strata-window-group)))
         (window-combination-limit (or managed window-combination-limit))
         (window-min-width (if managed 4 window-min-width))
         (new (apply original args)))
    (when managed
      (strata-windows--unatom new)
      (strata-windows--tag new nil nil)
      (set-window-dedicated-p new nil)
      (set-window-parameter new 'no-other-window nil)
      (strata-windows--reconcile))
    new))

(defun strata-windows-display-sidebar (buffer width)
  "Display sidebar BUFFER at WIDTH inside the browser's window group."
  (let* ((main (strata-panes--main-window))
         (g (or (window-parameter main 'strata-window-group)
                (strata-windows--new :dv (with-current-buffer (window-buffer main) (dirvish-curr)))))
         (browser (cl-remove-if (lambda (w) (eq (window-parameter w 'strata-window-role) 'terminal))
                                (strata-windows--owned g)))
         (root (or (strata-windows--root browser) main))
         new)
    (strata-windows--tag main g 'index (strata-windows--pane main))
    (let ((strata-windows--changing t) (ignore-window-parameters t)
          (window-combination-limit t) (window-min-width 4))
      (setq new (split-window root (- (min width (max 9 (/ (window-total-width root) 4)))) 'left))
      (set-window-buffer new buffer)
      (set-window-dedicated-p new t)
      (set-window-parameter new 'no-other-window t)
      (strata-windows--tag new g 'sidebar))
    (strata-windows--reconcile)
    new))

(defun strata-windows-display-terminal (main height pane)
  "Create a terminal below MAIN's whole browser at HEIGHT for PANE."
  (let* ((g (or (window-parameter main 'strata-window-group) (strata-windows--new)))
         (root (or (strata-windows--root (strata-windows--owned g)) main))
         new)
    (strata-windows--tag main g 'index pane)
    (let ((strata-windows--changing t) (ignore-window-parameters t)
          (window-combination-limit t))
      (setq new (split-window root (- height) 'below))
      (strata-windows--tag new g 'terminal pane))
    (strata-windows--reconcile)
    new))

;;;; Transpose logical browser groups, preserving their internal layout.

(defun strata-windows--state (node)
  "Capture NODE with a fresh origin for every leaf.
Emacs may retain an older clone-of parameter after restoring a configuration."
  (let ((state (window-state-get node))
        (leaves (strata-windows--leaves node)))
    (cl-labels ((rebase (tree)
                  (if (eq (car tree) 'leaf)
                      (setf (alist-get 'clone-of (cdr (assq 'parameters tree)))
                            (pop leaves))
                    (dolist (part (cdr tree))
                      (when (and (consp part) (memq (car part) '(leaf hc vc)))
                        (rebase part))))))
      (rebase (cdr state)))
    state))

(defun strata-windows--remap-overlays (frame origins)
  "Move window-specific overlays from ORIGINS to restored windows on FRAME."
  (dolist (w (window-list frame 'nomini))
    (let ((origin (window-parameter w 'clone-of)))
      (when (memq origin origins)
        (with-current-buffer (window-buffer w)
          (dolist (ov (append (car (overlay-lists)) (cdr (overlay-lists))))
            (when (eq (overlay-get ov 'window) origin)
              (overlay-put ov 'window w))))
        (set-window-parameter w 'clone-of w)))))

(defun strata-windows--transpose-get (original &optional frame subtree)
  "Capture browser subtrees as logical leaves for transpose-frame ORIGINAL."
  (if (or subtree strata-windows--transposing
          (not (cl-some (lambda (w) (window-parameter w 'strata-window-group))
                        (window-list frame 'nomini))))
      (funcall original frame subtree)
    (let* ((root (frame-root-window frame))
           (groups (delq nil (cl-delete-duplicates
                             (mapcar (lambda (w) (window-parameter w 'strata-window-group))
                                     (window-list frame 'nomini)) :test #'eq)))
           (bundles
            (mapcar
             (lambda (g)
               (let* ((owned (strata-windows--owned g frame))
                      (all (strata-windows--root owned)))
                 ;; With no outside editor, transpose the terminal relative to
                 ;; the complete browser.  Otherwise move the whole application.
                 (if (eq all root)
                     (strata-windows--root
                      (cl-remove-if (lambda (w) (eq (window-parameter w 'strata-window-role) 'terminal)) owned))
                   all))) groups)))
      (cl-labels
          ((capture (node)
             (if (or (window-live-p node) (memq node bundles))
                 (let* ((leaves (strata-windows--leaves node))
                        (representative (or (memq (frame-selected-window frame) leaves) leaves))
                        (w (car representative))
                        (leaf (funcall original frame w)))
                   (append leaf
                           (list (list 'strata-window-state
                                       (strata-windows--state node)
                                       leaves))))
               (let* ((vertical (window-combination-p node))
                      (size (float (if vertical (window-total-height node) (window-total-width node)))))
                 (cons (and vertical t)
                       (cl-loop for child = (window-child node) then (window-next-sibling child)
                                while child
                                collect (cons (capture child)
                                              (/ (if vertical (window-total-height child) (window-total-width child)) size))))))))
        (capture root)))))

(defun strata-windows--transpose-set (original config &optional window-or-frame &rest how)
  "Restore CONFIG through ORIGINAL, preserving browser leaves and references."
  (let ((metadata (and (bufferp (car config)) (nth 9 config))))
    (cond
     ;; A single logical browser, without a terminal or outside editor, has
     ;; nothing to transpose.  Keep its columns and horizontal header intact.
     ((and (not strata-windows--transposing)
           (eq (car-safe metadata) 'strata-window-state)) nil)
     ((and strata-windows--transposing (eq (car-safe metadata) 'strata-window-state))
      (let* ((target (if (windowp window-or-frame) window-or-frame
                       (frame-selected-window window-or-frame)))
             (state (nth 1 metadata))
             (old (nth 2 metadata)))
        (window-state-put state target 'safe)
        (strata-windows--remap-overlays (window-frame target) old)))
     ((or strata-windows--transposing
          (not (cl-some (lambda (w) (window-parameter w 'strata-window-group))
                        (window-list (unless (windowp window-or-frame) window-or-frame) 'nomini))))
      (apply original config window-or-frame how))
     (t
      (let* ((frame (or window-or-frame (selected-frame)))
             (saved (strata-windows--state (frame-root-window frame)))
             (origins (window-list frame 'nomini))
             (selected (frame-selected-window frame))
             (buffer (window-buffer selected))
             (group (window-parameter selected 'strata-window-group))
             (role (window-parameter selected 'strata-window-role))
             (pane (window-parameter selected 'strata-window-pane))
             failure)
        (let ((strata-windows--changing t) (strata-windows--transposing t)
              (ignore-window-parameters t) (window-combination-limit t)
              (window-min-height 1) (window-min-width 4))
          (strata-windows--unatom (frame-root-window frame))
          (dolist (w (window-list frame 'nomini)) (set-window-dedicated-p w nil))
          (condition-case err
              (apply original config window-or-frame how)
            (error (window-state-put saved (frame-root-window frame) 'safe)
                   (strata-windows--remap-overlays frame origins)
                   (setq failure err))))
        (strata-windows--reconcile frame)
        (when failure (signal (car failure) (cdr failure)))
        (when-let ((w (cl-find-if
                       (lambda (w) (and (eq (window-buffer w) buffer)
                                        (eq (window-parameter w 'strata-window-group) group)
                                        (eq (window-parameter w 'strata-window-role) role)
                                        (eq (window-parameter w 'strata-window-pane) pane)))
                       (window-list frame 'nomini))))
          (select-window w)))))))

(defun strata-windows-install ()
  "Install window containment and transpose-frame integration once."
  (dolist (parameter '(strata-window-group strata-window-role strata-window-pane
                       no-other-window))
    (setf (alist-get parameter window-persistent-parameters) t))
  (dolist (entry '((dirvish--build-layout . strata-windows--build)
                   (dirvish--display-buffer . strata-windows--display)
                   (dirvish-layout-toggle . strata-windows--layout-toggle)
                   (dirvish--clear-session . strata-windows--clear)
                   (dirvish-pre-redisplay-h . strata-windows--redisplay)
                   (dirvish-winbuf-change-h . strata-windows--buffer-change)
                   (delete-other-windows . strata-windows--delete-others)
                   (split-window . strata-windows--split)))
    (advice-add (car entry) :around (cdr entry)))
  (dolist (command '(strata-open-location strata-switch-view-mode strata-preview--split-standalone-window))
    (when (fboundp command) (advice-add command :after #'strata-windows--register)))
  (add-hook 'window-state-change-functions #'strata-windows--reconcile)
  (with-eval-after-load 'transpose-frame
    (advice-add 'transpose-frame-get-arrangement :around #'strata-windows--transpose-get)
    (advice-add 'transpose-frame-set-arrangement :around #'strata-windows--transpose-set)))

(provide 'strata-dirvish-windows)
;;; strata-dirvish-windows.el ends here
