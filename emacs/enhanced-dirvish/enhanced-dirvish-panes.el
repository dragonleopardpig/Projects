;;; enhanced-dirvish-panes.el --- Sidebar, split extra pane, vterm drawer, and workspace tabs -*- lexical-binding: t; -*-

;;; Commentary:
;; Implements the collapsible/rail Enhanced Dirvish Sidebar (Places, GTK Bookmarks/Pins,
;; Devices), Nemo-style Split Extra Pane (F3/F6) with active pane tracking,
;; persistent per-pane VTerm drawer (C-` / F9), and persistent Workspace Tabs with
;; reopen stack and TOML/ELD session restore.

;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'dirvish)
(require 'subr-x)
(require 'enhanced-dirvish-prefs)
(require 'enhanced-dirvish-devices)
(require 'enhanced-dirvish-views)

(declare-function vterm "vterm" (&optional buffer-name))
(declare-function vterm-send-string "vterm" (string &optional paste-p))
(declare-function vterm-copy-mode "vterm" (&optional arg))
(declare-function enhanced-dirvish-record-history "enhanced-dirvish-search" (pane dir))
(declare-function enhanced-dirvish-windows-display-sidebar "enhanced-dirvish-windows" (buffer width))
(declare-function enhanced-dirvish-windows-display-terminal "enhanced-dirvish-windows" (main height pane))
(declare-function enhanced-dirvish-windows--delete "enhanced-dirvish-windows" (window))
(declare-function enhanced-dirvish-windows--reconcile "enhanced-dirvish-windows" (&optional frame))

;;;; Workspace, Tab & Dual-Pane State

(cl-defstruct enhanced-dirvish-pane-state
  (id 1)                  ; 1 (primary) or 2 (extra)
  (dir "~/")
  (view-mode nil)
  (buffer nil)
  (window nil)
  (history-back nil)
  (history-fwd nil)
  (terminal-buf nil)
  (terminal-open nil))

(cl-defstruct enhanced-dirvish-tab-state
  (id 1)
  (label "Home")
  (dir "~/")
  (split-p nil)
  (active-pane 1)
  (pane1 nil)
  (pane2 nil))

(defvar enhanced-dirvish-workspace-tabs nil
  "List of active `enhanced-dirvish-tab-state' structs.")

(defvar enhanced-dirvish-active-tab-index 0
  "Zero-based index into `enhanced-dirvish-workspace-tabs'.")

(defvar enhanced-dirvish-closed-tabs nil
  "Stack of recently closed `enhanced-dirvish-tab-state' entries (max 20).")

(defvar enhanced-dirvish-next-tab-id 1)

(defvar enhanced-dirvish-sidebar-window nil
  "Window displaying `*Enhanced Dirvish Sidebar*' when visible.")

(defvar enhanced-dirvish-gtk-bookmarks-file
  (expand-file-name "gtk-3.0/bookmarks" (or (getenv "XDG_CONFIG_HOME") "~/.config"))
  "GTK bookmarks file shared with Enhanced Dirvish Pinned Places.")

(defvar enhanced-dirvish-tabs-state-file
  (expand-file-name "tabs.eld" enhanced-dirvish-state-dir)
  "Emacs persistence file for Enhanced Dirvish workspace tabs.")

(defun enhanced-dirvish-active-tab ()
  "Return the currently active `enhanced-dirvish-tab-state', creating one if empty."
  (unless enhanced-dirvish-workspace-tabs
    (let* ((pref-dir (enhanced-dirvish-prefs-default-directory (enhanced-dirvish-prefs)))
           (d (if (enhanced-dirvish-valid-location-p pref-dir)
                  pref-dir
                (expand-file-name "~/")))
           (p1 (make-enhanced-dirvish-pane-state :id 1 :dir d))
           (tab (make-enhanced-dirvish-tab-state :id (cl-incf enhanced-dirvish-next-tab-id)
                                       :label (let ((nm (file-name-nondirectory
                                                         (directory-file-name d))))
                                                (if (string-empty-p nm) "/" nm))
                                       :dir d :active-pane 1 :pane1 p1)))
      (setq enhanced-dirvish-workspace-tabs (list tab)
            enhanced-dirvish-active-tab-index 0)))
  (nth (max 0 (min enhanced-dirvish-active-tab-index (1- (length enhanced-dirvish-workspace-tabs))))
       enhanced-dirvish-workspace-tabs))

(defun enhanced-dirvish-split-active-p ()
  "Return non-nil when the active tab has the Extra Split Pane open."
  (when-let ((tab (car-safe enhanced-dirvish-workspace-tabs)))
    (ignore tab)
    (let ((active (enhanced-dirvish-active-tab)))
      (and (enhanced-dirvish-tab-state-split-p active)
           (enhanced-dirvish-tab-state-pane2 active)
           t))))

(defun enhanced-dirvish-active-pane ()
  "Return active `enhanced-dirvish-pane-state' in current tab."
  (let* ((tab (enhanced-dirvish-active-tab))
         (p1 (enhanced-dirvish-tab-state-pane1 tab))
         (p2 (enhanced-dirvish-tab-state-pane2 tab)))
    (if (and (enhanced-dirvish-tab-state-split-p tab) (= (enhanced-dirvish-tab-state-active-pane tab) 2) p2)
        p2
      p1)))

(defun enhanced-dirvish-panes--set-active-view (buffer window)
  "Record BUFFER and WINDOW on the active pane when workspace tabs exist."
  (when (consp enhanced-dirvish-workspace-tabs)
    (let ((pane (enhanced-dirvish-active-pane)))
      (setf (enhanced-dirvish-pane-state-buffer pane) buffer
            (enhanced-dirvish-pane-state-window pane) window))))

(defun enhanced-dirvish-other-pane ()
  "Return the inactive `enhanced-dirvish-pane-state' when split is open, or nil."
  (let ((tab (enhanced-dirvish-active-tab)))
    (when (enhanced-dirvish-tab-state-split-p tab)
      (if (= (enhanced-dirvish-tab-state-active-pane tab) 2)
          (enhanced-dirvish-tab-state-pane1 tab)
        (enhanced-dirvish-tab-state-pane2 tab)))))

(defun enhanced-dirvish-other-pane-directory ()
  "Return writable directory of the opposite split pane, or signal `user-error'."
  (let ((other (enhanced-dirvish-other-pane)))
    (unless other
      (user-error "Extra pane is not open (press F3 to open split view)"))
    (let ((dir (enhanced-dirvish-pane-state-dir other)))
      (enhanced-dirvish-guard-writable-location dir "Transfer to other pane")
      (unless (file-directory-p dir)
        (user-error "Other pane location is not a local folder: %s" dir))
      dir)))

(defun enhanced-dirvish-panes--pane-for-window (win)
  "Return the pane owning browser or embedded terminal window WIN."
  (or (and (window-live-p win)
           (memq (window-parameter win 'enhanced-dirvish-window-role) '(index terminal))
           (window-parameter win 'enhanced-dirvish-window-pane))
      (when (and (enhanced-dirvish-split-active-p)
                 (enhanced-dirvish-panes--valid-main-window-p win))
        (let* ((tab (enhanced-dirvish-active-tab))
               (p1 (enhanced-dirvish-tab-state-pane1 tab))
               (p2 (enhanced-dirvish-tab-state-pane2 tab))
               (w1 (and p1 (enhanced-dirvish-pane-state-window p1)))
               (w2 (and p2 (enhanced-dirvish-pane-state-window p2)))
               (b1 (and p1 (enhanced-dirvish-pane-state-buffer p1)))
               (b2 (and p2 (enhanced-dirvish-pane-state-buffer p2)))
               (wbuf (window-buffer win)))
          (cond
           ((and p1 (eq win w1)) p1)
           ((and p2 (eq win w2)) p2)
           ((and p1 (not (window-live-p w1)) (not (eq b1 b2)) (eq wbuf b1)) p1)
           ((and p2 (not (window-live-p w2)) (not (eq b1 b2)) (eq wbuf b2)) p2))))))

(defun enhanced-dirvish-panes--sync-active-pane-from-window (&optional win)
  "Sync active split pane to match main browser WIN (default `selected-window')."
  (let ((w (or win (selected-window))))
    (when-let ((matched (enhanced-dirvish-panes--pane-for-window w)))
      (let* ((tab (enhanced-dirvish-active-tab))
             (id (enhanced-dirvish-pane-state-id matched))
             (changed (/= (enhanced-dirvish-tab-state-active-pane tab) id)))
        (unless (eq (window-parameter w 'enhanced-dirvish-window-role) 'terminal)
          (setf (enhanced-dirvish-pane-state-window matched) w))
        (when changed
          (setf (enhanced-dirvish-tab-state-active-pane tab) id)
          (force-mode-line-update t)
          (enhanced-dirvish-sidebar-refresh)))
      matched)))

(defun enhanced-dirvish-panes--on-window-selection-change (&optional frame)
  "Track which split pane owns focus when selection moves in FRAME."
  (enhanced-dirvish-panes--sync-active-pane-from-window (frame-selected-window frame)))

(add-hook 'window-selection-change-functions #'enhanced-dirvish-panes--on-window-selection-change)

(defun enhanced-dirvish-panes--window-dir (&optional win)
  "Return directory path displayed inside browser window WIN."
  (let ((w (or win (selected-window))))
    (when (enhanced-dirvish-panes--valid-main-window-p w)
      (with-current-buffer (window-buffer w)
        (or (when-let ((p (enhanced-dirvish-panes--pane-for-window w)))
              (enhanced-dirvish-pane-state-dir p))
            (bound-and-true-p enhanced-dirvish-view-directory)
            (ignore-errors (dirvish-prop :root))
            (ignore-errors (dired-current-directory))
            default-directory)))))

(defun enhanced-dirvish-pane-active-p (&optional win)
  "Return non-nil if WIN (default `selected-window') corresponds to active pane."
  (let* ((w (or win (selected-window)))
         (p (enhanced-dirvish-active-pane))
         (pw (and p (enhanced-dirvish-pane-state-window p))))
    (or (not (enhanced-dirvish-split-active-p))
        (eq w pw)
        (and (not (window-live-p pw))
             (eq (window-buffer w) (enhanced-dirvish-pane-state-buffer p))))))

;;;; Bookmarks / Pinned Folders (~/.config/gtk-3.0/bookmarks sync)

(defun enhanced-dirvish-bookmarks-read ()
  "Read pinned locations from GTK bookmarks file as ((PATH . LABEL) ...)."
  (let (out)
    (when (file-readable-p enhanced-dirvish-gtk-bookmarks-file)
      (with-temp-buffer
        (insert-file-contents enhanced-dirvish-gtk-bookmarks-file)
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

(defun enhanced-dirvish-bookmarks-write (entries)
  "Write ENTRIES ((PATH . LABEL) ...) to `enhanced-dirvish-gtk-bookmarks-file'."
  (make-directory (file-name-directory enhanced-dirvish-gtk-bookmarks-file) t)
  (with-temp-file enhanced-dirvish-gtk-bookmarks-file
    (dolist (e entries)
      (let* ((p (directory-file-name (expand-file-name (car e))))
             (uri (if (string-prefix-p "/" p)
                      (concat "file://" (url-hexify-string p
                                                          (append url-unreserved-chars '(?/))))
                    p)))
        (insert (format "%s %s\n" uri (or (cdr e) (file-name-nondirectory p))))))))

(defun enhanced-dirvish-pin-directory (&optional dir label)
  "Pin DIR (defaults to current folder/entry) to Sidebar Bookmarks."
  (interactive)
  (let* ((target (or dir
                     (let ((f (enhanced-dirvish-current-file)))
                       (if (and f (file-directory-p f)) f default-directory))))
         (canon (directory-file-name (expand-file-name target)))
         (lbl (or label (file-name-nondirectory canon)))
         (pins (enhanced-dirvish-bookmarks-read)))
    (enhanced-dirvish-guard-writable-location canon "Pin")
    (if (assoc canon pins)
        (message "Already pinned: %s" lbl)
      (enhanced-dirvish-bookmarks-write (append pins (list (cons canon lbl))))
      (enhanced-dirvish-sidebar-refresh)
      (message "Pinned %s" lbl))))

(defun enhanced-dirvish-unpin-directory (&optional dir)
  "Unpin DIR from Sidebar Bookmarks."
  (interactive)
  (let* ((target (directory-file-name
                  (expand-file-name (or dir (let ((f (enhanced-dirvish-current-file)))
                                              (if (and f (file-directory-p f)) f default-directory))))))
         (pins (enhanced-dirvish-bookmarks-read)))
    (if (not (assoc target pins))
        (message "Folder is not pinned")
      (enhanced-dirvish-bookmarks-write (assoc-delete-all target pins))
      (enhanced-dirvish-sidebar-refresh)
      (message "Unpinned %s" (file-name-nondirectory target)))))

(defun enhanced-dirvish--flatten-layout ()
  "Leave Dirvish full-frame Miller layout cleanly when active."
  (when-let ((dv (dirvish-curr)))
    (when (dv-curr-layout dv)
      (dirvish-layout-toggle)
      (set-buffer (window-buffer (selected-window))))))

(defun enhanced-dirvish-panes--valid-main-window-p (win)
  "Return non-nil if WIN is a usable main browser window (not sidebar, preview, or aux)."
  (and (window-live-p win)
       (not (window-parameter win 'window-side))
       (not (window-minibuffer-p win))
       (not (eq win (bound-and-true-p enhanced-dirvish-preview-standalone-window)))
       (not (and (boundp 'dirvish--sessions)
                 (hash-table-p dirvish--sessions)
                 (cl-loop for dv being the hash-values of dirvish--sessions
                          thereis (eq win (dv-preview-window dv)))))
       (with-current-buffer (window-buffer win)
         (not (derived-mode-p 'dirvish-misc-mode
                              'dirvish-directory-view-mode
                              'dirvish-special-preview-mode
                              'enhanced-dirvish-sidebar-mode)))))

(defun enhanced-dirvish-panes--main-window (&optional pane)
  "Return the best main browser window for PANE, avoiding sidebars and aux panes."
  (let* ((p (or pane (enhanced-dirvish-active-pane)))
         (pw (and p (enhanced-dirvish-pane-state-window p))))
    (or (and (enhanced-dirvish-panes--valid-main-window-p pw) pw)
        (when-let ((dv (dirvish-curr)))
          (let ((rw (dv-root-window dv)))
            (and (enhanced-dirvish-panes--valid-main-window-p rw) rw)))
        (cl-find-if (lambda (w)
                      (and (enhanced-dirvish-panes--valid-main-window-p w)
                           (with-current-buffer (window-buffer w)
                             (or (dirvish-curr)
                                 (derived-mode-p 'dired-mode
                                                 'enhanced-dirvish-compact-mode
                                                 'enhanced-dirvish-icons-mode
                                                 'enhanced-dirvish-computer-mode
                                                 'enhanced-dirvish-trash-mode
                                                 'enhanced-dirvish-recent-mode)))))
                    (window-list))
        (cl-find-if #'enhanced-dirvish-panes--valid-main-window-p (window-list))
        (selected-window))))

(defun enhanced-dirvish-sidebar-ensure ()
  "Display `*Enhanced Dirvish Sidebar*' if `sidebar-expanded' pref is enabled.
Return non-nil if the sidebar was newly opened and rendered."
  (let ((p (enhanced-dirvish-prefs)))
    (when (and (enhanced-dirvish-prefs-sidebar-expanded p)
               (not (and (window-live-p enhanced-dirvish-sidebar-window)
                         (eq (window-buffer enhanced-dirvish-sidebar-window)
                             (get-buffer "*Enhanced Dirvish Sidebar*")))))
      (let* ((buf (get-buffer-create "*Enhanced Dirvish Sidebar*"))
             (w (if (enhanced-dirvish-prefs-sidebar-compact p) 9 28)))
        (with-current-buffer buf
          (unless (derived-mode-p 'enhanced-dirvish-sidebar-mode)
            (enhanced-dirvish-sidebar-mode)))
        (enhanced-dirvish-sidebar-render)
        (setq enhanced-dirvish-sidebar-window
              (enhanced-dirvish-windows-display-sidebar buf w))
        t))))

;;;; Location Navigation Inside Active Pane

(defun enhanced-dirvish-valid-location-p (loc)
  "Return non-nil when LOC resolves to a live path or virtual location."
  (when (and (stringp loc) (not (string-empty-p loc)))
    (let ((resolved (if (fboundp 'enhanced-dirvish-resolve-location-uri)
                        (ignore-errors (enhanced-dirvish-resolve-location-uri loc))
                      loc)))
      (or (member resolved '("computer:///" "trash:///" "recent:///" "network:///"))
          (and resolved
               (or (file-directory-p resolved)
                   (file-exists-p resolved)))))))

(defun enhanced-dirvish-open-location (loc &optional record-history)
  "Open LOC (path, virtual, or remote URI) cleanly inside the active pane."
  (interactive "sLocation or path: ")
  (when (enhanced-dirvish-panes--valid-main-window-p (selected-window))
    (enhanced-dirvish-panes--sync-active-pane-from-window (selected-window)))
  (let* ((resolved (enhanced-dirvish-resolve-location-uri loc))
         (tab (enhanced-dirvish-active-tab))
         (pane (enhanced-dirvish-active-pane))
         (old-dir (enhanced-dirvish-pane-state-dir pane)))
    (unless (or (null old-dir)
                (equal (directory-file-name (or old-dir ""))
                       (directory-file-name (or resolved ""))))
      (when (fboundp 'enhanced-dirvish-record-history)
        (enhanced-dirvish-record-history pane old-dir))
      (enhanced-dirvish-folder-view-remember old-dir))
    (setf (enhanced-dirvish-pane-state-dir pane) resolved)
    (when (= (enhanced-dirvish-pane-state-id pane) 1)
      (setf (enhanced-dirvish-tab-state-dir tab) resolved
            (enhanced-dirvish-tab-state-label tab)
            (pcase resolved
              ("computer:///" "Computer")
              ("trash:///" "Trash")
              ("recent:///" "Recent")
              ("network:///" "Network")
              (_ (let ((nm (file-name-nondirectory (directory-file-name resolved))))
                   (if (string-empty-p nm) "/" nm))))))
    ;; Focus pane window if alive (never overwrite sidebars or Dirvish aux panes!)
    (when (or (not (enhanced-dirvish-panes--valid-main-window-p (selected-window)))
              (and (enhanced-dirvish-panes--valid-main-window-p (enhanced-dirvish-pane-state-window pane))
                   (not (eq (selected-window) (enhanced-dirvish-pane-state-window pane)))))
      (when-let ((main-win (enhanced-dirvish-panes--main-window pane)))
        (select-window main-win)))
    (cond
     ((string= resolved "computer:///")
      (enhanced-dirvish--flatten-layout)
      (switch-to-buffer (enhanced-dirvish-open-computer-buffer)))
     ((string= resolved "trash:///")
      (enhanced-dirvish--flatten-layout)
      (switch-to-buffer (enhanced-dirvish-open-trash-buffer)))
     ((string= resolved "recent:///")
      (enhanced-dirvish--flatten-layout)
      (switch-to-buffer (enhanced-dirvish-open-recent-buffer)))
     ((string= resolved "network:///")
      (enhanced-dirvish--flatten-layout)
      (switch-to-buffer (enhanced-dirvish-open-network-buffer)))
     ((file-directory-p resolved)
      (let* ((snap (enhanced-dirvish-folder-view-restore resolved))
             (mode (enhanced-dirvish-prefs-browser-mode (enhanced-dirvish-prefs))))
        (pcase mode
          ('compact
           (enhanced-dirvish--flatten-layout)
           (let ((buf (enhanced-dirvish-view--buffer "Compact" resolved)))
             (switch-to-buffer buf)
             (enhanced-dirvish-compact-mode)
             (setq-local enhanced-dirvish-local-view-mode 'compact)
             (enhanced-dirvish-compact-render resolved)))
          ('icons
           (enhanced-dirvish--flatten-layout)
           (let ((buf (enhanced-dirvish-view--buffer "Icons" resolved)))
             (switch-to-buffer buf)
             (enhanced-dirvish-icons-mode)
             (setq-local enhanced-dirvish-local-view-mode 'icons)
             (enhanced-dirvish-icons-render resolved)))
          (_
           (let ((dired-listing-switches (enhanced-dirvish-compute-dired-switches)))
             (if (and (dirvish-curr) (not (enhanced-dirvish-split-active-p)))
                 (dirvish--find-entry 'find-file resolved)
               (if (enhanced-dirvish-split-active-p)
                   (let ((dirvish-reuse-session nil))
                     (dired resolved))
                 (dirvish resolved)))
             (set-buffer (window-buffer (selected-window)))
             (when (eq mode 'list)
               (enhanced-dirvish--flatten-layout)
               (when (derived-mode-p 'dired-mode)
                 (dired-hide-details-mode -1))))))
        (when (plist-get snap :cursor)
          (enhanced-dirvish-goto-file (plist-get snap :cursor)))))
     ((file-exists-p resolved)
      (enhanced-dirvish--flatten-layout)
      (find-file resolved))
     (t
      (let ((home (expand-file-name "~/")))
        (if (and (file-directory-p home)
                 (not (equal (directory-file-name resolved)
                             (directory-file-name home))))
            (progn
              (message "Location does not exist: %s — falling back to ~/" resolved)
              (enhanced-dirvish-open-location home record-history))
          (user-error "Location does not exist: %s" resolved)))))
    (setf (enhanced-dirvish-pane-state-buffer pane) (current-buffer)
          (enhanced-dirvish-pane-state-window pane) (selected-window))
    (ignore record-history)
    (enhanced-dirvish-tabs-save)
    (unless (enhanced-dirvish-sidebar-ensure)
      (enhanced-dirvish-sidebar-refresh))))

;;;; Split Extra Pane Controls (F3 / F6)

(defun enhanced-dirvish-panes--extra-shown-p (tab)
  "Return non-nil when split TAB's extra pane is on screen.
A split tab can have only pane 1 shown, for example after its extra
pane's window was deleted; F3 must then open the extra pane, not close it."
  (let* ((p1 (enhanced-dirvish-tab-state-pane1 tab))
         (p2 (enhanced-dirvish-tab-state-pane2 tab))
         (w2 (and p2 (enhanced-dirvish-pane-state-window p2))))
    (and (enhanced-dirvish-tab-state-split-p tab)
         (window-live-p w2)
         (eq (window-frame w2) (selected-frame))
         (not (eq w2 (and p1 (enhanced-dirvish-pane-state-window p1))))
         (enhanced-dirvish-panes--valid-main-window-p w2))))

(defun enhanced-dirvish-panes--open-extra (tab &optional window)
  "Show TAB's extra pane in WINDOW, or in a new window beside pane 1.
Pane 1 is in the selected window.  A new window takes half of pane 1's
width only: the split goes beside the whole browser, whose sidebar keeps
its width.  Pane 2 opens at its own folder in the browser view mode and
becomes the active pane.  Return its window."
  (let* ((p2 (enhanced-dirvish-tab-state-pane2 tab))
         (w2 (if (window-live-p window)
                 window
               (split-window-right
                (- (max window-min-width (/ (window-total-width) 2)))))))
    (set-window-parameter w2 'enhanced-dirvish-window-pane p2)
    (setf (enhanced-dirvish-tab-state-split-p tab) t
          (enhanced-dirvish-tab-state-active-pane tab) 2
          (enhanced-dirvish-pane-state-window p2) w2)
    (select-window w2)
    (enhanced-dirvish-open-location (enhanced-dirvish-pane-state-dir p2))
    w2))

(defun enhanced-dirvish-panes--focus-pane (tab id)
  "Select TAB's pane ID (falling back to pane 1) and make it active."
  (let* ((p2 (and (eql id 2) (enhanced-dirvish-panes--extra-shown-p tab)
                  (enhanced-dirvish-tab-state-pane2 tab)))
         (pane (or p2 (enhanced-dirvish-tab-state-pane1 tab)))
         (w (enhanced-dirvish-pane-state-window pane)))
    (when (window-live-p w)
      (select-window w))
    (setf (enhanced-dirvish-tab-state-active-pane tab) (enhanced-dirvish-pane-state-id pane))
    (force-mode-line-update t)
    (enhanced-dirvish-sidebar-refresh)))

(defun enhanced-dirvish-panes--show-active-tab (old)
  "Show the active tab's panes in the windows tab OLD's panes had.
Pane 1 takes OLD's pane 1 window.  A split tab's extra pane takes OLD's
extra pane window, or a new one beside pane 1; an extra pane window the
active tab has no use for closes.  Focus goes to the tab's active pane."
  (let* ((tab (enhanced-dirvish-active-tab))
         (p1 (or (enhanced-dirvish-tab-state-pane1 tab)
                 (setf (enhanced-dirvish-tab-state-pane1 tab)
                       (make-enhanced-dirvish-pane-state
                        :id 1 :dir (enhanced-dirvish-tab-state-dir tab)))))
         (focus (enhanced-dirvish-tab-state-active-pane tab))
         (prev (or old tab))
         (old-p1 (enhanced-dirvish-tab-state-pane1 prev))
         (w2 (and (enhanced-dirvish-panes--extra-shown-p prev)
                  (enhanced-dirvish-pane-state-window (enhanced-dirvish-tab-state-pane2 prev))))
         (w1 (let ((w (and old-p1 (enhanced-dirvish-pane-state-window old-p1))))
               (if (and (enhanced-dirvish-panes--valid-main-window-p w) (not (eq w w2)))
                   w
                 (enhanced-dirvish-panes--main-window p1)))))
    (when (eq w1 w2) (setq w2 nil))
    ;; Windows keep the pane they showed; hand them to this tab's panes.
    (select-window w1)
    (set-window-parameter w1 'enhanced-dirvish-window-pane p1)
    (setf (enhanced-dirvish-tab-state-active-pane tab) 1
          (enhanced-dirvish-pane-state-window p1) w1)
    (enhanced-dirvish-open-location (enhanced-dirvish-pane-state-dir p1))
    (cond
     ((and (enhanced-dirvish-tab-state-split-p tab) (enhanced-dirvish-tab-state-pane2 tab))
      (enhanced-dirvish-panes--open-extra tab w2))
     ((and (window-live-p w2) (not (eq w2 (selected-window))))
      (ignore-errors (delete-window w2))))
    (enhanced-dirvish-panes--focus-pane tab focus)))

(defun enhanced-dirvish-toggle-extra-pane ()
  "Toggle Nemo-style Extra Split Pane (`F3').
Closing the extra pane while focused promotes its location & view into Pane 1."
  (interactive)
  (let ((tab (enhanced-dirvish-active-tab)))
    (if (enhanced-dirvish-panes--extra-shown-p tab)
        ;; Close split
        (let* ((was-p2 (= (enhanced-dirvish-tab-state-active-pane tab) 2))
               (p1 (enhanced-dirvish-tab-state-pane1 tab))
               (p2 (enhanced-dirvish-tab-state-pane2 tab))
               (keep-dir (if (and was-p2 p2)
                             (enhanced-dirvish-pane-state-dir p2)
                           (enhanced-dirvish-pane-state-dir p1))))
          (when (and p2 (window-live-p (enhanced-dirvish-pane-state-window p2))
                     (not (one-window-p t)))
            (delete-window (enhanced-dirvish-pane-state-window p2)))
          (setf (enhanced-dirvish-tab-state-split-p tab) nil
                (enhanced-dirvish-tab-state-active-pane tab) 1
                (enhanced-dirvish-pane-state-dir p1) keep-dir)
          (when (window-live-p (enhanced-dirvish-pane-state-window p1))
            (select-window (enhanced-dirvish-pane-state-window p1)))
          (enhanced-dirvish-open-location keep-dir)
          (message "Closed split pane"))
      ;; Open split: ensure Pane 1 owns current window, split horizontally for Pane 2
      (let* ((cur-dir (or (bound-and-true-p enhanced-dirvish-view-directory)
                          (dirvish-prop :root)
                          default-directory))
             (p1 (or (enhanced-dirvish-tab-state-pane1 tab) (make-enhanced-dirvish-pane-state :id 1 :dir cur-dir)))
             (p2 (or (enhanced-dirvish-tab-state-pane2 tab) (make-enhanced-dirvish-pane-state :id 2 :dir cur-dir))))
        ;; Flatten Dirvish miller layout cleanly so two equal panes fit comfortably side by side
        (enhanced-dirvish--flatten-layout)
        (setf (enhanced-dirvish-pane-state-dir p1) cur-dir
              (enhanced-dirvish-pane-state-buffer p1) (current-buffer)
              (enhanced-dirvish-pane-state-window p1) (selected-window)
              (enhanced-dirvish-tab-state-pane1 tab) p1
              (enhanced-dirvish-tab-state-pane2 tab) p2)
        (enhanced-dirvish-panes--open-extra tab)
        (force-mode-line-update t)
        (message "Opened Extra Pane (F6 switches pane, C-S-c/C-S-x copies/moves across panes)")))))

(defun enhanced-dirvish-switch-other-pane ()
  "Switch keyboard & visual focus between Primary and Extra split panes (`F6')."
  (interactive)
  (let ((tab (enhanced-dirvish-active-tab)))
    (if (not (enhanced-dirvish-tab-state-split-p tab))
        (user-error "Extra pane is not open (press F3 to toggle split view)")
      (let* ((next-id (if (= (enhanced-dirvish-tab-state-active-pane tab) 1) 2 1))
             (target (if (= next-id 1)
                         (enhanced-dirvish-tab-state-pane1 tab)
                       (enhanced-dirvish-tab-state-pane2 tab))))
        (setf (enhanced-dirvish-tab-state-active-pane tab) next-id)
        (when (window-live-p (enhanced-dirvish-pane-state-window target))
          (select-window (enhanced-dirvish-pane-state-window target)))
        (force-mode-line-update t)
        (enhanced-dirvish-sidebar-refresh)))))

;;;; Per-Pane Persistent Terminal Drawer (C-` / F9) & Terminal Focus Guard

(defun enhanced-dirvish-terminal-focused-p (&optional win)
  "Return non-nil if focus is currently inside an embedded terminal buffer."
  (with-current-buffer (window-buffer (or win (selected-window)))
    (derived-mode-p 'vterm-mode 'term-mode 'eshell-mode)))

(defun enhanced-dirvish-pane--spawn-terminal (buf-name dir)
  "Create interactive terminal buffer BUF-NAME rooted at DIR."
  (let* ((default-directory (if (and dir (not (enhanced-dirvish-location-virtual-p dir)) (file-directory-p dir))
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
          (define-key lm (kbd "C-`") #'enhanced-dirvish-toggle-pane-terminal)
          (define-key lm (kbd "<f9>") #'enhanced-dirvish-toggle-pane-terminal)
          (use-local-map lm))))
    buf))

(defun enhanced-dirvish-toggle-pane-terminal ()
  "Toggle persistent embedded terminal drawer below active pane (`C-`' / `F9').
Keeps shell process & CWD alive while hidden."
  (interactive)
  (if (enhanced-dirvish-terminal-focused-p)
      ;; Inside terminal: hide drawer & return focus to parent file pane
      (let* ((pane (enhanced-dirvish-active-pane))
             (term-win (selected-window)))
        (setf (enhanced-dirvish-pane-state-terminal-open pane) nil)
        (when (not (one-window-p t))
          (enhanced-dirvish-windows--delete term-win))
        (when (window-live-p (enhanced-dirvish-pane-state-window pane))
          (select-window (enhanced-dirvish-pane-state-window pane))))
    (let* ((pane (enhanced-dirvish-active-pane))
           (tbuf (enhanced-dirvish-pane-state-terminal-buf pane))
           (existing-win (and (buffer-live-p tbuf) (get-buffer-window tbuf))))
      (cond
       (existing-win
        (setf (enhanced-dirvish-pane-state-terminal-open pane) nil)
        (enhanced-dirvish-windows--delete existing-win))
       (t
        (unless (buffer-live-p tbuf)
          (setq tbuf (enhanced-dirvish-pane--spawn-terminal
                      (format "*Enhanced Dirvish Terminal P%d (T%d)*"
                              (enhanced-dirvish-pane-state-id pane)
                              (enhanced-dirvish-tab-state-id (enhanced-dirvish-active-tab)))
                      (enhanced-dirvish-pane-state-dir pane)))
          (setf (enhanced-dirvish-pane-state-terminal-buf pane) tbuf))
        (let* ((pane-win (or (and (window-live-p (enhanced-dirvish-pane-state-window pane))
                                  (enhanced-dirvish-pane-state-window pane))
                             (selected-window)))
               (h (max 8 (/ (window-total-height pane-win) 3)))
               (twin (enhanced-dirvish-windows-display-terminal pane-win h pane)))
          (setf (enhanced-dirvish-pane-state-window pane) pane-win
                (enhanced-dirvish-pane-state-terminal-open pane) t)
          (select-window twin)
          (switch-to-buffer tbuf)
          (enhanced-dirvish-windows--reconcile)))))))

(defun enhanced-dirvish-open-external-terminal (&optional dir)
  "Launch host terminal emulator externally at DIR."
  (interactive)
  (let ((d (or dir (dirvish-prop :root) default-directory "~/")))
    (enhanced-dirvish-guard-writable-location d "Open in Terminal")
    (let ((term (cl-find-if #'executable-find '("foot" "kitty" "alacritty" "wezterm" "xterm")))
          (default-directory (file-name-as-directory (expand-file-name d))))
      (unless term (user-error "No external terminal emulator found on PATH"))
      (let ((process-environment (cons "FASTFETCH_ENABLED=0" process-environment)))
        (make-process :name "enhanced-dirvish-ext-term" :noquery t
                      :command (list term)
                      :file-handler nil))
      (message "Launched %s in %s" term d))))

;;;; Workspace Tabs & Session Persistence

(defun enhanced-dirvish-tabs-save ()
  "Save open workspace tabs to `enhanced-dirvish-tabs-state-file'."
  (when (enhanced-dirvish-prefs-restore-tabs (enhanced-dirvish-prefs))
    (let ((live (cl-remove-if-not
                 (lambda (tab) (enhanced-dirvish-valid-location-p (enhanced-dirvish-tab-state-dir tab)))
                 enhanced-dirvish-workspace-tabs)))
      (make-directory (file-name-directory enhanced-dirvish-tabs-state-file) t)
      (with-temp-file enhanced-dirvish-tabs-state-file
        (prin1 (list :active (if live
                                 (max 0 (min enhanced-dirvish-active-tab-index (1- (length live))))
                               0)
                     :tabs (mapcar (lambda (tab)
                                     (list :dir (enhanced-dirvish-tab-state-dir tab)
                                           :split-p (and (enhanced-dirvish-tab-state-split-p tab)
                                                         (enhanced-dirvish-tab-state-pane2 tab)
                                                         t)
                                           :pane2-dir (and (enhanced-dirvish-tab-state-split-p tab)
                                                           (enhanced-dirvish-tab-state-pane2 tab)
                                                           (enhanced-dirvish-pane-state-dir
                                                            (enhanced-dirvish-tab-state-pane2 tab)))))
                                   live))
               (current-buffer))
        (insert "\n")))))

(defun enhanced-dirvish-tabs-load ()
  "Restore saved tabs if `restore-tabs' is enabled and no tabs are loaded yet."
  (when (and (null enhanced-dirvish-workspace-tabs)
             (enhanced-dirvish-prefs-restore-tabs (enhanced-dirvish-prefs))
             (file-readable-p enhanced-dirvish-tabs-state-file))
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents enhanced-dirvish-tabs-state-file)
          (let* ((data (read (current-buffer)))
                 (saved (plist-get data :tabs))
                 (idx (or (plist-get data :active) 0)))
            (when (consp saved)
              (let ((live nil)
                    (orig-active (nth (max 0 (min idx (1- (length saved)))) saved))
                    (new-idx 0)
                    (i 0))
                (dolist (entry saved)
                  (let* ((d (or (plist-get entry :dir) "~/"))
                         (p2d (plist-get entry :pane2-dir))
                         (has-split (and (plist-get entry :split-p)
                                         p2d
                                         (enhanced-dirvish-valid-location-p p2d))))
                    (when (enhanced-dirvish-valid-location-p d)
                      (when (eq entry orig-active)
                        (setq new-idx i))
                      (push (make-enhanced-dirvish-tab-state
                             :id (cl-incf enhanced-dirvish-next-tab-id)
                             :label (let ((nm (file-name-nondirectory (directory-file-name d))))
                                      (if (string-empty-p nm) "/" nm))
                             :dir d
                             ;; The browser always starts with one pane (user
                             ;; choice); F3 reopens pane 2 where it was.
                             :split-p nil
                             :active-pane 1
                             :pane1 (make-enhanced-dirvish-pane-state :id 1 :dir d)
                             :pane2 (when has-split
                                      (make-enhanced-dirvish-pane-state :id 2 :dir p2d)))
                            live)
                      (cl-incf i))))
                (setq enhanced-dirvish-workspace-tabs (nreverse live)
                      enhanced-dirvish-active-tab-index
                      (if enhanced-dirvish-workspace-tabs
                          (max 0 (min new-idx (1- (length enhanced-dirvish-workspace-tabs))))
                        0))))))
      (error nil))))

(defun enhanced-dirvish-tab-new (&optional dir)
  "Open a new Enhanced Dirvish browser tab at DIR (or current folder)."
  (interactive)
  (let* ((d (or dir (enhanced-dirvish-pane-state-dir (enhanced-dirvish-active-pane)) "~/"))
         (p1 (make-enhanced-dirvish-pane-state :id 1 :dir d))
         (tab (make-enhanced-dirvish-tab-state
               :id (cl-incf enhanced-dirvish-next-tab-id)
               :label (file-name-nondirectory (directory-file-name d))
               :dir d :active-pane 1 :pane1 p1)))
    (let ((old (enhanced-dirvish-active-tab))) ; also initializes the tab list
      (setq enhanced-dirvish-workspace-tabs (append enhanced-dirvish-workspace-tabs (list tab))
            enhanced-dirvish-active-tab-index (1- (length enhanced-dirvish-workspace-tabs)))
      (enhanced-dirvish-panes--show-active-tab old))
    (message "Tab %d/%d: %s" (1+ enhanced-dirvish-active-tab-index) (length enhanced-dirvish-workspace-tabs)
             (enhanced-dirvish-tab-state-label tab))))

(defun enhanced-dirvish-tab-close ()
  "Close current tab, pushing it onto `enhanced-dirvish-closed-tabs' (max 20)."
  (interactive)
  (if (<= (length enhanced-dirvish-workspace-tabs) 1)
      (when (fboundp 'dirvish-quit) (dirvish-quit))
    (let ((closing (nth enhanced-dirvish-active-tab-index enhanced-dirvish-workspace-tabs)))
      (push closing enhanced-dirvish-closed-tabs)
      (when (> (length enhanced-dirvish-closed-tabs) 20)
        (setcdr (nthcdr 19 enhanced-dirvish-closed-tabs) nil))
      (setq enhanced-dirvish-workspace-tabs
            (cl-remove closing enhanced-dirvish-workspace-tabs :test #'eq)
            enhanced-dirvish-active-tab-index
            (max 0 (min enhanced-dirvish-active-tab-index (1- (length enhanced-dirvish-workspace-tabs)))))
      (enhanced-dirvish-panes--show-active-tab closing))))

(defun enhanced-dirvish-tab-reopen-closed ()
  "Reopen most recently closed Enhanced Dirvish tab (`C-S-t')."
  (interactive)
  (if (null enhanced-dirvish-closed-tabs)
      (message "No closed tabs to reopen")
    (let ((tab (pop enhanced-dirvish-closed-tabs))
          (old (enhanced-dirvish-active-tab)))
      (setq enhanced-dirvish-workspace-tabs (append enhanced-dirvish-workspace-tabs (list tab))
            enhanced-dirvish-active-tab-index (1- (length enhanced-dirvish-workspace-tabs)))
      (enhanced-dirvish-panes--show-active-tab old))))

(defun enhanced-dirvish-tab-switch-index (n)
  "Switch to 1-based Enhanced Dirvish tab number N."
  (interactive "p")
  (when enhanced-dirvish-workspace-tabs
    (let ((idx (max 0 (min (1- n) (1- (length enhanced-dirvish-workspace-tabs)))))
          (old (enhanced-dirvish-active-tab)))
      (setq enhanced-dirvish-active-tab-index idx)
      (enhanced-dirvish-panes--show-active-tab old)
      (message "Tab %d/%d: %s" (1+ idx) (length enhanced-dirvish-workspace-tabs)
               (enhanced-dirvish-tab-state-label (enhanced-dirvish-active-tab))))))

(defun enhanced-dirvish-tab-next ()
  "Cycle to next Enhanced Dirvish workspace tab."
  (interactive)
  (when (> (length enhanced-dirvish-workspace-tabs) 1)
    (let ((old (enhanced-dirvish-active-tab)))
      (setq enhanced-dirvish-active-tab-index
            (mod (1+ enhanced-dirvish-active-tab-index) (length enhanced-dirvish-workspace-tabs)))
      (enhanced-dirvish-panes--show-active-tab old))))

(defun enhanced-dirvish-tab-previous ()
  "Cycle to previous Enhanced Dirvish workspace tab."
  (interactive)
  (when (> (length enhanced-dirvish-workspace-tabs) 1)
    (let ((old (enhanced-dirvish-active-tab)))
      (setq enhanced-dirvish-active-tab-index
            (mod (1- enhanced-dirvish-active-tab-index) (length enhanced-dirvish-workspace-tabs)))
      (enhanced-dirvish-panes--show-active-tab old))))

(defun enhanced-dirvish-tab-move (delta)
  "Move current tab by DELTA (-1 left, +1 right) and persist order."
  (interactive "p")
  (let* ((len (length enhanced-dirvish-workspace-tabs))
         (idx enhanced-dirvish-active-tab-index)
         (next (+ idx delta)))
    (when (and (> len 1) (>= next 0) (< next len))
      (cl-rotatef (nth idx enhanced-dirvish-workspace-tabs) (nth next enhanced-dirvish-workspace-tabs))
      (setq enhanced-dirvish-active-tab-index next)
      (enhanced-dirvish-tabs-save)
      (message "Moved tab to position %d" (1+ next)))))

(defun enhanced-dirvish-open-in-new-tab ()
  "Open folder at point in a new Enhanced Dirvish tab (`C-RET')."
  (interactive)
  (let ((f (enhanced-dirvish-current-file)))
    (if (and f (file-directory-p f))
        (enhanced-dirvish-tab-new f)
      (find-file f))))

(defun enhanced-dirvish-open-in-new-frame ()
  "Open folder at point in a new Emacs frame (`S-RET')."
  (interactive)
  (let ((f (or (enhanced-dirvish-current-file) default-directory))
        (frame (make-frame)))
    (select-frame-set-input-focus frame)
    (if (file-directory-p f) (enhanced-dirvish-open-location f) (find-file f))))

;;;; Enhanced Dirvish Left Sidebar (Places + Pinned Bookmarks + Grouped Devices w/ Capacity Bars)

(defun enhanced-dirvish-sidebar-mouse-activate (event)
  "Select clicked entry at EVENT in `*Enhanced Dirvish Sidebar*' and open it."
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
      (enhanced-dirvish-sidebar-activate-at-point))))

(defvar enhanced-dirvish-sidebar-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    (define-key map (kbd "<down>") #'next-line)
    (define-key map (kbd "<up>") #'previous-line)
    (define-key map (kbd "RET") #'enhanced-dirvish-sidebar-activate-at-point)
    (define-key map (kbd "l") #'enhanced-dirvish-sidebar-activate-at-point)
    (define-key map (kbd "<right>") #'enhanced-dirvish-sidebar-activate-at-point)
    (define-key map (kbd "<mouse-1>") #'enhanced-dirvish-sidebar-mouse-activate)
    (define-key map (kbd "<double-mouse-1>") #'enhanced-dirvish-sidebar-mouse-activate)
    (define-key map (kbd "<drag-mouse-1>") #'enhanced-dirvish-sidebar-mouse-activate)
    (define-key map (kbd "<mouse-2>") #'enhanced-dirvish-sidebar-mouse-activate)
    (define-key map (kbd "t") #'enhanced-dirvish-sidebar-open-in-tab-at-point)
    (define-key map (kbd "m") #'enhanced-dirvish-sidebar-mount-at-point)
    (define-key map (kbd "u") #'enhanced-dirvish-sidebar-unmount-at-point)
    (define-key map (kbd "E") #'enhanced-dirvish-sidebar-eject-at-point)
    (define-key map (kbd "X") #'enhanced-dirvish-trash-empty)
    (define-key map (kbd "c") #'enhanced-dirvish-sidebar-toggle-rail)
    (define-key map (kbd "g") #'enhanced-dirvish-sidebar-force-refresh)
    (enhanced-dirvish-mouse-install-history-bindings map)
    map)
  "Keymap for `*Enhanced Dirvish Sidebar*' buffer.")

(define-derived-mode enhanced-dirvish-sidebar-mode special-mode "Enhanced-Dirvish-Sidebar"
  "Enhanced Dirvish Sidebar displaying Places, Pinned Bookmarks, and Devices."
  (setq-local truncate-lines t)
  (setq-local mode-line-format nil)
  (hl-line-mode 1)
  (add-hook 'enhanced-dirvish-devices-refresh-hook #'enhanced-dirvish-sidebar-refresh nil t))

(defun enhanced-dirvish-sidebar--place-specs ()
  "Return ordered list of standard place plists matching preferences."
  (let ((p (enhanced-dirvish-prefs))
        (specs `(("home" ,(enhanced-dirvish-icon-glyph 'home) "Home" ,(expand-file-name "~/") nil ,(enhanced-dirvish-prefs-sidebar-show-home (enhanced-dirvish-prefs)))
                 ("computer" ,(enhanced-dirvish-icon-glyph 'computer) "Computer" "computer:///" nil ,(enhanced-dirvish-prefs-sidebar-show-computer (enhanced-dirvish-prefs)))
                 ("trash" ,(enhanced-dirvish-icon-glyph 'trash) ,(format "Trash (%d)" (length (enhanced-dirvish-trash-items))) "trash:///" nil ,(enhanced-dirvish-prefs-sidebar-show-trash (enhanced-dirvish-prefs)))
                 ("network" ,(enhanced-dirvish-icon-glyph 'network) "Network" "network:///" nil ,(enhanced-dirvish-prefs-sidebar-show-network (enhanced-dirvish-prefs)))
                 ("recent" ,(enhanced-dirvish-icon-glyph 'recent) "Recent" "recent:///" nil ,(enhanced-dirvish-prefs-sidebar-show-recent (enhanced-dirvish-prefs)))
                 ("desktop" ,(enhanced-dirvish-icon-glyph 'desktop) "Desktop" ,(expand-file-name "~/Desktop") nil ,(enhanced-dirvish-prefs-sidebar-show-desktop (enhanced-dirvish-prefs)))
                 ("documents" ,(enhanced-dirvish-icon-glyph 'documents) "Documents" ,(expand-file-name "~/Documents") nil ,(enhanced-dirvish-prefs-sidebar-show-documents (enhanced-dirvish-prefs)))
                 ("downloads" ,(enhanced-dirvish-icon-glyph 'downloads) "Downloads" ,(expand-file-name "~/Downloads") nil ,(enhanced-dirvish-prefs-sidebar-show-downloads (enhanced-dirvish-prefs)))
                 ("music" ,(enhanced-dirvish-icon-glyph 'music) "Music" ,(expand-file-name "~/Music") nil ,(enhanced-dirvish-prefs-sidebar-show-music (enhanced-dirvish-prefs)))
                 ("pictures" ,(enhanced-dirvish-icon-glyph 'pictures) "Pictures" ,(expand-file-name "~/Pictures") nil ,(enhanced-dirvish-prefs-sidebar-show-pictures (enhanced-dirvish-prefs)))
                 ("videos" ,(enhanced-dirvish-icon-glyph 'videos) "Videos" ,(expand-file-name "~/Videos") nil ,(enhanced-dirvish-prefs-sidebar-show-videos (enhanced-dirvish-prefs))))))
    (cl-loop for id in (enhanced-dirvish-prefs-sidebar-order p)
             for sp = (assoc id specs)
             when (and sp (nth 5 sp)
                       (or (enhanced-dirvish-location-virtual-p (nth 3 sp))
                           (file-directory-p (nth 3 sp))))
             collect sp)))

(defun enhanced-dirvish-sidebar-render ()
  "Render `*Enhanced Dirvish Sidebar*' contents."
  (when-let ((buf (get-buffer "*Enhanced Dirvish Sidebar*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (pt (point))
            (p (enhanced-dirvish-prefs))
            (rail (enhanced-dirvish-prefs-sidebar-compact (enhanced-dirvish-prefs)))
            (cur-dir (ignore-errors (enhanced-dirvish-pane-state-dir (enhanced-dirvish-active-pane)))))
        (erase-buffer)
        (insert (propertize (if rail " Places\n" "  PLACES\n") 'face 'enhanced-dirvish-section-heading))
        (dolist (sp (enhanced-dirvish-sidebar--place-specs))
          (let* ((icon (nth 1 sp))
                 (label (nth 2 sp))
                 (loc (nth 3 sp))
                 (active (and cur-dir (equal (directory-file-name cur-dir) (directory-file-name loc))))
                 (txt (if rail (format "  %s\n" icon)
                        (format "  %s  %s\n" icon (propertize label 'face (if active 'enhanced-dirvish-header-accent 'default))))))
            (insert (enhanced-dirvish-add-row-properties
                     txt (list 'enhanced-dirvish-sidebar-loc loc
                               'mouse-face 'highlight
                               'pointer 'hand
                               'help-echo loc)))))
        (unless (enhanced-dirvish-prefs-sidebar-pinned-collapsed p)
          (let ((pins (enhanced-dirvish-bookmarks-read))
                (idx 0)
                (pin-ico (enhanced-dirvish-icon-glyph 'bookmark 'enhanced-dirvish-header-accent)))
            (when pins
              (insert "\n" (propertize (if rail " Pins\n" "  PINNED\n") 'face 'enhanced-dirvish-section-heading))
              (dolist (pin pins)
                (setq idx (1+ idx))
                (let* ((loc (car pin))
                       (lbl (cdr pin))
                       (keycap (if (<= idx 9) (propertize (format "[%d]" idx) 'face 'enhanced-dirvish-hint-key) "   "))
                       (txt (if rail (format "  %s%s\n" pin-ico (if (<= idx 9) (number-to-string idx) ""))
                              (format "  %s %s %s\n" pin-ico keycap lbl))))
                  (insert (enhanced-dirvish-add-row-properties
                           txt (list 'enhanced-dirvish-sidebar-loc loc
                                     'mouse-face 'highlight
                                     'pointer 'hand
                                     'help-echo loc))))))))
        (unless (enhanced-dirvish-prefs-sidebar-devices-collapsed p)
          (insert "\n" (propertize (if rail " Devs\n" "  DEVICES\n") 'face 'enhanced-dirvish-section-heading))
          (if (null enhanced-dirvish-devices-cache)
              (let ((txt (if rail "  [Scan]\n" "  [Scan drives (g)]\n")))
                (insert (enhanced-dirvish-add-row-properties
                         txt '(enhanced-dirvish-sidebar-action scan-devices
                               mouse-face highlight
                               pointer hand
                               help-echo "Scan block and mounted devices (g)"))))
            (dolist (dev enhanced-dirvish-devices-cache)
              (let* ((icon (enhanced-dirvish-device-icon dev))
                     (name (enhanced-dirvish-device-name dev))
                     (mp (enhanced-dirvish-device-mountpoint dev))
                     (bar (when (and (not rail) (enhanced-dirvish-device-usage dev))
                            (concat "\n     " (enhanced-dirvish-format-capacity-bar (enhanced-dirvish-device-usage dev) 10 t))))
                     (txt (if rail
                              (format "  %s\n" icon)
                            (format "  %s  %s%s\n" icon name (or bar "")))))
                (insert (enhanced-dirvish-add-row-properties
                         txt (list 'enhanced-dirvish-device dev 'enhanced-dirvish-sidebar-loc mp
                                   'mouse-face 'highlight
                                   'pointer 'hand
                                   'help-echo (or mp (enhanced-dirvish-device-device dev)))))))))
        (goto-char (min pt (point-max)))
        (when (fboundp 'enhanced-dirvish-watch-sync)
          (enhanced-dirvish-watch-sync buf))))))

(defun enhanced-dirvish-sidebar-refresh ()
  "Refresh a visible `*Enhanced Dirvish Sidebar*' without a device rescan."
  (interactive)
  (when (get-buffer "*Enhanced Dirvish Sidebar*")
    (enhanced-dirvish-sidebar-render)))

(defun enhanced-dirvish-sidebar-force-refresh ()
  "Scan devices and refresh `*Enhanced Dirvish Sidebar*'."
  (interactive)
  (enhanced-dirvish-devices-list t)
  (enhanced-dirvish-sidebar-refresh))

(defun enhanced-dirvish-sidebar-toggle ()
  "Toggle visibility of the left Enhanced Dirvish Sidebar (`C-b` / `C-n`)."
  (interactive)
  (let ((p (enhanced-dirvish-prefs)))
    (if (window-live-p enhanced-dirvish-sidebar-window)
        (progn
          (enhanced-dirvish-windows--delete enhanced-dirvish-sidebar-window)
          (setq enhanced-dirvish-sidebar-window nil)
          (setf (enhanced-dirvish-prefs-sidebar-expanded p) nil)
          (enhanced-dirvish-prefs-save))
      (let* ((buf (get-buffer-create "*Enhanced Dirvish Sidebar*"))
             (w (if (enhanced-dirvish-prefs-sidebar-compact p) 9 28)))
        (with-current-buffer buf
          (unless (derived-mode-p 'enhanced-dirvish-sidebar-mode)
            (enhanced-dirvish-sidebar-mode)))
        (enhanced-dirvish-sidebar-render)
        (setq enhanced-dirvish-sidebar-window
              (enhanced-dirvish-windows-display-sidebar buf w))
        (setf (enhanced-dirvish-prefs-sidebar-expanded p) t)
        (enhanced-dirvish-prefs-save)))))

(defun enhanced-dirvish-sidebar-toggle-rail ()
  "Toggle compact/rail mode on the left Enhanced Dirvish Sidebar."
  (interactive)
  (let ((p (enhanced-dirvish-prefs)))
    (setf (enhanced-dirvish-prefs-sidebar-compact p) (not (enhanced-dirvish-prefs-sidebar-compact p)))
    (enhanced-dirvish-prefs-save)
    (when (window-live-p enhanced-dirvish-sidebar-window)
      (enhanced-dirvish-sidebar-toggle)
      (enhanced-dirvish-sidebar-toggle))))

(defun enhanced-dirvish-sidebar-focus ()
  "Focus the Enhanced Dirvish Sidebar (opening it if hidden)."
  (interactive)
  (unless (window-live-p enhanced-dirvish-sidebar-window)
    (enhanced-dirvish-sidebar-toggle))
  (when (window-live-p enhanced-dirvish-sidebar-window)
    (select-window enhanced-dirvish-sidebar-window)))

(defun enhanced-dirvish-sidebar--row-prop (prop)
  "Read text property PROP from point, or from the beginning of the current row."
  (or (get-text-property (point) prop)
      (get-text-property (line-beginning-position) prop)))

(defun enhanced-dirvish-sidebar-activate-at-point ()
  "Activate place, pin, or device on current Sidebar row."
  (interactive)
  (let ((action (enhanced-dirvish-sidebar--row-prop 'enhanced-dirvish-sidebar-action))
        (dev (enhanced-dirvish-sidebar--row-prop 'enhanced-dirvish-device))
        (loc (enhanced-dirvish-sidebar--row-prop 'enhanced-dirvish-sidebar-loc)))
    (cond
     ((eq action 'scan-devices)
      (enhanced-dirvish-sidebar-force-refresh))
     ((and dev (not (enhanced-dirvish-device-mounted-p dev)))
      (enhanced-dirvish-device-mount dev #'enhanced-dirvish-open-location))
     (loc (enhanced-dirvish-open-location loc))
     (t (user-error "Nothing selectable on this sidebar row")))))

(defun enhanced-dirvish-sidebar-open-in-tab-at-point ()
  "Open Sidebar place/device at point in a new tab."
  (interactive)
  (when-let ((loc (enhanced-dirvish-sidebar--row-prop 'enhanced-dirvish-sidebar-loc)))
    (enhanced-dirvish-tab-new loc)))

(defun enhanced-dirvish-sidebar-mount-at-point ()
  "Mount/unlock device on Sidebar row."
  (interactive)
  (if-let ((dev (enhanced-dirvish-sidebar--row-prop 'enhanced-dirvish-device)))
      (enhanced-dirvish-device-mount dev)
    (user-error "No device on this row")))

(defun enhanced-dirvish-sidebar-unmount-at-point ()
  "Unmount device on Sidebar row."
  (interactive)
  (if-let ((dev (enhanced-dirvish-sidebar--row-prop 'enhanced-dirvish-device)))
      (enhanced-dirvish-device-unmount dev)
    (user-error "No device on this row")))

(defun enhanced-dirvish-sidebar-eject-at-point ()
  "Safely eject device on Sidebar row."
  (interactive)
  (if-let ((dev (enhanced-dirvish-sidebar--row-prop 'enhanced-dirvish-device)))
      (enhanced-dirvish-device-eject dev)
    (user-error "No device on this row")))

(provide 'enhanced-dirvish-panes)
;;; enhanced-dirvish-panes.el ends here
