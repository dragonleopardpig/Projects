;;; strata-dirvish.el --- Full Strata file manager integration for Emacs Dirvish -*- lexical-binding: t; -*-

;;; Commentary:
;; Entry point wiring all Strata-Dirvish modules into Dirvish, Dashboard,
;; Noctalia/active Emacs themes, and Dired live file watching.

;;; Code:

(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))

(require 'cl-lib)
(require 'dired)
(require 'dirvish)
(require 'strata-dirvish-prefs)
(require 'strata-dirvish-devices)
(require 'strata-dirvish-views)
(require 'strata-dirvish-panes)
(require 'strata-dirvish-previews)
(require 'strata-dirvish-search)
(require 'strata-dirvish-ops)
(require 'strata-dirvish-keys)

(defun strata-dirvish--sync-auto-revert ()
  "Disable Dired auto-revert and notify watches on FUSE/cloud/remote mounts."
  (if (and default-directory (strata-path-unsafe-probe-p default-directory))
      (setq-local dired-auto-revert-buffer nil
                  auto-revert-use-notify nil)
    (kill-local-variable 'dired-auto-revert-buffer)
    (kill-local-variable 'auto-revert-use-notify)))

(defun strata-dirvish--enable-in-browser ()
  "Enable `strata-dirvish-mode' in Strata/Dirvish browser buffers cleanly."
  (strata-dirvish--sync-auto-revert)
  (when (and (derived-mode-p 'strata-compact-mode 'strata-icons-mode)
             (fboundp 'strata--enforce-no-wrap))
    (strata--enforce-no-wrap))
  (when (derived-mode-p 'dired-mode)
    (when (bound-and-true-p hl-line-mode)
      (hl-line-mode -1))
    (add-hook 'post-command-hook #'strata-view--update-selection-highlight nil t)
    (add-hook 'dired-after-readin-hook #'strata-view--update-selection-highlight nil t)
    (strata-view--update-selection-highlight))
  (unless (strata-terminal-focused-p)
    (strata-dirvish-mode 1)))

(defun strata-dirvish-launch (&optional dir)
  "Launch or focus the Strata-enhanced Dirvish file browser (`C-c d').
When called from `*dashboard*', honors `restore-tabs' and opens `~/' (or last
valid saved tab) along with the collapsible Strata Sidebar if enabled.
Always falls back to `~/' when the target or saved directory does not exist."
  (interactive)
  (strata-tabs-load)
  (when strata-workspace-tabs
    (setq strata-workspace-tabs
          (cl-remove-if-not
           (lambda (tab) (strata-valid-location-p (strata-tab-state-dir tab)))
           strata-workspace-tabs))
    (setq strata-active-tab-index
          (if strata-workspace-tabs
              (max 0 (min strata-active-tab-index
                          (1- (length strata-workspace-tabs))))
            0)))
  (let* ((home (expand-file-name "~/"))
         (from-dash (string= (buffer-name) "*dashboard*"))
         (tab-dir (and from-dash
                       strata-workspace-tabs
                       (strata-tab-state-dir (strata-active-tab))))
         (candidate (cond
                     (dir dir)
                     (from-dash tab-dir)
                     (t default-directory)))
         (target (if (strata-valid-location-p candidate) candidate home)))
    (strata-open-location target t)))

(defun strata-dirvish-launch-computer ()
  "Open Strata `computer:///' virtual view."
  (interactive)
  (strata-open-location "computer:///" t))

(defun strata-dirvish-launch-trash ()
  "Open Strata `trash:///' virtual view."
  (interactive)
  (strata-open-location "trash:///" t))

(defun strata-dirvish-launch-recent ()
  "Open Strata `recent:///' virtual view."
  (interactive)
  (strata-open-location "recent:///" t))

(defun strata-dirvish--save-tabs-on-exit ()
  "Persist Strata workspace tabs on interactive Emacs exit."
  (unless noninteractive
    (strata-tabs-save)))

(defun strata-dirvish-dashboard-install ()
  "Blend crisp Strata navigator buttons into Emacs Dashboard."
  (when (boundp 'dashboard-navigator-buttons)
    (setq dashboard-navigator-buttons
          `(((,(strata-icon-glyph 'folder 'strata-header-accent)
              "Files"
              "Open Strata-Dirvish File Browser (C-c d)"
              (lambda (&rest _) (strata-dirvish-launch))
              strata-header-accent "" "")
             (,(strata-icon-glyph 'computer 'strata-crumb-segment)
              "Computer"
              "Open Computer Drives & Cloud Mounts (computer:///)"
              (lambda (&rest _) (strata-dirvish-launch-computer))
              strata-crumb-segment "" "")
             (,(strata-icon-glyph 'search 'strata-hint-key)
              "Search"
              "Global Recursive Search across Home & Drives (C-k)"
              (lambda (&rest _) (call-interactively #'strata-global-search))
              strata-hint-key "" "")
             (,(strata-icon-glyph 'trash 'shadow)
              "Trash"
              "Open Trash (trash:///)"
              (lambda (&rest _) (strata-dirvish-launch-trash))
              shadow "" "")
             (,(strata-icon-glyph 'recent 'shadow)
              "Recent"
              "Open Recent Files (recent:///)"
              (lambda (&rest _) (strata-dirvish-launch-recent))
              shadow "" "")
             (,(strata-icon-glyph 'gear 'shadow)
              "Prefs"
              "Open Strata Settings & Diagnostics (C-,)"
              (lambda (&rest _) (strata-open-settings))
              shadow "" ""))))))

(defun strata-dirvish--collapse-guard (orig-fn f-name)
  "Skip `dirvish-collapse--cache' for F-NAME on FUSE, cloud, or remote mounts."
  (if (strata-path-unsafe-probe-p f-name)
      '(nil . nil)
    (funcall orig-fn f-name)))

(defvar strata-dirvish--in-sidebar-ensure nil
  "Non-nil while restoring `*Strata Sidebar*' to avoid advice recursion.")

(defvar strata-dirvish--quitting nil
  "Non-nil while `dirvish-quit' is tearing down a Dirvish session.")

(defun strata-dirvish--parent-buffer-filter (buf)
  "Ensure Dirvish Miller-column parent BUF keeps Strata attrs and directory."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when-let ((pdir (car-safe (car-safe dired-subdir-alist))))
        (when (file-directory-p pdir)
          (setq-local default-directory (file-name-as-directory pdir))))
      (dirvish-prop :attrs
        (dirvish--attrs-expand '(strata-icon strata-dir-mouse strata-color)))))
  buf)

(defun strata-dirvish--after-build-layout (&rest _)
  "Ensure `*Strata Sidebar*' stays visible after Dirvish builds or reuses layout."
  (when (and (not strata-dirvish--in-sidebar-ensure)
             (not strata-dirvish--quitting)
             (fboundp 'strata-sidebar-ensure)
             (strata-prefs-sidebar-expanded (strata-prefs))
             (or (ignore-errors (dirvish-curr)) (derived-mode-p 'dired-mode)))
    (let ((strata-dirvish--in-sidebar-ensure t)
          (orig-win (selected-window)))
      (unless (strata-sidebar-ensure)
        (when (fboundp 'strata-sidebar-refresh)
          (strata-sidebar-refresh)))
      (when (window-live-p orig-win)
        (select-window orig-win t)))))

(defun strata-dirvish--around-quit (orig-fn &rest args)
  "Run ORIG-FN with ARGS and close `*Strata Sidebar*' if no browser stays open."
  (let ((strata-dirvish--quitting t))
    (unwind-protect
        (apply orig-fn args)
      (when (and (boundp 'strata-sidebar-window)
                 (window-live-p strata-sidebar-window)
                 (not (cl-some (lambda (w)
                                 (with-current-buffer (window-buffer w)
                                   (or (ignore-errors (dirvish-curr))
                                       (derived-mode-p 'dired-mode
                                                       'strata-compact-mode
                                                       'strata-icons-mode
                                                       'strata-computer-mode
                                                       'strata-trash-mode
                                                       'strata-recent-mode))))
                               (window-list))))
        (delete-window strata-sidebar-window)
        (setq strata-sidebar-window nil))
      (when (and (boundp 'strata-preview-standalone-window)
                 (window-live-p strata-preview-standalone-window)
                 (not (cl-some (lambda (w)
                                 (with-current-buffer (window-buffer w)
                                   (or (ignore-errors (dirvish-curr))
                                       (derived-mode-p 'dired-mode
                                                       'strata-compact-mode
                                                       'strata-icons-mode
                                                       'strata-computer-mode
                                                       'strata-trash-mode
                                                       'strata-recent-mode))))
                               (window-list))))
        (delete-window strata-preview-standalone-window)
        (setq strata-preview-standalone-window nil)))))

(defun strata-dirvish--dirview-setup ()
  "Ensure `dirvish-directory-view-mode' panes expose Strata icons & clickable dirs."
  (unless (dirvish-prop :attrs)
    (dirvish-prop :attrs
      (dirvish--attrs-expand '(strata-icon strata-dir-mouse strata-color)))))

(defun strata-dirvish--on-frame-created (&optional frame)
  "Refresh Strata icon font cache and dashboard buttons when GUI FRAME opens."
  (let ((fr (or frame (selected-frame))))
    (when (display-graphic-p fr)
      (setq strata-icon--family-cache nil)
      (with-selected-frame fr
        (strata-sync-theme-faces)
        (strata-dirvish-dashboard-install)
        (when (fboundp 'strata-sidebar-refresh)
          (strata-sidebar-refresh))))))

(defun strata-dirvish-setup ()
  "Configure Dirvish, hooks, theme blending, and Dashboard integration."
  (let ((p (strata-prefs)))
    (strata-history-load)
    (strata-sync-theme-faces)
    (when (fboundp 'customize-set-variable)
      (ignore-errors (customize-set-variable 'dirvish-subtree-state-style 'arrow)))
    (setq dired-listing-switches (strata-compute-dired-switches p)
          dirvish-default-layout '(1 0.14 0.48)
          dirvish-use-header-line 'global
          dirvish-attributes
          '(strata-icon strata-dir-mouse strata-color strata-size strata-time
            vc-state subtree-state)
          dirvish-preview-dispatchers
          '(strata-mount-guard strata-rich-image strata-rich-pdf strata-rich-document
            image gif video audio epub pdf archive)
          dirvish-header-line-format '(:left (strata-breadcrumb) :right (strata-view-info))
          dirvish-mode-line-format '(:left (strata-footer) :right (sort omit yank index)))
    (when (boundp 'dirvish-directory-view-mode-map)
      (define-key dirvish-directory-view-mode-map (kbd "<mouse-1>") #'strata-mouse-click-entry)
      (define-key dirvish-directory-view-mode-map (kbd "<mouse-2>") #'strata-mouse-activate-at-event)
      (define-key dirvish-directory-view-mode-map (kbd "<double-mouse-1>") #'strata-mouse-activate-at-event))
    (add-hook 'dirvish-directory-view-mode-hook #'strata-dirvish--dirview-setup)
    (when (fboundp 'dirvish--create-parent-buffer)
      (advice-add 'dirvish--create-parent-buffer :filter-return #'strata-dirvish--parent-buffer-filter))
    (when (fboundp 'dirvish--build-layout)
      (advice-add 'dirvish--build-layout :after #'strata-dirvish--after-build-layout))
    (when (fboundp 'dirvish--try-reuse)
      (advice-add 'dirvish--try-reuse :after #'strata-dirvish--after-build-layout))
    (when (fboundp 'dirvish-quit)
      (advice-add 'dirvish-quit :around #'strata-dirvish--around-quit))
    (with-eval-after-load 'dirvish-collapse
      (advice-add 'dirvish-collapse--cache :around #'strata-dirvish--collapse-guard))
    (dolist (hook '(dired-mode-hook
                    strata-compact-mode-hook
                    strata-icons-mode-hook
                    strata-computer-mode-hook
                    strata-trash-mode-hook
                    strata-recent-mode-hook))
      (add-hook hook #'strata-dirvish--enable-in-browser))
    (add-hook 'dired-after-readin-hook #'strata-dirvish--sync-auto-revert)
    (add-hook 'after-make-frame-functions #'strata-dirvish--on-frame-created)
    (add-hook 'server-after-make-frame-hook #'strata-dirvish--on-frame-created)
    (add-hook 'kill-emacs-hook #'strata-media-stop)
    (remove-hook 'kill-emacs-hook #'strata-tabs-save)
    (add-hook 'kill-emacs-hook #'strata-dirvish--save-tabs-on-exit)
    (with-eval-after-load 'dashboard
      (strata-dirvish-dashboard-install))
    (when (featurep 'dashboard)
      (strata-dirvish-dashboard-install))))

(provide 'strata-dirvish)
;;; strata-dirvish.el ends here
