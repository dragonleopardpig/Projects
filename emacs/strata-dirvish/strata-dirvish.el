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
    (strata-open-location target t)
    (strata-sidebar-ensure)))

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
    (let ((ico (lambda (name fallback)
                 (if (and (display-graphic-p) (fboundp 'all-the-icons-octicon))
                     (ignore-errors (all-the-icons-octicon name :height 1.05 :v-adjust 0.0))
                   fallback))))
      (setq dashboard-navigator-buttons
            `(((,(or (funcall ico "file-directory" "📁") "📁")
                "Files"
                "Open Strata-Dirvish File Browser (C-c d)"
                (lambda (&rest _) (strata-dirvish-launch))
                strata-header-accent "" "")
               (,(or (funcall ico "device-desktop" "🖥") "🖥")
                "Computer"
                "Open Computer Drives & Cloud Mounts (computer:///)"
                (lambda (&rest _) (strata-dirvish-launch-computer))
                strata-crumb-segment "" "")
               (,(or (funcall ico "search" "🔍") "🔍")
                "Search"
                "Global Recursive Search across Home & Drives (C-k)"
                (lambda (&rest _) (call-interactively #'strata-global-search))
                strata-hint-key "" "")
               (,(or (funcall ico "trashcan" "🗑") "🗑")
                "Trash"
                "Open Trash (trash:///)"
                (lambda (&rest _) (strata-dirvish-launch-trash))
                shadow "" "")
               (,(or (funcall ico "history" "🕒") "🕒")
                "Recent"
                "Open Recent Files (recent:///)"
                (lambda (&rest _) (strata-dirvish-launch-recent))
                shadow "" "")
               (,(or (funcall ico "gear" "⚙") "⚙")
                "Prefs"
                "Open Strata Settings & Diagnostics (C-,)"
                (lambda (&rest _) (strata-open-settings))
                shadow "" "")))))))

(defun strata-dirvish-setup ()
  "Configure Dirvish, hooks, theme blending, and Dashboard integration."
  (let ((p (strata-prefs)))
    (strata-history-load)
    (strata-sync-theme-faces)
    (setq dired-listing-switches (strata-compute-dired-switches p)
          dirvish-default-layout '(1 0.14 0.48)
          dirvish-use-header-line 'global
          dirvish-attributes '(strata-icon strata-color strata-size strata-time vc-state subtree-state collapse)
          dirvish-preview-dispatchers
          '(strata-rich-image strata-rich-pdf strata-rich-document
            image gif video audio epub pdf archive)
          dirvish-header-line-format '(:left (strata-breadcrumb) :right (strata-view-info))
          dirvish-mode-line-format '(:left (strata-footer) :right (sort omit yank index)))
    (dolist (hook '(dired-mode-hook
                    strata-compact-mode-hook
                    strata-icons-mode-hook
                    strata-computer-mode-hook
                    strata-trash-mode-hook
                    strata-recent-mode-hook))
      (add-hook hook #'strata-dirvish--enable-in-browser))
    (add-hook 'kill-emacs-hook #'strata-media-stop)
    (add-hook 'kill-emacs-hook #'strata-tabs-save)
    (with-eval-after-load 'dashboard
      (strata-dirvish-dashboard-install))
    (when (featurep 'dashboard)
      (strata-dirvish-dashboard-install))))

(provide 'strata-dirvish)
;;; strata-dirvish.el ends here
