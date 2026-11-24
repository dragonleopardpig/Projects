;;; enhanced-dirvish.el --- A full file manager built on Dirvish -*- lexical-binding: t; -*-

;; Copyright (C) 2026 dragonleopardpig

;; Author: dragonleopardpig <https://github.com/dragonleopardpig>
;; Assisted-by: Claude:claude-opus-5-5
;; Maintainer: dragonleopardpig <https://github.com/dragonleopardpig>
;; URL: https://github.com/dragonleopardpig/enhanced-dirvish
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (dirvish "2.0"))
;; Keywords: files, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Enhanced Dirvish builds a full file manager on Dirvish: Columns,
;; Icons, List and Compact views; a Places sidebar with devices and
;; bookmarks; tabs; a Nemo-style split pane; rich previews that can be
;; edited in place; search and filters; trash with undo; archives; and
;; live refresh through file notifications.
;;
;; Quick start:
;;
;;   (use-package enhanced-dirvish
;;     :after dirvish
;;     :config (enhanced-dirvish-setup))
;;
;; then M-x enhanced-dirvish-launch, or bind it to a key of your own.
;; `enhanced-dirvish-setup' installs the package's hooks and Dirvish
;; settings; loading the package alone changes nothing.
;;
;; Emacs leaves F5-F9 and C-c followed by a letter to users.  Set
;; `enhanced-dirvish-file-manager-keys' to t for Explorer/Nemo-style
;; F5 (refresh), F6 (switch pane), F9 (terminal) and C-c s/t/c/x/v
;; (sort, terminal, copy, cut, paste).
;;
;; Settings are kept in $XDG_CONFIG_HOME/enhanced-dirvish/settings.toml.

