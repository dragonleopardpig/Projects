;;; strata-dirvish-panes.el --- Sidebar, split extra pane, vterm drawer, and workspace tabs -*- lexical-binding: t; -*-

;;; Commentary:
;; Implements the collapsible/rail Strata Sidebar (Places, GTK Bookmarks/Pins,
;; Devices), Nemo-style Split Extra Pane (F3/F6) with active pane tracking,
;; persistent per-pane VTerm drawer (C-` / F9), and persistent Workspace Tabs with
;; reopen stack and TOML/ELD session restore.

;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'dirvish)
(require 'subr-x)
(require 'strata-dirvish-prefs)
(require 'strata-dirvish-devices)
(require 'strata-dirvish-views)

(declare-function vterm "vterm" (&optional buffer-name))
(declare-function vterm-send-string "vterm" (string &optional paste-p))
(declare-function vterm-copy-mode "vterm" (&optional arg))
(declare-function strata-record-history "strata-dirvish-search" (pane dir))

;;;; Workspace, Tab & Dual-Pane State

(cl-defstruct strata-pane-state
  (id 1)                  ; 1 (primary) or 2 (extra)
  (dir "~/")
  (view-mode nil)
  (buffer nil)
  (window nil)
  (history-back nil)
  (history-fwd nil)
  (terminal-buf nil)
  (terminal-open nil))

(cl-defstruct strata-tab-state
  (id 1)
  (label "Home")
  (dir "~/")
  (split-p nil)
  (active-pane 1)
  (pane1 nil)
  (pane2 nil))

(defvar strata-workspace-tabs nil
  "List of active `strata-tab-state' structs.")

(defvar strata-active-tab-index 0
  "Zero-based index into `strata-workspace-tabs'.")

(defvar strata-closed-tabs nil
  "Stack of recently closed `strata-tab-state' entries (max 20).")

(defvar strata-next-tab-id 1)

(defvar strata-sidebar-window nil
  "Window displaying `*Strata Sidebar*' when visible.")

(defvar strata-gtk-bookmarks-file
  (expand-file-name "gtk-3.0/bookmarks" (or (getenv "XDG_CONFIG_HOME") "~/.config"))
  "GTK bookmarks file shared with Strata Pinned Places.")

(defvar strata-tabs-state-file
  (expand-file-name "tabs.eld" strata-dirvish-state-dir)
  "Emacs persistence file for Strata workspace tabs.")

(defun strata-active-tab ()
  "Return the currently active `strata-tab-state', creating one if empty."
  (unless strata-workspace-tabs
    (let* ((d (or (cl-find-if #'strata-valid-location-p
                              (list (strata-prefs-default-directory (strata-prefs))
                                    default-directory
                                    (expand-file-name "~/")
                                    "/"))
                  (expand-file-name "~/")))
           (p1 (make-strata-pane-state :id 1 :dir d))
           (tab (make-strata-tab-state :id (cl-incf strata-next-tab-id)
                                       :label (let ((nm (file-name-nondirectory
                                                         (directory-file-name d))))
                                                (if (string-empty-p nm) "/" nm))
                                       :dir d :active-pane 1 :pane1 p1)))
      (setq strata-workspace-tabs (list tab)
            strata-active-tab-index 0)))
  (nth (max 0 (min strata-active-tab-index (1- (length strata-workspace-tabs))))
       strata-workspace-tabs))

(defun strata-split-active-p ()
  "Return non-nil when the active tab has the Extra Split Pane open."
  (when-let ((tab (car-safe strata-workspace-tabs)))
    (ignore tab)
    (strata-tab-state-split-p (strata-active-tab))))

(defun strata-active-pane ()
  "Return active `strata-pane-state' in current tab."
  (let* ((tab (strata-active-tab))
         (p1 (strata-tab-state-pane1 tab))
         (p2 (strata-tab-state-pane2 tab)))
    (if (and (strata-tab-state-split-p tab) (= (strata-tab-state-active-pane tab) 2) p2)
        p2
      p1)))

(defun strata-other-pane ()
  "Return the inactive `strata-pane-state' when split is open, or nil."
  (let ((tab (strata-active-tab)))
    (when (strata-tab-state-split-p tab)
      (if (= (strata-tab-state-active-pane tab) 2)
          (strata-tab-state-pane1 tab)
        (strata-tab-state-pane2 tab)))))

(defun strata-other-pane-directory ()
  "Return writable directory of the opposite split pane, or signal `user-error'."
  (let ((other (strata-other-pane)))
    (unless other
      (user-error "Extra pane is not open (press F3 to open split view)"))
    (let ((dir (strata-pane-state-dir other)))
      (strata-guard-writable-location dir "Transfer to other pane")
      (unless (file-directory-p dir)
        (user-error "Other pane location is not a local folder: %s" dir))
      dir)))

(defun strata-pane-active-p (&optional win)
  "Return non-nil if WIN (default `selected-window') corresponds to active pane."
  (let* ((w (or win (selected-window)))
         (p (strata-active-pane)))
    (or (not (strata-split-active-p))
        (eq w (strata-pane-state-window p))
        (eq (window-buffer w) (strata-pane-state-buffer p)))))

;;;; Bookmarks / Pinned Folders (~/.config/gtk-3.0/bookmarks sync)

(defun strata-bookmarks-read ()
  "Read pinned locations from GTK bookmarks file as ((PATH . LABEL) ...)."
  (let (out)
    (when (file-readable-p strata-gtk-bookmarks-file)
      (with-temp-buffer
        (insert-file-contents strata-gtk-bookmarks-file)
        (dolist (line (split-string (buffer-string) "\n" t))
          (when (string-match "\\`\\([^ ]+\\)\\(?: \\(.+\\)\\)?\\'" line)
            (let* ((raw (match-string 1 line))
                   (lbl (match-string 2 line))
                   (path (if (string-prefix-p "file://" raw)
                             (url-unhex-string (string-remove-prefix "file://" raw))
                           raw))
                   (name (or lbl (file-name-nondirectory (directory-file-name path)))))
              (push (cons path name) out))))))
    (nreverse out)))

(defun strata-bookmarks-write (entries)
  "Persist ENTRIES ((PATH . LABEL) ...) back to `strata-gtk-bookmarks-file'."
  (make-directory (file-name-directory strata-gtk-bookmarks-file) t)
  (with-temp-file strata-gtk-bookmarks-file
    (dolist (e entries)
      (let* ((p (directory-file-name (expand-file-name (car e))))
             (uri (if (string-prefix-p "/" p)
                      (concat "file://" (url-hexify-string p
                                                          (append url-unreserved-chars '(?/))))
                    p)))
        (insert (format "%s %s\n" uri (or (cdr e) (file-name-nondirectory p))))))))

(defun strata-pin-directory (&optional dir label)
  "Pin DIR (defaults to current folder/entry) to Sidebar Bookmarks."
  (interactive)
  (let* ((target (or dir
                     (let ((f (strata-current-file)))
                       (if (and f (file-directory-p f)) f default-directory))))
         (canon (directory-file-name (expand-file-name target)))
         (lbl (or label (file-name-nondirectory canon)))
         (pins (strata-bookmarks-read)))
    (strata-guard-writable-location canon "Pin")
    (if (assoc canon pins)
        (message "Already pinned: %s" lbl)
      (strata-bookmarks-write (append pins (list (cons canon lbl))))
      (strata-sidebar-refresh)
      (message "Pinned %s" lbl))))

(defun strata-unpin-directory (&optional dir)
  "Unpin DIR from Sidebar Bookmarks."
  (interactive)
  (let* ((target (directory-file-name
                  (expand-file-name (or dir (let ((f (strata-current-file)))
                                              (if (and f (file-directory-p f)) f default-directory))))))
         (pins (strata-bookmarks-read)))
    (if (not (assoc target pins))
        (message "Folder is not pinned")
      (strata-bookmarks-write (assoc-delete-all target pins))
      (strata-sidebar-refresh)
      (message "Unpinned %s" (file-name-nondirectory target)))))

(defun strata-dirvish--flatten-layout ()
  "Leave Dirvish full-frame Miller layout cleanly when active."
  (when-let ((dv (dirvish-curr)))
    (when (dv-curr-layout dv)
      (dirvish-layout-toggle)
      (set-buffer (window-buffer (selected-window))))))

(defun strata-panes--valid-main-window-p (win)
  "Return non-nil if WIN is a usable main browser window (not sidebar, preview, or aux)."
  (and (window-live-p win)
       (not (window-parameter win 'window-side))
       (not (window-minibuffer-p win))
       (not (eq win (bound-and-true-p strata-preview-standalone-window)))
       (not (and (boundp 'dirvish--sessions)
                 (hash-table-p dirvish--sessions)
                 (cl-loop for dv being the hash-values of dirvish--sessions
                          thereis (eq win (dv-preview-window dv)))))
       (with-current-buffer (window-buffer win)
         (not (derived-mode-p 'dirvish-misc-mode
                              'dirvish-directory-view-mode
                              'dirvish-special-preview-mode
                              'strata-sidebar-mode)))))

(defun strata-panes--main-window (&optional pane)
  "Return the best main browser window for PANE, avoiding sidebars and aux panes."
  (let* ((p (or pane (strata-active-pane)))
         (pw (and p (strata-pane-state-window p))))
    (or (and (strata-panes--valid-main-window-p pw) pw)
        (when-let ((dv (dirvish-curr)))
          (let ((rw (dv-root-window dv)))
            (and (strata-panes--valid-main-window-p rw) rw)))
        (cl-find-if (lambda (w)
                      (and (strata-panes--valid-main-window-p w)
                           (with-current-buffer (window-buffer w)
                             (or (dirvish-curr)
                                 (derived-mode-p 'dired-mode
                                                 'strata-compact-mode
                                                 'strata-icons-mode
                                                 'strata-computer-mode
                                                 'strata-trash-mode
                                                 'strata-recent-mode)))))
                    (window-list))
        (cl-find-if #'strata-panes--valid-main-window-p (window-list))
        (selected-window))))

(defun strata-sidebar-ensure ()
  "Display `*Strata Sidebar*' if `sidebar-expanded' pref is enabled.
Return non-nil if the sidebar was newly opened and rendered."
  (let ((p (strata-prefs)))
    (when (and (strata-prefs-sidebar-expanded p)
               (not (and (window-live-p strata-sidebar-window)
                         (eq (window-buffer strata-sidebar-window)
                             (get-buffer "*Strata Sidebar*")))))
      (let* ((buf (get-buffer-create "*Strata Sidebar*"))
             (w (if (strata-prefs-sidebar-compact p) 9 28)))
        (with-current-buffer buf
          (unless (derived-mode-p 'strata-sidebar-mode)
            (strata-sidebar-mode)))
        (strata-sidebar-render)
        (setq strata-sidebar-window
              (display-buffer-in-side-window buf `((side . left) (slot . -1) (window-width . ,w))))
        t))))

;;;; Location Navigation Inside Active Pane

(defun strata-valid-location-p (loc)
  "Return non-nil when LOC resolves to a live path or virtual location."
  (when (and (stringp loc) (not (string-empty-p loc)))
    (let ((resolved (if (fboundp 'strata-resolve-location-uri)
                        (ignore-errors (strata-resolve-location-uri loc))
                      loc)))
      (or (member resolved '("computer:///" "trash:///" "recent:///" "network:///"))
          (and resolved
               (or (file-directory-p resolved)
                   (file-exists-p resolved)))))))

(defun strata-open-location (loc &optional record-history)
  "Open LOC (filesystem path, URI, or `computer:///'/`trash:///'/`recent:///'/`network:///')
in the currently active pane cleanly."
  (interactive "sLocation or path: ")
  (let* ((resolved (strata-resolve-location-uri loc))
         (tab (strata-active-tab))
         (pane (strata-active-pane))
         (old-dir (strata-pane-state-dir pane)))
    (unless (or (null old-dir)
                (equal (directory-file-name (or old-dir ""))
                       (directory-file-name (or resolved ""))))
      (when (fboundp 'strata-record-history)
        (strata-record-history pane old-dir))
      (strata-folder-view-remember old-dir))
    (setf (strata-pane-state-dir pane) resolved)
    (when (= (strata-pane-state-id pane) 1)
      (setf (strata-tab-state-dir tab) resolved
            (strata-tab-state-label tab)
            (pcase resolved
              ("computer:///" "Computer")
              ("trash:///" "Trash")
              ("recent:///" "Recent")
              ("network:///" "Network")
              (_ (let ((nm (file-name-nondirectory (directory-file-name resolved))))
                   (if (string-empty-p nm) "/" nm))))))
    ;; Focus pane window if alive (never overwrite sidebars or Dirvish aux panes!)
    (when (or (not (strata-panes--valid-main-window-p (selected-window)))
              (and (strata-panes--valid-main-window-p (strata-pane-state-window pane))
                   (not (eq (selected-window) (strata-pane-state-window pane)))))
      (when-let ((main-win (strata-panes--main-window pane)))
        (select-window main-win)))
    (cond
     ((string= resolved "computer:///")
      (strata-dirvish--flatten-layout)
      (switch-to-buffer (strata-open-computer-buffer)))
     ((string= resolved "trash:///")
      (strata-dirvish--flatten-layout)
      (switch-to-buffer (strata-open-trash-buffer)))
     ((string= resolved "recent:///")
      (strata-dirvish--flatten-layout)
      (switch-to-buffer (strata-open-recent-buffer)))
     ((string= resolved "network:///")
      (strata-dirvish--flatten-layout)
      (switch-to-buffer (strata-open-network-buffer)))
     ((file-directory-p resolved)
      (let* ((snap (strata-folder-view-restore resolved))
             (mode (strata-prefs-browser-mode (strata-prefs))))
        (pcase mode
          ('compact
           (strata-dirvish--flatten-layout)
           (let ((buf (get-buffer-create (format "*Strata Compact: %s*"
                                                 (file-name-nondirectory (directory-file-name resolved))))))
             (switch-to-buffer buf)
             (strata-compact-mode)
             (setq-local strata-local-view-mode 'compact)
             (strata-compact-render resolved)))
          ('icons
           (strata-dirvish--flatten-layout)
           (let ((buf (get-buffer-create (format "*Strata Icons: %s*"
                                                 (file-name-nondirectory (directory-file-name resolved))))))
             (switch-to-buffer buf)
             (strata-icons-mode)
             (setq-local strata-local-view-mode 'icons)
             (strata-icons-render resolved)))
          (_
           (let ((dired-listing-switches (strata-compute-dired-switches)))
             (if (and (dirvish-curr) (not (strata-split-active-p)))
                 (dirvish--find-entry 'find-file resolved)
               (if (strata-split-active-p)
                   (let ((dirvish-reuse-session nil))
                     (dired resolved))
                 (dirvish resolved)))
             (set-buffer (window-buffer (selected-window)))
             (when (eq mode 'list)
               (strata-dirvish--flatten-layout)
               (when (derived-mode-p 'dired-mode)
                 (dired-hide-details-mode -1))))))
        (when (plist-get snap :cursor)
          (strata-goto-file (plist-get snap :cursor)))))
     ((file-exists-p resolved)
      (strata-dirvish--flatten-layout)
      (find-file resolved))
     (t (user-error "Location does not exist: %s" resolved)))
    (setf (strata-pane-state-buffer pane) (current-buffer)
          (strata-pane-state-window pane) (selected-window))
    (ignore record-history)
    (strata-tabs-save)
    (unless (strata-sidebar-ensure)
      (strata-sidebar-refresh))))

;;;; Split Extra Pane Controls (F3 / F6)

(defun strata-toggle-extra-pane ()
  "Toggle Nemo-style Extra Split Pane (`F3').
Closing the extra pane while focused promotes its location & view into Pane 1."
  (interactive)
  (let ((tab (strata-active-tab)))
    (if (strata-tab-state-split-p tab)
        ;; Close split
        (let* ((was-p2 (= (strata-tab-state-active-pane tab) 2))
               (p1 (strata-tab-state-pane1 tab))
               (p2 (strata-tab-state-pane2 tab))
               (keep-dir (if (and was-p2 p2)
                             (strata-pane-state-dir p2)
                           (strata-pane-state-dir p1))))
          (when (and p2 (window-live-p (strata-pane-state-window p2))
                     (not (one-window-p t)))
            (delete-window (strata-pane-state-window p2)))
          (setf (strata-tab-state-split-p tab) nil
                (strata-tab-state-active-pane tab) 1
                (strata-pane-state-dir p1) keep-dir)
          (when (window-live-p (strata-pane-state-window p1))
            (select-window (strata-pane-state-window p1)))
          (strata-open-location keep-dir)
          (message "Closed split pane"))
      ;; Open split: ensure Pane 1 owns current window, split horizontally for Pane 2
      (let* ((cur-dir (or (bound-and-true-p strata-view-directory)
                          (dirvish-prop :root)
                          default-directory))
             (p1 (or (strata-tab-state-pane1 tab) (make-strata-pane-state :id 1 :dir cur-dir)))
             (p2 (or (strata-tab-state-pane2 tab) (make-strata-pane-state :id 2 :dir cur-dir))))
        ;; Flatten Dirvish miller layout cleanly so two equal panes fit comfortably side by side
        (strata-dirvish--flatten-layout)
        (setf (strata-pane-state-dir p1) cur-dir
              (strata-pane-state-buffer p1) (current-buffer)
              (strata-pane-state-window p1) (selected-window))
        (let ((w2 (split-window-right)))
          (setf (strata-tab-state-pane1 tab) p1
                (strata-tab-state-pane2 tab) p2
                (strata-tab-state-split-p tab) t
                (strata-tab-state-active-pane tab) 2
                (strata-pane-state-window p2) w2)
          (select-window w2)
          (let ((dired-listing-switches (strata-compute-dired-switches)))
            (dired (strata-pane-state-dir p2)))
          (setf (strata-pane-state-buffer p2) (current-buffer)))
        (force-mode-line-update t)
        (strata-tabs-save)
        (message "Opened Extra Pane (F6 switches pane, C-S-c/C-S-x copies/moves across panes)")))))

(defun strata-switch-other-pane ()
  "Switch keyboard & visual focus between Primary and Extra split panes (`F6')."
  (interactive)
  (let ((tab (strata-active-tab)))
    (if (not (strata-tab-state-split-p tab))
        (user-error "Extra pane is not open (press F3 to toggle split view)")
      (let* ((next-id (if (= (strata-tab-state-active-pane tab) 1) 2 1))
             (target (if (= next-id 1)
                         (strata-tab-state-pane1 tab)
                       (strata-tab-state-pane2 tab))))
        (setf (strata-tab-state-active-pane tab) next-id)
        (when (window-live-p (strata-pane-state-window target))
          (select-window (strata-pane-state-window target)))
        (force-mode-line-update t)
        (strata-sidebar-refresh)))))

;;;; Per-Pane Persistent Terminal Drawer (C-` / F9) & Terminal Focus Guard

(defun strata-terminal-focused-p (&optional win)
  "Return non-nil if focus is currently inside an embedded terminal buffer."
  (with-current-buffer (window-buffer (or win (selected-window)))
    (derived-mode-p 'vterm-mode 'term-mode 'eshell-mode)))

(defun strata-pane--spawn-terminal (buf-name dir)
  "Create interactive terminal buffer BUF-NAME rooted at DIR."
  (let* ((default-directory (if (and dir (not (strata-location-virtual-p dir)) (file-directory-p dir))
                                (file-name-as-directory dir)
                              (file-name-as-directory (expand-file-name "~/"))))
         (process-environment (append '("TERM=xterm-256color" "COLORTERM=truecolor" "FASTFETCH_ENABLED=0")
                                      process-environment))
         (buf
          (cond
           ((fboundp 'vterm)
            (save-window-excursion
              (vterm buf-name)))
           (t
            (save-window-excursion
              (ansi-term (or (getenv "SHELL") "/bin/bash")
                         (string-trim buf-name "\\*" "\\*")))))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((lm (copy-keymap (or (current-local-map) (make-sparse-keymap)))))
          (define-key lm (kbd "C-`") #'strata-toggle-pane-terminal)
          (define-key lm (kbd "<f9>") #'strata-toggle-pane-terminal)
          (use-local-map lm))))
    buf))

(defun strata-toggle-pane-terminal ()
  "Toggle persistent embedded terminal drawer below active pane (`C-`' / `F9').
Keeps shell process & CWD alive while hidden."
  (interactive)
  (if (strata-terminal-focused-p)
      ;; Inside terminal: hide drawer & return focus to parent file pane
      (let* ((pane (strata-active-pane))
             (term-win (selected-window)))
        (setf (strata-pane-state-terminal-open pane) nil)
        (when (not (one-window-p t))
          (delete-window term-win))
        (when (window-live-p (strata-pane-state-window pane))
          (select-window (strata-pane-state-window pane))))
    (let* ((pane (strata-active-pane))
           (tbuf (strata-pane-state-terminal-buf pane))
           (existing-win (and (buffer-live-p tbuf) (get-buffer-window tbuf))))
      (cond
       (existing-win
        (setf (strata-pane-state-terminal-open pane) nil)
        (delete-window existing-win))
       (t
        (unless (buffer-live-p tbuf)
          (setq tbuf (strata-pane--spawn-terminal
                      (format "*Strata Terminal P%d (T%d)*"
                              (strata-pane-state-id pane)
                              (strata-tab-state-id (strata-active-tab)))
                      (strata-pane-state-dir pane)))
          (setf (strata-pane-state-terminal-buf pane) tbuf))
        (let* ((pane-win (or (and (window-live-p (strata-pane-state-window pane))
                                  (strata-pane-state-window pane))
                             (selected-window)))
               (h (max 8 (/ (window-total-height pane-win) 3)))
               (twin (split-window pane-win (- h) 'below)))
          (setf (strata-pane-state-window pane) pane-win
                (strata-pane-state-terminal-open pane) t)
          (select-window twin)
          (switch-to-buffer tbuf)))))))

(defun strata-open-external-terminal (&optional dir)
  "Launch host terminal emulator externally at DIR."
  (interactive)
  (let ((d (or dir (dirvish-prop :root) default-directory "~/")))
    (strata-guard-writable-location d "Open in Terminal")
    (let ((term (cl-find-if #'executable-find '("foot" "kitty" "alacritty" "wezterm" "xterm")))
          (default-directory (file-name-as-directory (expand-file-name d))))
      (unless term (user-error "No external terminal emulator found on PATH"))
      (let ((process-environment (cons "FASTFETCH_ENABLED=0" process-environment)))
        (make-process :name "strata-ext-term" :noquery t
                      :command (list term)
                      :file-handler nil))
      (message "Launched %s in %s" term d))))

;;;; Workspace Tabs & Session Persistence

(defun strata-tabs-save ()
  "Save open Strata workspace tabs to `strata-tabs-state-file'."
  (when (strata-prefs-restore-tabs (strata-prefs))
    (let ((live (cl-remove-if-not
                 (lambda (tab) (strata-valid-location-p (strata-tab-state-dir tab)))
                 strata-workspace-tabs)))
      (make-directory (file-name-directory strata-tabs-state-file) t)
      (with-temp-file strata-tabs-state-file
        (prin1 (list :active (if live
                                 (max 0 (min strata-active-tab-index (1- (length live))))
                               0)
                     :tabs (mapcar (lambda (tab)
                                     (list :dir (strata-tab-state-dir tab)
                                           :split-p (strata-tab-state-split-p tab)))
                                   live))
               (current-buffer))
        (insert "\n")))))

(defun strata-tabs-load ()
  "Restore saved tabs if `restore-tabs' is enabled and no tabs are loaded yet."
  (when (and (null strata-workspace-tabs)
             (strata-prefs-restore-tabs (strata-prefs))
             (file-readable-p strata-tabs-state-file))
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents strata-tabs-state-file)
          (let* ((data (read (current-buffer)))
                 (saved (plist-get data :tabs))
                 (idx (or (plist-get data :active) 0)))
            (when (consp saved)
              (let ((live nil)
                    (orig-active (nth (max 0 (min idx (1- (length saved)))) saved))
                    (new-idx 0)
                    (i 0))
                (dolist (entry saved)
                  (let ((d (or (plist-get entry :dir) "~/")))
                    (when (strata-valid-location-p d)
                      (when (eq entry orig-active)
                        (setq new-idx i))
                      (push (make-strata-tab-state
                             :id (cl-incf strata-next-tab-id)
                             :label (let ((nm (file-name-nondirectory (directory-file-name d))))
                                      (if (string-empty-p nm) "/" nm))
                             :dir d
                             :split-p (plist-get entry :split-p)
                             :active-pane 1
                             :pane1 (make-strata-pane-state :id 1 :dir d))
                            live)
                      (cl-incf i))))
                (setq strata-workspace-tabs (nreverse live)
                      strata-active-tab-index
                      (if strata-workspace-tabs
                          (max 0 (min new-idx (1- (length strata-workspace-tabs))))
                        0))))))
      (error nil))))

(defun strata-tab-new (&optional dir)
  "Open a new Strata browser tab at DIR (or current folder)."
  (interactive)
  (let* ((d (or dir (strata-pane-state-dir (strata-active-pane)) "~/"))
         (p1 (make-strata-pane-state :id 1 :dir d))
         (tab (make-strata-tab-state
               :id (cl-incf strata-next-tab-id)
               :label (file-name-nondirectory (directory-file-name d))
               :dir d :active-pane 1 :pane1 p1)))
    (strata-active-tab) ; ensure initialized
    (setq strata-workspace-tabs (append strata-workspace-tabs (list tab))
          strata-active-tab-index (1- (length strata-workspace-tabs)))
    (strata-open-location d)
    (message "Tab %d/%d: %s" (1+ strata-active-tab-index) (length strata-workspace-tabs)
             (strata-tab-state-label tab))))

(defun strata-tab-close ()
  "Close current Strata tab cleanly, pushing it onto `strata-closed-tabs' (max 20)."
  (interactive)
  (if (<= (length strata-workspace-tabs) 1)
      (when (fboundp 'dirvish-quit) (dirvish-quit))
    (let ((closing (nth strata-active-tab-index strata-workspace-tabs)))
      (push closing strata-closed-tabs)
      (when (> (length strata-closed-tabs) 20)
        (setcdr (nthcdr 19 strata-closed-tabs) nil))
      (setq strata-workspace-tabs
            (cl-remove closing strata-workspace-tabs :test #'eq)
            strata-active-tab-index
            (max 0 (min strata-active-tab-index (1- (length strata-workspace-tabs)))))
      (strata-open-location (strata-tab-state-dir (strata-active-tab))))))

(defun strata-tab-reopen-closed ()
  "Reopen most recently closed Strata tab (`C-S-t')."
  (interactive)
  (if (null strata-closed-tabs)
      (message "No closed tabs to reopen")
    (let ((tab (pop strata-closed-tabs)))
      (setq strata-workspace-tabs (append strata-workspace-tabs (list tab))
            strata-active-tab-index (1- (length strata-workspace-tabs)))
      (strata-open-location (strata-tab-state-dir tab)))))

(defun strata-tab-switch-index (n)
  "Switch to 1-based Strata tab number N."
  (interactive "p")
  (when strata-workspace-tabs
    (let ((idx (max 0 (min (1- n) (1- (length strata-workspace-tabs))))))
      (setq strata-active-tab-index idx)
      (strata-open-location (strata-tab-state-dir (strata-active-tab)))
      (message "Tab %d/%d: %s" (1+ idx) (length strata-workspace-tabs)
               (strata-tab-state-label (strata-active-tab))))))

(defun strata-tab-next ()
  "Cycle to next Strata workspace tab."
  (interactive)
  (when (> (length strata-workspace-tabs) 1)
    (setq strata-active-tab-index
          (mod (1+ strata-active-tab-index) (length strata-workspace-tabs)))
    (strata-open-location (strata-tab-state-dir (strata-active-tab)))))

(defun strata-tab-previous ()
  "Cycle to previous Strata workspace tab."
  (interactive)
  (when (> (length strata-workspace-tabs) 1)
    (setq strata-active-tab-index
          (mod (1- strata-active-tab-index) (length strata-workspace-tabs)))
    (strata-open-location (strata-tab-state-dir (strata-active-tab)))))

(defun strata-tab-move (delta)
  "Move current tab by DELTA (-1 left, +1 right) and persist order."
  (interactive "p")
  (let* ((len (length strata-workspace-tabs))
         (idx strata-active-tab-index)
         (next (+ idx delta)))
    (when (and (> len 1) (>= next 0) (< next len))
      (cl-rotatef (nth idx strata-workspace-tabs) (nth next strata-workspace-tabs))
      (setq strata-active-tab-index next)
      (strata-tabs-save)
      (message "Moved tab to position %d" (1+ next)))))

(defun strata-open-in-new-tab ()
  "Open folder at point in a new Strata tab (`C-RET')."
  (interactive)
  (let ((f (strata-current-file)))
    (if (and f (file-directory-p f))
        (strata-tab-new f)
      (find-file f))))

(defun strata-open-in-new-frame ()
  "Open folder at point in a new Emacs frame (`S-RET')."
  (interactive)
  (let ((f (or (strata-current-file) default-directory))
        (frame (make-frame)))
    (select-frame-set-input-focus frame)
    (if (file-directory-p f) (strata-open-location f) (find-file f))))

;;;; Strata Left Sidebar (Places + Pinned Bookmarks + Grouped Devices w/ Capacity Bars)

(defun strata-sidebar-mouse-activate (event)
  "Select clicked entry at EVENT in `*Strata Sidebar*' and open it."
  (interactive "e")
  (let* ((start (event-start event))
         (end (event-end event))
         (win (posn-window end))
         (drag-p (eq (car-safe event) 'drag-mouse-1))
         (same-row (or (not drag-p)
                       (and (window-live-p win)
                            (integerp (posn-point start))
                            (integerp (posn-point end))
                            (with-current-buffer (window-buffer win)
                              (= (line-number-at-pos (posn-point start))
                                 (line-number-at-pos (posn-point end))))))))
    (when same-row
      (mouse-set-point event)
      (deactivate-mark)
      (strata-sidebar-activate-at-point))))

(defvar strata-sidebar-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    (define-key map (kbd "<down>") #'next-line)
    (define-key map (kbd "<up>") #'previous-line)
    (define-key map (kbd "RET") #'strata-sidebar-activate-at-point)
    (define-key map (kbd "l") #'strata-sidebar-activate-at-point)
    (define-key map (kbd "<right>") #'strata-sidebar-activate-at-point)
    (define-key map (kbd "<mouse-1>") #'strata-sidebar-mouse-activate)
    (define-key map (kbd "<double-mouse-1>") #'strata-sidebar-mouse-activate)
    (define-key map (kbd "<drag-mouse-1>") #'strata-sidebar-mouse-activate)
    (define-key map (kbd "<mouse-2>") #'strata-sidebar-mouse-activate)
    (define-key map (kbd "t") #'strata-sidebar-open-in-tab-at-point)
    (define-key map (kbd "m") #'strata-sidebar-mount-at-point)
    (define-key map (kbd "u") #'strata-sidebar-unmount-at-point)
    (define-key map (kbd "E") #'strata-sidebar-eject-at-point)
    (define-key map (kbd "X") #'strata-trash-empty)
    (define-key map (kbd "c") #'strata-sidebar-toggle-rail)
    (define-key map (kbd "g") #'strata-sidebar-force-refresh)
    map)
  "Keymap for `*Strata Sidebar*' buffer.")

(define-derived-mode strata-sidebar-mode special-mode "Strata-Sidebar"
  "Strata Sidebar displaying Places, Pinned Bookmarks, and Devices."
  (setq-local truncate-lines t)
  (setq-local mode-line-format nil)
  (hl-line-mode 1)
  (add-hook 'strata-devices-refresh-hook #'strata-sidebar-refresh nil t))

(defun strata-sidebar--place-specs ()
  "Return ordered list of standard place plists matching preferences."
  (let ((p (strata-prefs))
        (specs `(("home" ,(strata-icon-glyph 'home) "Home" ,(expand-file-name "~/") nil ,(strata-prefs-sidebar-show-home (strata-prefs)))
                 ("computer" ,(strata-icon-glyph 'computer) "Computer" "computer:///" nil ,(strata-prefs-sidebar-show-computer (strata-prefs)))
                 ("trash" ,(strata-icon-glyph 'trash) ,(format "Trash (%d)" (length (strata-trash-items))) "trash:///" nil ,(strata-prefs-sidebar-show-trash (strata-prefs)))
                 ("network" ,(strata-icon-glyph 'network) "Network" "network:///" nil ,(strata-prefs-sidebar-show-network (strata-prefs)))
                 ("recent" ,(strata-icon-glyph 'recent) "Recent" "recent:///" nil ,(strata-prefs-sidebar-show-recent (strata-prefs)))
                 ("desktop" ,(strata-icon-glyph 'desktop) "Desktop" ,(expand-file-name "~/Desktop") nil ,(strata-prefs-sidebar-show-desktop (strata-prefs)))
                 ("documents" ,(strata-icon-glyph 'documents) "Documents" ,(expand-file-name "~/Documents") nil ,(strata-prefs-sidebar-show-documents (strata-prefs)))
                 ("downloads" ,(strata-icon-glyph 'downloads) "Downloads" ,(expand-file-name "~/Downloads") nil ,(strata-prefs-sidebar-show-downloads (strata-prefs)))
                 ("music" ,(strata-icon-glyph 'music) "Music" ,(expand-file-name "~/Music") nil ,(strata-prefs-sidebar-show-music (strata-prefs)))
                 ("pictures" ,(strata-icon-glyph 'pictures) "Pictures" ,(expand-file-name "~/Pictures") nil ,(strata-prefs-sidebar-show-pictures (strata-prefs)))
                 ("videos" ,(strata-icon-glyph 'videos) "Videos" ,(expand-file-name "~/Videos") nil ,(strata-prefs-sidebar-show-videos (strata-prefs))))))
    (cl-loop for id in (strata-prefs-sidebar-order p)
             for sp = (assoc id specs)
             when (and sp (nth 5 sp)
                       (or (strata-location-virtual-p (nth 3 sp))
                           (file-directory-p (nth 3 sp))))
             collect sp)))

(defun strata-sidebar-render ()
  "Render `*Strata Sidebar*' contents."
  (when-let ((buf (get-buffer "*Strata Sidebar*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (pt (point))
            (p (strata-prefs))
            (rail (strata-prefs-sidebar-compact (strata-prefs)))
            (cur-dir (ignore-errors (strata-pane-state-dir (strata-active-pane)))))
        (erase-buffer)
        (insert (propertize (if rail " Places\n" "  PLACES\n") 'face 'strata-section-heading))
        (dolist (sp (strata-sidebar--place-specs))
          (let* ((icon (nth 1 sp))
                 (label (nth 2 sp))
                 (loc (nth 3 sp))
                 (active (and cur-dir (equal (directory-file-name cur-dir) (directory-file-name loc))))
                 (txt (if rail (format "  %s\n" icon)
                        (format "  %s  %s\n" icon (propertize label 'face (if active 'strata-header-accent 'default))))))
            (insert (strata-add-row-properties
                     txt (list 'strata-sidebar-loc loc
                               'mouse-face 'highlight
                               'pointer 'hand
                               'help-echo loc)))))
        (unless (strata-prefs-sidebar-pinned-collapsed p)
          (let ((pins (strata-bookmarks-read))
                (idx 0)
                (pin-ico (strata-icon-glyph 'bookmark 'strata-header-accent)))
            (when pins
              (insert "\n" (propertize (if rail " Pins\n" "  PINNED\n") 'face 'strata-section-heading))
              (dolist (pin pins)
                (setq idx (1+ idx))
                (let* ((loc (car pin))
                       (lbl (cdr pin))
                       (keycap (if (<= idx 9) (propertize (format "[%d]" idx) 'face 'strata-hint-key) "   "))
                       (txt (if rail (format "  %s%s\n" pin-ico (if (<= idx 9) (number-to-string idx) ""))
                              (format "  %s %s %s\n" pin-ico keycap lbl))))
                  (insert (strata-add-row-properties
                           txt (list 'strata-sidebar-loc loc
                                     'mouse-face 'highlight
                                     'pointer 'hand
                                     'help-echo loc))))))))
        (unless (strata-prefs-sidebar-devices-collapsed p)
          (insert "\n" (propertize (if rail " Devs\n" "  DEVICES\n") 'face 'strata-section-heading))
          (if (null strata-devices-cache)
              (let ((txt (if rail "  [Scan]\n" "  [Scan drives (g)]\n")))
                (insert (strata-add-row-properties
                         txt '(strata-sidebar-action scan-devices
                               mouse-face highlight
                               pointer hand
                               help-echo "Scan block and mounted devices (g)"))))
            (dolist (dev strata-devices-cache)
              (let* ((icon (strata-device-icon dev))
                     (name (strata-device-name dev))
                     (mp (strata-device-mountpoint dev))
                     (bar (when (and (not rail) (strata-device-usage dev))
                            (concat "\n     " (strata-format-capacity-bar (strata-device-usage dev) 10 t))))
                     (txt (if rail
                              (format "  %s\n" icon)
                            (format "  %s  %s%s\n" icon name (or bar "")))))
                (insert (strata-add-row-properties
                         txt (list 'strata-device dev 'strata-sidebar-loc mp
                                   'mouse-face 'highlight
                                   'pointer 'hand
                                   'help-echo (or mp (strata-device-device dev)))))))))
        (goto-char (min pt (point-max)))))))

(defun strata-sidebar-refresh ()
  "Refresh `*Strata Sidebar*' when visible without triggering a device rescan."
  (interactive)
  (when (get-buffer "*Strata Sidebar*")
    (strata-sidebar-render)))

(defun strata-sidebar-force-refresh ()
  "Scan devices and refresh `*Strata Sidebar*'."
  (interactive)
  (strata-devices-list t)
  (strata-sidebar-refresh))

(defun strata-sidebar-toggle ()
  "Toggle visibility of the left Strata Sidebar (`C-b` / `C-n`)."
  (interactive)
  (let ((p (strata-prefs)))
    (if (window-live-p strata-sidebar-window)
        (progn
          (delete-window strata-sidebar-window)
          (setq strata-sidebar-window nil)
          (setf (strata-prefs-sidebar-expanded p) nil)
          (strata-prefs-save))
      (let* ((buf (get-buffer-create "*Strata Sidebar*"))
             (w (if (strata-prefs-sidebar-compact p) 9 28)))
        (with-current-buffer buf
          (unless (derived-mode-p 'strata-sidebar-mode)
            (strata-sidebar-mode)))
        (strata-sidebar-render)
        (setq strata-sidebar-window
              (display-buffer-in-side-window buf `((side . left) (slot . -1) (window-width . ,w))))
        (setf (strata-prefs-sidebar-expanded p) t)
        (strata-prefs-save)))))

(defun strata-sidebar-toggle-rail ()
  "Toggle compact/rail mode on the left Strata Sidebar."
  (interactive)
  (let ((p (strata-prefs)))
    (setf (strata-prefs-sidebar-compact p) (not (strata-prefs-sidebar-compact p)))
    (strata-prefs-save)
    (when (window-live-p strata-sidebar-window)
      (strata-sidebar-toggle)
      (strata-sidebar-toggle))))

(defun strata-sidebar-focus ()
  "Focus the Strata Sidebar (opening it if hidden)."
  (interactive)
  (unless (window-live-p strata-sidebar-window)
    (strata-sidebar-toggle))
  (when (window-live-p strata-sidebar-window)
    (select-window strata-sidebar-window)))

(defun strata-sidebar--row-prop (prop)
  "Read text property PROP from point, or from the beginning of the current row."
  (or (get-text-property (point) prop)
      (get-text-property (line-beginning-position) prop)))

(defun strata-sidebar-activate-at-point ()
  "Activate place, pin, or device on current Sidebar row."
  (interactive)
  (let ((action (strata-sidebar--row-prop 'strata-sidebar-action))
        (dev (strata-sidebar--row-prop 'strata-device))
        (loc (strata-sidebar--row-prop 'strata-sidebar-loc)))
    (cond
     ((eq action 'scan-devices)
      (strata-sidebar-force-refresh))
     ((and dev (not (strata-device-mounted-p dev)))
      (strata-device-mount dev #'strata-open-location))
     (loc (strata-open-location loc))
     (t (user-error "Nothing selectable on this sidebar row")))))

(defun strata-sidebar-open-in-tab-at-point ()
  "Open Sidebar place/device at point in a new tab."
  (interactive)
  (when-let ((loc (strata-sidebar--row-prop 'strata-sidebar-loc)))
    (strata-tab-new loc)))

(defun strata-sidebar-mount-at-point ()
  "Mount/unlock device on Sidebar row."
  (interactive)
  (if-let ((dev (strata-sidebar--row-prop 'strata-device)))
      (strata-device-mount dev)
    (user-error "No device on this row")))

(defun strata-sidebar-unmount-at-point ()
  "Unmount device on Sidebar row."
  (interactive)
  (if-let ((dev (strata-sidebar--row-prop 'strata-device)))
      (strata-device-unmount dev)
    (user-error "No device on this row")))

(defun strata-sidebar-eject-at-point ()
  "Safely eject device on Sidebar row."
  (interactive)
  (if-let ((dev (strata-sidebar--row-prop 'strata-device)))
      (strata-device-eject dev)
    (user-error "No device on this row")))

(provide 'strata-dirvish-panes)
;;; strata-dirvish-panes.el ends here
