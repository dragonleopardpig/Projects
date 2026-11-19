;;; enhanced-dirvish-windows.el --- Contain browser layouts in Emacs windows -*- lexical-binding: t; -*-

;;; Commentary:
;; A browser is an atomic window subtree: ordinary Emacs splits operate beside
;; the whole browser.  Dirvish's internal splits and rebuilds stay inside it.
;; Window roles survive window-state restoration, including transpose-frame.

;;; Code:

(require 'cl-lib)
(require 'dirvish)
(require 'enhanced-dirvish-panes)

(defvar enhanced-dirvish-preview-standalone-window)

(cl-defstruct (enhanced-dirvish-windows--group (:constructor enhanced-dirvish-windows--new))
  dv directory)

(defvar enhanced-dirvish-windows--changing nil)
(defvar enhanced-dirvish-windows--building nil)
(defvar enhanced-dirvish-windows--build-width nil)
(defvar enhanced-dirvish-windows--transposing nil)

(defun enhanced-dirvish-windows--leaves (&optional root)
  "Return live leaves below ROOT, defaulting to this frame's root."
  (let ((node (or root (frame-root-window))))
    (if (window-live-p node) (list node)
      (cl-loop for child = (window-child node) then (window-next-sibling child)
               while child append (enhanced-dirvish-windows--leaves child)))))

(defun enhanced-dirvish-windows--owned (group &optional frame)
  "Return windows belonging to GROUP on FRAME."
  (cl-remove-if-not
   (lambda (w) (eq (window-parameter w 'enhanced-dirvish-window-group) group))
   (window-list frame 'nomini)))

(defun enhanced-dirvish-windows--ancestor-p (ancestor window)
  "Whether ANCESTOR contains WINDOW."
  (while (and window (not (eq ancestor window)))
    (setq window (window-parent window)))
  (eq ancestor window))

(defun enhanced-dirvish-windows--root (windows)
  "Return the smallest window subtree containing WINDOWS."
  (let ((root (car windows)))
    (dolist (w (cdr windows))
      (while (and root (not (enhanced-dirvish-windows--ancestor-p root w)))
        (setq root (window-parent root))))
    root))

(defun enhanced-dirvish-windows--unatom (node)
  "Clear atomic grouping throughout NODE."
  (when (window-valid-p node)
    (set-window-parameter node 'window-atom nil)
    (cl-loop for child = (window-child node) then (window-next-sibling child)
             while child do (enhanced-dirvish-windows--unatom child))))

(defun enhanced-dirvish-windows--tag (window group role &optional pane)
  "Record GROUP, ROLE and PANE on WINDOW."
  (set-window-parameter window 'enhanced-dirvish-window-group group)
  (set-window-parameter window 'enhanced-dirvish-window-role role)
  (set-window-parameter window 'enhanced-dirvish-window-pane pane))

(defun enhanced-dirvish-windows--pane (window)
  "Find the browser pane associated with WINDOW without creating tabs."
  (or (window-parameter window 'enhanced-dirvish-window-pane)
      (cl-loop for tab in enhanced-dirvish-workspace-tabs
               thereis (cl-find-if
                        (lambda (p) (and p (eq (enhanced-dirvish-pane-state-window p) window)))
                        (list (enhanced-dirvish-tab-state-pane1 tab)
                              (enhanced-dirvish-tab-state-pane2 tab))))))

(defun enhanced-dirvish-windows--session-group (dv)
  "Find DV's visible group on this frame."
  (cl-loop for w in (window-list nil 'nomini)
           for g = (window-parameter w 'enhanced-dirvish-window-group)
           when (and g (eq (enhanced-dirvish-windows--group-dv g) dv)) return g))

(defun enhanced-dirvish-windows--browser-p (window)
  "Whether WINDOW displays a main browser buffer."
  (with-current-buffer (window-buffer window)
    (derived-mode-p 'dired-mode 'enhanced-dirvish-compact-mode 'enhanced-dirvish-icons-mode
                    'enhanced-dirvish-computer-mode 'enhanced-dirvish-trash-mode 'enhanced-dirvish-recent-mode
                    'enhanced-dirvish-network-mode)))

(defun enhanced-dirvish-windows--register (&rest _)
  "Register the active browser and any standalone preview."
  (unless enhanced-dirvish-windows--changing
    (let ((w (selected-window)))
      (when (enhanced-dirvish-windows--browser-p w)
        (let* ((g (or (window-parameter w 'enhanced-dirvish-window-group)
                      (enhanced-dirvish-windows--new :dv (dirvish-curr))))
               (pane (enhanced-dirvish-windows--pane w)))
          (enhanced-dirvish-windows--tag w g 'index pane)
          (when (and (boundp 'enhanced-dirvish-preview-standalone-window)
                     (window-live-p enhanced-dirvish-preview-standalone-window))
            (enhanced-dirvish-windows--tag enhanced-dirvish-preview-standalone-window g 'standalone-preview pane))
          (enhanced-dirvish-windows--reconcile))))))

(defun enhanced-dirvish-windows--reconcile (&optional frame)
  "Refresh window references and atomic groups after changes on FRAME."
  (unless enhanced-dirvish-windows--changing
    (with-selected-frame (or frame (selected-frame))
      (let* ((enhanced-dirvish-windows--changing t)
             (windows (window-list nil 'nomini))
             (groups (delq nil (cl-delete-duplicates
                               (mapcar (lambda (w) (window-parameter w 'enhanced-dirvish-window-group))
                                       windows) :test #'eq))))
        (dolist (g groups)
          (let* ((owned (enhanced-dirvish-windows--owned g))
                 (root (enhanced-dirvish-windows--root owned))
                 (dv (enhanced-dirvish-windows--group-dv g)))
            (enhanced-dirvish-windows--unatom root)
            (unless (cl-some (lambda (w) (and (eq (window-parameter w 'enhanced-dirvish-window-role) 'index)
                                             (enhanced-dirvish-windows--browser-p w))) owned)
              ;; C-x b in the main browser window returns it to normal editing.
              (let ((ignore-window-parameters t))
                (enhanced-dirvish-windows--cleanup g t))
              (dolist (w (enhanced-dirvish-windows--owned g)) (enhanced-dirvish-windows--tag w nil nil))
              (when dv
                (setf (dv-curr-layout dv) nil (dv-winconf dv) nil (dv-preview-window dv) nil))
              (setq owned nil root nil))
            ;; Never include an unrelated editor in the browser's atom.
            (when (and root (not (window-live-p root))
                       (equal (length owned) (length (enhanced-dirvish-windows--leaves root))))
              (window-make-atom root))
            (dolist (w owned)
              (let ((pane (window-parameter w 'enhanced-dirvish-window-pane)))
                (pcase (window-parameter w 'enhanced-dirvish-window-role)
                  ('index
                   (when dv (setf (dv-root-window dv) w (dv-winconf dv) nil))
                   (when pane
                     (setf (enhanced-dirvish-pane-state-window pane) w
                           (enhanced-dirvish-pane-state-buffer pane) (window-buffer w))))
                  ('preview (when dv (setf (dv-preview-window dv) w)))
                  ('standalone-preview (setq enhanced-dirvish-preview-standalone-window w))
                  ('sidebar (setq enhanced-dirvish-sidebar-window w))
                  ('terminal
                   (when pane
                     (setf (enhanced-dirvish-pane-state-terminal-buf pane) (window-buffer w)
                           (enhanced-dirvish-pane-state-terminal-open pane) t))))))))
        (dolist (tab enhanced-dirvish-workspace-tabs)
          (dolist (pane (list (enhanced-dirvish-tab-state-pane1 tab) (enhanced-dirvish-tab-state-pane2 tab)))
            (when pane
              (setf (enhanced-dirvish-pane-state-terminal-open pane)
                    (and (buffer-live-p (enhanced-dirvish-pane-state-terminal-buf pane))
                         (not (null (get-buffer-window (enhanced-dirvish-pane-state-terminal-buf pane) t))))))))))))

(defun enhanced-dirvish-windows--delete (window)
  "Delete just WINDOW, preserving other members of its browser group."
  (let ((ignore-window-parameters t)
        (enhanced-dirvish-windows--changing t))
    (delete-window window))
  (enhanced-dirvish-windows--reconcile))

(defun enhanced-dirvish-windows--cleanup (group &optional all)
  "Remove GROUP's layout chrome, or all auxiliaries if ALL is non-nil."
  (dolist (w (enhanced-dirvish-windows--owned group))
    (when (memq (window-parameter w 'enhanced-dirvish-window-role)
                (if all '(parent preview header footer sidebar terminal standalone-preview)
                  '(parent preview header footer)))
      (delete-window w))))

(defun enhanced-dirvish-windows--build (original dv)
  "Build DV with ORIGINAL inside the current browser's subtree."
  (let* ((window (selected-window))
         (existing (enhanced-dirvish-windows--session-group dv))
         (group (or (window-parameter window 'enhanced-dirvish-window-group)
                    existing (enhanced-dirvish-windows--new :dv dv))))
    ;; A standard split initially shows the same buffer in the new editor.
    ;; That clone must not take ownership of the original browser's session.
    (unless (and existing (not (eq (window-parameter window 'enhanced-dirvish-window-group) existing)))
      (let ((enhanced-dirvish-windows--changing t)
            (ignore-window-parameters t)
            (window-combination-limit t))
        (enhanced-dirvish-windows--unatom (enhanced-dirvish-windows--root (enhanced-dirvish-windows--owned group)))
        (enhanced-dirvish-windows--cleanup group)
        (setf (enhanced-dirvish-windows--group-dv group) dv)
        (enhanced-dirvish-windows--tag window group 'index (enhanced-dirvish-windows--pane window))
        (let ((before (window-list nil 'nomini))
              (enhanced-dirvish-windows--building group)
              (enhanced-dirvish-windows--build-width (window-total-width window)))
          (unwind-protect
              (funcall original dv)
            (setf (dv-winconf dv) nil (dv-root-window dv) window)
            (set-window-dedicated-p window nil)
            (dolist (w (cl-set-difference (window-list nil 'nomini) before))
              (enhanced-dirvish-windows--tag
               w group (cond ((eq w (dv-preview-window dv)) 'preview)
                             ((with-current-buffer (window-buffer w)
                                (derived-mode-p 'dirvish-directory-view-mode)) 'parent)
                             ((string-match-p "header" (buffer-name (window-buffer w))) 'header)
                             (t 'footer)))))
          (setf (enhanced-dirvish-windows--group-directory group) default-directory)))
      (enhanced-dirvish-windows--reconcile))))

(defun enhanced-dirvish-windows--delete-others (original &optional window interactive)
  "Scope Dirvish cleanup, forwarding WINDOW and INTERACTIVE to ORIGINAL."
  (unless enhanced-dirvish-windows--building
    (let* ((w (or window (selected-window)))
           (group (window-parameter w 'enhanced-dirvish-window-group))
           (atom (and group (window-atom-root w))))
      (if (and (window-live-p w)
               (with-current-buffer (window-buffer w)
                 (or (bound-and-true-p enhanced-dirvish-preview-edit-mode)
                     (bound-and-true-p enhanced-dirvish-preview-read-mode))))
          ;; A file being read or edited can still be maximized with C-x 1.
          (let ((ignore-window-parameters t) (enhanced-dirvish-windows--changing t))
            (enhanced-dirvish-windows--unatom (frame-root-window (window-frame w)))
            (funcall original window interactive)
            (enhanced-dirvish-windows--tag w nil nil)
            (when-let ((dv (and group (enhanced-dirvish-windows--group-dv group))))
              (setf (dv-curr-layout dv) nil (dv-winconf dv) nil (dv-preview-window dv) nil)))
        (unless (eq atom (frame-root-window (window-frame w)))
          (funcall original window interactive))))))

(defun enhanced-dirvish-windows--display (original buffer alist)
  "Scale Dirvish BUFFER's ALIST to the browser width, using ORIGINAL."
  (when enhanced-dirvish-windows--building
    (setq alist (copy-tree alist))
    (setf (alist-get 'window-width alist)
          (* (- (or (alist-get 'window-width alist) 0.5))
             (/ (float enhanced-dirvish-windows--build-width) (frame-width)))))
  (funcall original buffer alist))

(defun enhanced-dirvish-windows--redisplay (original window)
  "Keep an unowned clone WINDOW from taking over a Dirvish session."
  (let* ((dv (dirvish-curr))
         (g (and dv (enhanced-dirvish-windows--session-group dv))))
    (unless (or enhanced-dirvish-windows--changing
                (and g (not (and (eq (window-parameter window 'enhanced-dirvish-window-group) g)
                                  (eq (window-parameter window 'enhanced-dirvish-window-role) 'index)))))
      (funcall original window))))

(defun enhanced-dirvish-windows--buffer-change (original window)
  "Rebuild only owned browser WINDOW when its directory actually changes."
  (unless enhanced-dirvish-windows--changing
    (with-selected-window window
      (let* ((dv (dirvish-curr))
             (g (and dv (enhanced-dirvish-windows--session-group dv))))
        (unless (and g
                     (or (not (eq (window-parameter window 'enhanced-dirvish-window-group) g))
                         (equal (enhanced-dirvish-windows--group-directory g) default-directory)))
          (funcall original window))))))

(defun enhanced-dirvish-windows--layout-toggle (original)
  "Toggle the managed layout without restoring a frame-wide configuration."
  (let* ((dv (dirvish-curr))
         (g (and dv (enhanced-dirvish-windows--session-group dv))))
    (if (not g) (funcall original)
      (setf (dv-curr-layout dv) (unless (dv-curr-layout dv) (dv-ff-layout dv))
            (dv-preview-hash dv) (dirvish--ht) (dv-parent-hash dv) (dirvish--ht))
      (with-selected-window (dv-root-window dv)
        (dirvish--build-layout dv)))))

(defun enhanced-dirvish-windows--clear (original dv &rest args)
  "Clear DV's own windows while keeping surrounding Emacs editors."
  (when-let ((g (enhanced-dirvish-windows--session-group dv)))
    (let ((enhanced-dirvish-windows--changing t) (ignore-window-parameters t))
      (enhanced-dirvish-windows--unatom (enhanced-dirvish-windows--root (enhanced-dirvish-windows--owned g)))
      (enhanced-dirvish-windows--cleanup g t)
      (dolist (w (enhanced-dirvish-windows--owned g))
        (enhanced-dirvish-windows--tag w nil nil)))
    (setf (dv-winconf dv) nil (dv-curr-layout dv) nil (dv-preview-window dv) nil))
  (apply original dv args))

(defun enhanced-dirvish-windows--split (original &rest args)
  "Let standard splits create a normal editor beside the atomic browser."
  (let* ((w (or (car args) (selected-window)))
         (managed (and (not enhanced-dirvish-windows--changing)
                       (not ignore-window-parameters)
                       (window-parameter w 'enhanced-dirvish-window-group)))
         (window-combination-limit (or managed window-combination-limit))
         (window-min-width (if managed 4 window-min-width))
         (new (apply original args)))
    (when managed
      (enhanced-dirvish-windows--unatom new)
      (enhanced-dirvish-windows--tag new nil nil)
      (set-window-dedicated-p new nil)
      (set-window-parameter new 'no-other-window nil)
      (enhanced-dirvish-windows--reconcile))
    new))

(defun enhanced-dirvish-windows-display-sidebar (buffer width)
  "Display sidebar BUFFER at WIDTH inside the browser's window group."
  (let* ((main (enhanced-dirvish-panes--main-window))
         (g (or (window-parameter main 'enhanced-dirvish-window-group)
                (enhanced-dirvish-windows--new :dv (with-current-buffer (window-buffer main) (dirvish-curr)))))
         (browser (cl-remove-if (lambda (w) (eq (window-parameter w 'enhanced-dirvish-window-role) 'terminal))
                                (enhanced-dirvish-windows--owned g)))
         (root (or (enhanced-dirvish-windows--root browser) main))
         new)
    (enhanced-dirvish-windows--tag main g 'index (enhanced-dirvish-windows--pane main))
    (let ((enhanced-dirvish-windows--changing t) (ignore-window-parameters t)
          (window-combination-limit t) (window-min-width 4))
      (setq new (split-window root (- (min width (max 9 (/ (window-total-width root) 4)))) 'left))
      (set-window-buffer new buffer)
      (set-window-dedicated-p new t)
      (set-window-parameter new 'no-other-window t)
      (enhanced-dirvish-windows--tag new g 'sidebar))
    (enhanced-dirvish-windows--reconcile)
    new))

(defun enhanced-dirvish-windows-display-terminal (main height pane)
  "Create a terminal below MAIN's whole browser at HEIGHT for PANE."
  (let* ((g (or (window-parameter main 'enhanced-dirvish-window-group) (enhanced-dirvish-windows--new)))
         (root (or (enhanced-dirvish-windows--root (enhanced-dirvish-windows--owned g)) main))
         new)
    (enhanced-dirvish-windows--tag main g 'index pane)
    (let ((enhanced-dirvish-windows--changing t) (ignore-window-parameters t)
          (window-combination-limit t))
      (setq new (split-window root (- height) 'below))
      (enhanced-dirvish-windows--tag new g 'terminal pane))
    (enhanced-dirvish-windows--reconcile)
    new))

;;;; Transpose logical browser groups, preserving their internal layout.

(defun enhanced-dirvish-windows--state (node)
  "Capture NODE with a fresh origin for every leaf.
Emacs may retain an older clone-of parameter after restoring a configuration."
  (let ((state (window-state-get node))
        (leaves (enhanced-dirvish-windows--leaves node)))
    (cl-labels ((rebase (tree)
                  (if (eq (car tree) 'leaf)
                      (setf (alist-get 'clone-of (cdr (assq 'parameters tree)))
                            (pop leaves))
                    (dolist (part (cdr tree))
                      (when (and (consp part) (memq (car part) '(leaf hc vc)))
                        (rebase part))))))
      (rebase (cdr state)))
    state))

(defun enhanced-dirvish-windows--remap-overlays (frame origins)
  "Move window-specific overlays from ORIGINS to restored windows on FRAME."
  (dolist (w (window-list frame 'nomini))
    (let ((origin (window-parameter w 'clone-of)))
      (when (memq origin origins)
        (with-current-buffer (window-buffer w)
          (dolist (ov (append (car (overlay-lists)) (cdr (overlay-lists))))
            (when (eq (overlay-get ov 'window) origin)
              (overlay-put ov 'window w))))
        (set-window-parameter w 'clone-of w)))))

(defun enhanced-dirvish-windows--transpose-get (original &optional frame subtree)
  "Capture browser subtrees as logical leaves for transpose-frame ORIGINAL."
  (if (or subtree enhanced-dirvish-windows--transposing
          (not (cl-some (lambda (w) (window-parameter w 'enhanced-dirvish-window-group))
                        (window-list frame 'nomini))))
      (funcall original frame subtree)
    (let* ((root (frame-root-window frame))
           (groups (delq nil (cl-delete-duplicates
                             (mapcar (lambda (w) (window-parameter w 'enhanced-dirvish-window-group))
                                     (window-list frame 'nomini)) :test #'eq)))
           (bundles
            (mapcar
             (lambda (g)
               (let* ((owned (enhanced-dirvish-windows--owned g frame))
                      (all (enhanced-dirvish-windows--root owned)))
                 ;; With no outside editor, transpose the terminal relative to
                 ;; the complete browser.  Otherwise move the whole application.
                 (if (eq all root)
                     (enhanced-dirvish-windows--root
                      (cl-remove-if (lambda (w) (eq (window-parameter w 'enhanced-dirvish-window-role) 'terminal)) owned))
                   all))) groups)))
      (cl-labels
          ((capture (node)
             (if (or (window-live-p node) (memq node bundles))
                 (let* ((leaves (enhanced-dirvish-windows--leaves node))
                        (representative (or (memq (frame-selected-window frame) leaves) leaves))
                        (w (car representative))
                        (leaf (funcall original frame w)))
                   (append leaf
                           (list (list 'enhanced-dirvish-window-state
                                       (enhanced-dirvish-windows--state node)
                                       leaves))))
               (let* ((vertical (window-combination-p node))
                      (size (float (if vertical (window-total-height node) (window-total-width node)))))
                 (cons (and vertical t)
                       (cl-loop for child = (window-child node) then (window-next-sibling child)
                                while child
                                collect (cons (capture child)
                                              (/ (if vertical (window-total-height child) (window-total-width child)) size))))))))
        (capture root)))))

(defun enhanced-dirvish-windows--transpose-set (original config &optional window-or-frame &rest how)
  "Restore CONFIG through ORIGINAL, preserving browser leaves and references."
  (let ((metadata (and (bufferp (car config)) (nth 9 config))))
    (cond
     ;; A single logical browser, without a terminal or outside editor, has
     ;; nothing to transpose.  Keep its columns and horizontal header intact.
     ((and (not enhanced-dirvish-windows--transposing)
           (eq (car-safe metadata) 'enhanced-dirvish-window-state)) nil)
     ((and enhanced-dirvish-windows--transposing (eq (car-safe metadata) 'enhanced-dirvish-window-state))
      (let* ((target (if (windowp window-or-frame) window-or-frame
                       (frame-selected-window window-or-frame)))
             (state (nth 1 metadata))
             (old (nth 2 metadata)))
        (window-state-put state target 'safe)
        (enhanced-dirvish-windows--remap-overlays (window-frame target) old)))
     ((or enhanced-dirvish-windows--transposing
          (not (cl-some (lambda (w) (window-parameter w 'enhanced-dirvish-window-group))
                        (window-list (unless (windowp window-or-frame) window-or-frame) 'nomini))))
      (apply original config window-or-frame how))
     (t
      (let* ((frame (or window-or-frame (selected-frame)))
             (saved (enhanced-dirvish-windows--state (frame-root-window frame)))
             (origins (window-list frame 'nomini))
             (selected (frame-selected-window frame))
             (buffer (window-buffer selected))
             (group (window-parameter selected 'enhanced-dirvish-window-group))
             (role (window-parameter selected 'enhanced-dirvish-window-role))
             (pane (window-parameter selected 'enhanced-dirvish-window-pane))
             failure)
        (let ((enhanced-dirvish-windows--changing t) (enhanced-dirvish-windows--transposing t)
              (ignore-window-parameters t) (window-combination-limit t)
              (window-min-height 1) (window-min-width 4))
          (enhanced-dirvish-windows--unatom (frame-root-window frame))
          (dolist (w (window-list frame 'nomini)) (set-window-dedicated-p w nil))
          (condition-case err
              (apply original config window-or-frame how)
            (error (window-state-put saved (frame-root-window frame) 'safe)
                   (enhanced-dirvish-windows--remap-overlays frame origins)
                   (setq failure err))))
        (enhanced-dirvish-windows--reconcile frame)
        (when failure (signal (car failure) (cdr failure)))
        (when-let ((w (cl-find-if
                       (lambda (w) (and (eq (window-buffer w) buffer)
                                        (eq (window-parameter w 'enhanced-dirvish-window-group) group)
                                        (eq (window-parameter w 'enhanced-dirvish-window-role) role)
                                        (eq (window-parameter w 'enhanced-dirvish-window-pane) pane)))
                       (window-list frame 'nomini))))
          (select-window w)))))))

(defun enhanced-dirvish-windows-install ()
  "Install window containment and transpose-frame integration once."
  (dolist (parameter '(enhanced-dirvish-window-group enhanced-dirvish-window-role enhanced-dirvish-window-pane
                       no-other-window))
    (setf (alist-get parameter window-persistent-parameters) t))
  (dolist (entry '((dirvish--build-layout . enhanced-dirvish-windows--build)
                   (dirvish--display-buffer . enhanced-dirvish-windows--display)
                   (dirvish-layout-toggle . enhanced-dirvish-windows--layout-toggle)
                   (dirvish--clear-session . enhanced-dirvish-windows--clear)
                   (dirvish-pre-redisplay-h . enhanced-dirvish-windows--redisplay)
                   (dirvish-winbuf-change-h . enhanced-dirvish-windows--buffer-change)
                   (delete-other-windows . enhanced-dirvish-windows--delete-others)
                   (split-window . enhanced-dirvish-windows--split)))
    (advice-add (car entry) :around (cdr entry)))
  (dolist (command '(enhanced-dirvish-open-location enhanced-dirvish-switch-view-mode enhanced-dirvish-preview--split-standalone-window))
    (when (fboundp command) (advice-add command :after #'enhanced-dirvish-windows--register)))
  (add-hook 'window-state-change-functions #'enhanced-dirvish-windows--reconcile)
  (with-eval-after-load 'transpose-frame
    (advice-add 'transpose-frame-get-arrangement :around #'enhanced-dirvish-windows--transpose-get)
    (advice-add 'transpose-frame-set-arrangement :around #'enhanced-dirvish-windows--transpose-set)))

(provide 'enhanced-dirvish-windows)
;;; enhanced-dirvish-windows.el ends here