;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'dirvish)
(require 'enhanced-dirvish-prefs)
(require 'enhanced-dirvish-devices)
(require 'enhanced-dirvish-views)
(require 'enhanced-dirvish-panes)
(require 'enhanced-dirvish-previews)
(require 'enhanced-dirvish-search)
(require 'enhanced-dirvish-ops)
(require 'enhanced-dirvish-keys)
(require 'enhanced-dirvish-watch)
(require 'enhanced-dirvish-menu)
(require 'enhanced-dirvish-windows)

(declare-function dashboard-insert-navigator "ext:dashboard-widgets")
(declare-function dashboard-insert-items "ext:dashboard")

(defun enhanced-dirvish--sync-auto-revert ()
  "Disable Dired auto-revert and notify watches on FUSE/cloud/remote mounts."
  (if (and default-directory (enhanced-dirvish-path-unsafe-probe-p default-directory))
      (setq-local dired-auto-revert-buffer nil
                  auto-revert-use-notify nil)
    (kill-local-variable 'dired-auto-revert-buffer)
    (kill-local-variable 'auto-revert-use-notify))
  (enhanced-dirvish-view--set-browser-text-scale))

(defun enhanced-dirvish--enable-in-browser ()
  "Enable `enhanced-dirvish-mode' in Enhanced Dirvish browser buffers cleanly."
  (enhanced-dirvish--sync-auto-revert)
  (enhanced-dirvish-view--install-browser-text-zoom)
  (when (and (derived-mode-p 'enhanced-dirvish-compact-mode 'enhanced-dirvish-icons-mode)
             (fboundp 'enhanced-dirvish--enforce-no-wrap))
    (enhanced-dirvish--enforce-no-wrap))
  (when (derived-mode-p 'dired-mode)
    (when (bound-and-true-p hl-line-mode)
      (hl-line-mode -1))
    (add-hook 'post-command-hook #'enhanced-dirvish-view--update-selection-highlight nil t)
    (add-hook 'dired-after-readin-hook #'enhanced-dirvish-view--update-selection-highlight nil t)
    (enhanced-dirvish-view--update-selection-highlight))
  (unless (enhanced-dirvish-terminal-focused-p)
    (enhanced-dirvish-mode 1)))

(defun enhanced-dirvish-launch (&optional dir)
  "Launch or focus the Enhanced-Dirvish-enhanced Dirvish file browser (`C-c d').
When called from `*dashboard*', honors `restore-tabs' and opens `~/' (or last
valid saved tab) along with the collapsible Enhanced Dirvish Sidebar if enabled.
Always falls back to `~/' when the target or saved directory does not exist."
  (interactive)
  (enhanced-dirvish-tabs-load)
  (when enhanced-dirvish-workspace-tabs
    (setq enhanced-dirvish-workspace-tabs
          (cl-remove-if-not
           (lambda (tab) (enhanced-dirvish-valid-location-p (enhanced-dirvish-tab-state-dir tab)))
           enhanced-dirvish-workspace-tabs))
    (setq enhanced-dirvish-active-tab-index
          (if enhanced-dirvish-workspace-tabs
              (max 0 (min enhanced-dirvish-active-tab-index
                          (1- (length enhanced-dirvish-workspace-tabs))))
            0)))
  (let* ((home (expand-file-name "~/"))
         (from-dash (string= (buffer-name) "*dashboard*"))
         (tab-dir (and from-dash
                       enhanced-dirvish-workspace-tabs
                       (enhanced-dirvish-tab-state-dir (enhanced-dirvish-active-tab))))
         (candidate (cond
                     (dir dir)
                     (from-dash tab-dir)
                     (t default-directory)))
         (target (if (enhanced-dirvish-valid-location-p candidate) candidate home)))
    (enhanced-dirvish-open-location target t)))

(defun enhanced-dirvish-launch-computer ()
  "Open Enhanced Dirvish `computer:///' virtual view."
  (interactive)
  (enhanced-dirvish-open-location "computer:///" t))

(defun enhanced-dirvish-launch-trash ()
  "Open Enhanced Dirvish `trash:///' virtual view."
  (interactive)
  (enhanced-dirvish-open-location "trash:///" t))

(defun enhanced-dirvish-launch-recent ()
  "Open Enhanced Dirvish `recent:///' virtual view."
  (interactive)
  (enhanced-dirvish-open-location "recent:///" t))

(defun enhanced-dirvish--save-tabs-on-exit ()
  "Persist Enhanced Dirvish workspace tabs on interactive Emacs exit."
  (unless noninteractive
    (enhanced-dirvish-tabs-save)))

(defun enhanced-dirvish-dashboard-icon (kind face)
  "Return KIND's icon with fixed padding before Dashboard's button label.
Dashboard adds a variable-pitch space; it can be too narrow for Nerd glyphs."
  (concat (enhanced-dirvish-icon-glyph kind face)
          (propertize " " 'display '(space :width 1.5))))

(defun enhanced-dirvish-dashboard--start-line (&rest _)
  "Keep navigator shortcuts on their own line after Dashboard's init info."
  (unless (bolp) (insert "\n")))

(defun enhanced-dirvish-dashboard-install ()
  "Blend crisp Enhanced Dirvish navigator buttons into Emacs Dashboard."
  (when (boundp 'dashboard-navigator-buttons)
    (advice-add 'dashboard-insert-navigator :before #'enhanced-dirvish-dashboard--start-line)
    ;; Recent Dashboard versions require the navigator in the render list;
    ;; setting its buttons alone leaves every shortcut invisible.
    (if (boundp 'dashboard-startupify-list)
        (unless (memq #'dashboard-insert-navigator dashboard-startupify-list)
          (let ((index (or (cl-position #'dashboard-insert-items dashboard-startupify-list)
                           (length dashboard-startupify-list))))
            (setq dashboard-startupify-list
                  (append (cl-subseq dashboard-startupify-list 0 index)
                          (list #'dashboard-insert-navigator)
                          (nthcdr index dashboard-startupify-list)))))
      (when (boundp 'dashboard-set-navigator)
        (setq dashboard-set-navigator t)))
    (setq dashboard-navigator-buttons
          `(((,(enhanced-dirvish-dashboard-icon 'folder 'enhanced-dirvish-header-accent)
              "Dirvish"
              "Open Enhanced Dirvish File Browser (C-c d)"
              (lambda (&rest _) (enhanced-dirvish-launch))
              enhanced-dirvish-header-accent "" "  ")
             (,(enhanced-dirvish-dashboard-icon 'computer 'enhanced-dirvish-crumb-segment)
              "Computer"
              "Open Computer Drives & Cloud Mounts (computer:///)"
              (lambda (&rest _) (enhanced-dirvish-launch-computer))
              enhanced-dirvish-crumb-segment "" "  ")
             (,(enhanced-dirvish-dashboard-icon 'search 'enhanced-dirvish-hint-key)
              "Search"
              "Global Recursive Search across Home & Drives (C-k)"
              (lambda (&rest _) (call-interactively #'enhanced-dirvish-global-search))
              enhanced-dirvish-hint-key "" "  ")
             (,(enhanced-dirvish-dashboard-icon 'trash 'shadow)
              "Trash"
              "Open Trash (trash:///)"
              (lambda (&rest _) (enhanced-dirvish-launch-trash))
              shadow "" "  ")
             (,(enhanced-dirvish-dashboard-icon 'recent 'shadow)
              "Recent"
              "Open Recent Files (recent:///)"
              (lambda (&rest _) (enhanced-dirvish-launch-recent))
              shadow "" "  ")
             (,(enhanced-dirvish-dashboard-icon 'gear 'shadow)
              "Prefs"
              "Open Enhanced Dirvish Settings & Diagnostics (C-,)"
              (lambda (&rest _) (enhanced-dirvish-open-settings))
              shadow "" "  "))))))

(defun enhanced-dirvish--collapse-guard (orig-fn f-name)
  "Skip `dirvish-collapse--cache' for F-NAME on FUSE, cloud, or remote mounts."
  (if (enhanced-dirvish-path-unsafe-probe-p f-name)
      '(nil . nil)
    (funcall orig-fn f-name)))

(defvar enhanced-dirvish--in-sidebar-ensure nil
  "Non-nil while restoring `*Enhanced Dirvish Sidebar*' to avoid advice recursion.")

(defvar enhanced-dirvish--quitting nil
  "Non-nil while `dirvish-quit' is tearing down a Dirvish session.")

(defun enhanced-dirvish--parent-buffer-filter (buf)
  "Ensure Dirvish Miller-column parent BUF keeps attrs and directory."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when-let ((pdir (car-safe (car-safe dired-subdir-alist))))
        (when (file-directory-p pdir)
          (setq-local default-directory (file-name-as-directory pdir))))
      (dirvish-prop :attrs
        (dirvish--attrs-expand '(enhanced-dirvish-icon enhanced-dirvish-dir-mouse enhanced-dirvish-color)))
      (enhanced-dirvish-view--install-browser-text-zoom))
    (when (fboundp 'enhanced-dirvish-watch-sync)
      (enhanced-dirvish-watch-sync buf)))
  buf)

(defun enhanced-dirvish--after-build-layout (&rest _)
  "Keep `*Enhanced Dirvish Sidebar*' visible when Dirvish redoes its layout."
  (when (and (not enhanced-dirvish--in-sidebar-ensure)
             (not enhanced-dirvish-windows--changing)
             (not enhanced-dirvish--quitting)
             (fboundp 'enhanced-dirvish-sidebar-ensure)
             (enhanced-dirvish-prefs-sidebar-expanded (enhanced-dirvish-prefs))
             (or (ignore-errors (dirvish-curr)) (derived-mode-p 'dired-mode)))
    (let ((enhanced-dirvish--in-sidebar-ensure t)
          (orig-win (selected-window)))
      (unless (enhanced-dirvish-sidebar-ensure)
        (when (fboundp 'enhanced-dirvish-sidebar-refresh)
          (enhanced-dirvish-sidebar-refresh)))
      (when (window-live-p orig-win)
        (select-window orig-win t)))))

(defun enhanced-dirvish--around-quit (orig-fn &rest args)
  "Run ORIG-FN with ARGS; close `*Enhanced Dirvish Sidebar*' without a browser."
  (let ((enhanced-dirvish--quitting t))
    (unwind-protect
        (apply orig-fn args)
      (when (and (boundp 'enhanced-dirvish-sidebar-window)
                 (window-live-p enhanced-dirvish-sidebar-window)
                 (not (cl-some (lambda (w)
                                 (with-current-buffer (window-buffer w)
                                   (or (ignore-errors (dirvish-curr))
                                       (derived-mode-p 'dired-mode
                                                       'enhanced-dirvish-compact-mode
                                                       'enhanced-dirvish-icons-mode
                                                       'enhanced-dirvish-computer-mode
                                                       'enhanced-dirvish-trash-mode
                                                       'enhanced-dirvish-recent-mode))))
                               (window-list))))
        (delete-window enhanced-dirvish-sidebar-window)
        (setq enhanced-dirvish-sidebar-window nil))
      (when (and (boundp 'enhanced-dirvish-preview-standalone-window)
                 (window-live-p enhanced-dirvish-preview-standalone-window)
                 (not (cl-some (lambda (w)
                                 (with-current-buffer (window-buffer w)
                                   (or (ignore-errors (dirvish-curr))
                                       (derived-mode-p 'dired-mode
                                                       'enhanced-dirvish-compact-mode
                                                       'enhanced-dirvish-icons-mode
                                                       'enhanced-dirvish-computer-mode
                                                       'enhanced-dirvish-trash-mode
                                                       'enhanced-dirvish-recent-mode))))
                               (window-list))))
        (delete-window enhanced-dirvish-preview-standalone-window)
        (setq enhanced-dirvish-preview-standalone-window nil)))))

(defun enhanced-dirvish--dirview-setup ()
  "Ensure `dirvish-directory-view-mode' panes expose icons & clickable dirs."
  (unless (dirvish-prop :attrs)
    (dirvish-prop :attrs
      (dirvish--attrs-expand '(enhanced-dirvish-icon enhanced-dirvish-dir-mouse enhanced-dirvish-color))))
  (enhanced-dirvish-view--install-browser-text-zoom))

(defun enhanced-dirvish--on-frame-created (&optional frame)
  "Refresh icon font cache and dashboard buttons when GUI FRAME opens."
  (let ((fr (or frame (selected-frame))))
    (when (display-graphic-p fr)
      (setq enhanced-dirvish-icon--family-cache nil)
      (with-selected-frame fr
        (enhanced-dirvish-sync-theme-faces)
        (enhanced-dirvish-dashboard-install)
        (when (fboundp 'enhanced-dirvish-sidebar-refresh)
          (enhanced-dirvish-sidebar-refresh))))))

(defun enhanced-dirvish-setup ()
  "Configure Dirvish, hooks, theme blending, and Dashboard integration.
Loading the package changes nothing; this installs its global hooks,
advice and Dirvish settings, and the keys of
`enhanced-dirvish-file-manager-keys' when that option is on."
  (enhanced-dirvish-apply-file-manager-keys)
  (add-hook 'window-selection-change-functions #'enhanced-dirvish-panes--on-window-selection-change)
  (add-hook 'window-selection-change-functions #'enhanced-dirvish-preview--on-window-selection-change)
  (add-hook 'enable-theme-functions #'enhanced-dirvish-sync-theme-faces)
  (add-hook 'dired-after-readin-hook #'enhanced-dirvish-dired-decorate-dirs)
  (add-hook 'dirvish-preview-setup-hook #'enhanced-dirvish-preview--setup-dirvish-fontlock-h)
  (enhanced-dirvish-preview--ensure-common-auto-modes)
  (when (fboundp 'dirvish--preview-update)
    (advice-add 'dirvish--preview-update :around #'enhanced-dirvish-preview--guard-dirvish-update))
  (enhanced-dirvish-ui-install-mouse-routing)
  (enhanced-dirvish-menu-install)
  (enhanced-dirvish-windows-install)
  (let ((p (enhanced-dirvish-prefs)))
    (enhanced-dirvish-history-load)
    (enhanced-dirvish-sync-theme-faces)
    (when (fboundp 'customize-set-variable)
      (ignore-errors (customize-set-variable 'dirvish-subtree-state-style 'arrow)))
    (setq dired-listing-switches (enhanced-dirvish-compute-dired-switches p)
          dirvish-default-layout '(1 0.14 0.48)
          dirvish-use-header-line 'global
          dirvish-attributes
          '(enhanced-dirvish-icon enhanced-dirvish-dir-mouse enhanced-dirvish-color enhanced-dirvish-size enhanced-dirvish-time
            vc-state subtree-state)
          dirvish-preview-dispatchers
          '(enhanced-dirvish-mount-guard enhanced-dirvish-rich-image enhanced-dirvish-rich-pdf enhanced-dirvish-rich-document
            image gif video audio epub pdf archive)
          dirvish-header-line-format '(:left (enhanced-dirvish-breadcrumb) :right (enhanced-dirvish-view-info))
          dirvish-mode-line-format '(:left (enhanced-dirvish-footer) :right (sort omit yank index)))
    (when (boundp 'dirvish-directory-view-mode-map)
      (define-key dirvish-directory-view-mode-map (kbd "<mouse-1>") #'enhanced-dirvish-mouse-click-entry)
      (define-key dirvish-directory-view-mode-map (kbd "<mouse-2>") #'enhanced-dirvish-mouse-activate-at-event)
      (define-key dirvish-directory-view-mode-map (kbd "<double-mouse-1>") #'enhanced-dirvish-mouse-activate-at-event))
    (dolist (map '(dirvish-directory-view-mode-map dirvish-misc-mode-map
                   dirvish-special-preview-mode-map))
      (when (boundp map) (enhanced-dirvish-mouse-install-history-bindings (symbol-value map))))
    (add-hook 'dirvish-directory-view-mode-hook #'enhanced-dirvish--dirview-setup)
    (add-hook 'window-buffer-change-functions #'enhanced-dirvish-view--on-window-buffer-change)
    (advice-add 'dirvish-post-command-h :around #'enhanced-dirvish-view--dirvish-post-command)
    (when (fboundp 'dirvish--render-attrs-1)
      (advice-add 'dirvish--render-attrs-1 :around #'enhanced-dirvish--render-attrs-scaled-1))
    (when (fboundp 'dirvish--render-attrs)
      (advice-add 'dirvish--render-attrs :after #'enhanced-dirvish--render-attrs-align-scaled))
    (when (fboundp 'dired--trivial-next-line)
      (advice-add 'dired--trivial-next-line :around #'enhanced-dirvish--dired-trivial-next-line-around))
    (when (fboundp 'dirvish--create-parent-buffer)
      (advice-add 'dirvish--create-parent-buffer :filter-return #'enhanced-dirvish--parent-buffer-filter))
    (when (fboundp 'dirvish--build-layout)
      (advice-add 'dirvish--build-layout :after #'enhanced-dirvish--after-build-layout))
    (when (fboundp 'dirvish--try-reuse)
      (advice-add 'dirvish--try-reuse :after #'enhanced-dirvish--after-build-layout))
    (when (fboundp 'dirvish-quit)
      (advice-add 'dirvish-quit :around #'enhanced-dirvish--around-quit))
    ;; Advice applies once the optional extension defines the function.
    (advice-add 'dirvish-collapse--cache :around #'enhanced-dirvish--collapse-guard)
    ;; Nothing walks up a cloud or network mount looking for .git,
    ;; .dir-locals.el, a project or .editorconfig (each step is a call into it).
    (advice-add 'locate-dominating-file :around #'enhanced-dirvish--dominating-file-guard)
    (dolist (hook '(dired-mode-hook
                    enhanced-dirvish-compact-mode-hook
                    enhanced-dirvish-icons-mode-hook
                    enhanced-dirvish-computer-mode-hook
                    enhanced-dirvish-trash-mode-hook
                    enhanced-dirvish-recent-mode-hook))
      (add-hook hook #'enhanced-dirvish--enable-in-browser))
    (add-hook 'dired-after-readin-hook #'enhanced-dirvish--sync-auto-revert)
    (when (fboundp 'enhanced-dirvish-watch-install)
      (enhanced-dirvish-watch-install))
    (add-hook 'after-make-frame-functions #'enhanced-dirvish--on-frame-created)
    (add-hook 'server-after-make-frame-hook #'enhanced-dirvish--on-frame-created)
    (add-hook 'kill-emacs-hook #'enhanced-dirvish-media-stop)
    (remove-hook 'kill-emacs-hook #'enhanced-dirvish-tabs-save)
    (add-hook 'kill-emacs-hook #'enhanced-dirvish--save-tabs-on-exit)
    (with-eval-after-load 'dashboard
      (enhanced-dirvish-dashboard-install))
    (when (featurep 'dashboard)
      (enhanced-dirvish-dashboard-install))))

(provide 'enhanced-dirvish)
;;; enhanced-dirvish.el ends here
