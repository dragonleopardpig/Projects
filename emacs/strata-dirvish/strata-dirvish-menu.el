;;; strata-dirvish-menu.el --- Context-aware Strata menu bar -*- lexical-binding: t; -*-

;;; Commentary:
;; The complete file-manager menu remains available throughout Emacs.  Only
;; relevant commands are enabled.  Menu context uses buffer state and cached
;; mount information, without enumerating devices or probing remote files.

;;; Code:

(require 'easymenu)
(require 'strata-dirvish-keys)

(defvar strata-menu--context nil "Snapshot of the current menu's buffer and capabilities.")

(defun strata-menu--writable-p (dir)
  "Check local DIR permissions, without statting remote or cloud mounts."
  (strata-path-writable-p dir))

(defun strata-menu--refresh-context ()
  "Capture the selected window's file-manager state without changing it."
  (let* ((window (selected-window))
         (dv (with-current-buffer (window-buffer window) (ignore-errors (dirvish-curr)))))
    (when (and dv (with-current-buffer (window-buffer window)
                    (derived-mode-p 'dirvish-misc-mode)))
      (when (window-live-p (dv-root-window dv)) (setq window (dv-root-window dv))))
    (with-current-buffer (window-buffer window)
      (let* ((browser (derived-mode-p 'dired-mode 'strata-compact-mode 'strata-icons-mode))
             (sidebar (derived-mode-p 'strata-sidebar-mode))
             (computer (derived-mode-p 'strata-computer-mode))
             (trash (derived-mode-p 'strata-trash-mode))
             (recent (derived-mode-p 'strata-recent-mode))
             (search (derived-mode-p 'strata-global-search-mode))
             (tab (nth strata-active-tab-index strata-workspace-tabs))
             (pane (and tab (if (= (strata-tab-state-active-pane tab) 2)
                                    (strata-tab-state-pane2 tab) (strata-tab-state-pane1 tab))))
             (terminal (and pane (derived-mode-p 'vterm-mode 'term-mode 'eshell-mode)
                            (eq (current-buffer) (strata-pane-state-terminal-buf pane))))
             (read-preview (bound-and-true-p strata-preview-read-mode))
             (edit-preview (bound-and-true-p strata-preview-edit-mode))
             (workspace (or browser sidebar computer trash recent search terminal read-preview edit-preview))
             (other (and tab (strata-tab-state-split-p tab)
                         (if (= (strata-tab-state-active-pane tab) 2)
                             (strata-tab-state-pane1 tab) (strata-tab-state-pane2 tab))))
             (dir (and browser (or strata-view-directory (dirvish-prop :root) default-directory)))
             (physical (and dir (not (strata-location-virtual-p dir))))
             (writable (and physical (strata-menu--writable-p dir)))
             ;; Do not call strata-marked-files-only in custom grids here:
             ;; that helper stats every marked file to prune vanished paths.
             (marked (and browser (if (derived-mode-p 'dired-mode)
                                      (strata-marked-files-only)
                                    (reverse strata-marked-entries))))
             (current (and browser (strata-current-file)))
             (items (or marked (when current (list current))))
             (single (= (length items) 1))
             (directory-p (and current
                               (or (get-text-property (point) 'strata-entry-dir)
                                   (and (derived-mode-p 'dired-mode)
                                        (save-excursion (beginning-of-line) (looking-at-p dired-re-dir))))))
             (item-dir-p (and single
                              (if (and current (equal (directory-file-name (car items))
                                                      (directory-file-name current)))
                                  directory-p
                                (and (not (strata-path-unsafe-probe-p (car items)))
                                     (file-directory-p (car items))))))
             (preview-window (or (and dv (dv-preview-window dv)) strata-preview-standalone-window))
             (preview (and workspace (or read-preview edit-preview (window-live-p preview-window))))
             (device (and (or sidebar computer)
                          (or (get-text-property (point) 'strata-device)
                              (get-text-property (line-beginning-position) 'strata-device))))
             (mounted (and device (strata-device-mounted-p device)))
             (removable (and device (eq (strata-device-placement device) 'removable)))
             (other-dir (and other (strata-pane-state-dir other)))
             (transfer (and items other-dir (strata-menu--writable-p other-dir)
                            (not (equal (directory-file-name dir) (directory-file-name other-dir)))))
             (archive (and single (not item-dir-p)
                           (strata-archive-file-p (car items))))
             (media (and workspace (or (and preview (eq strata-active-preview-kind 'media))
                                      (and single (not item-dir-p)
                                           (string-match-p
                                            "\\.\\(?:mp[34]\\|mkv\\|webm\\|wav\\|flac\\|ogg\\|opus\\|m4a\\|mov\\|avi\\)\\'"
                                            (downcase (car items))))))))
        (setq strata-menu--context
              (list :window window :buffer (current-buffer)
                    :always t :workspace workspace :browser browser :physical physical :dir dir
                    :writable writable :items items :current current
                    :single (and browser single current (equal current (car items)))
                    :file (and browser current (not directory-p))
                    :writable-items (and items writable)
                    :writable-single (and single current (equal current (car items)) writable)
                    :marks marked :filter (and browser (or strata-local-filter (dirvish-prop :narrow-info)))
                    :find (and browser strata-last-find-query)
                    :back (and workspace pane (strata-pane-state-history-back pane))
                    :forward (and workspace pane (strata-pane-state-history-fwd pane))
                    :columns (and browser (eq (strata-view-current-mode) 'columns))
                    :list (and browser (eq (strata-view-current-mode) 'list))
                    :sorted (and browser (not (eq (strata-prefs-sort-key (strata-prefs)) 'unsorted)))
                    :name-sort (and browser (eq (strata-prefs-sort-key (strata-prefs)) 'name))
                    :icons (derived-mode-p 'strata-icons-mode) :compact (derived-mode-p 'strata-compact-mode)
                    :split (and workspace other) :transfer transfer :move-transfer (and transfer writable)
                    :clipboard (and writable (plist-get strata-clipboard :files))
                    :clipboard-any (plist-get strata-clipboard :files)
                    :undo (and browser strata-undo-stack) :redo (and browser strata-redo-stack)
                    :tabs (and workspace tab) :cycle-tabs (and workspace (> (length strata-workspace-tabs) 1))
                    :tab-left (and workspace tab (> strata-active-tab-index 0))
                    :tab-right (and workspace tab (< strata-active-tab-index (1- (length strata-workspace-tabs))))
                    :closed-tabs strata-closed-tabs :terminal (and workspace (or browser terminal))
                    :terminal-open (and workspace pane (strata-pane-state-terminal-open pane))
                    :preview preview :preview-read read-preview :preview-edit edit-preview
                    :preview-text (and preview (eq strata-active-preview-kind 'text))
                    :zoom (and preview (memq strata-active-preview-kind '(text image pdf)))
                    :pdf (and preview (eq strata-active-preview-kind 'pdf))
                    :media media :playing (and strata-media-proc (process-live-p strata-media-proc))
                    :computer computer :sidebar sidebar :device device
                    :mount (and device (not mounted))
                    :unmount (and mounted (not (equal (strata-device-mountpoint device) "/")))
                    :eject (and removable (not (equal (strata-device-mountpoint device) "/")))
                    :trash trash :trash-item (and trash (get-text-property (line-beginning-position) 'strata-trash-item))
                    :trash-items (and trash (text-property-not-all (point-min) (point-max) 'strata-trash-item nil))
                    :recent recent :recent-item (and recent (get-text-property (line-beginning-position) 'strata-recent-path))
                    :search-item (and search (get-text-property (line-beginning-position) 'strata-search-path))
                    :sidebar-item (and sidebar (or device (get-text-property (line-beginning-position) 'strata-sidebar-loc)))
                    :sidebar-location (and sidebar (get-text-property (line-beginning-position) 'strata-sidebar-loc))
                    :archive (and archive writable) :bookmarks (strata-prefs-marks (strata-prefs))))))))

(defun strata-menu--enabled-p (command capability)
  "Whether COMMAND is available for CAPABILITY in the current menu snapshot."
  (and (fboundp command) (plist-get strata-menu--context (intern (concat ":" (symbol-name capability))))))

(defun strata-menu--selected-p (state)
  "Return the checked state for menu STATE."
  (pcase state
    (`(view ,mode)
     (let ((buf (plist-get strata-menu--context :buffer)))
       (and (buffer-live-p buf)
            (plist-get strata-menu--context :browser)
            (with-current-buffer buf
              (eq (strata-view-current-mode) mode)))))
    (`(pref ,accessor) (funcall accessor (strata-prefs)))
    (`(direction ,direction) (eq (strata-prefs-sort-direction (strata-prefs)) direction))
    (`(context ,key) (plist-get strata-menu--context (intern (concat ":" (symbol-name key)))))
    (_ nil)))

(defun strata-menu--dispatch (command arguments)
  "Run COMMAND with ARGUMENTS in the context used to build the menu."
  (let ((window (plist-get strata-menu--context :window)))
    (when (window-live-p window)
      (select-window window)
      (strata-panes--sync-active-pane-from-window window)))
  ;; `use-dialog-box-p' inspects `last-nonmenu-event', which stays a key event
  ;; across native menu-bar clicks; also treat `(menu-bar ...)` events as mouse.
  (let* ((mouse-p
          (and (display-graphic-p)
               (display-popup-menus-p)
               (or (eq (car-safe last-input-event) 'menu-bar)
                   (eq (car-safe last-command-event) 'menu-bar)
                   (let ((use-dialog-box t)) (use-dialog-box-p)))))
         (strata-ui-input-method (if mouse-p 'mouse 'keyboard))
         (use-dialog-box t) (use-file-dialog t))
    (pcase command
      ((or 'strata-letter-bookmark-set 'strata-letter-bookmark-go)
       (let* ((letters (if (eq command 'strata-letter-bookmark-go)
                           (mapcar #'car (strata-prefs-marks (strata-prefs)))
                         (number-sequence ?a ?z)))
              (letter (string-to-char
                       (strata-ui-completing-read "Bookmark letter:" (mapcar #'char-to-string letters) nil t))))
         (if (eq command 'strata-letter-bookmark-set)
             (funcall command letter (plist-get strata-menu--context :dir))
           (funcall command letter))))
      ('strata-tab-switch-index
       (funcall command (string-to-number
                         (strata-ui-completing-read "Tab number:"
                                                   (mapcar #'number-to-string (number-sequence 1 (length strata-workspace-tabs))) nil t))))
      (_ (if (or arguments (not (commandp command)))
             (apply command arguments)
           (call-interactively command))))))

(defconst strata-menu--catalog
  '(["Open File Browser" strata-dirvish-launch always]
    "--"
    ("Files"
     ["Open / Edit" strata-open-or-edit-at-point current]
     ["Open With…" strata-open-with items]
     ["Open in New Tab" strata-open-in-new-tab single]
     ["Open in New Frame" strata-open-in-new-frame single]
     "--"
     ["New File…" strata-new-file writable]
     ["New Folder…" strata-new-folder writable]
     ["Create File or Folder…" strata-create-entry writable]
     ["New Folder with Selection…" strata-new-folder-with-selection writable-items]
     ["Rename…" strata-rename writable-single]
     ["Duplicate" strata-duplicate writable-items]
     ["Move to Trash…" strata-move-to-trash writable-items]
     ["Delete Permanently…" strata-delete-permanently writable-items]
     "--"
     ["Compress Archive…" strata-archive-compress writable-items]
     ["Extract Here" strata-archive-extract archive]
     ["Extract to Folder…" strata-archive-extract archive (t)]
     ["Properties…" strata-show-properties-for-path physical]
     ["Customize Folder…" strata-customize-folder writable])
    ("Clipboard & Transfers"
     ["Copy" strata-copy-selection items] ["Cut" strata-cut-selection writable-items]
     ["Paste (Keep Both)" strata-paste-keep-both clipboard]
     ["Paste (Replace)" strata-paste-replace clipboard]
     ["Save Clipboard Image / Text…" strata-paste-content-drop writable]
     ["Copy Path" strata-copy-path items] ["Copy Name" strata-copy-name items]
     ["Clear Clipboard" strata-unyank clipboard-any]
     "--"
     ["Copy to Folder…" strata-copy-to items] ["Move to Folder…" strata-move-to writable-items]
     ["Copy to Other Pane" strata-copy-to-other-pane transfer]
     ["Move to Other Pane" strata-move-to-other-pane move-transfer]
     "--" ["Undo File Operation" strata-undo undo] ["Redo File Operation" strata-redo redo])
    ("Selection"
     ["Toggle Current Item" strata-view-toggle-mark items] ["Unmark Current Item" strata-view-unmark items]
     ["Select All" strata-select-all browser] ["Clear Selection" strata-clear-all-marks marks]
     ["Invert Selection" strata-invert-selection browser] ["Clear Selection and Filter" strata-escape browser]
     ["Visual Range Selection" strata-visual-toggle items]
     ("Extend Range"
      ["Next Row" strata-shift-select-next items] ["Previous Row" strata-shift-select-prev items]
      ["Left" strata-shift-select-left items] ["Right" strata-shift-select-right items]
      ["To First Item" strata-shift-select-first items] ["To Last Item" strata-shift-select-last items]))
    ("Go"
     ["Open File Browser" strata-dirvish-launch always]
     ["Home" strata-open-location always ("~/")]
     ["Computer / Drives" strata-dirvish-launch-computer always]
     ["Trash" strata-dirvish-launch-trash always] ["Recent Files" strata-dirvish-launch-recent always]
     ["Location…" strata-location-prompt workspace] ["Connect to Server…" strata-connect-server always]
     ["Visited Folder…" strata-jump-visited-folder always] ["Recent File…" strata-jump-recent-file always]
     "--" ["Back" strata-history-back back] ["Forward" strata-history-forward forward]
     ["Parent Directory" strata-view-up-directory browser]
     ["Left / Collapse" strata-tree-collapse-or-up browser]
     ["Open / Expand" strata-tree-expand-or-open current]
     ["Make First Column" strata-make-first-column columns]
     ["Next Item" strata-nav-next-line browser] ["Previous Item" strata-nav-prev-line browser]
     ["Half Page Down" strata-half-page-down browser] ["Half Page Up" strata-half-page-up browser]
     ("Grid Navigation"
      ["Icons: Next Cell" strata-icons-next-cell icons] ["Icons: Previous Cell" strata-icons-prev-cell icons]
      ["Icons: Next Row" strata-icons-next-row icons] ["Icons: Previous Row" strata-icons-prev-row icons]
      ["Compact: Next Item" strata-compact-next-item compact] ["Compact: Previous Item" strata-compact-prev-item compact]
      ["Compact: Next Column" strata-compact-next-col compact] ["Compact: Previous Column" strata-compact-prev-col compact]))
    ("View & Sort"
     ["Columns" strata-view-columns browser nil (view columns)]
     ["Icons" strata-view-icons browser nil (view icons)]
     ["List / Tree" strata-view-list browser nil (view list)]
     ["Compact" strata-view-compact browser nil (view compact)]
     ["Choose Layout…" strata-switch-view-mode browser]
     "--"
     ["Sort By…" strata-sort-menu browser] ["Choose Sort Key…" strata-sort-set browser]
     ["Ascending" strata-sort-ascending sorted nil (direction asc)]
     ["Descending" strata-sort-descending sorted nil (direction desc)]
     ["Reverse Sort Direction" strata-sort-toggle-direction sorted]
     ["Folders First" strata-sort-toggle-folders-first sorted nil (pref strata-prefs-folders-first)]
     ["Natural Numeric Names" strata-sort-toggle-natural name-sort nil (pref strata-prefs-natural-sort)]
     ["Group by Type" strata-toggle-group-by-type browser nil (pref strata-prefs-group-by-type)]
     "--"
     ["Show Hidden Files" strata-toggle-hidden-files browser nil (pref strata-prefs-show-hidden)]
     ["Expandable Folders in List" strata-toggle-expandable-tree list nil (pref strata-prefs-expandable-tree)]
     ["Compact Full Filenames" strata-toggle-compact-full-names compact nil (pref strata-prefs-compact-full-names)]
     ["Larger Icons" strata-thumbnails-scale icons (16)] ["Smaller Icons" strata-thumbnails-scale icons (-16)]
     ["Reset Icon Size" strata-thumbnails-scale icons (0)]
     ("Refresh"
      ["Active View" strata-refresh-active-view browser] ["Compact" strata-compact-refresh compact]
      ["Icons" strata-icons-refresh icons] ["Enable Live Watching" strata-watch-setup browser]))
    ("Search & Bookmarks"
     ["Global Search…" strata-global-search always] ["Filter Folder…" strata-filter-pane browser]
     ["Filter Including Subfolders…" strata-filter-pane browser (t)] ["Clear Filter" strata-clear-filter filter]
     ["Find in Folder…" strata-find-in-folder browser] ["Find Backward…" strata-find-in-folder browser (t)]
     ["Repeat Find" strata-find-repeat find]
     ["Set Letter Bookmark…" strata-letter-bookmark-set physical]
     ["Go to Letter Bookmark…" strata-letter-bookmark-go bookmarks]
     ["Pin Directory" strata-pin-directory physical] ["Unpin Directory" strata-unpin-directory physical]
     "--" ["Open Search Result" strata-search-activate-at-point search-item]
     ["Open Result's Folder" strata-search-open-folder-at-point search-item]
     ["Open Recent Item" strata-recent-open-at-point recent-item]
     ["Open Recent Item's Folder" strata-recent-open-folder-at-point recent-item]
     ["Refresh Recent Files" strata-recent-refresh recent])
    ("Panes, Tabs & Sidebar"
     ["Toggle Extra Pane" strata-toggle-extra-pane physical nil (context split)]
     ["Switch Pane" strata-switch-other-pane split]
     ["Toggle Pane Terminal" strata-toggle-pane-terminal terminal nil (context terminal-open)]
     ["External Terminal" strata-open-external-terminal physical]
     "--" ["New Tab" strata-tab-new always] ["Close Tab" strata-tab-close tabs]
     ["Reopen Closed Tab" strata-tab-reopen-closed closed-tabs]
     ["Next Tab" strata-tab-next cycle-tabs] ["Previous Tab" strata-tab-previous cycle-tabs]
     ["Choose Tab…" strata-tab-switch-index tabs]
     ["Move Tab Left" strata-tab-move tab-left (-1)] ["Move Tab Right" strata-tab-move tab-right (1)]
     "--" ["Show / Hide Sidebar" strata-sidebar-toggle always nil (pref strata-prefs-sidebar-expanded)]
     ["Focus Sidebar" strata-sidebar-focus always]
     ["Compact Sidebar Rail" strata-sidebar-toggle-rail always nil (pref strata-prefs-sidebar-compact)]
     ["Refresh Sidebar" strata-sidebar-refresh always] ["Scan Devices" strata-sidebar-force-refresh always]
     ["Open Sidebar Item" strata-sidebar-activate-at-point sidebar-item]
     ["Open Sidebar Item in Tab" strata-sidebar-open-in-tab-at-point sidebar-location])
    ("Preview & Media"
     ["Preview Current File" strata-preview-at-point current]
     ["Enter Read-Only Preview" strata-preview-enter-at-point file]
     ["Toggle Peek Drawer" strata-toggle-peek browser]
     ["Return from Read-Only Preview" strata-preview-read-leave preview-read]
     ["Leave Edit Preview" strata-preview-edit-leave preview-edit]
     ["Save and Exit Edit Preview" strata-preview-edit-exit preview-edit]
     ["Abort Edit Preview…" strata-preview-edit-abort preview-edit]
     ["Rendered Document / Source" strata-toggle-rendered-document preview nil (pref strata-prefs-render-documents-by-default)]
     ["Wrap Preview Lines" strata-toggle-preview-wrap preview-text nil (pref strata-prefs-preview-text-wrap)]
     ["Find in Preview…" strata-preview-find preview-text]
     ["Zoom In" strata-preview-zoom-in zoom] ["Zoom Out" strata-preview-zoom-out zoom]
     ["Reset Zoom" strata-preview-zoom-reset zoom]
     ["Scroll Preview Down" strata-scroll-preview-down preview] ["Scroll Preview Up" strata-scroll-preview-up preview]
     ["Read Preview: Page Down" strata-preview-read-scroll-down preview-read]
     ["Read Preview: Page Up" strata-preview-read-scroll-up preview-read]
     ["Next PDF Page" strata-pdf-page-step pdf (1)] ["Previous PDF Page" strata-pdf-page-step pdf (-1)]
     ("Media"
      ["Play / Pause" strata-media-play-pause media] ["Stop" strata-media-stop playing]
      ["Seek Back 5 Seconds" strata-media-seek playing (-5)] ["Seek Forward 5 Seconds" strata-media-seek playing (5)]
      ["Volume Up" strata-media-volume-step playing (5)] ["Volume Down" strata-media-volume-step playing (-5)]
      ["Mute / Unmute" strata-media-mute-toggle playing] ["Open in External Player" strata-media-open-external media]))
    ("Drives & Trash"
     ["Refresh Computer / Drives" strata-computer-refresh computer]
     ["Open Drive" strata-computer-open-at-point computer-device]
     ["Mount / Unlock Drive" strata-computer-mount-at-point computer-mount]
     ["Unmount Drive" strata-computer-unmount-at-point computer-unmount]
     ["Safely Eject Drive" strata-computer-eject-at-point computer-eject]
     ["Set Drive Label…" strata-computer-rename-label-at-point computer-device]
     ["Drive Properties" strata-computer-properties-at-point computer-device]
     ("Sidebar Drives"
      ["Mount / Unlock" strata-sidebar-mount-at-point sidebar-mount]
      ["Unmount" strata-sidebar-unmount-at-point sidebar-unmount]
      ["Safely Eject" strata-sidebar-eject-at-point sidebar-eject])
     "--" ["Restore Trashed Item" strata-trash-restore-at-point trash-item]
     ["Delete Trashed Item Permanently…" strata-trash-delete-at-point trash-item]
     ["Empty Trash…" strata-trash-empty trash-items] ["Refresh Trash" strata-trash-refresh trash])
    ("Tools & Help"
     ["Run Custom Action…" strata-run-custom-action items]
     ["Run Folder Action…" strata-run-custom-action physical (nil t)]
     ["Install Action Recipe…" strata-install-action-recipe always]
     ["Background Jobs" strata-jobs-dashboard always]
     ["10xer Keyboard Mode" strata-toggle-tenxer-mode always nil (pref strata-prefs-tenxer-mode)]
     ["Settings & Diagnostics" strata-open-settings always]
     ["Shortcut Reference" strata-open-shortcut-reference always]))
  "Complete user-facing actions.  Vectors hold label, command, capability, args and checked state.")

(defun strata-menu--build-items (items)
  "Convert command catalog ITEMS into an Easy Menu specification."
  (mapcar
   (lambda (item)
     (cond
      ((stringp item) item)
      ((vectorp item)
       (let* ((label (aref item 0)) (command (aref item 1)) (capability (aref item 2))
              (args (and (> (length item) 3) (aref item 3)))
              (state (and (> (length item) 4) (aref item 4))))
         (vconcat (list label `(strata-menu--dispatch ',command ',args)
                        :enable `(strata-menu--enabled-p ',command ',capability))
                  (when state (list :style (if (memq (car state) '(view direction)) 'radio 'toggle)
                                    :selected `(strata-menu--selected-p ',state))))))
      (t (cons (car item) (strata-menu--build-items (cdr item))))))
   items))

(defun strata-menu--derive-capabilities ()
  "Populate combined drive capabilities after taking a context snapshot."
  (dolist (mode '(computer sidebar))
    (dolist (action '(device mount unmount eject))
      (let ((value (and (plist-get strata-menu--context (intern (concat ":" (symbol-name mode))))
                        (plist-get strata-menu--context (intern (concat ":" (symbol-name action)))))))
        (setq strata-menu--context
              (plist-put strata-menu--context (intern (format ":%s-%s" mode action)) value))))))

(defun strata-menu--update ()
  "Refresh enabled states when Emacs opens its menu bar."
  (strata-menu--refresh-context)
  (strata-menu--derive-capabilities))

(defvar strata-menu-map
  (easy-menu-create-menu "Strata" (strata-menu--build-items strata-menu--catalog))
  "The global, context-aware Strata file-manager menu.")

(defun strata-menu-install ()
  "Install the Strata main menu once, available in every Emacs buffer."
  (define-key-after global-map [menu-bar strata] (list 'menu-item "Strata" strata-menu-map) 'tools)
  (add-hook 'menu-bar-update-hook #'strata-menu--update))

(provide 'strata-dirvish-menu)
;;; strata-dirvish-menu.el ends here
