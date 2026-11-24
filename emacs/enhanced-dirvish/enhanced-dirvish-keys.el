;;; enhanced-dirvish-keys.el --- Keymaps, chords, Settings, Diagnostics, Help & Menus -*- lexical-binding: t; -*-

;; Copyright (C) 2026 dragonleopardpig
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.  It is part of Enhanced Dirvish;
;; see enhanced-dirvish.el for the full license notice.

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
(require 'enhanced-dirvish-prefs)
(require 'enhanced-dirvish-devices)
(require 'enhanced-dirvish-views)
(require 'enhanced-dirvish-panes)
(require 'enhanced-dirvish-previews)
(require 'enhanced-dirvish-search)
(require 'enhanced-dirvish-ops)

;;;; Explorer/Nemo-Style Keys Reserved for Users (opt-in)

(defconst enhanced-dirvish--file-manager-bindings
  '((enhanced-dirvish-default-keymap
     ("<f5>" . enhanced-dirvish-refresh-active-view)
     ("<f6>" . enhanced-dirvish-switch-other-pane)
     ("<f9>" . enhanced-dirvish-toggle-pane-terminal)
     ("C-c s" . enhanced-dirvish-sort-menu)
     ("C-c t" . enhanced-dirvish-toggle-pane-terminal)
     ("C-c c" . enhanced-dirvish-copy-selection)
     ("C-c x" . enhanced-dirvish-cut-selection)
     ("C-c v" . enhanced-dirvish-paste-keep-both))
    (enhanced-dirvish-compact-mode-map ("<f5>" . enhanced-dirvish-compact-refresh))
    (enhanced-dirvish-icons-mode-map ("<f5>" . enhanced-dirvish-icons-refresh))
    (enhanced-dirvish-computer-mode-map ("<f5>" . enhanced-dirvish-computer-refresh))
    (enhanced-dirvish-trash-mode-map ("<f5>" . enhanced-dirvish-trash-refresh))
    (enhanced-dirvish-recent-mode-map ("<f5>" . enhanced-dirvish-recent-refresh))
    (enhanced-dirvish-preview-read-mode-map ("C-c q" . enhanced-dirvish-preview-read-leave))
    (enhanced-dirvish-preview-edit-mode-map
     ("C-c q" . enhanced-dirvish-preview-edit-exit)
     ("C-c k" . enhanced-dirvish-preview-edit-abort)))
  "Keys bound when `enhanced-dirvish-file-manager-keys' is on, by keymap.")

(defcustom enhanced-dirvish-file-manager-keys nil
  "Non-nil binds Explorer/Nemo-style keys that Emacs leaves to users.
These are F5 (refresh), F6 (switch split pane), F9 (pane terminal) and
\\`C-c s', \\`C-c t', \\`C-c c', \\`C-c x' and \\`C-c v' (sort menu, pane
terminal, copy, cut, paste) in browser buffers, and \\`C-c q' and \\`C-c k'
\(leave, abort) in the preview reader and editor.  Emacs reserves F5-F9
and \\`C-c' followed by a letter for users, so these are off by default;
the same commands have other keys and menu entries.  Customize applies
a change at once; set it with `setq' before `enhanced-dirvish-setup'."
  :type 'boolean
  :group 'enhanced-dirvish
  :initialize #'custom-initialize-default
  :set (lambda (symbol value)
         (set-default symbol value)
         (enhanced-dirvish-apply-file-manager-keys)))

(defun enhanced-dirvish-apply-file-manager-keys ()
  "Bind or unbind the keys of `enhanced-dirvish-file-manager-keys'."
  (pcase-dolist (`(,map . ,bindings) enhanced-dirvish--file-manager-bindings)
    (when (and (boundp map) (keymapp (symbol-value map)))
      (pcase-dolist (`(,key . ,command) bindings)
        (define-key (symbol-value map) (kbd key)
                    (and enhanced-dirvish-file-manager-keys command))))))

(defun enhanced-dirvish-file-manager-keys-for (command)
  "Return the opt-in keys (strings) of COMMAND, or nil while they are off."
  (when enhanced-dirvish-file-manager-keys
    (delete-dups
     (cl-loop for (_map . bindings) in enhanced-dirvish--file-manager-bindings
              append (cl-loop for (key . cmd) in bindings
                              when (eq cmd command) collect key)))))

;;;; Active Chord Hint Engine

(defun enhanced-dirvish-chord--with-hint (label table &optional handler)
  "Show chord hint LABEL, read a key and dispatch it.
The key is looked up in the alist TABLE or passed to HANDLER."
  (let ((enhanced-dirvish-active-chord label))
    (force-mode-line-update t)
    (unwind-protect
        (let* ((prompt (format "%s   [%s] "
                               (propertize label 'face 'enhanced-dirvish-pill-chord)
                               (mapconcat (lambda (kv)
                                            (format "%s:%s"
                                                    (propertize (key-description (vector (car kv))) 'face 'enhanced-dirvish-hint-key)
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
      (setq enhanced-dirvish-active-chord nil)
      (force-mode-line-update t))))

(defun enhanced-dirvish-chord-go ()
  "Execute Enhanced Dirvish `g` navigation chord."
  (interactive)
  (let* ((pins (enhanced-dirvish-bookmarks-read))
         (pin-cmds (cl-loop for i from 1 to (min 9 (length pins))
                            for pin in pins
                            collect (let ((loc (car pin))
                                          (lbl (cdr pin)))
                                      (cons (+ ?0 i)
                                            (cons lbl (lambda () (interactive) (enhanced-dirvish-open-location loc t)))))))
         (table (append
                 `((?g "Top" . ,(lambda () (interactive) (goto-char (point-min))))
                   (?f "Follow" . ,#'dired-find-file)
                   (?\s "Location" . ,#'enhanced-dirvish-location-prompt)
                   (?h "Home" . ,(lambda () (interactive) (enhanced-dirvish-open-location "~/" t)))
                   (?c "~/.config" . ,(lambda () (interactive) (enhanced-dirvish-open-location "~/.config/" t)))
                   (?d "Downloads" . ,(lambda () (interactive) (enhanced-dirvish-open-location "~/Downloads/" t)))
                   (?k "Documents" . ,(lambda () (interactive) (enhanced-dirvish-open-location "~/Documents/" t)))
                   (?m "Music" . ,(lambda () (interactive) (enhanced-dirvish-open-location "~/Music/" t)))
                   (?p "Pictures" . ,(lambda () (interactive) (enhanced-dirvish-open-location "~/Pictures/" t)))
                   (?v "Videos" . ,(lambda () (interactive) (enhanced-dirvish-open-location "~/Videos/" t)))
                   (?t "Trash" . ,(lambda () (interactive) (enhanced-dirvish-open-location "trash:///" t)))
                   (?n "Network" . ,(lambda () (interactive) (enhanced-dirvish-open-location "network:///" t)))
                   (?r "Recent" . ,(lambda () (interactive) (enhanced-dirvish-open-location "recent:///" t)))
                   (?e "Computer" . ,(lambda () (interactive) (enhanced-dirvish-open-location "computer:///" t)))
                   (?+ "Pin" . ,#'enhanced-dirvish-pin-directory)
                   (?- "Unpin" . ,#'enhanced-dirvish-unpin-directory))
                 pin-cmds)))
    (enhanced-dirvish-chord--with-hint "g _" table)))

(defun enhanced-dirvish-chord-sort ()
  "Execute `,` sort/group chord (including `, f` Folders First per #2074)."
  (interactive)
  (enhanced-dirvish-chord--with-hint
   ", _"
   `((?a "Name" . ,(lambda () (interactive) (enhanced-dirvish-sort-set 'name)))
     (?m "Modified" . ,(lambda () (interactive) (enhanced-dirvish-sort-set 'modified)))
     (?s "Size" . ,(lambda () (interactive) (enhanced-dirvish-sort-set 'size)))
     (?e "Type" . ,(lambda () (interactive) (enhanced-dirvish-sort-set 'type)))
     (?x "Ext" . ,(lambda () (interactive) (enhanced-dirvish-sort-set 'extension)))
     (?b "Created" . ,(lambda () (interactive) (enhanced-dirvish-sort-set 'created)))
     (?u "Unsorted" . ,(lambda () (interactive) (enhanced-dirvish-sort-set 'unsorted)))
     (?n "Natural" . ,#'enhanced-dirvish-sort-toggle-natural)
     (?l "Direction" . ,#'enhanced-dirvish-sort-toggle-direction)
     (?f "Folders first" . ,#'enhanced-dirvish-sort-toggle-folders-first)
     (?g "Group type" . ,#'enhanced-dirvish-toggle-group-by-type))))

(defun enhanced-dirvish-chord-copy-as ()
  "Execute Enhanced Dirvish `c` Copy-As / Customize chord."
  (interactive)
  (enhanced-dirvish-chord--with-hint
   "c _"
   `((?c "Copy path" . ,#'enhanced-dirvish-copy-path)
     (?n "Copy name" . ,#'enhanced-dirvish-copy-name)
     (?f "Customize folder" . ,#'enhanced-dirvish-customize-folder))))

(defun enhanced-dirvish-chord-folder-actions ()
  "Execute `; .` folder-targeted custom actions chord (`fork/feat/1743`)."
  (interactive)
  (let ((table (cl-loop for i from 1 to 9
                        collect (let ((idx i))
                                  (cons (+ ?0 i)
                                        (cons (format "Folder Action %d" i)
                                              (lambda () (interactive) (enhanced-dirvish-run-custom-action idx t))))))))
    (push (cons ?. (cons "Pick..." (lambda () (interactive) (enhanced-dirvish-run-custom-action nil t)))) table)
    (enhanced-dirvish-chord--with-hint "; . _" (reverse table))))

(defun enhanced-dirvish-chord-actions ()
  "Execute the `;' Actions chord.
Keys: `t' terminal, `c' compress, `e'/`E' extract, `1'..`9', `.'."
  (interactive)
  (let ((acts (enhanced-dirvish-actions-load))
        (table `((?t "Terminal" . ,#'enhanced-dirvish-open-external-terminal)
                 (?c "Compress" . ,#'enhanced-dirvish-archive-compress)
                 (?e "Extract" . ,(lambda () (interactive) (enhanced-dirvish-archive-extract nil)))
                 (?E "Extract to" . ,(lambda () (interactive) (enhanced-dirvish-archive-extract t)))
                 (?. "On folder…" . ,#'enhanced-dirvish-chord-folder-actions))))
    (dotimes (i (min 9 (length acts)))
      (let ((idx (1+ i))
            (nm (plist-get (nth i acts) :name)))
        (push (cons (+ ?1 i)
                    (cons nm (lambda () (interactive) (enhanced-dirvish-run-custom-action idx nil))))
              table)))
    (enhanced-dirvish-chord--with-hint "; _" (reverse table))))

(defun enhanced-dirvish-chord-tabs ()
  "Execute Enhanced Dirvish `t` Tab management chord."
  (interactive)
  (let ((table `((?n "New tab" . ,#'enhanced-dirvish-tab-new)
                 (?x "Close tab" . ,#'enhanced-dirvish-tab-close)
                 (?t "Prev tab" . ,#'enhanced-dirvish-tab-previous))))
    (dotimes (i 9)
      (let ((n (1+ i)))
        (push (cons (+ ?1 i)
                    (cons (format "Tab %d" n) (lambda () (interactive) (enhanced-dirvish-tab-switch-index n))))
              table)))
    (enhanced-dirvish-chord--with-hint "t _" (reverse table))))

(defun enhanced-dirvish-chord-trash-or-d ()
  "In 10xer mode, support `d d` two-key confirm before trashing."
  (interactive)
  (if (not (enhanced-dirvish-prefs-tenxer-delete-confirm (enhanced-dirvish-prefs)))
      (enhanced-dirvish-move-to-trash)
    (let ((enhanced-dirvish-active-chord "d _"))
      (force-mode-line-update t)
      (unwind-protect
          (let ((ch (read-key "d _  [d: Confirm Move to Trash · Esc: Cancel] ")))
            (when (eq ch ?d) (enhanced-dirvish-move-to-trash)))
        (setq enhanced-dirvish-active-chord nil)
        (force-mode-line-update t)))))

;;;; Mode Toggle, Visual Selection & Half-Page Helpers

(defun enhanced-dirvish-toggle-tenxer-mode ()
  "Toggle 10xer (Vi/Yazi modal) mode (`C-S-m')."
  (interactive)
  (let* ((p (enhanced-dirvish-prefs))
         (next (not (enhanced-dirvish-prefs-tenxer-mode p))))
    (setf (enhanced-dirvish-prefs-tenxer-mode p) next)
    (enhanced-dirvish-prefs-save)
    (dolist (b (buffer-list))
      (when (buffer-live-p b)
        (with-current-buffer b
          (when (bound-and-true-p enhanced-dirvish-mode)
            (enhanced-dirvish--apply-active-keymap)))))
    (force-mode-line-update t)
    (message "Enhanced Dirvish 10xer Mode: %s" (if next "ON (Vi/Yazi single-key chords)" "OFF (Desktop mode)"))))

(defun enhanced-dirvish-half-page-down ()
  "Scroll down half window in browser without touching line/goal columns."
  (interactive)
  (forward-line (max 4 (/ (window-body-height) 2))))

(defun enhanced-dirvish-half-page-up ()
  "Scroll up half window in browser."
  (interactive)
  (forward-line (- (max 4 (/ (window-body-height) 2)))))

(defun enhanced-dirvish-select-all ()
  "Select/mark all entries in active browser buffer (`C-a')."
  (interactive)
  (enhanced-dirvish-view--reset-selection-range (enhanced-dirvish-current-file))
  (let ((order (enhanced-dirvish-view--entry-order)))
    (enhanced-dirvish-mouse--apply-selection-keys order (mapcar #'enhanced-dirvish--path-key order) t)))

(defun enhanced-dirvish-invert-selection ()
  "Invert marked selection (`C-r' in 10xer mode)."
  (interactive)
  (enhanced-dirvish-view--reset-selection-range (enhanced-dirvish-current-file))
  (let* ((order (enhanced-dirvish-view--entry-order))
         (marked (mapcar #'enhanced-dirvish--path-key (enhanced-dirvish-marked-files-only)))
         (keys (cl-remove-if (lambda (key) (member key marked))
                             (mapcar #'enhanced-dirvish--path-key order))))
    (enhanced-dirvish-mouse--apply-selection-keys order keys t)))

(defun enhanced-dirvish-visual-toggle ()
  "Toggle visual selection range in 10xer mode (`v')."
  (interactive)
  (when-let ((cur (enhanced-dirvish-current-file)))
    (if enhanced-dirvish-visual-anchor
        (progn
          (enhanced-dirvish-view--reset-selection-range enhanced-dirvish-visual-anchor)
          (enhanced-dirvish-view--mark-range enhanced-dirvish-visual-anchor cur t)
          (setq enhanced-dirvish-visual-anchor nil)
          (message "Visual range selected"))
      (setq enhanced-dirvish-visual-anchor cur)
      (enhanced-dirvish-view--reset-selection-range cur)
      (enhanced-dirvish-view--set-entry-mark cur t)
      (message "Visual anchor set — move and press v to select the range"))))

(defun enhanced-dirvish-clear-all-marks ()
  "Unmark all files (`V')."
  (interactive)
  (setq enhanced-dirvish-visual-anchor nil)
  (enhanced-dirvish-view--reset-selection-range)
  (cond
   ((derived-mode-p 'dired-mode)
    (dired-unmark-all-marks)
    (enhanced-dirvish-view--refresh-after-mark))
   ((or (derived-mode-p 'enhanced-dirvish-compact-mode) (derived-mode-p 'enhanced-dirvish-icons-mode))
    (setq enhanced-dirvish-marked-entries nil)
    (enhanced-dirvish-view--refresh-after-mark))))

(defun enhanced-dirvish-escape ()
  "Clear explicit selection and any active folder filter."
  (interactive)
  (enhanced-dirvish-clear-all-marks)
  ;; Dirvish narrowing stores its filter in Dirvish properties instead of
  ;; `enhanced-dirvish-local-filter'; retain Escape's directory refresh there.
  (when (or enhanced-dirvish-local-filter (derived-mode-p 'dired-mode))
    (enhanced-dirvish-clear-filter)))

;;;; Dynamic Transient Context Menu & Quick Hub (`Menu` / `S-F10` / `<mouse-3>`)

(defun enhanced-dirvish-context--popup-menu ()
  "Build a mouse context menu for the current item or marked group."
  (let* ((items (enhanced-dirvish-selected-files))
         (has-items (and items t))
         (single (= (length items) 1))
         (dir (or (dirvish-prop :root) default-directory))
         (writable (enhanced-dirvish-path-writable-p dir))
         (archive (and single
                       (let ((f (car items)))
                         (and (not (and (not (enhanced-dirvish-path-unsafe-probe-p f))
                                        (file-directory-p f)))
                              (enhanced-dirvish-archive-file-p f)))))
         (browser (and (derived-mode-p 'dired-mode 'enhanced-dirvish-compact-mode 'enhanced-dirvish-icons-mode) t))
         ;; Pin: the one selected folder, or this folder when nothing is selected
         ;; (an item on a cloud mount is not statted to find out if it is a folder).
         (pin-target (cond ((and single (not (enhanced-dirvish-path-unsafe-probe-p (car items)))
                                 (file-directory-p (car items)))
                            (car items))
                           ((and (not has-items) (stringp dir) (not (file-remote-p dir))
                                 (not (enhanced-dirvish-location-virtual-p dir)))
                            dir)))
         (pinned (and pin-target (enhanced-dirvish-pinned-p pin-target) t))
         (title (if (enhanced-dirvish-marked-files-only)
                    (format "Enhanced Dirvish — %d selected" (length (enhanced-dirvish-marked-files-only)))
                  "Enhanced Dirvish"))
         (menu
          (easy-menu-create-menu
           title
           `(["Open" enhanced-dirvish-tree-expand-or-open :enable ,has-items]
             ["Open With…" enhanced-dirvish-open-with :enable ,has-items]
             ["Open in New Tab" enhanced-dirvish-open-in-new-tab :enable ,has-items]
             ["Open in New Frame" enhanced-dirvish-open-in-new-frame :enable ,has-items]
             ["Pin to Sidebar" (enhanced-dirvish-pin-directory ,pin-target)
              :visible ,(and pin-target (not pinned))]
             ["Unpin from Sidebar" (enhanced-dirvish-unpin-directory ,pin-target) :visible ,pinned]
             "--"
             ["Copy" enhanced-dirvish-copy-selection :enable ,has-items]
             ["Copy Path" enhanced-dirvish-copy-path :enable ,has-items]
             ["Cut" enhanced-dirvish-cut-selection :enable ,(and has-items writable)]
             ["Paste (Keep Both)" enhanced-dirvish-paste-keep-both
              :enable ,(and writable (plist-get enhanced-dirvish-clipboard :files) t)]
             ["Rename…" enhanced-dirvish-rename :enable ,(and single writable)]
             ["Duplicate" enhanced-dirvish-duplicate :enable ,(and has-items writable)]
             ["Move to Trash" enhanced-dirvish-move-to-trash :enable ,(and has-items writable)]
             "--"
             ["Extract Here" enhanced-dirvish-archive-extract :visible ,archive :enable ,writable]
             ["Extract to Folder…" (enhanced-dirvish-archive-extract t) :visible ,archive :enable ,writable]
             ["Compress…" enhanced-dirvish-archive-compress :enable ,(and has-items writable)]
             ["Compress with Encryption…" enhanced-dirvish-archive-compress-encrypted
              :enable ,(and has-items writable)]
             "--"
             ["New Folder…" enhanced-dirvish-new-folder :enable ,writable]
             ["New File…" enhanced-dirvish-new-file :enable ,writable]
             ("Selection"
              ["Select All" enhanced-dirvish-select-all :enable ,browser]
              ["Invert Selection" enhanced-dirvish-invert-selection :enable ,browser]
              ["Clear Selection" enhanced-dirvish-clear-all-marks :enable ,browser])
             ("More File Actions"
              ["Paste (Replace)" enhanced-dirvish-paste-replace
               :enable ,(and writable (plist-get enhanced-dirvish-clipboard :files) t)]
              ["New Folder with Selection…" enhanced-dirvish-new-folder-with-selection
               :enable ,(and has-items writable)]
              ["Copy Name" enhanced-dirvish-copy-name :enable ,has-items]
              ["Save Clipboard Image/Text" enhanced-dirvish-paste-content-drop :enable ,writable]
              ["Delete Permanently…" enhanced-dirvish-delete-permanently :enable ,(and has-items writable)])
             ["Properties…" enhanced-dirvish-show-properties-for-path]
             "--"
             ("Panes & Tools"
              ["Split Extra Pane" enhanced-dirvish-toggle-extra-pane]
              ["Copy to Other Pane" enhanced-dirvish-copy-to-other-pane
               :enable ,(and has-items (enhanced-dirvish-split-active-p))]
              ["Move to Other Pane" enhanced-dirvish-move-to-other-pane
               :enable ,(and has-items writable (enhanced-dirvish-split-active-p))]
              ["Pane Terminal" enhanced-dirvish-toggle-pane-terminal]
              ["Customize Folder Color/Icon…" enhanced-dirvish-customize-folder]
              ["Run Custom Action…" enhanced-dirvish-run-custom-action]
              ["Undo" enhanced-dirvish-undo :enable ,(and enhanced-dirvish-undo-stack t)]
              ["Redo" enhanced-dirvish-redo :enable ,(and enhanced-dirvish-redo-stack t)]
              ["Settings & Diagnostics" enhanced-dirvish-open-settings])
             ["Shortcut Reference (?)" enhanced-dirvish-open-shortcut-reference]))))
    ;; Reuse the same submenus as the two header buttons.
    (define-key-after menu [view]
      (list 'menu-item "View" (enhanced-dirvish-view--menu) :enable browser))
    (define-key-after menu [sort]
      (list 'menu-item "Sort By" (enhanced-dirvish-sort--menu) :enable browser))
    menu))

(defun enhanced-dirvish-mouse-context-menu (event)
  "Select EVENT target and show the GUI context menu (`<mouse-3>').
Text terminals use `enhanced-dirvish-context-menu', also available with
Shift-F10."
  (interactive "e")
  (if (bound-and-true-p enhanced-dirvish-mouse--suppress-mouse-3-once)
      (setq enhanced-dirvish-mouse--suppress-mouse-3-once nil)
    (let ((file (enhanced-dirvish-mouse--entry-at-posn (event-end event)))
          (compact-position (enhanced-dirvish-mouse--compact-position (event-end event))))
      (enhanced-dirvish-mouse--sync-event event)
      (when file
        (setq enhanced-dirvish--empty-click-p nil enhanced-dirvish--empty-click-position nil))
      ;; A menu on an unmarked item must operate on that item, not an old batch.
      (unless (and file (member (enhanced-dirvish--path-key file)
                               (mapcar #'enhanced-dirvish--path-key (enhanced-dirvish-marked-files-only))))
        (enhanced-dirvish-clear-all-marks))
      (unless file
        (enhanced-dirvish-mouse--clear-focus compact-position)))
    (enhanced-dirvish-view--update-selection-highlight)
    (if (display-popup-menus-p)
        (popup-menu (enhanced-dirvish-context--popup-menu) event)
      (call-interactively #'enhanced-dirvish-context-menu))))

(transient-define-prefix enhanced-dirvish-context-menu ()
  "Enhanced Dirvish Context Menu adapting dynamically to selection & location."
  [:description
   (lambda ()
     (let ((marked (enhanced-dirvish-marked-files-only))
           (f (enhanced-dirvish-current-file)))
       (format "Enhanced Dirvish Actions — %s"
               (cond ((> (length marked) 0)
                      (format "%d selected" (length marked)))
                     ((enhanced-dirvish-location-virtual-p (dirvish-prop :root))
                      (or (dirvish-prop :root) "Virtual"))
                     (f (file-name-nondirectory (directory-file-name f)))
                     (t (abbreviate-file-name default-directory))))))
   ["Navigation & View"
    ("RET" "Open" enhanced-dirvish-tree-expand-or-open)
    ("O" "Open With…" enhanced-dirvish-open-with)
    ("T" "Open in New Tab" enhanced-dirvish-open-in-new-tab)
    ("F" "Open in New Frame" enhanced-dirvish-open-in-new-frame)
    ("1" "Columns View" enhanced-dirvish-view-columns)
    ("2" "Icons Grid View" enhanced-dirvish-view-icons)
    ("3" "List / Tree View" enhanced-dirvish-view-list)
    ("4" "Compact View" enhanced-dirvish-view-compact)
    ("S" "Sort By…" enhanced-dirvish-sort-menu)]
   ["File Operations"
    ("y" "Copy" enhanced-dirvish-copy-selection)
    ("x" "Cut" enhanced-dirvish-cut-selection)
    ("p" "Paste (Keep Both)" enhanced-dirvish-paste-keep-both)
    ("P" "Paste (Replace)" enhanced-dirvish-paste-replace)
    ("d" "Duplicate" enhanced-dirvish-duplicate)
    ("r" "Rename" enhanced-dirvish-rename)
    ("+" "New Folder" enhanced-dirvish-new-folder)
    ("f" "New File" enhanced-dirvish-new-file)
    ("N" "New Folder w/ Selection" enhanced-dirvish-new-folder-with-selection)
    ("V" "Clear Selection" enhanced-dirvish-clear-all-marks)]
   ["Trash, Archives & Clipboard"
    ("DEL" "Move to Trash" enhanced-dirvish-move-to-trash)
    ("D" "Delete Permanently" enhanced-dirvish-delete-permanently)
    ("z" "Undo" enhanced-dirvish-undo)
    ("Z" "Redo" enhanced-dirvish-redo)
    ("c" "Compress Archive…" enhanced-dirvish-archive-compress)
    ("C-e" "Compress with Encryption…" enhanced-dirvish-archive-compress-encrypted)
    ("e" "Extract Here" enhanced-dirvish-archive-extract)
    ("v" "Save Clipboard Image/Text" enhanced-dirvish-paste-content-drop)
    ("Y" "Copy Path" enhanced-dirvish-copy-path)]
   ["Panes, Customize & Tools"
    ("s" "Split Extra Pane (F3)" enhanced-dirvish-toggle-extra-pane)
    (">" "Copy to Other Pane" enhanced-dirvish-copy-to-other-pane)
    ("<" "Move to Other Pane" enhanced-dirvish-move-to-other-pane)
    ("t" "Pane Terminal (C-`)" enhanced-dirvish-toggle-pane-terminal)
    ("C" "Customize Folder Color/Icon" enhanced-dirvish-customize-folder)
    ("i" "Properties (M-RET)" enhanced-dirvish-show-properties-for-path)
    ("a" "Run Custom Action…" enhanced-dirvish-run-custom-action)
    ("," "Settings & Diagnostics" enhanced-dirvish-open-settings)
    ("?" "Shortcut Reference (C-c ? / ~)" enhanced-dirvish-open-shortcut-reference)]])

;;;; Interactive Settings & 26-Point Diagnostics (`C-,`)

(defun enhanced-dirvish-open-settings ()
  "Open instant Enhanced Dirvish Settings & Diagnostics buffer (`C-,')."
  (interactive)
  (let ((buf (get-buffer-create "*Enhanced Dirvish Settings*"))
        (p (enhanced-dirvish-prefs)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (setq-local header-line-format
                    (concat "  "
                            (enhanced-dirvish-icon-glyph 'gear 'enhanced-dirvish-header-accent)
                            (propertize "  Enhanced Dirvish Settings & Diagnostics   [Click/RET on setting to toggle · g: Refresh · q: Close]"
                                        'face 'enhanced-dirvish-header-accent)))
        (cl-labels ((toggle-row (label desc getter setter)
                      (let* ((val (funcall getter p))
                             (btn (format "   %-34s  [%s]   %s\n"
                                          label
                                          (propertize (if val "ON " "OFF")
                                                      'face (if val 'enhanced-dirvish-bar-ok 'shadow))
                                          (propertize desc 'face 'enhanced-dirvish-hint-desc)))
                             (act (lambda ()
                                    (interactive)
                                    (funcall setter p (not val))
                                    (enhanced-dirvish-prefs-save)
                                    (enhanced-dirvish-open-settings)))
                             (km (make-sparse-keymap)))
                        (define-key km (kbd "RET") act)
                        (define-key km [mouse-1] act)
                        (insert (enhanced-dirvish-add-row-properties
                                 btn (list 'keymap km
                                           'mouse-face 'highlight
                                           'pointer 'hand)))))
                    (cycle-row (label val choices setter)
                      (let* ((btn (format "   %-34s  [%s]\n"
                                          label
                                          (propertize (format "%s" val) 'face 'enhanced-dirvish-header-accent)))
                             (act (lambda ()
                                    (interactive)
                                    (let* ((pos (or (cl-position val choices) 0))
                                           (next (nth (mod (1+ pos) (length choices)) choices)))
                                      (funcall setter p next)
                                      (enhanced-dirvish-prefs-save)
                                      (enhanced-dirvish-open-settings))))
                             (km (make-sparse-keymap)))
                        (define-key km (kbd "RET") act)
                        (define-key km [mouse-1] act)
                        (insert (enhanced-dirvish-add-row-properties
                                 btn (list 'keymap km
                                           'mouse-face 'highlight
                                           'pointer 'hand))))))
          (insert "\n" (propertize "  GENERAL & BROWSING\n" 'face 'enhanced-dirvish-section-heading))
          (cycle-row "Default View Mode" (enhanced-dirvish-prefs-browser-mode p) '(columns icons list compact)
                     (lambda (pr v) (setf (enhanced-dirvish-prefs-browser-mode pr) v)))
          (toggle-row "Expandable folders in List view" "Show disclosure chevrons in List"
                      #'enhanced-dirvish-prefs-expandable-tree
                      (lambda (pr v) (setf (enhanced-dirvish-prefs-expandable-tree pr) v)))
          (toggle-row "Remember folder views" "Save view/sort per folder (LRU 128)"
                      #'enhanced-dirvish-prefs-remember-folder-views
                      (lambda (pr v) (setf (enhanced-dirvish-prefs-remember-folder-views pr) v)))
          (toggle-row "Restore tabs on startup" "Persist workspace tabs across sessions"
                      #'enhanced-dirvish-prefs-restore-tabs
                      (lambda (pr v) (setf (enhanced-dirvish-prefs-restore-tabs pr) v)))
          (toggle-row "Folders first" "Keep folders sorted above files"
                      #'enhanced-dirvish-prefs-folders-first
                      (lambda (pr v) (setf (enhanced-dirvish-prefs-folders-first pr) v)))
          (toggle-row "Natural numeric sort" "Sort file2 before file10"
                      #'enhanced-dirvish-prefs-natural-sort
                      (lambda (pr v) (setf (enhanced-dirvish-prefs-natural-sort pr) v)))
          (toggle-row "Show hidden dot-files" "Include .dotfiles in listings"
                      #'enhanced-dirvish-prefs-show-hidden
                      (lambda (pr v) (setf (enhanced-dirvish-prefs-show-hidden pr) v)))

          (insert "\n" (propertize "  APPEARANCE & PREVIEWS\n" 'face 'enhanced-dirvish-section-heading))
          (toggle-row "Render Markdown & Docs by default" "Toggle raw source with [V]"
                      #'enhanced-dirvish-prefs-render-documents-by-default
                      (lambda (pr v) (setf (enhanced-dirvish-prefs-render-documents-by-default pr) v)))
          (toggle-row "Show full names in Compact view" "Disable ellipsis truncation in Compact"
                      #'enhanced-dirvish-prefs-compact-full-names
                      (lambda (pr v) (setf (enhanced-dirvish-prefs-compact-full-names pr) v)))
          (cycle-row "Unit system" (enhanced-dirvish-prefs-unit-system p) '(metric binary)
                     (lambda (pr v) (setf (enhanced-dirvish-prefs-unit-system pr) v)))
          (cycle-row "Date format" (enhanced-dirvish-prefs-date-format p) '(relative iso locale)
                     (lambda (pr v) (setf (enhanced-dirvish-prefs-date-format pr) v)))
          (toggle-row "Columns show file sizes" "Display file sizes in Miller columns"
                      #'enhanced-dirvish-prefs-columns-show-sizes
                      (lambda (pr v) (setf (enhanced-dirvish-prefs-columns-show-sizes pr) v)))
          (toggle-row "Show keybinding hints" "Show shortcut strip in footer"
                      #'enhanced-dirvish-prefs-show-keybinding-hints
                      (lambda (pr v) (setf (enhanced-dirvish-prefs-show-keybinding-hints pr) v)))

          (insert "\n" (propertize "  KEYBOARD & 10XER WORKFLOW\n" 'face 'enhanced-dirvish-section-heading))
          (toggle-row "10xer Mode (C-S-m)" "Yazi/Vim modal navigation & chords"
                      #'enhanced-dirvish-prefs-tenxer-mode
                      (lambda (_pr _v) (enhanced-dirvish-toggle-tenxer-mode)))
          (toggle-row "10xer d-d trash confirm" "Require second 'd' before trashing"
                      #'enhanced-dirvish-prefs-tenxer-delete-confirm
                      (lambda (pr v) (setf (enhanced-dirvish-prefs-tenxer-delete-confirm pr) v)))

          (insert "\n" (propertize "  CUSTOM ACTIONS & DIAGNOSTICS\n" 'face 'enhanced-dirvish-section-heading))
          (insert (format "   Loaded Custom Actions: %d  (Press [a] to run or [i] to install starter recipe)\n"
                          (length (enhanced-dirvish-actions-load))))
          (insert (format "   Browser Text Zoom:     %+d\n"
                          (enhanced-dirvish-prefs-browser-text-scale p)))
          (insert (format "   Preview Zoom Levels:   Text %+d · Image %.0f%% · PDF %.0f%%\n\n"
                          (enhanced-dirvish-prefs-preview-text-scale p)
                          (* 100 (enhanced-dirvish-prefs-preview-image-scale p))
                          (* 100 (enhanced-dirvish-prefs-preview-pdf-scale p))))
          (insert (propertize "  RUNTIME DIAGNOSTICS PROBE\n" 'face 'enhanced-dirvish-section-heading))
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
                                          'face (if found 'enhanced-dirvish-bar-ok 'enhanced-dirvish-bar-danger))
                              (propertize (cdr tool) 'face 'shadow)))))
          (local-set-key (kbd "g") #'enhanced-dirvish-open-settings)
          (local-set-key (kbd "i") #'enhanced-dirvish-install-action-recipe)
          (local-set-key (kbd "a") #'enhanced-dirvish-run-custom-action))
        (goto-char (point-min))))
    (pop-to-buffer buf)))

;;;; Searchable Shortcut Reference (`C-c ?' / `?' / `~')

(defun enhanced-dirvish-open-shortcut-reference ()
  "Open the Shortcut Reference (`C-c ?' / `?' / `~') for the active bindings."
  (interactive)
  (let ((buf (get-buffer-create "*Enhanced Dirvish Shortcuts*"))
        (tenx (enhanced-dirvish-prefs-tenxer-mode (enhanced-dirvish-prefs))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (setq-local header-line-format
                    (concat "  "
                            (enhanced-dirvish-icon-glyph 'keyboard 'enhanced-dirvish-header-accent)
                            (propertize (format "  Enhanced Dirvish Shortcut Reference (%s Mode)   [C-S-m: Switch Mode · f: Filter · q: Close]"
                                                (if tenx "10xer" "Default"))
                                        'face 'enhanced-dirvish-header-accent)))
        (insert "\n")
        (dolist (sec
                 `(("NAVIGATION"
                    (,(if tenx "h / l / ← / →" "← / →") "Parent folder / Open Folder, Expand Tree, or Enter Read-Only Preview")
                    (,(if tenx "j / k / ↑ / ↓" "↑ / ↓") "Move down / up; keep explicit marks")
                    (,(if tenx "H / L / M-← / M-→" "M-← / M-→") "Pane History Back / Forward")
                    ("M-↑ / M-↓" "Parent folder / Make First Column")
                    ("RET / Double-Click" "Open Folder / Direct-Edit File in Preview Pane")
                    (,(if enhanced-dirvish-file-manager-keys "C-← / C-c C-c or C-c q / C-c C-k or C-c k" "C-← / C-c C-c / C-c C-k")
                     "Leave Preview or Edit (Save Prompt) / Exit Left / Abort Edits")
                    (,(if tenx "SPC / i / M-i" "SPC / M-i") "Preview File (Keep Focus) / Toggle Peek Drawer")
                    ("C-RET / S-RET" "Open in New Tab / New Frame")
                    ("C-l / g SPC" "Edit Location (~/, computer:///, trash:///, recent:///, sftp://, admin:///)")
                    (,(if tenx "z / Z / C-S-k" "C-S-k") "Jump to Visited Folder (10xer Z: Recent File)"))
                   ("SELECTION (DIRECTORY VIEWS)"
                    ("Click file" "Select one file and preview; replaces old marks (folder click opens)")
                    ("Click empty space" "Clear selection without selecting the last file")
                    ("C-SPC / C-Click" "Toggle current / clicked item; repeat to deselect")
                    ("C-Arrows" "Move focus one entry, row or column; keep marked files")
                    ("C-SPC, C-Arrow, C-SPC" "Mark one file, move focus, then add another file")
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
                    ("Drag unmarked / empty space" "Select a live range; reverse drag to shrink")
                    ("Icons / Compact drag" "Select a rectangle across rows and columns")
                    ("C-Drag / S-Drag" "Add a range to existing marks within the same pane")
                    ("Drop onto folder / pane" "Transfer files into that folder; choose Copy / Move / Cancel")
                    ("Dragging marked files" "A badge follows the pointer with filenames, count and destination")
                    ("C-Drag / S-Drag onto folder" "Copy / Move into a folder or pane (Ctrl wins with both modifiers)")
                    ("ESC / C-g / Right-Click" "During drag: cancel and restore the previous selection")
                    ("Right-Click item" "Keep a marked batch; an unmarked item becomes the menu target")
                    ("Right-Click menu" "GUI actions beside the pointer; Shift-F10 / Menu opens keyboard actions")
                    ("Right-Click archives" "Extract Here / Extract to Folder; multiple roots get a wrapping folder")
                    ("Right-Click → Compress…" "Create an archive; Compress with Encryption uses AES and a confirmed password")
                    ("Mouse Back / Forward" "Navigate the folder history of the pane under the pointer")
                    ("Mouse file actions" "Follow-up choices, names, passwords and confirmations use GUI dialogs")
                    ("Keyboard file actions" "Keep text prompts, completion and the keyboard actions menu")
                    ("Double-Click / Middle" "Open folder or edit file"))
                   ("VIEWS, SORT & ZOOM"
                    ("Menu bar → Enhanced Dirvish" "All file-manager commands; irrelevant actions are greyed out")
                    ("C-1 / C-2 / C-3 / C-4" "Columns / Icons Grid / List (Tree) / Compact View")
                    ("Click View…" "Choose a layout from the header menu; the current view is checked")
                    (,(if enhanced-dirvish-file-manager-keys "C-c s / Click Sort By…" "Click Sort By…")
                     "Sort menu in every directory layout; also S-F10 then S")
                    ("Sort By… options" "Name / Modification date / Size / Type or extension / Unsorted")
                    ("Sort order" "Ascending / Descending; Folders first; Natural names (file2 before file10)")
                    ("TAB" "Expand / Collapse folder subtree (List/Tree view)")
                    (,(if tenx "C-. / ." "C-.") "Toggle Hidden Dot-files")
                    (,(if tenx "M-v / W / M-w" "M-v / M-w") "Toggle Rendered Document Mode / Preview Line Wrap")
                    ("C-+ / C-- / C-0" "Independent Preview Zoom (Text / Image / PDF)")
                    ("C-Wheel / C-x C-+/−/0" "Persistent Browser View Text Zoom across folders & layouts")
                    ("C-M-+ / C-M-- / C-M-0" "Icons Grid Thumbnail Size")
                    ("10xer: J / K" "Scroll Preview Window Down / Up"))
                   ("PANES, TERMINAL & TABS"
                    (,(if enhanced-dirvish-file-manager-keys "F3 / F6" "F3 / C-x o") "Toggle Extra Split Pane / Switch Active Pane")
                    ("C-x 3 / C-x 2" "Split an Emacs window beside / below the whole browser")
                    ("C-x o / C-x 0 / C-x 1" "Other window / Close window group / Keep window group")
                    ("M-x transpose-frame" "Transpose browser, editor and terminal groups")
                    ("C-S-c / C-S-x" "Copy / Move selection to Other Pane (or Drag across panes)")
                    (,(if enhanced-dirvish-file-manager-keys "C-` / F9 / C-M-t" "C-` / C-M-t") "Toggle Pane Embedded Terminal / External Terminal")
                    (,(if tenx "C-n / C-S-b" "C-b / C-S-b") "Toggle / Focus Left Sidebar (c inside Sidebar: Rail mode)")
                    ("C-t / C-w / C-S-t" "New Tab / Close Tab / Reopen Closed Tab")
                    ("C-TAB / C-S-TAB" "Next / Previous Tab"))
                   ("FILES, SEARCH & ACTIONS"
                    (,(if tenx "C-k / f / s" "C-k / C-f") "Global Recursive Search / Filter Folder (10xer s: Include Subfolders)")
                    ("10xer: / / M-? / n / N" "Incremental Find / Backward Find / Repeat Forward / Backward")
                    ("y / x / p / P" ,(concat "Copy / Cut / Paste Keep Both / Paste Replace (10xer; Default: "
                                              (if enhanced-dirvish-file-manager-keys "C-c c/x/v" "context menu") ")"))
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
          (insert (propertize (format "  %s\n" (car sec)) 'face 'enhanced-dirvish-section-heading))
          (dolist (row (cdr sec))
            (insert (format "   %-22s  %s\n"
                            (propertize (car row) 'face 'enhanced-dirvish-hint-key)
                            (cadr row))))
          (insert "\n"))
        (local-set-key (kbd "f") (lambda () (interactive) (call-interactively #'occur)))
        (local-set-key (kbd "C-S-m")
                       (lambda () (interactive)
                         (enhanced-dirvish-toggle-tenxer-mode)
                         (enhanced-dirvish-open-shortcut-reference)))
        (goto-char (point-min))))
    (pop-to-buffer buf)))

;;;; Dual Minor Mode Keymaps (Default Desktop vs 10xer Modal)

(defvar enhanced-dirvish-default-keymap
  (let ((map (make-sparse-keymap)))
    ;; Navigation & Views
    (define-key map (kbd "<left>") #'enhanced-dirvish-tree-collapse-or-up)
    (define-key map (kbd "<right>") #'enhanced-dirvish-tree-expand-or-open)
    (define-key map (kbd "TAB") #'dirvish-toggle-subtree)
    (define-key map (kbd "M-<left>") #'enhanced-dirvish-history-back)
    (define-key map (kbd "M-<right>") #'enhanced-dirvish-history-forward)
    (define-key map (kbd "M-<up>") #'dired-up-directory)
    (define-key map (kbd "M-<down>") #'enhanced-dirvish-make-first-column)
    (define-key map (kbd "M-<home>") (lambda () (interactive) (enhanced-dirvish-open-location "~/" t)))
    (define-key map (kbd "SPC") #'enhanced-dirvish-preview-at-point)
    (define-key map (kbd "RET") #'enhanced-dirvish-open-or-edit-at-point)
    (define-key map (kbd "M-i") #'enhanced-dirvish-toggle-peek)
    (define-key map (kbd "C-<return>") #'enhanced-dirvish-open-in-new-tab)
    (define-key map (kbd "S-<return>") #'enhanced-dirvish-open-in-new-frame)

    ;; Views & Zoom
    (define-key map (kbd "C-1") #'enhanced-dirvish-view-columns)
    (define-key map (kbd "C-2") #'enhanced-dirvish-view-icons)
    (define-key map (kbd "C-3") #'enhanced-dirvish-view-list)
    (define-key map (kbd "C-4") #'enhanced-dirvish-view-compact)
    (define-key map (kbd "C-=") #'enhanced-dirvish-preview-zoom-in)
    (define-key map (kbd "C-+") #'enhanced-dirvish-preview-zoom-in)
    (define-key map (kbd "C--") #'enhanced-dirvish-preview-zoom-out)
    (define-key map (kbd "C-0") #'enhanced-dirvish-preview-zoom-reset)
    (define-key map (kbd "C-M-=") (lambda () (interactive) (enhanced-dirvish-thumbnails-scale 16)))
    (define-key map (kbd "C-M--") (lambda () (interactive) (enhanced-dirvish-thumbnails-scale -16)))
    (define-key map (kbd "C-M-0") (lambda () (interactive) (enhanced-dirvish-thumbnails-scale 0)))
    (define-key map (kbd "M-<next>") (lambda () (interactive) (enhanced-dirvish-pdf-page-step 1)))
    (define-key map (kbd "M-<prior>") (lambda () (interactive) (enhanced-dirvish-pdf-page-step -1)))
    (define-key map (kbd "C-.") #'enhanced-dirvish-toggle-hidden-files)

    ;; Split Pane / Terminal / Sidebar / Tabs
    (define-key map (kbd "<f3>") #'enhanced-dirvish-toggle-extra-pane)
    (define-key map (kbd "C-`") #'enhanced-dirvish-toggle-pane-terminal)
    (define-key map (kbd "C-S-c") #'enhanced-dirvish-copy-to-other-pane)
    (define-key map (kbd "C-S-x") #'enhanced-dirvish-move-to-other-pane)
    (define-key map (kbd "C-M-t") #'enhanced-dirvish-open-external-terminal)
    (define-key map (kbd "C-b") #'enhanced-dirvish-sidebar-toggle)
    (define-key map (kbd "C-S-b") #'enhanced-dirvish-sidebar-focus)
    (define-key map (kbd "C-t") #'enhanced-dirvish-tab-new)
    (define-key map (kbd "C-w") #'enhanced-dirvish-tab-close)
    (define-key map (kbd "C-S-t") #'enhanced-dirvish-tab-reopen-closed)
    (define-key map (kbd "C-a") #'enhanced-dirvish-select-all)
    (define-key map (kbd "C-S-a") #'enhanced-dirvish-clear-all-marks)
    (define-key map (kbd "C-S-i") #'enhanced-dirvish-invert-selection)
    (define-key map (kbd "C-SPC") #'enhanced-dirvish-view-toggle-mark)
    (define-key map (kbd "C-@") #'enhanced-dirvish-view-toggle-mark)
    (define-key map (kbd "m") #'enhanced-dirvish-view-toggle-mark)
    (define-key map (kbd "u") #'enhanced-dirvish-view-unmark)
    (define-key map (kbd "U") #'enhanced-dirvish-clear-all-marks)
    (define-key map (kbd "M-v") #'enhanced-dirvish-toggle-rendered-document)
    (define-key map (kbd "M-w") #'enhanced-dirvish-toggle-preview-wrap)
    (define-key map (kbd "C-<tab>") #'enhanced-dirvish-tab-next)
    (define-key map (kbd "C-<next>") #'enhanced-dirvish-tab-next)
    (define-key map (kbd "C-S-<tab>") #'enhanced-dirvish-tab-previous)
    (define-key map (kbd "C-<prior>") #'enhanced-dirvish-tab-previous)
    (define-key map (kbd "C-S-<prior>") (lambda () (interactive) (enhanced-dirvish-tab-move -1)))
    (define-key map (kbd "C-S-<next>") (lambda () (interactive) (enhanced-dirvish-tab-move 1)))

    ;; File Operations, Search & Mouse Click Navigation
    (define-key map (kbd "C-S-v") #'enhanced-dirvish-paste-content-drop)
    (define-key map (kbd "C-d") #'enhanced-dirvish-duplicate)
    (define-key map (kbd "C-S-n") #'enhanced-dirvish-new-folder)
    (define-key map (kbd "C-M-n") #'enhanced-dirvish-new-folder-with-selection)
    (define-key map (kbd "<f2>") #'enhanced-dirvish-rename)
    (define-key map (kbd "C-r") #'enhanced-dirvish-rename)
    (define-key map (kbd "<delete>") #'enhanced-dirvish-move-to-trash)
    (define-key map (kbd "S-<delete>") #'enhanced-dirvish-delete-permanently)
    (define-key map (kbd "C-z") #'enhanced-dirvish-undo)
    (define-key map (kbd "C-S-z") #'enhanced-dirvish-redo)
    (define-key map (kbd "M-RET") #'enhanced-dirvish-show-properties-for-path)
    (define-key map (kbd "<menu>") #'enhanced-dirvish-context-menu)
    (define-key map (kbd "S-<f10>") #'enhanced-dirvish-context-menu)
    (define-key map (kbd "S-<down>") #'enhanced-dirvish-shift-select-next)
    (define-key map (kbd "C-<down>") #'enhanced-dirvish-view--focus-down)
    (define-key map (kbd "C-<up>") #'enhanced-dirvish-view--focus-up)
    (define-key map (kbd "C-<right>") #'enhanced-dirvish-view--focus-right)
    (define-key map (kbd "C-<left>") #'enhanced-dirvish-view--focus-left)
    (define-key map (kbd "S-<up>") #'enhanced-dirvish-shift-select-prev)
    (define-key map (kbd "S-<right>") #'enhanced-dirvish-shift-select-right)
    (define-key map (kbd "S-<left>") #'enhanced-dirvish-shift-select-left)
    (define-key map (kbd "C-S-<down>") #'enhanced-dirvish-shift-select-next)
    (define-key map (kbd "C-S-<up>") #'enhanced-dirvish-shift-select-prev)
    (define-key map (kbd "C-S-<right>") #'enhanced-dirvish-shift-select-right)
    (define-key map (kbd "C-S-<left>") #'enhanced-dirvish-shift-select-left)
    (define-key map (kbd "S-<home>") #'enhanced-dirvish-shift-select-first)
    (define-key map (kbd "S-<end>") #'enhanced-dirvish-shift-select-last)
    (define-key map (kbd "C-S-<home>") #'enhanced-dirvish-shift-select-first)
    (define-key map (kbd "C-S-<end>") #'enhanced-dirvish-shift-select-last)
    (enhanced-dirvish-mouse-install-keymap-bindings map)
    (define-key map (kbd "C-k") #'enhanced-dirvish-global-search)
    (define-key map (kbd "C-S-k") #'enhanced-dirvish-jump-visited-folder)
    (define-key map (kbd "C-f") #'enhanced-dirvish-filter-pane)
    (define-key map (kbd "C-l") #'enhanced-dirvish-location-prompt)

    ;; Media Playback Controls
    (define-key map (kbd "C-M-SPC") #'enhanced-dirvish-media-play-pause)
    (define-key map (kbd "C-M-<left>") (lambda () (interactive) (enhanced-dirvish-media-seek -5)))
    (define-key map (kbd "C-M-<right>") (lambda () (interactive) (enhanced-dirvish-media-seek 5)))
    (define-key map (kbd "C-M-<up>") (lambda () (interactive) (enhanced-dirvish-media-volume-step 5)))
    (define-key map (kbd "C-M-<down>") (lambda () (interactive) (enhanced-dirvish-media-volume-step -5)))
    (define-key map (kbd "C-M-m") #'enhanced-dirvish-media-mute-toggle)

    ;; Mode / Settings / Help
    (define-key map (kbd "<escape>") #'enhanced-dirvish-escape)
    (define-key map (kbd "C-,") #'enhanced-dirvish-open-settings)
    (define-key map (kbd "C-c ?") #'enhanced-dirvish-open-shortcut-reference)
    (define-key map (kbd "?") #'enhanced-dirvish-open-shortcut-reference)
    (define-key map (kbd "C-S-m") #'enhanced-dirvish-toggle-tenxer-mode)
    map)
  "Enhanced Dirvish Default Desktop keymap for `enhanced-dirvish-mode'.")

(defvar enhanced-dirvish-10xer-keymap
  (let ((map (make-sparse-keymap)))
    ;; Navigation
    (define-key map (kbd "j") #'enhanced-dirvish-nav-next-line)
    (define-key map (kbd "k") #'enhanced-dirvish-nav-prev-line)
    (define-key map (kbd "h") #'enhanced-dirvish-tree-collapse-or-up)
    (define-key map (kbd "l") #'enhanced-dirvish-tree-expand-or-open)
    (define-key map (kbd "o") #'enhanced-dirvish-tree-expand-or-open)
    (define-key map (kbd "O") #'enhanced-dirvish-open-with)
    (define-key map (kbd "G") #'end-of-buffer)
    (define-key map (kbd "C-u") #'enhanced-dirvish-half-page-up)
    (define-key map (kbd "C-d") #'enhanced-dirvish-half-page-down)
    (define-key map (kbd "C-b") #'scroll-down-command)
    (define-key map (kbd "C-f") #'scroll-up-command)
    (define-key map (kbd "C-n") #'enhanced-dirvish-sidebar-toggle)
    (define-key map (kbd "H") #'enhanced-dirvish-history-back)
    (define-key map (kbd "L") #'enhanced-dirvish-history-forward)
    (define-key map (kbd "i") #'enhanced-dirvish-toggle-peek)
    (define-key map (kbd "J") #'enhanced-dirvish-scroll-preview-down)
    (define-key map (kbd "K") #'enhanced-dirvish-scroll-preview-up)
    (define-key map (kbd "C-r") #'enhanced-dirvish-invert-selection)
    (define-key map (kbd "W") #'enhanced-dirvish-toggle-preview-wrap)

    ;; Selection & File Verbs
    (define-key map (kbd "v") #'enhanced-dirvish-visual-toggle)
    (define-key map (kbd "V") #'enhanced-dirvish-clear-all-marks)
    (define-key map (kbd "y") #'enhanced-dirvish-copy-selection)
    (define-key map (kbd "x") #'enhanced-dirvish-cut-selection)
    (define-key map (kbd "Y") #'enhanced-dirvish-unyank)
    (define-key map (kbd "X") #'enhanced-dirvish-unyank)
    (define-key map (kbd "p") #'enhanced-dirvish-paste-keep-both)
    (define-key map (kbd "P") #'enhanced-dirvish-paste-replace)
    (define-key map (kbd "a") #'enhanced-dirvish-create-entry)
    (define-key map (kbd "r") #'enhanced-dirvish-rename)
    (define-key map (kbd "d") #'enhanced-dirvish-chord-trash-or-d)
    (define-key map (kbd "D") #'enhanced-dirvish-delete-permanently)
    (define-key map (kbd "C") #'enhanced-dirvish-copy-to)
    (define-key map (kbd "M") #'enhanced-dirvish-move-to)
    (define-key map (kbd "R") #'enhanced-dirvish-trash-restore-at-point)
    (define-key map (kbd ".") #'enhanced-dirvish-toggle-hidden-files)

    ;; Search / Jump / Bookmarks
    (define-key map (kbd "/") #'enhanced-dirvish-find-in-folder)
    (define-key map (kbd "?") #'enhanced-dirvish-open-shortcut-reference)
    (define-key map (kbd "M-?") (lambda () (interactive) (enhanced-dirvish-find-in-folder t)))
    (define-key map (kbd "n") #'enhanced-dirvish-find-repeat)
    (define-key map (kbd "N") (lambda () (interactive) (enhanced-dirvish-find-repeat t)))
    (define-key map (kbd "f") #'enhanced-dirvish-filter-pane)
    (define-key map (kbd "s") (lambda () (interactive) (enhanced-dirvish-filter-pane t)))
    (define-key map (kbd "z") #'enhanced-dirvish-jump-visited-folder)
    (define-key map (kbd "Z") #'enhanced-dirvish-jump-recent-file)
    (define-key map (kbd "m") #'enhanced-dirvish-letter-bookmark-set)
    (define-key map (kbd "'") #'enhanced-dirvish-letter-bookmark-go)

    ;; Thumbnail Quick Steps
    (define-key map (kbd "+") (lambda () (interactive) (if (derived-mode-p 'enhanced-dirvish-icons-mode) (enhanced-dirvish-thumbnails-scale 16) (enhanced-dirvish-preview-zoom-in))))
    (define-key map (kbd "=") (lambda () (interactive) (if (derived-mode-p 'enhanced-dirvish-icons-mode) (enhanced-dirvish-thumbnails-scale 16) (enhanced-dirvish-preview-zoom-in))))
    (define-key map (kbd "-") (lambda () (interactive) (if (derived-mode-p 'enhanced-dirvish-icons-mode) (enhanced-dirvish-thumbnails-scale -16) (enhanced-dirvish-preview-zoom-out))))

    ;; Multi-Key Chords, Mouse Navigation & Reference
    (define-key map (kbd "g") #'enhanced-dirvish-chord-go)
    (define-key map (kbd ",") #'enhanced-dirvish-chord-sort)
    (define-key map (kbd "c") #'enhanced-dirvish-chord-copy-as)
    (define-key map (kbd ";") #'enhanced-dirvish-chord-actions)
    (define-key map (kbd "t") #'enhanced-dirvish-chord-tabs)
    (define-key map (kbd "~") #'enhanced-dirvish-open-shortcut-reference)
    (enhanced-dirvish-mouse-install-keymap-bindings map)
    map)
  "Enhanced Dirvish 10xer overlay keymap for `enhanced-dirvish-tenxer-mode'.")

(define-minor-mode enhanced-dirvish-tenxer-mode
  "10xer modal overlay above `enhanced-dirvish-mode' while `tenxer-mode' is t."
  :lighter " 10X"
  :keymap enhanced-dirvish-10xer-keymap
  ;; The base minor mode can appear before this mode in Emacs's map order.
  ;; Compose its buffer-local map explicitly so every 10xer override wins,
  ;; including C-r/C-d/C-f, on first load and on live reload alike.
  (setq-local minor-mode-overriding-map-alist
              (assq-delete-all 'enhanced-dirvish-mode
                               minor-mode-overriding-map-alist))
  (when enhanced-dirvish-tenxer-mode
    (push (cons 'enhanced-dirvish-mode
                (make-composed-keymap enhanced-dirvish-10xer-keymap enhanced-dirvish-default-keymap))
          minor-mode-overriding-map-alist)))

(define-minor-mode enhanced-dirvish-mode
  "Buffer-local minor mode exposing all features inside Dirvish & view buffers."
  :lighter " Enhanced Dirvish"
  :keymap enhanced-dirvish-default-keymap
  (if enhanced-dirvish-mode
      (progn
        (add-hook 'post-command-hook #'enhanced-dirvish-view--selection-post-command nil t)
        ;; Extra panes may use ordinary Dired without Dirvish's header composer.
        (when (and (derived-mode-p 'dired-mode) (null header-line-format)
                   (not (when-let ((dv (dirvish-curr))) (dv-curr-layout dv))))
          (setq-local header-line-format '(:eval (enhanced-dirvish-view-header-line))))
        (enhanced-dirvish--apply-active-keymap))
    (remove-hook 'post-command-hook #'enhanced-dirvish-view--selection-post-command t)
    (enhanced-dirvish-tenxer-mode -1)))

(defun enhanced-dirvish--apply-active-keymap ()
  "Enable or disable `enhanced-dirvish-tenxer-mode' honoring terminal focus guard."
  (if (and (not (enhanced-dirvish-terminal-focused-p))
           (enhanced-dirvish-prefs-tenxer-mode (enhanced-dirvish-prefs)))
      (enhanced-dirvish-tenxer-mode 1)
    (enhanced-dirvish-tenxer-mode -1)))

(provide 'enhanced-dirvish-keys)
;;; enhanced-dirvish-keys.el ends here
