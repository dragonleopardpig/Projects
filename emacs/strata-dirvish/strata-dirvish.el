;;; strata-dirvish.el --- Full Strata file manager integration for Emacs Dirvish -*- lexical-binding: t; -*-

;;; Commentary:
;; Entry point wiring all Strata-Dirvish modules into Dirvish, Dashboard,
;; Noctalia/active Emacs themes, and Dired live file watching.

;;; Code:

(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))

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

(defun strata-dirvish--enable-in-browser ()
  "Enable `strata-dirvish-mode' in Strata/Dirvish browser buffers cleanly."
  (unless (strata-terminal-focused-p)
    (strata-dirvish-mode 1)))

(defun strata-dirvish-launch (&optional dir)
  "Launch or focus the Strata-enhanced Dirvish file browser (`C-c d').
When called from `*dashboard*', honors `restore-tabs' and opens `~/' (or last
saved tab) along with the collapsible Strata Sidebar if enabled."
  (interactive)
  (let* ((from-dash (string= (buffer-name) "*dashboard*"))
         (target (or dir
                     (and from-dash
                          (progn (strata-tabs-load)
                                 (when strata-workspace-tabs
                                   (strata-tab-state-dir (strata-active-tab)))))
                     default-directory
                     (expand-file-name "~/"))))
    (strata-tabs-load)
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

(defun strata-dirvish--parent-buffer-filter (buf)
  "Ensure Dirvish Miller-column parent buffer BUF renders Strata icons & hand cursor."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (dirvish-prop :attrs
        (dirvish--attrs-expand '(strata-icon strata-dir-mouse strata-color)))))
  buf)

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
    (with-eval-after-load 'dirvish-collapse
      (advice-add 'dirvish-collapse--cache :around #'strata-dirvish--collapse-guard))
    (dolist (hook '(dired-mode-hook
                    strata-compact-mode-hook
                    strata-icons-mode-hook
                    strata-computer-mode-hook
                    strata-trash-mode-hook
                    strata-recent-mode-hook))
      (add-hook hook #'strata-dirvish--enable-in-browser))
    (add-hook 'after-make-frame-functions #'strata-dirvish--on-frame-created)
    (add-hook 'server-after-make-frame-hook #'strata-dirvish--on-frame-created)
    (add-hook 'kill-emacs-hook #'strata-media-stop)
    (add-hook 'kill-emacs-hook #'strata-tabs-save)
    (with-eval-after-load 'dashboard
      (strata-dirvish-dashboard-install))
    (when (featurep 'dashboard)
      (strata-dirvish-dashboard-install))))

(provide 'strata-dirvish)
;;; strata-dirvish.el ends here
