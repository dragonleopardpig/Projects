;;; strata-dirvish-keys.el --- Keymaps, chords, Settings, Diagnostics, Help & Menus -*- lexical-binding: t; -*-

;;; Commentary:
;; Dual keymap engine (Default Desktop Mode + 10xer Modal/Chord Mode),
;; chord indicator UI, dynamic Transient Context Menu, interactive Settings &
;; Diagnostics buffer (C-,), and Searchable Shortcut Reference (C-c ? / ? / ~).

;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'dirvish)
(require 'transient)
(require 'subr-x)
(require 'strata-dirvish-prefs)
(require 'strata-dirvish-devices)
(require 'strata-dirvish-views)
(require 'strata-dirvish-panes)
(require 'strata-dirvish-previews)
(require 'strata-dirvish-search)
(require 'strata-dirvish-ops)

;;;; Active Chord Hint Engine

(defun strata-chord--with-hint (label table &optional handler)
  "Display interactive chord hint LABEL, read key, dispatch in TABLE alist or HANDLER."
  (let ((strata-active-chord label))
    (force-mode-line-update t)
    (unwind-protect
        (let* ((prompt (format "%s   [%s] "
                               (propertize label 'face 'strata-pill-chord)
                               (mapconcat (lambda (kv)
                                            (format "%s:%s"
                                                    (propertize (key-description (vector (car kv))) 'face 'strata-hint-key)
                                                    (car (cdr kv))))
                                          table "  ")))
               (ch (read-key prompt)))
          (cond
           ((memq ch '(?\e ?\C-g))
            (message "Chord cancelled"))
           (handler (funcall handler ch))
           (t
            (if-let ((hit (assoc ch table)))
                (call-interactively (cddr hit))
              (message "Unbound key '%s' after %s" (key-description (vector ch)) label)))))
      (setq strata-active-chord nil)
      (force-mode-line-update t))))

(defun strata-chord-go ()
  "Execute Strata `g` navigation chord."
  (interactive)
  (let* ((pins (strata-bookmarks-read))
         (pin-cmds (cl-loop for i from 1 to (min 9 (length pins))
                            for pin in pins
                            collect (let ((loc (car pin))
                                          (lbl (cdr pin)))
                                      (cons (+ ?0 i)
                                            (cons lbl (lambda () (interactive) (strata-open-location loc t)))))))
         (table (append
                 `((?g "Top" . ,(lambda () (interactive) (goto-char (point-min))))
                   (?f "Follow" . ,#'dired-find-file)
                   (?\s "Location" . ,#'strata-location-prompt)
                   (?h "Home" . ,(lambda () (interactive) (strata-open-location "~/" t)))
                   (?c "~/.config" . ,(lambda () (interactive) (strata-open-location "~/.config/" t)))
                   (?d "Downloads" . ,(lambda () (interactive) (strata-open-location "~/Downloads/" t)))
                   (?k "Documents" . ,(lambda () (interactive) (strata-open-location "~/Documents/" t)))
                   (?m "Music" . ,(lambda () (interactive) (strata-open-location "~/Music/" t)))
                   (?p "Pictures" . ,(lambda () (interactive) (strata-open-location "~/Pictures/" t)))
                   (?v "Videos" . ,(lambda () (interactive) (strata-open-location "~/Videos/" t)))
                   (?t "Trash" . ,(lambda () (interactive) (strata-open-location "trash:///" t)))
                   (?n "Network" . ,(lambda () (interactive) (strata-open-location "network:///" t)))
                   (?r "Recent" . ,(lambda () (interactive) (strata-open-location "recent:///" t)))
                   (?e "Computer" . ,(lambda () (interactive) (strata-open-location "computer:///" t)))
                   (?+ "Pin" . ,#'strata-pin-directory)
                   (?- "Unpin" . ,#'strata-unpin-directory))
                 pin-cmds)))
    (strata-chord--with-hint "g _" table)))

(defun strata-chord-sort ()
  "Execute Strata `,` sort/group chord (including `, f` Folders First per #2074)."
  (interactive)
  (strata-chord--with-hint
   ", _"
   `((?a "Name" . ,(lambda () (interactive) (strata-sort-set 'name)))
     (?m "Modified" . ,(lambda () (interactive) (strata-sort-set 'modified)))
     (?s "Size" . ,(lambda () (interactive) (strata-sort-set 'size)))
     (?e "Type" . ,(lambda () (interactive) (strata-sort-set 'type)))
     (?x "Ext" . ,(lambda () (interactive) (strata-sort-set 'extension)))
     (?b "Created" . ,(lambda () (interactive) (strata-sort-set 'created)))
     (?u "Unsorted" . ,(lambda () (interactive) (strata-sort-set 'unsorted)))
     (?n "Natural" . ,#'strata-sort-toggle-natural)
     (?l "Direction" . ,#'strata-sort-toggle-direction)
     (?f "Folders first" . ,#'strata-sort-toggle-folders-first)
     (?g "Group type" . ,#'strata-toggle-group-by-type))))

(defun strata-chord-copy-as ()
  "Execute Strata `c` Copy-As / Customize chord."
  (interactive)
  (strata-chord--with-hint
   "c _"
   `((?c "Copy path" . ,#'strata-copy-path)
     (?n "Copy name" . ,#'strata-copy-name)
     (?f "Customize folder" . ,#'strata-customize-folder))))

(defun strata-chord-folder-actions ()
  "Execute Strata `; .` folder-targeted custom actions chord (`fork/feat/1743`)."
  (interactive)
  (let ((table (cl-loop for i from 1 to 9
                        collect (let ((idx i))
                                  (cons (+ ?0 i)
                                        (cons (format "Folder Action %d" i)
                                              (lambda () (interactive) (strata-run-custom-action idx t))))))))
    (push (cons ?. (cons "Pick..." (lambda () (interactive) (strata-run-custom-action nil t)))) table)
    (strata-chord--with-hint "; . _" (reverse table))))

(defun strata-chord-actions ()
  "Execute Strata `;` Actions chord (`t` terminal, `c` compress, `e`/`E` extract, `1..9`, `.`)."
  (interactive)
  (let ((acts (strata-actions-load))
        (table `((?t "Terminal" . ,#'strata-open-external-terminal)
                 (?c "Compress" . ,#'strata-archive-compress)
                 (?e "Extract" . ,(lambda () (interactive) (strata-archive-extract nil)))
                 (?E "Extract to" . ,(lambda () (interactive) (strata-archive-extract t)))
                 (?. "On folder…" . ,#'strata-chord-folder-actions))))
    (dotimes (i (min 9 (length acts)))
      (let ((idx (1+ i))
            (nm (plist-get (nth i acts) :name)))
        (push (cons (+ ?1 i)
                    (cons nm (lambda () (interactive) (strata-run-custom-action idx nil))))
              table)))
    (strata-chord--with-hint "; _" (reverse table))))

(defun strata-chord-tabs ()
  "Execute Strata `t` Tab management chord."
  (interactive)
  (let ((table `((?n "New tab" . ,#'strata-tab-new)
                 (?x "Close tab" . ,#'strata-tab-close)
                 (?t "Prev tab" . ,#'strata-tab-previous))))
    (dotimes (i 9)
      (let ((n (1+ i)))
        (push (cons (+ ?1 i)
                    (cons (format "Tab %d" n) (lambda () (interactive) (strata-tab-switch-index n))))
              table)))
    (strata-chord--with-hint "t _" (reverse table))))

(defun strata-chord-trash-or-d ()
  "In 10xer mode, support `d d` two-key confirm before trashing."
  (interactive)
  (if (not (strata-prefs-tenxer-delete-confirm (strata-prefs)))
      (strata-move-to-trash)
    (let ((strata-active-chord "d _"))
      (force-mode-line-update t)
      (unwind-protect
          (let ((ch (read-key "d _  [d: Confirm Move to Trash · Esc: Cancel] ")))
            (when (eq ch ?d) (strata-move-to-trash)))
        (setq strata-active-chord nil)
        (force-mode-line-update t)))))

;;;; Mode Toggle, Visual Selection & Half-Page Helpers

(defun strata-toggle-tenxer-mode ()
  "Toggle 10xer (Vi/Yazi modal) mode (`C-S-m')."
  (interactive)
  (let* ((p (strata-prefs))
         (next (not (strata-prefs-tenxer-mode p))))
    (setf (strata-prefs-tenxer-mode p) next)
    (strata-prefs-save)
    (dolist (b (buffer-list))
      (when (buffer-live-p b)
        (with-current-buffer b
          (when (bound-and-true-p strata-dirvish-mode)
            (strata-dirvish--apply-active-keymap)))))
    (force-mode-line-update t)
    (message "Strata 10xer Mode: %s" (if next "ON (Vi/Yazi single-key chords)" "OFF (Desktop mode)"))))

(defun strata-half-page-down ()
  "Scroll down half window in browser without touching line/goal columns."
  (interactive)
  (forward-line (max 4 (/ (window-body-height) 2))))

(defun strata-half-page-up ()
  "Scroll up half window in browser."
  (interactive)
  (forward-line (- (max 4 (/ (window-body-height) 2)))))

(defun strata-select-all ()
  "Select/mark all entries in active browser buffer (`C-a')."
  (interactive)
  (strata-view--reset-selection-range (strata-current-file))
  (let ((order (strata-view--entry-order)))
    (strata-mouse--apply-selection-keys order (mapcar #'strata--path-key order) t)))

(defun strata-invert-selection ()
  "Invert marked selection (`C-r' in 10xer mode)."
  (interactive)
  (strata-view--reset-selection-range (strata-current-file))
  (let* ((order (strata-view--entry-order))
         (marked (mapcar #'strata--path-key (strata-marked-files-only)))
         (keys (cl-remove-if (lambda (key) (member key marked))
                             (mapcar #'strata--path-key order))))
    (strata-mouse--apply-selection-keys order keys t)))

(defun strata-visual-toggle ()
  "Toggle visual selection range in 10xer mode (`v')."
  (interactive)
  (when-let ((cur (strata-current-file)))
    (if strata-visual-anchor
        (progn
          (strata-view--reset-selection-range strata-visual-anchor)
          (strata-view--mark-range strata-visual-anchor cur t)
          (setq strata-visual-anchor nil)
          (message "Visual range selected"))
      (setq strata-visual-anchor cur)
      (strata-view--reset-selection-range cur)
      (strata-view--set-entry-mark cur t)
      (message "Visual anchor set — move and press v to select the range"))))

(defun strata-clear-all-marks ()
  "Unmark all files (`V')."
  (interactive)
  (setq strata-visual-anchor nil)
  (strata-view--reset-selection-range)
  (cond
   ((derived-mode-p 'dired-mode)
    (dired-unmark-all-marks)
    (strata-view--refresh-after-mark))
   ((or (derived-mode-p 'strata-compact-mode) (derived-mode-p 'strata-icons-mode))
    (setq strata-marked-entries nil)
    (strata-view--refresh-after-mark))))

(defun strata-escape ()
  "Clear explicit selection and any active folder filter."
  (interactive)
  (strata-clear-all-marks)
  ;; Dirvish narrowing stores its filter in Dirvish properties instead of
  ;; `strata-local-filter'; retain Escape's directory refresh there.
  (when (or strata-local-filter (derived-mode-p 'dired-mode))
    (strata-clear-filter)))

;;;; Dynamic Transient Context Menu & Quick Hub (`Menu` / `S-F10` / `<mouse-3>`)

(defun strata-mouse-context-menu (event)
  "Select EVENT target and open `strata-context-menu' (`<mouse-3>')."
  (interactive "e")
  (if (bound-and-true-p strata-mouse--suppress-mouse-3-once)
      (setq strata-mouse--suppress-mouse-3-once nil)
    (strata-mouse--sync-event event)
    ;; A menu on an unmarked item must operate on that item, not an old batch.
    (when-let ((file (strata-current-file)))
      (unless (member (strata--path-key file)
                      (mapcar #'strata--path-key (strata-marked-files-only)))
        (strata-clear-all-marks)))
    (strata-view--update-selection-highlight)
    (call-interactively #'strata-context-menu)))

(transient-define-prefix strata-context-menu ()
  "Strata Context Menu adapting dynamically to selection & location."
  [:description
   (lambda ()
     (let ((marked (strata-marked-files-only))
           (f (strata-current-file)))
       (format "Strata Actions — %s"
               (cond ((> (length marked) 0)
                      (format "%d selected" (length marked)))
                     ((strata-location-virtual-p (dirvish-prop :root))
                      (or (dirvish-prop :root) "Virtual"))
                     (f (file-name-nondirectory (directory-file-name f)))
                     (t (abbreviate-file-name default-directory))))))
   ["Navigation & View"
    ("RET" "Open" strata-tree-expand-or-open)
    ("O" "Open With…" strata-open-with)
    ("T" "Open in New Tab" strata-open-in-new-tab)
    ("F" "Open in New Frame" strata-open-in-new-frame)
    ("1" "Columns View" strata-view-columns)
    ("2" "Icons Grid View" strata-view-icons)
    ("3" "List / Tree View" strata-view-list)
    ("4" "Compact View" strata-view-compact)
    ("S" "Sort By… (C-c s)" strata-sort-menu)]
   ["File Operations"
    ("y" "Copy" strata-copy-selection)
    ("x" "Cut" strata-cut-selection)
    ("p" "Paste (Keep Both)" strata-paste-keep-both)
    ("P" "Paste (Replace)" strata-paste-replace)
    ("d" "Duplicate" strata-duplicate)
    ("r" "Rename" strata-rename)
    ("+" "New Folder" strata-new-folder)
    ("f" "New File" strata-new-file)
    ("N" "New Folder w/ Selection" strata-new-folder-with-selection)
    ("V" "Clear Selection" strata-clear-all-marks)]
   ["Trash, Archives & Clipboard"
    ("DEL" "Move to Trash" strata-move-to-trash)
    ("D" "Delete Permanently" strata-delete-permanently)
    ("z" "Undo" strata-undo)
    ("Z" "Redo" strata-redo)
    ("c" "Compress Archive…" strata-archive-compress)
    ("e" "Extract Here" strata-archive-extract)
    ("v" "Save Clipboard Image/Text" strata-paste-content-drop)
    ("Y" "Copy Path" strata-copy-path)]
   ["Panes, Customize & Tools"
    ("s" "Split Extra Pane (F3)" strata-toggle-extra-pane)
    (">" "Copy to Other Pane" strata-copy-to-other-pane)
    ("<" "Move to Other Pane" strata-move-to-other-pane)
    ("t" "Pane Terminal (C-` / F9)" strata-toggle-pane-terminal)
    ("C" "Customize Folder Color/Icon" strata-customize-folder)
    ("i" "Properties (M-RET)" strata-show-properties-for-path)
    ("a" "Run Custom Action…" strata-run-custom-action)
    ("," "Settings & Diagnostics" strata-open-settings)
    ("?" "Shortcut Reference (C-c ? / ~)" strata-open-shortcut-reference)]])

;;;; Interactive Settings & 26-Point Diagnostics (`C-,`)

(defun strata-open-settings ()
  "Open instant Strata Settings & Diagnostics buffer (`C-,')."
  (interactive)
  (let ((buf (get-buffer-create "*Strata Settings*"))
        (p (strata-prefs)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (setq-local header-line-format
                    (concat "  "
                            (strata-icon-glyph 'gear 'strata-header-accent)
                            (propertize "  Strata Settings & Diagnostics   [Click/RET on setting to toggle · g: Refresh · q: Close]"
                                        'face 'strata-header-accent)))
        (cl-labels ((toggle-row (label desc getter setter)
                      (let* ((val (funcall getter p))
                             (btn (format "   %-34s  [%s]   %s\n"
                                          label
                                          (propertize (if val "ON " "OFF")
                                                      'face (if val 'strata-bar-ok 'shadow))
                                          (propertize desc 'face 'strata-hint-desc)))
                             (act (lambda ()
                                    (interactive)
                                    (funcall setter p (not val))
                                    (strata-prefs-save)
                                    (strata-open-settings)))
                             (km (make-sparse-keymap)))
                        (define-key km (kbd "RET") act)
                        (define-key km [mouse-1] act)
                        (insert (strata-add-row-properties
                                 btn (list 'keymap km
                                           'mouse-face 'highlight
                                           'pointer 'hand)))))
                    (cycle-row (label val choices setter)
                      (let* ((btn (format "   %-34s  [%s]\n"
                                          label
                                          (propertize (format "%s" val) 'face 'strata-header-accent)))
                             (act (lambda ()
                                    (interactive)
                                    (let* ((pos (or (cl-position val choices) 0))
                                           (next (nth (mod (1+ pos) (length choices)) choices)))
                                      (funcall setter p next)
                                      (strata-prefs-save)
                                      (strata-open-settings))))
                             (km (make-sparse-keymap)))
                        (define-key km (kbd "RET") act)
                        (define-key km [mouse-1] act)
                        (insert (strata-add-row-properties
                                 btn (list 'keymap km
                                           'mouse-face 'highlight
                                           'pointer 'hand))))))
          (insert "\n" (propertize "  GENERAL & BROWSING\n" 'face 'strata-section-heading))
          (cycle-row "Default View Mode" (strata-prefs-browser-mode p) '(columns icons list compact)
                     (lambda (pr v) (setf (strata-prefs-browser-mode pr) v)))
          (toggle-row "Expandable folders in List view" "Show disclosure chevrons in List"
                      #'strata-prefs-expandable-tree
                      (lambda (pr v) (setf (strata-prefs-expandable-tree pr) v)))
          (toggle-row "Remember folder views" "Save view/sort per folder (LRU 128)"
                      #'strata-prefs-remember-folder-views
                      (lambda (pr v) (setf (strata-prefs-remember-folder-views pr) v)))
          (toggle-row "Restore tabs on startup" "Persist workspace tabs across sessions"
                      #'strata-prefs-restore-tabs
                      (lambda (pr v) (setf (strata-prefs-restore-tabs pr) v)))
          (toggle-row "Folders first" "Keep folders sorted above files"
                      #'strata-prefs-folders-first
                      (lambda (pr v) (setf (strata-prefs-folders-first pr) v)))
          (toggle-row "Natural numeric sort" "Sort file2 before file10"
                      #'strata-prefs-natural-sort
                      (lambda (pr v) (setf (strata-prefs-natural-sort pr) v)))
          (toggle-row "Show hidden dot-files" "Include .dotfiles in listings"
                      #'strata-prefs-show-hidden
                      (lambda (pr v) (setf (strata-prefs-show-hidden pr) v)))

          (insert "\n" (propertize "  APPEARANCE & PREVIEWS\n" 'face 'strata-section-heading))
          (toggle-row "Render Markdown & Docs by default" "Toggle raw source with [V]"
                      #'strata-prefs-render-documents-by-default
                      (lambda (pr v) (setf (strata-prefs-render-documents-by-default pr) v)))
          (toggle-row "Show full names in Compact view" "Disable ellipsis truncation in Compact"
                      #'strata-prefs-compact-full-names
                      (lambda (pr v) (setf (strata-prefs-compact-full-names pr) v)))
          (cycle-row "Unit system" (strata-prefs-unit-system p) '(metric binary)
                     (lambda (pr v) (setf (strata-prefs-unit-system pr) v)))
          (cycle-row "Date format" (strata-prefs-date-format p) '(relative iso locale)
                     (lambda (pr v) (setf (strata-prefs-date-format pr) v)))
          (toggle-row "Columns show file sizes" "Display file sizes in Miller columns"
                      #'strata-prefs-columns-show-sizes
                      (lambda (pr v) (setf (strata-prefs-columns-show-sizes pr) v)))
          (toggle-row "Show keybinding hints" "Show shortcut strip in footer"
                      #'strata-prefs-show-keybinding-hints
                      (lambda (pr v) (setf (strata-prefs-show-keybinding-hints pr) v)))

          (insert "\n" (propertize "  KEYBOARD & 10XER WORKFLOW\n" 'face 'strata-section-heading))
          (toggle-row "10xer Mode (C-S-m)" "Yazi/Vim modal navigation & chords"
                      #'strata-prefs-tenxer-mode
                      (lambda (_pr _v) (strata-toggle-tenxer-mode)))
          (toggle-row "10xer d-d trash confirm" "Require second 'd' before trashing"
                      #'strata-prefs-tenxer-delete-confirm
                      (lambda (pr v) (setf (strata-prefs-tenxer-delete-confirm pr) v)))

          (insert "\n" (propertize "  CUSTOM ACTIONS & DIAGNOSTICS\n" 'face 'strata-section-heading))
          (insert (format "   Loaded Custom Actions: %d  (Press [a] to run or [i] to install starter recipe)\n"
                          (length (strata-actions-load))))
          (insert (format "   Preview Zoom Levels:   Text %+d · Image %.0f%% · PDF %.0f%%\n\n"
                          (strata-prefs-preview-text-scale p)
                          (* 100 (strata-prefs-preview-image-scale p))
                          (* 100 (strata-prefs-preview-pdf-scale p))))
          (insert (propertize "  RUNTIME DIAGNOSTICS PROBE\n" 'face 'strata-section-heading))
          (dolist (tool '(("fd" . "Global & subfolder search")
                          ("rg" . "Content search")
                          ("gio" . "XDG Trash & GVfs mounts")
                          ("udisksctl" . "Mount / unmount / LUKS unlock")
                          ("vipsthumbnail" . "Fast image thumbnails & previews")
                          ("ffmpegthumbnailer" . "Video storyboard thumbnails")
                          ("mpv" . "Audio/video preview IPC & player")
                          ("mediainfo" . "Media codec & HDR badges")
                          ("pdftoppm" . "PDF page preview rasterizer")
                          ("7z" . "Archive preview, compress & extract")
                          ("pandoc" . "DOCX / ODT / RTF rendering")
                          ("exiftool" . "Camera RAW / EXIF metadata")
                          ("fc-query" . "Font specimen inspection")
                          ("wl-paste" . "Wayland clipboard image/text drops")))
            (let ((found (executable-find (car tool))))
              (insert (format "   %-18s %-8s  %s\n"
                              (car tool)
                              (propertize (if found "OK" "MISSING")
                                          'face (if found 'strata-bar-ok 'strata-bar-danger))
                              (propertize (cdr tool) 'face 'shadow)))))
          (local-set-key (kbd "g") #'strata-open-settings)
          (local-set-key (kbd "i") #'strata-install-action-recipe)
          (local-set-key (kbd "a") #'strata-run-custom-action))
        (goto-char (point-min))))
    (pop-to-buffer buf)))

;;;; Searchable Shortcut Reference (`C-c ?' / `?' / `~')

(defun strata-open-shortcut-reference ()
  "Open Strata Shortcut Reference (`C-c ?' / `?' / `~') documenting active mode bindings."
  (interactive)
  (let ((buf (get-buffer-create "*Strata Shortcuts*"))
        (tenx (strata-prefs-tenxer-mode (strata-prefs))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (setq-local header-line-format
                    (concat "  "
                            (strata-icon-glyph 'keyboard 'strata-header-accent)
                            (propertize (format "  Strata Shortcut Reference (%s Mode)   [C-S-m: Switch Mode · f: Filter · q: Close]"
                                                (if tenx "10xer" "Default"))
                                        'face 'strata-header-accent)))
        (insert "\n")
        (dolist (sec
                 `(("NAVIGATION"
                    (,(if tenx "h / l / ← / →" "← / →") "Parent folder / Open Folder, Expand Tree, or Enter Read-Only Preview")
                    (,(if tenx "j / k / ↑ / ↓" "↑ / ↓") "Move down / up; keep explicit marks")
                    (,(if tenx "H / L / M-← / M-→" "M-← / M-→") "Pane History Back / Forward")
                    ("M-↑ / M-↓" "Parent folder / Make First Column")
                    ("RET / Double-Click" "Open Folder / Direct-Edit File in Preview Pane")
                    ("C-← / C-c q / C-c k" "Leave Preview or Edit (Save Prompt) / Exit Left / Abort Edits")
                    (,(if tenx "SPC / i / M-i" "SPC / M-i") "Preview File (Keep Focus) / Toggle Peek Drawer")
                    ("C-RET / S-RET" "Open in New Tab / New Frame")
                    ("C-l / g SPC" "Edit Location (~/, computer:///, trash:///, recent:///, sftp://, admin:///)")
                    (,(if tenx "z / Z / C-S-k" "C-S-k") "Jump to Visited Folder (10xer Z: Recent File)"))
                   ("SELECTION (DIRECTORY VIEWS)"
                    ("Click file" "Select one file and preview; replaces old marks (folder click opens)")
                    ("C-SPC / C-Click" "Toggle current / clicked item; repeat to deselect")
                    (,(if tenx "u / U / V" "m / u / U")
                     ,(if tenx "Unmark current / Clear all marks (U or V)" "Toggle current / Unmark current / Clear all marks"))
                    ("C-a / C-S-a" "Select all visible entries / Clear all marks")
                    ("ESC" "Clear all marks and the active folder filter")
                    ("S-Arrows / S-Click" "Select an inclusive range; reverse direction to shrink")
                    ("First S-Arrow" "Usually selects two items: the starting item and the destination")
                    ("C-S-Arrows / C-S-Click" "Add a range while preserving other marked items")
                    ("S-Home / S-End" "Range to first / last entry; add Ctrl to preserve other marks")
                    (,(if tenx "C-S-i / C-r" "C-S-i") "Invert selection")
                    ("S-F10 then V" "Clear Selection from the context menu")
                    ("Current file" "Used by copy/cut and file actions when no items are marked")
                    ("10xer: v ... v" "Set anchor, move, press v again to mark the inclusive range"))
                   ("MOUSE & DRAG SELECTION"
                    ("Drag within pane" "Replace marks with a live range; reverse drag to shrink")
                    ("Icons / Compact drag" "Select a rectangle across rows and columns")
                    ("C-Drag / S-Drag" "Add a range to existing marks within the same pane")
                    ("Drag to other pane" "Transfer the marked group; choose Copy / Move / Cancel")
                    ("C-Drag / S-Drag across" "Copy / Move into another pane (Ctrl wins with both modifiers)")
                    ("ESC / C-g / Right-Click" "During drag: cancel and restore the previous selection")
                    ("Right-Click item" "Keep a marked batch; an unmarked item becomes the menu target")
                    ("Double-Click / Middle" "Open folder or edit file"))
                   ("VIEWS, SORT & ZOOM"
                    ("C-1 / C-2 / C-3 / C-4" "Columns / Icons Grid / List (Tree) / Compact View")
                    ("Click View…" "Choose a layout from the header menu; the current view is checked")
                    ("C-c s / Click Sort By…" "Sort menu in every directory layout; also S-F10 then S")
                    ("Sort By… options" "Name / Modification date / Size / Type or extension / Unsorted")
                    ("Sort order" "Ascending / Descending; Folders first; Natural names (file2 before file10)")
                    ("TAB" "Expand / Collapse folder subtree (List/Tree view)")
                    (,(if tenx "C-. / ." "C-.") "Toggle Hidden Dot-files")
                    (,(if tenx "M-v / W / M-w" "M-v / M-w") "Toggle Rendered Document Mode / Preview Line Wrap")
                    ("C-+ / C-- / C-0" "Independent Preview Zoom (Text / Image / PDF)")
                    ("C-M-+ / C-M-- / C-M-0" "Icons Grid Thumbnail Size")
                    ("10xer: J / K" "Scroll Preview Window Down / Up"))
                   ("PANES, TERMINAL & TABS"
                    ("F3 / F6" "Toggle Extra Split Pane / Switch Active Pane")
                    ("C-S-c / C-S-x" "Copy / Move selection to Other Pane (or Drag across panes)")
                    ("C-` / F9 / C-M-t" "Toggle Pane Embedded Terminal / External Terminal")
                    (,(if tenx "C-n / C-S-b" "C-b / C-S-b") "Toggle / Focus Left Sidebar (c inside Sidebar: Rail mode)")
                    ("C-t / C-w / C-S-t" "New Tab / Close Tab / Reopen Closed Tab")
                    ("C-TAB / C-S-TAB" "Next / Previous Tab"))
                   ("FILES, SEARCH & ACTIONS"
                    (,(if tenx "C-k / f / s" "C-k / C-f") "Global Recursive Search / Filter Folder (10xer s: Include Subfolders)")
                    ("10xer: / / M-? / n / N" "Incremental Find / Backward Find / Repeat Forward / Backward")
                    ("y / x / p / P" "Copy / Cut / Paste Keep Both / Paste Replace (10xer; Default: C-c c/x/v)")
                    ("a / C-S-n / C-M-n" "Create Entry / New Folder / New Folder with Selection")
                    ("F2 / r / DEL / S-DEL" "Rename (supports sub/path) / Trash / Permanent Delete")
                    ("C-z / C-S-z" "Undo / Redo File Operation")
                    ("M-RET / 10xer O" "Properties / Open With")
                    ("S-F10 / Menu" "Dynamic Context Actions Menu")
                    ("C-, / C-S-m" "Settings & Diagnostics / Toggle 10xer Mode")
                    ("? / C-c ? / 10xer ~" "Open this Shortcut Reference in either mode"))
                   ("10XER CHORDS & MEDIA"
                    ("m <a-z> / ' <a-z>" "10xer: Set / Jump Persistent Letter Bookmark")
                    ("C-u / C-d / C-b / C-f" "10xer: Half Page Up / Down / Page Up / Down")
                    ("g <key>" "Go: h Home, e Computer, t Trash, n Network, r Recent, 1-9 Pins, +/- Pin")
                    (", <key>" "Sort: a Name, m Mod, s Size, e Type, x Ext, b Created, u Unsorted, n Natural, l Reverse, f Folders first, g Group")
                    ("Repeat sort chord" "Selecting the same sort key again reverses its order")
                    ("; <key>" "Actions: t Term, c Compress, e/E Extract, 1-9 Action, . Folder Action")
                    ("t <key>" "Tabs: n New, x Close, t Prev, 1-9 Tab N")
                    ("C-M-SPC / C-M-←/→" "Media Play-Pause / Seek ±5s (mpv IPC)"))))
          (insert (propertize (format "  %s\n" (car sec)) 'face 'strata-section-heading))
          (dolist (row (cdr sec))
            (insert (format "   %-22s  %s\n"
                            (propertize (car row) 'face 'strata-hint-key)
                            (cadr row))))
          (insert "\n"))
        (local-set-key (kbd "f") (lambda () (interactive) (call-interactively #'occur)))
        (local-set-key (kbd "C-S-m")
                       (lambda () (interactive)
                         (strata-toggle-tenxer-mode)
                         (strata-open-shortcut-reference)))
        (goto-char (point-min))))
    (pop-to-buffer buf)))

;;;; Dual Minor Mode Keymaps (Default Desktop vs 10xer Modal)

(defvar strata-default-keymap
  (let ((map (make-sparse-keymap)))
    ;; Navigation & Views
    (define-key map (kbd "<left>") #'strata-tree-collapse-or-up)
    (define-key map (kbd "<right>") #'strata-tree-expand-or-open)
    (define-key map (kbd "TAB") #'dirvish-toggle-subtree)
    (define-key map (kbd "M-<left>") #'strata-history-back)
    (define-key map (kbd "M-<right>") #'strata-history-forward)
    (define-key map (kbd "M-<up>") #'dired-up-directory)
    (define-key map (kbd "M-<down>") #'strata-make-first-column)
    (define-key map (kbd "M-<home>") (lambda () (interactive) (strata-open-location "~/" t)))
    (define-key map (kbd "SPC") #'strata-preview-at-point)
    (define-key map (kbd "RET") #'strata-open-or-edit-at-point)
    (define-key map (kbd "M-i") #'strata-toggle-peek)
    (define-key map (kbd "C-<return>") #'strata-open-in-new-tab)
    (define-key map (kbd "S-<return>") #'strata-open-in-new-frame)

    ;; Views & Zoom
    (define-key map (kbd "C-1") #'strata-view-columns)
    (define-key map (kbd "C-2") #'strata-view-icons)
    (define-key map (kbd "C-3") #'strata-view-list)
    (define-key map (kbd "C-4") #'strata-view-compact)
    (define-key map (kbd "C-c s") #'strata-sort-menu)
    (define-key map (kbd "C-=") #'strata-preview-zoom-in)
    (define-key map (kbd "C-+") #'strata-preview-zoom-in)
    (define-key map (kbd "C--") #'strata-preview-zoom-out)
    (define-key map (kbd "C-0") #'strata-preview-zoom-reset)
    (define-key map (kbd "C-M-=") (lambda () (interactive) (strata-thumbnails-scale 16)))
    (define-key map (kbd "C-M--") (lambda () (interactive) (strata-thumbnails-scale -16)))
    (define-key map (kbd "C-M-0") (lambda () (interactive) (strata-thumbnails-scale 0)))
    (define-key map (kbd "M-<next>") (lambda () (interactive) (strata-pdf-page-step 1)))
    (define-key map (kbd "M-<prior>") (lambda () (interactive) (strata-pdf-page-step -1)))
    (define-key map (kbd "C-.") #'strata-toggle-hidden-files)

    ;; Split Pane / Terminal / Sidebar / Tabs
    (define-key map (kbd "<f3>") #'strata-toggle-extra-pane)
    (define-key map (kbd "C-`") #'strata-toggle-pane-terminal)
    (define-key map (kbd "<f9>") #'strata-toggle-pane-terminal)
    (define-key map (kbd "C-c t") #'strata-toggle-pane-terminal)
    (define-key map (kbd "<f5>") #'strata-refresh-active-view)
    (define-key map (kbd "<f6>") #'strata-switch-other-pane)
    (define-key map (kbd "C-S-c") #'strata-copy-to-other-pane)
    (define-key map (kbd "C-S-x") #'strata-move-to-other-pane)
    (define-key map (kbd "C-M-t") #'strata-open-external-terminal)
    (define-key map (kbd "C-b") #'strata-sidebar-toggle)
    (define-key map (kbd "C-S-b") #'strata-sidebar-focus)
    (define-key map (kbd "C-t") #'strata-tab-new)
    (define-key map (kbd "C-w") #'strata-tab-close)
    (define-key map (kbd "C-S-t") #'strata-tab-reopen-closed)
    (define-key map (kbd "C-a") #'strata-select-all)
    (define-key map (kbd "C-S-a") #'strata-clear-all-marks)
    (define-key map (kbd "C-S-i") #'strata-invert-selection)
    (define-key map (kbd "C-SPC") #'strata-view-toggle-mark)
    (define-key map (kbd "m") #'strata-view-toggle-mark)
    (define-key map (kbd "u") #'strata-view-unmark)
    (define-key map (kbd "U") #'strata-clear-all-marks)
    (define-key map (kbd "M-v") #'strata-toggle-rendered-document)
    (define-key map (kbd "M-w") #'strata-toggle-preview-wrap)
    (define-key map (kbd "C-<tab>") #'strata-tab-next)
    (define-key map (kbd "C-<next>") #'strata-tab-next)
    (define-key map (kbd "C-S-<tab>") #'strata-tab-previous)
    (define-key map (kbd "C-<prior>") #'strata-tab-previous)
    (define-key map (kbd "C-S-<prior>") (lambda () (interactive) (strata-tab-move -1)))
    (define-key map (kbd "C-S-<next>") (lambda () (interactive) (strata-tab-move 1)))

    ;; File Operations, Search & Mouse Click Navigation
    (define-key map (kbd "C-c c") #'strata-copy-selection)
    (define-key map (kbd "C-c x") #'strata-cut-selection)
    (define-key map (kbd "C-c v") #'strata-paste-keep-both)
    (define-key map (kbd "C-S-v") #'strata-paste-content-drop)
    (define-key map (kbd "C-d") #'strata-duplicate)
    (define-key map (kbd "C-S-n") #'strata-new-folder)
    (define-key map (kbd "C-M-n") #'strata-new-folder-with-selection)
    (define-key map (kbd "<f2>") #'strata-rename)
    (define-key map (kbd "C-r") #'strata-rename)
    (define-key map (kbd "<delete>") #'strata-move-to-trash)
    (define-key map (kbd "S-<delete>") #'strata-delete-permanently)
    (define-key map (kbd "C-z") #'strata-undo)
    (define-key map (kbd "C-S-z") #'strata-redo)
    (define-key map (kbd "M-RET") #'strata-show-properties-for-path)
    (define-key map (kbd "<menu>") #'strata-context-menu)
    (define-key map (kbd "S-<f10>") #'strata-context-menu)
    (define-key map (kbd "S-<down>") #'strata-shift-select-next)
    (define-key map (kbd "S-<up>") #'strata-shift-select-prev)
    (define-key map (kbd "S-<right>") #'strata-shift-select-right)
    (define-key map (kbd "S-<left>") #'strata-shift-select-left)
    (define-key map (kbd "C-S-<down>") #'strata-shift-select-next)
    (define-key map (kbd "C-S-<up>") #'strata-shift-select-prev)
    (define-key map (kbd "C-S-<right>") #'strata-shift-select-right)
    (define-key map (kbd "C-S-<left>") #'strata-shift-select-left)
    (define-key map (kbd "S-<home>") #'strata-shift-select-first)
    (define-key map (kbd "S-<end>") #'strata-shift-select-last)
    (define-key map (kbd "C-S-<home>") #'strata-shift-select-first)
    (define-key map (kbd "C-S-<end>") #'strata-shift-select-last)
    (strata-mouse-install-keymap-bindings map)
    (define-key map (kbd "C-k") #'strata-global-search)
    (define-key map (kbd "C-S-k") #'strata-jump-visited-folder)
    (define-key map (kbd "C-f") #'strata-filter-pane)
    (define-key map (kbd "C-l") #'strata-location-prompt)

    ;; Media Playback Controls
    (define-key map (kbd "C-M-SPC") #'strata-media-play-pause)
    (define-key map (kbd "C-M-<left>") (lambda () (interactive) (strata-media-seek -5)))
    (define-key map (kbd "C-M-<right>") (lambda () (interactive) (strata-media-seek 5)))
    (define-key map (kbd "C-M-<up>") (lambda () (interactive) (strata-media-volume-step 5)))
    (define-key map (kbd "C-M-<down>") (lambda () (interactive) (strata-media-volume-step -5)))
    (define-key map (kbd "C-M-m") #'strata-media-mute-toggle)

    ;; Mode / Settings / Help
    (define-key map (kbd "<escape>") #'strata-escape)
    (define-key map (kbd "C-,") #'strata-open-settings)
    (define-key map (kbd "C-c ?") #'strata-open-shortcut-reference)
    (define-key map (kbd "?") #'strata-open-shortcut-reference)
    (define-key map (kbd "C-S-m") #'strata-toggle-tenxer-mode)
    map)
  "Strata Default Desktop keymap for `strata-dirvish-mode'.")

(defvar strata-10xer-keymap
  (let ((map (make-sparse-keymap)))
    ;; Navigation
    (define-key map (kbd "j") #'strata-nav-next-line)
    (define-key map (kbd "k") #'strata-nav-prev-line)
    (define-key map (kbd "h") #'strata-tree-collapse-or-up)
    (define-key map (kbd "l") #'strata-tree-expand-or-open)
    (define-key map (kbd "o") #'strata-tree-expand-or-open)
    (define-key map (kbd "O") #'strata-open-with)
    (define-key map (kbd "G") #'end-of-buffer)
    (define-key map (kbd "C-u") #'strata-half-page-up)
    (define-key map (kbd "C-d") #'strata-half-page-down)
    (define-key map (kbd "C-b") #'scroll-down-command)
    (define-key map (kbd "C-f") #'scroll-up-command)
    (define-key map (kbd "C-n") #'strata-sidebar-toggle)
    (define-key map (kbd "H") #'strata-history-back)
    (define-key map (kbd "L") #'strata-history-forward)
    (define-key map (kbd "i") #'strata-toggle-peek)
    (define-key map (kbd "J") #'strata-scroll-preview-down)
    (define-key map (kbd "K") #'strata-scroll-preview-up)
    (define-key map (kbd "C-r") #'strata-invert-selection)
    (define-key map (kbd "W") #'strata-toggle-preview-wrap)

    ;; Selection & File Verbs
    (define-key map (kbd "v") #'strata-visual-toggle)
    (define-key map (kbd "V") #'strata-clear-all-marks)
    (define-key map (kbd "y") #'strata-copy-selection)
    (define-key map (kbd "x") #'strata-cut-selection)
    (define-key map (kbd "Y") #'strata-unyank)
    (define-key map (kbd "X") #'strata-unyank)
    (define-key map (kbd "p") #'strata-paste-keep-both)
    (define-key map (kbd "P") #'strata-paste-replace)
    (define-key map (kbd "a") #'strata-create-entry)
    (define-key map (kbd "r") #'strata-rename)
    (define-key map (kbd "d") #'strata-chord-trash-or-d)
    (define-key map (kbd "D") #'strata-delete-permanently)
    (define-key map (kbd "C") #'strata-copy-to)
    (define-key map (kbd "M") #'strata-move-to)
    (define-key map (kbd "R") #'strata-trash-restore-at-point)
    (define-key map (kbd ".") #'strata-toggle-hidden-files)

    ;; Search / Jump / Bookmarks
    (define-key map (kbd "/") #'strata-find-in-folder)
    (define-key map (kbd "?") #'strata-open-shortcut-reference)
    (define-key map (kbd "M-?") (lambda () (interactive) (strata-find-in-folder t)))
    (define-key map (kbd "n") #'strata-find-repeat)
    (define-key map (kbd "N") (lambda () (interactive) (strata-find-repeat t)))
    (define-key map (kbd "f") #'strata-filter-pane)
    (define-key map (kbd "s") (lambda () (interactive) (strata-filter-pane t)))
    (define-key map (kbd "z") #'strata-jump-visited-folder)
    (define-key map (kbd "Z") #'strata-jump-recent-file)
    (define-key map (kbd "m") #'strata-letter-bookmark-set)
    (define-key map (kbd "'") #'strata-letter-bookmark-go)

    ;; Thumbnail Quick Steps
    (define-key map (kbd "+") (lambda () (interactive) (if (derived-mode-p 'strata-icons-mode) (strata-thumbnails-scale 16) (strata-preview-zoom-in))))
    (define-key map (kbd "=") (lambda () (interactive) (if (derived-mode-p 'strata-icons-mode) (strata-thumbnails-scale 16) (strata-preview-zoom-in))))
    (define-key map (kbd "-") (lambda () (interactive) (if (derived-mode-p 'strata-icons-mode) (strata-thumbnails-scale -16) (strata-preview-zoom-out))))

    ;; Multi-Key Chords, Mouse Navigation & Reference
    (define-key map (kbd "g") #'strata-chord-go)
    (define-key map (kbd ",") #'strata-chord-sort)
    (define-key map (kbd "c") #'strata-chord-copy-as)
    (define-key map (kbd ";") #'strata-chord-actions)
    (define-key map (kbd "t") #'strata-chord-tabs)
    (define-key map (kbd "~") #'strata-open-shortcut-reference)
    (strata-mouse-install-keymap-bindings map)
    map)
  "Strata 10xer overlay keymap for `strata-dirvish-tenxer-mode'.")

(define-minor-mode strata-dirvish-tenxer-mode
  "10xer modal overlay active above `strata-dirvish-mode' when `tenxer-mode' is t."
  :lighter " 10X"
  :keymap strata-10xer-keymap
  ;; The base minor mode can appear before this mode in Emacs's map order.
  ;; Compose its buffer-local map explicitly so every 10xer override wins,
  ;; including C-r/C-d/C-f, on first load and on live reload alike.
  (setq-local minor-mode-overriding-map-alist
              (assq-delete-all 'strata-dirvish-mode
                               minor-mode-overriding-map-alist))
  (when strata-dirvish-tenxer-mode
    (push (cons 'strata-dirvish-mode
                (make-composed-keymap strata-10xer-keymap strata-default-keymap))
          minor-mode-overriding-map-alist)))

(define-minor-mode strata-dirvish-mode
  "Buffer-local minor mode exposing all Strata features inside Dirvish & view buffers."
  :lighter " Strata"
  :keymap strata-default-keymap
  (if strata-dirvish-mode
      (progn
        (add-hook 'post-command-hook #'strata-view--selection-post-command nil t)
        ;; Extra panes may use ordinary Dired without Dirvish's header composer.
        (when (and (derived-mode-p 'dired-mode) (null header-line-format)
                   (not (when-let ((dv (dirvish-curr))) (dv-curr-layout dv))))
          (setq-local header-line-format '(:eval (strata-view-header-line))))
        (strata-dirvish--apply-active-keymap))
    (remove-hook 'post-command-hook #'strata-view--selection-post-command t)
    (strata-dirvish-tenxer-mode -1)))

(defun strata-dirvish--apply-active-keymap ()
  "Enable or disable `strata-dirvish-tenxer-mode' honoring terminal focus guard."
  (if (and (not (strata-terminal-focused-p))
           (strata-prefs-tenxer-mode (strata-prefs)))
      (strata-dirvish-tenxer-mode 1)
    (strata-dirvish-tenxer-mode -1)))

(provide 'strata-dirvish-keys)
;;; strata-dirvish-keys.el ends here
