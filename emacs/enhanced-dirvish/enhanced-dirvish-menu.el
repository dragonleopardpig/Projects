;;; enhanced-dirvish-menu.el --- Context-aware Enhanced Dirvish menu bar -*- lexical-binding: t; -*-

;;; Commentary:
;; The complete file-manager menu remains available throughout Emacs.  Only
;; relevant commands are enabled.  Menu context uses buffer state and cached
;; mount information, without enumerating devices or probing remote files.

;;; Code:

(require 'easymenu)
(require 'enhanced-dirvish-keys)

(defvar enhanced-dirvish-menu--context nil "Snapshot of the current menu's buffer and capabilities.")

(defun enhanced-dirvish-menu--writable-p (dir)
  "Check local DIR permissions, without statting remote or cloud mounts."
  (enhanced-dirvish-path-writable-p dir))

(defun enhanced-dirvish-menu--refresh-context ()
  "Capture the selected window's file-manager state without changing it."
  (let* ((window (selected-window))
         (dv (with-current-buffer (window-buffer window) (ignore-errors (dirvish-curr)))))
    (when (and dv (with-current-buffer (window-buffer window)
                    (derived-mode-p 'dirvish-misc-mode)))
      (when (window-live-p (dv-root-window dv)) (setq window (dv-root-window dv))))
    (with-current-buffer (window-buffer window)
      (let* ((browser (derived-mode-p 'dired-mode 'enhanced-dirvish-compact-mode 'enhanced-dirvish-icons-mode))
             (sidebar (derived-mode-p 'enhanced-dirvish-sidebar-mode))
             (computer (derived-mode-p 'enhanced-dirvish-computer-mode))
             (trash (derived-mode-p 'enhanced-dirvish-trash-mode))
             (recent (derived-mode-p 'enhanced-dirvish-recent-mode))
             (search (derived-mode-p 'enhanced-dirvish-global-search-mode))
             (tab (nth enhanced-dirvish-active-tab-index enhanced-dirvish-workspace-tabs))
             (pane (and tab (if (= (enhanced-dirvish-tab-state-active-pane tab) 2)
                                    (enhanced-dirvish-tab-state-pane2 tab) (enhanced-dirvish-tab-state-pane1 tab))))
             (terminal (and pane (derived-mode-p 'vterm-mode 'term-mode 'eshell-mode)
                            (eq (current-buffer) (enhanced-dirvish-pane-state-terminal-buf pane))))
             (read-preview (bound-and-true-p enhanced-dirvish-preview-read-mode))
             (edit-preview (bound-and-true-p enhanced-dirvish-preview-edit-mode))
             (workspace (or browser sidebar computer trash recent search terminal read-preview edit-preview))
             (other (and tab (enhanced-dirvish-tab-state-split-p tab)
                         (if (= (enhanced-dirvish-tab-state-active-pane tab) 2)
                             (enhanced-dirvish-tab-state-pane1 tab) (enhanced-dirvish-tab-state-pane2 tab))))
             (dir (and browser (or enhanced-dirvish-view-directory (dirvish-prop :root) default-directory)))
             (physical (and dir (not (enhanced-dirvish-location-virtual-p dir))))
             (writable (and physical (enhanced-dirvish-menu--writable-p dir)))
             ;; Do not call enhanced-dirvish-marked-files-only in custom grids here:
             ;; that helper stats every marked file to prune vanished paths.
             (marked (and browser (if (derived-mode-p 'dired-mode)
                                      (enhanced-dirvish-marked-files-only)
                                    (reverse enhanced-dirvish-marked-entries))))
             (current (and browser (enhanced-dirvish-current-file)))
             (items (or marked (when current (list current))))
             (single (= (length items) 1))
             (directory-p (and current
                               (or (get-text-property (point) 'enhanced-dirvish-entry-dir)
                                   (and (derived-mode-p 'dired-mode)
                                        (save-excursion (beginning-of-line) (looking-at-p dired-re-dir))))))
             (item-dir-p (and single
                              (if (and current (equal (directory-file-name (car items))
                                                      (directory-file-name current)))
                                  directory-p
                                (and (not (enhanced-dirvish-path-unsafe-probe-p (car items)))
                                     (file-directory-p (car items))))))
             (preview-window (or (and dv (dv-preview-window dv)) enhanced-dirvish-preview-standalone-window))
             (preview (and workspace (or read-preview edit-preview (window-live-p preview-window))))
             (device (and (or sidebar computer)
                          (or (get-text-property (point) 'enhanced-dirvish-device)
                              (get-text-property (line-beginning-position) 'enhanced-dirvish-device))))
             (mounted (and device (enhanced-dirvish-device-mounted-p device)))
             (removable (and device (eq (enhanced-dirvish-device-placement device) 'removable)))
             (other-dir (and other (enhanced-dirvish-pane-state-dir other)))
             (transfer (and items other-dir (enhanced-dirvish-menu--writable-p other-dir)
                            (not (equal (directory-file-name dir) (directory-file-name other-dir)))))
             (archive (and single (not item-dir-p)
                           (enhanced-dirvish-archive-file-p (car items))))
             (media (and workspace (or (and preview (eq enhanced-dirvish-active-preview-kind 'media))
                                      (and single (not item-dir-p)
                                           (string-match-p
                                            "\\.\\(?:mp[34]\\|mkv\\|webm\\|wav\\|flac\\|ogg\\|opus\\|m4a\\|mov\\|avi\\)\\'"
                                            (downcase (car items))))))))
        (setq enhanced-dirvish-menu--context
              (list :window window :buffer (current-buffer)
                    :always t :workspace workspace :browser browser :physical physical :dir dir
                    :writable writable :items items :current current
                    :single (and browser single current (equal current (car items)))
                    :file (and browser current (not directory-p))
                    :writable-items (and items writable)
                    :writable-single (and single current (equal current (car items)) writable)
                    :marks marked :filter (and browser (or enhanced-dirvish-local-filter (dirvish-prop :narrow-info)))
                    :find (and browser enhanced-dirvish-last-find-query)
                    :back (and workspace pane (enhanced-dirvish-pane-state-history-back pane))
                    :forward (and workspace pane (enhanced-dirvish-pane-state-history-fwd pane))
                    :columns (and browser (eq (enhanced-dirvish-view-current-mode) 'columns))
                    :list (and browser (eq (enhanced-dirvish-view-current-mode) 'list))
                    :sorted (and browser (not (eq (enhanced-dirvish-prefs-sort-key (enhanced-dirvish-prefs)) 'unsorted)))
                    :name-sort (and browser (eq (enhanced-dirvish-prefs-sort-key (enhanced-dirvish-prefs)) 'name))
                    :icons (derived-mode-p 'enhanced-dirvish-icons-mode) :compact (derived-mode-p 'enhanced-dirvish-compact-mode)
                    :split (and workspace other) :transfer transfer :move-transfer (and transfer writable)
                    :clipboard (and writable (plist-get enhanced-dirvish-clipboard :files))
                    :clipboard-any (plist-get enhanced-dirvish-clipboard :files)
                    :undo (and browser enhanced-dirvish-undo-stack) :redo (and browser enhanced-dirvish-redo-stack)
                    :tabs (and workspace tab) :cycle-tabs (and workspace (> (length enhanced-dirvish-workspace-tabs) 1))
                    :tab-left (and workspace tab (> enhanced-dirvish-active-tab-index 0))
                    :tab-right (and workspace tab (< enhanced-dirvish-active-tab-index (1- (length enhanced-dirvish-workspace-tabs))))
                    :closed-tabs enhanced-dirvish-closed-tabs :terminal (and workspace (or browser terminal))
                    :terminal-open (and workspace pane (enhanced-dirvish-pane-state-terminal-open pane))
                    :preview preview :preview-read read-preview :preview-edit edit-preview
                    :preview-text (and preview (eq enhanced-dirvish-active-preview-kind 'text))
                    :zoom (and preview (memq enhanced-dirvish-active-preview-kind '(text image pdf)))
                    :pdf (and preview (eq enhanced-dirvish-active-preview-kind 'pdf))
                    :media media :playing (and enhanced-dirvish-media-proc (process-live-p enhanced-dirvish-media-proc))
                    :computer computer :sidebar sidebar :device device
                    :mount (and device (not mounted))
                    :unmount (and mounted (not (equal (enhanced-dirvish-device-mountpoint device) "/")))
                    :eject (and removable (not (equal (enhanced-dirvish-device-mountpoint device) "/")))
                    :trash trash :trash-item (and trash (get-text-property (line-beginning-position) 'enhanced-dirvish-trash-item))
                    :trash-items (and trash (text-property-not-all (point-min) (point-max) 'enhanced-dirvish-trash-item nil))
                    :recent recent :recent-item (and recent (get-text-property (line-beginning-position) 'enhanced-dirvish-recent-path))
                    :search-item (and search (get-text-property (line-beginning-position) 'enhanced-dirvish-search-path))
                    :sidebar-item (and sidebar (or device (get-text-property (line-beginning-position) 'enhanced-dirvish-sidebar-loc)))
                    :sidebar-location (and sidebar (get-text-property (line-beginning-position) 'enhanced-dirvish-sidebar-loc))
                    :archive (and archive writable) :bookmarks (enhanced-dirvish-prefs-marks (enhanced-dirvish-prefs))))))))

(defun enhanced-dirvish-menu--enabled-p (command capability)
  "Whether COMMAND is available for CAPABILITY in the current menu snapshot."
  (and (fboundp command) (plist-get enhanced-dirvish-menu--context (intern (concat ":" (symbol-name capability))))))

(defun enhanced-dirvish-menu--selected-p (state)
  "Return the checked state for menu STATE."
  (pcase state
    (`(view ,mode)
     (let ((buf (plist-get enhanced-dirvish-menu--context :buffer)))
       (and (buffer-live-p buf)
            (plist-get enhanced-dirvish-menu--context :browser)
            (with-current-buffer buf
              (eq (enhanced-dirvish-view-current-mode) mode)))))
    (`(pref ,accessor) (funcall accessor (enhanced-dirvish-prefs)))
    (`(direction ,direction) (eq (enhanced-dirvish-prefs-sort-direction (enhanced-dirvish-prefs)) direction))
    (`(context ,key) (plist-get enhanced-dirvish-menu--context (intern (concat ":" (symbol-name key)))))
    (_ nil)))

(defun enhanced-dirvish-menu--dispatch (command arguments)
  "Run COMMAND with ARGUMENTS in the context used to build the menu."
  (let ((window (plist-get enhanced-dirvish-menu--context :window)))
    (when (window-live-p window)
      (select-window window)
      (enhanced-dirvish-panes--sync-active-pane-from-window window)))
  ;; `use-dialog-box-p' inspects `last-nonmenu-event', which stays a key event
  ;; across native menu-bar clicks; also treat `(menu-bar ...)` events as mouse.
  (let* ((mouse-p
          (and (display-graphic-p)
               (display-popup-menus-p)
               (or (eq (car-safe last-input-event) 'menu-bar)
                   (eq (car-safe last-command-event) 'menu-bar)
                   (let ((use-dialog-box t)) (use-dialog-box-p)))))
         (enhanced-dirvish-ui-input-method (if mouse-p 'mouse 'keyboard))
         (use-dialog-box t) (use-file-dialog t))
    (pcase command
      ((or 'enhanced-dirvish-letter-bookmark-set 'enhanced-dirvish-letter-bookmark-go)
       (let* ((letters (if (eq command 'enhanced-dirvish-letter-bookmark-go)
                           (mapcar #'car (enhanced-dirvish-prefs-marks (enhanced-dirvish-prefs)))
                         (number-sequence ?a ?z)))
              (letter (string-to-char
                       (enhanced-dirvish-ui-completing-read "Bookmark letter:" (mapcar #'char-to-string letters) nil t))))
         (if (eq command 'enhanced-dirvish-letter-bookmark-set)
             (funcall command letter (plist-get enhanced-dirvish-menu--context :dir))
           (funcall command letter))))
      ('enhanced-dirvish-tab-switch-index
       (funcall command (string-to-number
                         (enhanced-dirvish-ui-completing-read "Tab number:"
                                                   (mapcar #'number-to-string (number-sequence 1 (length enhanced-dirvish-workspace-tabs))) nil t))))
      (_ (if (or arguments (not (commandp command)))
             (apply command arguments)
           (call-interactively command))))))

(defconst enhanced-dirvish-menu--catalog
  '(["Open File Browser" enhanced-dirvish-launch always]
    "--"
    ("Files"
     ["Open / Edit" enhanced-dirvish-open-or-edit-at-point current]
     ["Open With…" enhanced-dirvish-open-with items]
     ["Open in New Tab" enhanced-dirvish-open-in-new-tab single]
     ["Open in New Frame" enhanced-dirvish-open-in-new-frame single]
     "--"
     ["New File…" enhanced-dirvish-new-file writable]
     ["New Folder…" enhanced-dirvish-new-folder writable]
     ["Create File or Folder…" enhanced-dirvish-create-entry writable]
     ["New Folder with Selection…" enhanced-dirvish-new-folder-with-selection writable-items]
     ["Rename…" enhanced-dirvish-rename writable-single]
     ["Duplicate" enhanced-dirvish-duplicate writable-items]
     ["Move to Trash…" enhanced-dirvish-move-to-trash writable-items]
     ["Delete Permanently…" enhanced-dirvish-delete-permanently writable-items]
     "--"
     ["Compress Archive…" enhanced-dirvish-archive-compress writable-items]
     ["Compress with Encryption…" enhanced-dirvish-archive-compress-encrypted writable-items]
     ["Extract Here" enhanced-dirvish-archive-extract archive]
     ["Extract to Folder…" enhanced-dirvish-archive-extract archive (t)]
     ["Properties…" enhanced-dirvish-show-properties-for-path physical]
     ["Customize Folder…" enhanced-dirvish-customize-folder writable])
    ("Clipboard & Transfers"
     ["Copy" enhanced-dirvish-copy-selection items] ["Cut" enhanced-dirvish-cut-selection writable-items]
     ["Paste (Keep Both)" enhanced-dirvish-paste-keep-both clipboard]
     ["Paste (Replace)" enhanced-dirvish-paste-replace clipboard]
     ["Save Clipboard Image / Text…" enhanced-dirvish-paste-content-drop writable]
     ["Copy Path" enhanced-dirvish-copy-path items] ["Copy Name" enhanced-dirvish-copy-name items]
     ["Clear Clipboard" enhanced-dirvish-unyank clipboard-any]
     "--"
     ["Copy to Folder…" enhanced-dirvish-copy-to items] ["Move to Folder…" enhanced-dirvish-move-to writable-items]
     ["Copy to Other Pane" enhanced-dirvish-copy-to-other-pane transfer]
     ["Move to Other Pane" enhanced-dirvish-move-to-other-pane move-transfer]
     "--" ["Undo File Operation" enhanced-dirvish-undo undo] ["Redo File Operation" enhanced-dirvish-redo redo])
    ("Selection"
     ["Toggle Current Item" enhanced-dirvish-view-toggle-mark items] ["Unmark Current Item" enhanced-dirvish-view-unmark items]
     ["Select All" enhanced-dirvish-select-all browser] ["Clear Selection" enhanced-dirvish-clear-all-marks marks]
     ["Invert Selection" enhanced-dirvish-invert-selection browser] ["Clear Selection and Filter" enhanced-dirvish-escape browser]
     ["Visual Range Selection" enhanced-dirvish-visual-toggle items]
     ("Extend Range"
      ["Next Row" enhanced-dirvish-shift-select-next items] ["Previous Row" enhanced-dirvish-shift-select-prev items]
      ["Left" enhanced-dirvish-shift-select-left items] ["Right" enhanced-dirvish-shift-select-right items]
      ["To First Item" enhanced-dirvish-shift-select-first items] ["To Last Item" enhanced-dirvish-shift-select-last items]))
    ("Go"
     ["Open File Browser" enhanced-dirvish-launch always]
     ["Home" enhanced-dirvish-open-location always ("~/")]
     ["Computer / Drives" enhanced-dirvish-launch-computer always]
     ["Trash" enhanced-dirvish-launch-trash always] ["Recent Files" enhanced-dirvish-launch-recent always]
     ["Location…" enhanced-dirvish-location-prompt workspace] ["Connect to Server…" enhanced-dirvish-connect-server always]
     ["Visited Folder…" enhanced-dirvish-jump-visited-folder always] ["Recent File…" enhanced-dirvish-jump-recent-file always]
     "--" ["Back" enhanced-dirvish-history-back back] ["Forward" enhanced-dirvish-history-forward forward]
     ["Parent Directory" enhanced-dirvish-view-up-directory browser]
     ["Left / Collapse" enhanced-dirvish-tree-collapse-or-up browser]
     ["Open / Expand" enhanced-dirvish-tree-expand-or-open current]
     ["Make First Column" enhanced-dirvish-make-first-column columns]
     ["Next Item" enhanced-dirvish-nav-next-line browser] ["Previous Item" enhanced-dirvish-nav-prev-line browser]
     ["Half Page Down" enhanced-dirvish-half-page-down browser] ["Half Page Up" enhanced-dirvish-half-page-up browser]
     ("Grid Navigation"
      ["Icons: Next Cell" enhanced-dirvish-icons-next-cell icons] ["Icons: Previous Cell" enhanced-dirvish-icons-prev-cell icons]
      ["Icons: Next Row" enhanced-dirvish-icons-next-row icons] ["Icons: Previous Row" enhanced-dirvish-icons-prev-row icons]
      ["Compact: Next Item" enhanced-dirvish-compact-next-item compact] ["Compact: Previous Item" enhanced-dirvish-compact-prev-item compact]
      ["Compact: Next Column" enhanced-dirvish-compact-next-col compact] ["Compact: Previous Column" enhanced-dirvish-compact-prev-col compact]))
    ("View & Sort"
     ["Columns" enhanced-dirvish-view-columns browser nil (view columns)]
     ["Icons" enhanced-dirvish-view-icons browser nil (view icons)]
     ["List / Tree" enhanced-dirvish-view-list browser nil (view list)]
     ["Compact" enhanced-dirvish-view-compact browser nil (view compact)]
     ["Choose Layout…" enhanced-dirvish-switch-view-mode browser]
     "--"
     ["Sort By…" enhanced-dirvish-sort-menu browser] ["Choose Sort Key…" enhanced-dirvish-sort-set browser]
     ["Ascending" enhanced-dirvish-sort-ascending sorted nil (direction asc)]
     ["Descending" enhanced-dirvish-sort-descending sorted nil (direction desc)]
     ["Reverse Sort Direction" enhanced-dirvish-sort-toggle-direction sorted]
     ["Folders First" enhanced-dirvish-sort-toggle-folders-first sorted nil (pref enhanced-dirvish-prefs-folders-first)]
     ["Natural Numeric Names" enhanced-dirvish-sort-toggle-natural name-sort nil (pref enhanced-dirvish-prefs-natural-sort)]
     ["Group by Type" enhanced-dirvish-toggle-group-by-type browser nil (pref enhanced-dirvish-prefs-group-by-type)]
     "--"
     ["Show Hidden Files" enhanced-dirvish-toggle-hidden-files browser nil (pref enhanced-dirvish-prefs-show-hidden)]
     ["Expandable Folders in List" enhanced-dirvish-toggle-expandable-tree list nil (pref enhanced-dirvish-prefs-expandable-tree)]
     ["Compact Full Filenames" enhanced-dirvish-toggle-compact-full-names compact nil (pref enhanced-dirvish-prefs-compact-full-names)]
     ["Larger Icons" enhanced-dirvish-thumbnails-scale icons (16)] ["Smaller Icons" enhanced-dirvish-thumbnails-scale icons (-16)]
     ["Reset Icon Size" enhanced-dirvish-thumbnails-scale icons (0)]
     ("Refresh"
      ["Active View" enhanced-dirvish-refresh-active-view browser] ["Compact" enhanced-dirvish-compact-refresh compact]
      ["Icons" enhanced-dirvish-icons-refresh icons] ["Enable Live Watching" enhanced-dirvish-watch-setup browser]))
    ("Search & Bookmarks"
     ["Global Search…" enhanced-dirvish-global-search always] ["Filter Folder…" enhanced-dirvish-filter-pane browser]
     ["Filter Including Subfolders…" enhanced-dirvish-filter-pane browser (t)] ["Clear Filter" enhanced-dirvish-clear-filter filter]
     ["Find in Folder…" enhanced-dirvish-find-in-folder browser] ["Find Backward…" enhanced-dirvish-find-in-folder browser (t)]
     ["Repeat Find" enhanced-dirvish-find-repeat find]
     ["Set Letter Bookmark…" enhanced-dirvish-letter-bookmark-set physical]
     ["Go to Letter Bookmark…" enhanced-dirvish-letter-bookmark-go bookmarks]
     ["Pin Directory" enhanced-dirvish-pin-directory physical] ["Unpin Directory" enhanced-dirvish-unpin-directory physical]
     "--" ["Open Search Result" enhanced-dirvish-search-activate-at-point search-item]
     ["Open Result's Folder" enhanced-dirvish-search-open-folder-at-point search-item]
     ["Open Recent Item" enhanced-dirvish-recent-open-at-point recent-item]
     ["Open Recent Item's Folder" enhanced-dirvish-recent-open-folder-at-point recent-item]
     ["Refresh Recent Files" enhanced-dirvish-recent-refresh recent])
    ("Panes, Tabs & Sidebar"
     ["Toggle Extra Pane" enhanced-dirvish-toggle-extra-pane physical nil (context split)]
     ["Switch Pane" enhanced-dirvish-switch-other-pane split]
     ["Toggle Pane Terminal" enhanced-dirvish-toggle-pane-terminal terminal nil (context terminal-open)]
     ["External Terminal" enhanced-dirvish-open-external-terminal physical]
     "--" ["New Tab" enhanced-dirvish-tab-new always] ["Close Tab" enhanced-dirvish-tab-close tabs]
     ["Reopen Closed Tab" enhanced-dirvish-tab-reopen-closed closed-tabs]
     ["Next Tab" enhanced-dirvish-tab-next cycle-tabs] ["Previous Tab" enhanced-dirvish-tab-previous cycle-tabs]
     ["Choose Tab…" enhanced-dirvish-tab-switch-index tabs]
     ["Move Tab Left" enhanced-dirvish-tab-move tab-left (-1)] ["Move Tab Right" enhanced-dirvish-tab-move tab-right (1)]
     "--" ["Show / Hide Sidebar" enhanced-dirvish-sidebar-toggle always nil (pref enhanced-dirvish-prefs-sidebar-expanded)]
     ["Focus Sidebar" enhanced-dirvish-sidebar-focus always]
     ["Compact Sidebar Rail" enhanced-dirvish-sidebar-toggle-rail always nil (pref enhanced-dirvish-prefs-sidebar-compact)]
     ["Refresh Sidebar" enhanced-dirvish-sidebar-refresh always] ["Scan Devices" enhanced-dirvish-sidebar-force-refresh always]
     ["Open Sidebar Item" enhanced-dirvish-sidebar-activate-at-point sidebar-item]
     ["Open Sidebar Item in Tab" enhanced-dirvish-sidebar-open-in-tab-at-point sidebar-location])
    ("Preview & Media"
     ["Preview Current File" enhanced-dirvish-preview-at-point current]
     ["Enter Read-Only Preview" enhanced-dirvish-preview-enter-at-point file]
     ["Toggle Peek Drawer" enhanced-dirvish-toggle-peek browser]
     ["Return from Read-Only Preview" enhanced-dirvish-preview-read-leave preview-read]
     ["Leave Edit Preview" enhanced-dirvish-preview-edit-leave preview-edit]
     ["Save and Exit Edit Preview" enhanced-dirvish-preview-edit-exit preview-edit]
     ["Abort Edit Preview…" enhanced-dirvish-preview-edit-abort preview-edit]
     ["Rendered Document / Source" enhanced-dirvish-toggle-rendered-document preview nil (pref enhanced-dirvish-prefs-render-documents-by-default)]
     ["Wrap Preview Lines" enhanced-dirvish-toggle-preview-wrap preview-text nil (pref enhanced-dirvish-prefs-preview-text-wrap)]
     ["Find in Preview…" enhanced-dirvish-preview-find preview-text]
     ["Zoom In" enhanced-dirvish-preview-zoom-in zoom] ["Zoom Out" enhanced-dirvish-preview-zoom-out zoom]
     ["Reset Zoom" enhanced-dirvish-preview-zoom-reset zoom]
     ["Scroll Preview Down" enhanced-dirvish-scroll-preview-down preview] ["Scroll Preview Up" enhanced-dirvish-scroll-preview-up preview]
     ["Read Preview: Page Down" enhanced-dirvish-preview-read-scroll-down preview-read]
     ["Read Preview: Page Up" enhanced-dirvish-preview-read-scroll-up preview-read]
     ["Next PDF Page" enhanced-dirvish-pdf-page-step pdf (1)] ["Previous PDF Page" enhanced-dirvish-pdf-page-step pdf (-1)]
     ("Media"
      ["Play / Pause" enhanced-dirvish-media-play-pause media] ["Stop" enhanced-dirvish-media-stop playing]
      ["Seek Back 5 Seconds" enhanced-dirvish-media-seek playing (-5)] ["Seek Forward 5 Seconds" enhanced-dirvish-media-seek playing (5)]
      ["Volume Up" enhanced-dirvish-media-volume-step playing (5)] ["Volume Down" enhanced-dirvish-media-volume-step playing (-5)]
      ["Mute / Unmute" enhanced-dirvish-media-mute-toggle playing] ["Open in External Player" enhanced-dirvish-media-open-external media]))
    ("Drives & Trash"
     ["Refresh Computer / Drives" enhanced-dirvish-computer-refresh computer]
     ["Open Drive" enhanced-dirvish-computer-open-at-point computer-device]
     ["Mount / Unlock Drive" enhanced-dirvish-computer-mount-at-point computer-mount]
     ["Unmount Drive" enhanced-dirvish-computer-unmount-at-point computer-unmount]
     ["Safely Eject Drive" enhanced-dirvish-computer-eject-at-point computer-eject]
     ["Set Drive Label…" enhanced-dirvish-computer-rename-label-at-point computer-device]
     ["Drive Properties" enhanced-dirvish-computer-properties-at-point computer-device]
     ("Sidebar Drives"
      ["Mount / Unlock" enhanced-dirvish-sidebar-mount-at-point sidebar-mount]
      ["Unmount" enhanced-dirvish-sidebar-unmount-at-point sidebar-unmount]
      ["Safely Eject" enhanced-dirvish-sidebar-eject-at-point sidebar-eject])
     "--" ["Restore Trashed Item" enhanced-dirvish-trash-restore-at-point trash-item]
     ["Delete Trashed Item Permanently…" enhanced-dirvish-trash-delete-at-point trash-item]
     ["Empty Trash…" enhanced-dirvish-trash-empty trash-items] ["Refresh Trash" enhanced-dirvish-trash-refresh trash])
    ("Tools & Help"
     ["Run Custom Action…" enhanced-dirvish-run-custom-action items]
     ["Run Folder Action…" enhanced-dirvish-run-custom-action physical (nil t)]
     ["Install Action Recipe…" enhanced-dirvish-install-action-recipe always]
     ["Background Jobs" enhanced-dirvish-jobs-dashboard always]
     ["10xer Keyboard Mode" enhanced-dirvish-toggle-tenxer-mode always nil (pref enhanced-dirvish-prefs-tenxer-mode)]
     ["Settings & Diagnostics" enhanced-dirvish-open-settings always]
     ["Shortcut Reference" enhanced-dirvish-open-shortcut-reference always]))
  "Complete user-facing actions.  Vectors hold label, command, capability, args and checked state.")

(defun enhanced-dirvish-menu--build-items (items)
  "Convert command catalog ITEMS into an Easy Menu specification."
  (mapcar
   (lambda (item)
     (cond
      ((stringp item) item)
      ((vectorp item)
       (let* ((label (aref item 0)) (command (aref item 1)) (capability (aref item 2))
              (args (and (> (length item) 3) (aref item 3)))
              (state (and (> (length item) 4) (aref item 4))))
         (vconcat (list label `(enhanced-dirvish-menu--dispatch ',command ',args)
                        :enable `(enhanced-dirvish-menu--enabled-p ',command ',capability))
                  (when state (list :style (if (memq (car state) '(view direction)) 'radio 'toggle)
                                    :selected `(enhanced-dirvish-menu--selected-p ',state))))))
      (t (cons (car item) (enhanced-dirvish-menu--build-items (cdr item))))))
   items))

(defun enhanced-dirvish-menu--derive-capabilities ()
  "Populate combined drive capabilities after taking a context snapshot."
  (dolist (mode '(computer sidebar))
    (dolist (action '(device mount unmount eject))
      (let ((value (and (plist-get enhanced-dirvish-menu--context (intern (concat ":" (symbol-name mode))))
                        (plist-get enhanced-dirvish-menu--context (intern (concat ":" (symbol-name action)))))))
        (setq enhanced-dirvish-menu--context
              (plist-put enhanced-dirvish-menu--context (intern (format ":%s-%s" mode action)) value))))))

(defun enhanced-dirvish-menu--update ()
  "Refresh enabled states when Emacs opens its menu bar."
  (enhanced-dirvish-menu--refresh-context)
  (enhanced-dirvish-menu--derive-capabilities))

(defvar enhanced-dirvish-menu-map
  (easy-menu-create-menu "Enhanced Dirvish" (enhanced-dirvish-menu--build-items enhanced-dirvish-menu--catalog))
  "The global, context-aware Enhanced Dirvish file-manager menu.")

(defun enhanced-dirvish-menu-install ()
  "Install the main menu once, available in every Emacs buffer."
  (define-key-after global-map [menu-bar enhanced-dirvish] (list 'menu-item "Enhanced Dirvish" enhanced-dirvish-menu-map) 'tools)
  (add-hook 'menu-bar-update-hook #'enhanced-dirvish-menu--update))

(provide 'enhanced-dirvish-menu)
;;; enhanced-dirvish-menu.el ends here
