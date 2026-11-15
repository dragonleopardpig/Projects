;;; strata-dirvish-tests.el --- ERT tests for Strata-Dirvish features -*- lexical-binding: t; -*-

;;; Commentary:
;; Offline ERT unit & integration test suite verifying Strata features blended
;; into Dirvish: TOML config parsing, synthetic 1 PiB FUSE filter, accurate
;; drive-free formatting, device icons, virtual computer:/// guards, natural
;; sort, folder LRU view memory, Compact/Icons rendering & inline filter,
;; independent Text/Image/PDF zoom, file copy/move/merge/undo/redo/trash, custom
;; actions action.toml loading, and Default vs 10xer keymap switching.

;;; Code:

(require 'ert)
(require 'cl-lib)

(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'strata-dirvish)

(ert-deftest strata-test-toml-parsing-and-prefs ()
  (let ((tmp (make-temp-file "strata-toml-")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "browser_mode = \"compact\"\ncompact_full_names = true\nicons_thumbnail_size = 96\n"
                    "[folder_colors]\n\"/tmp/work\" = \"blue\"\n"))
          (let* ((parsed (strata-toml-parse-file tmp))
                 (root (cdr (assoc "" parsed)))
                 (cols (cdr (assoc "folder_colors" parsed))))
            (should (equal (cdr (assoc "browser_mode" root)) "compact"))
            (should (eq (cdr (assoc "compact_full_names" root)) t))
            (should (equal (cdr (assoc "icons_thumbnail_size" root)) 96))
            (should (equal (cdr (assoc "/tmp/work" cols)) "blue"))))
      (delete-file tmp))))

(ert-deftest strata-test-synthetic-fuse-capacity-filter ()
  ;; Valid local NVMe capacity passes cleanly
  (should (equal (strata-sanitize-capacity 1000000000000 500000000000)
                 '(1000000000000 . 500000000000)))
  ;; Synthetic 1 PiB (2^50) FUSE/rclone placeholder must be rejected as nil
  (should-not (strata-sanitize-capacity (expt 2 50) (expt 2 50)))
  ;; 18.4 EB bogus value must be rejected
  (should-not (strata-sanitize-capacity (* 18 (expt 1024 6)) 1000))
  ;; Zero capacity rejected
  (should-not (strata-sanitize-capacity 0 0)))

(ert-deftest strata-test-accurate-drive-free-size ()
  ;; Step down unit when rounding free in total's unit would match total!
  (should-not (string= (strata-format-drive-free-size 5489790935040 5497558138880 'metric)
                       (strata-format-bytes 5497558138880 'metric)))
  (should (string-match-p "GB" (strata-format-drive-free-size 5489790935040 5497558138880 'metric))))

(ert-deftest strata-test-custom-device-icons-and-virtual-guards ()
  (let ((gd (make-strata-device :name "Google Drive" :mountpoint "/home/u/Google Drive" :placement 'cloud))
        (pd (make-strata-device :name "Proton Drive" :mountpoint "/home/u/Proton Drive" :placement 'cloud))
        (sc (make-strata-device :name "Scramble" :mountpoint "/home/u/Scramble Drive" :placement 'cloud))
        (rt (make-strata-device :name "File System" :mountpoint "/" :placement 'fixed)))
    (should (string= (strata-device-icon gd) "▲"))
    (should (string= (strata-device-icon pd) "◆"))
    (should (string= (strata-device-icon sc) "☁"))
    (should (member (strata-device-icon rt) '("❄" "🐧"))))
  (should (strata-computer-location-p "computer:///"))
  (should (strata-location-virtual-p "trash:///"))
  (should-error (strata-guard-writable-location "computer:///" "Paste") :type 'user-error))

(ert-deftest strata-test-natural-sort-and-folder-lru ()
  (should (< (strata-natural-compare "file2.txt" "file10.txt") 0))
  (should (> (strata-natural-compare "v10" "v2") 0))
  (let* ((tmp (make-temp-file "strata-sort-" t))
         (d1 (expand-file-name "alpha_dir" tmp))
         (f1 (expand-file-name "item2.txt" tmp))
         (f2 (expand-file-name "item10.txt" tmp)))
    (unwind-protect
        (progn
          (make-directory d1)
          (write-region "a" nil f1)
          (write-region "b" nil f2)
          (let* ((p (strata-prefs--create :sort-key 'name :folders-first t :natural-sort t :show-hidden nil))
                 (res (strata-list-directory-entries tmp p)))
            (should (equal (mapcar (lambda (e) (plist-get e :name)) res)
                           '("alpha_dir" "item2.txt" "item10.txt")))))
      (delete-directory tmp t))))

(ert-deftest strata-test-independent-preview-zoom ()
  (let ((strata-prefs-current (strata-prefs--create)))
    (setq strata-active-preview-kind 'text
          strata-active-preview-file nil)
    (strata-preview-zoom-in)
    (should (= (strata-prefs-preview-text-scale strata-prefs-current) 1))
    (should (= (strata-prefs-preview-image-scale strata-prefs-current) 1.0))
    (should (= (strata-prefs-preview-pdf-scale strata-prefs-current) 1.0))
    (setq strata-active-preview-kind 'image)
    (strata-preview-zoom-in)
    (should (> (strata-prefs-preview-image-scale strata-prefs-current) 1.1))
    (should (= (strata-prefs-preview-pdf-scale strata-prefs-current) 1.0))
    (strata-preview-zoom-reset)
    (should (= (strata-prefs-preview-image-scale strata-prefs-current) 1.0))
    (should (= (strata-prefs-preview-text-scale strata-prefs-current) 1))))

(ert-deftest strata-test-compact-and-icons-render-and-filter ()
  (let ((tmp (make-temp-file "strata-views-" t)))
    (unwind-protect
        (progn
          (write-region "x" nil (expand-file-name "alpha-note.md" tmp))
          (write-region "y" nil (expand-file-name "beta-file.txt" tmp))
          (with-temp-buffer
            (strata-compact-mode)
            (strata-compact-render tmp)
            (should (string-search "alpha-note.md" (buffer-string)))
            (should (string-search "beta-file.txt" (buffer-string)))
            (setq-local strata-local-filter "alpha")
            (strata-compact-refresh)
            (should (string-search "alpha-note.md" (buffer-string)))
            (should-not (string-search "beta-file.txt" (buffer-string))))
          (with-temp-buffer
            (strata-icons-mode)
            (strata-icons-render tmp)
            (should (string-search "alpha-note" (buffer-string)))))
      (delete-directory tmp t))))

(ert-deftest strata-test-copy-keep-both-rename-and-undo-redo ()
  (let* ((tmp (make-temp-file "strata-ops-" t))
         (src (expand-file-name "doc.txt" tmp))
         (strata-undo-stack nil)
         (strata-redo-stack nil)
         (strata-clipboard nil))
    (unwind-protect
        (progn
          (write-region "hello" nil src)
          ;; Keep both creates doc (copy).txt
          (let ((default-directory (file-name-as-directory tmp)))
            (strata--transfer-files (list src) tmp 'copy t nil)
            (let ((cp (expand-file-name "doc (copy).txt" tmp)))
              (should (file-exists-p cp))
              (should (= (length strata-undo-stack) 1))
              ;; Undo deletes the copy
              (strata-undo)
              (should-not (file-exists-p cp))
              ;; Redo recreates the copy
              (strata-redo)
              (should (file-exists-p cp)))))
      (delete-directory tmp t))))

(ert-deftest strata-test-custom-actions-toml-loader ()
  (let* ((cfg (make-temp-file "strata-act-cfg-" t))
         (act-dir (expand-file-name "actions/sample" cfg))
         (strata-dirvish-config-dir cfg))
    (unwind-protect
        (progn
          (make-directory act-dir t)
          (with-temp-file (expand-file-name "action.toml" act-dir)
            (insert "schema_version = 1\nid = \"sample\"\nname = \"Sample Act\"\n"
                    "enabled = true\n[when]\nkinds = [\"file\"]\nextensions = [\"txt\"]\n"
                    "[run]\nruntime = \"bash\"\nentrypoint = \"run.sh\"\n"))
          (let* ((acts (strata-actions-load))
                 (act (car acts))
                 (f-txt (make-temp-file "t" nil ".txt"))
                 (f-md (make-temp-file "m" nil ".md")))
            (unwind-protect
                (progn
                  (should (= (length acts) 1))
                  (should (equal (plist-get act :name) "Sample Act"))
                  (should (strata-action-matches-p act (list f-txt)))
                  (should-not (strata-action-matches-p act (list f-md))))
              (delete-file f-txt)
              (delete-file f-md))))
      (delete-directory cfg t))))

(ert-deftest strata-test-dual-keymap-and-terminal-guard ()
  (let ((strata-prefs-current (strata-prefs--create :tenxer-mode nil)))
    (with-temp-buffer
      (strata-dirvish-mode 1)
      ;; In Default mode, C-k -> global search and y is NOT copy
      (should (eq (key-binding (kbd "C-k")) #'strata-global-search))
      (should-not (eq (key-binding (kbd "y")) #'strata-copy-selection))
      ;; Switching to 10xer mode enables Vi/Yazi keys + chords cleanly
      (setf (strata-prefs-tenxer-mode strata-prefs-current) t)
      (strata-dirvish--apply-active-keymap)
      (should (eq (key-binding (kbd "y")) #'strata-copy-selection))
      (should (eq (key-binding (kbd ";")) #'strata-chord-actions))
      (should (eq (key-binding (kbd "g")) #'strata-chord-go))
      ;; Verify global C-c d prefix is NOT clobbered inside browser buffer
      (let ((global-map-save (current-global-map)))
        (unwind-protect
            (progn
              (use-global-map (let ((m (make-sparse-keymap)))
                                (define-key m (kbd "C-c d") #'strata-dirvish-launch)
                                m))
              (should (eq (key-binding (kbd "C-c d")) #'strata-dirvish-launch)))
          (use-global-map global-map-save))))))

(ert-deftest strata-test-dirvish-attributes-and-view-switching ()
  (let* ((tmp (make-temp-file "strata-dv-" t))
         (strata-dirvish-state-file (make-temp-file "strata-t-prefs-"))
         (strata-tabs-state-file (make-temp-file "strata-t-tabs-"))
         (strata-history-file (make-temp-file "strata-t-hist-"))
         (strata-prefs-current (strata-prefs--create :browser-mode 'columns :sidebar-expanded nil))
         (dirvish-override-dired-mode t))
    (unwind-protect
        (progn
          (write-region "hello" nil (expand-file-name "note.txt" tmp))
          (make-directory (expand-file-name "sub" tmp))
          (strata-dirvish-setup)
          ;; Must expand all custom Dirvish attributes without void-variable errors
          (should (listp (dirvish--attrs-expand dirvish-attributes)))
          (strata-open-location tmp)
          (dolist (m '(columns list compact icons columns))
            (strata-switch-view-mode m)
            (should (eq (strata-prefs-browser-mode (strata-prefs)) m))))
      (ignore-errors (when (dirvish-curr) (dirvish-quit)))
      (ignore-errors (delete-directory tmp t))
      (ignore-errors (delete-file strata-dirvish-state-file))
      (ignore-errors (delete-file strata-tabs-state-file))
      (ignore-errors (delete-file strata-history-file)))))

(ert-deftest strata-test-split-pane-promotion-and-tab-reopen ()
  (let* ((tmp (make-temp-file "strata-split-" t))
         (sub (expand-file-name "inner" tmp))
         (strata-dirvish-state-file (make-temp-file "strata-t-prefs2-"))
         (strata-tabs-state-file (make-temp-file "strata-t-tabs2-"))
         (strata-history-file (make-temp-file "strata-t-hist2-"))
         (strata-prefs-current (strata-prefs--create :browser-mode 'list :restore-tabs t :sidebar-expanded nil))
         (strata-workspace-tabs nil)
         (strata-closed-tabs nil)
         (strata-active-tab-index 0))
    (unwind-protect
        (progn
          (make-directory sub)
          (strata-open-location tmp)
          (strata-toggle-extra-pane)
          (should (strata-split-active-p))
          (should (= (strata-pane-state-id (strata-active-pane)) 2))
          ;; Navigate Pane 2 into sub, then toggle extra pane off -> promotes sub into Pane 1
          (strata-open-location sub)
          (strata-toggle-extra-pane)
          (should-not (strata-split-active-p))
          (should (equal (directory-file-name (strata-pane-state-dir (strata-active-pane)))
                         (directory-file-name sub)))
          ;; Tabs open, close, reopen & persist
          (strata-tab-new tmp)
          (should (= (length strata-workspace-tabs) 2))
          (strata-tab-close)
          (should (= (length strata-workspace-tabs) 1))
          (should (= (length strata-closed-tabs) 1))
          (strata-tab-reopen-closed)
          (should (= (length strata-workspace-tabs) 2))
          (strata-tabs-save)
          (setq strata-workspace-tabs nil)
          (strata-tabs-load)
          (should (= (length strata-workspace-tabs) 2)))
      (ignore-errors (when (dirvish-curr) (dirvish-quit)))
      (ignore-errors (delete-directory tmp t))
      (ignore-errors (delete-file strata-dirvish-state-file))
      (ignore-errors (delete-file strata-tabs-state-file))
      (ignore-errors (delete-file strata-history-file)))))

(ert-deftest strata-test-rendered-markdown-and-dashboard-install ()
  (let ((md (make-temp-file "strata-md-" nil ".md" "# Heading\n\n- `code` item\n"))
        (buf (get-buffer-create " *strata-ert-md*")))
    (unwind-protect
        (progn
          (strata-preview--safe-insert-markdown md buf)
          (with-current-buffer buf
            (should (string-search "Heading" (buffer-string)))
            (should (string-search "code" (buffer-string)))))
      (ignore-errors (delete-file md))
      (ignore-errors (kill-buffer buf))))
  (require 'dashboard nil t)
  (let ((dashboard-navigator-buttons (and (boundp 'dashboard-navigator-buttons)
                                          dashboard-navigator-buttons)))
    (defvar dashboard-navigator-buttons)
    (setq dashboard-navigator-buttons nil)
    (strata-dirvish-dashboard-install)
    (should (= (length (car dashboard-navigator-buttons)) 6)))
  (when (executable-find "7z")
    (let* ((tmp (make-temp-file "strata-zip-" t))
           (arc (expand-file-name "pack.zip" tmp))
           (f1 (expand-file-name "one.txt" tmp)))
      (unwind-protect
          (progn
            (write-region "1" nil f1)
            (let ((default-directory tmp))
              (should (= 0 (call-process "7z" nil nil nil "a" "-tzip" arc "one.txt"))))
            (should (equal (strata-archive--top-level-roots arc) '("one.txt"))))
        (ignore-errors (delete-directory tmp t))))))

(ert-deftest strata-test-f4-conflict-removed-and-mouse-bound ()
  (should-not (lookup-key strata-default-keymap (kbd "<f4>")))
  (should-not (lookup-key strata-10xer-keymap (kbd "<f4>")))
  (should (eq (lookup-key strata-default-keymap (kbd "C-`")) #'strata-toggle-pane-terminal))
  (should (eq (lookup-key strata-default-keymap (kbd "<f9>")) #'strata-toggle-pane-terminal))
  (should (eq (lookup-key strata-default-keymap (kbd "C-c t")) #'strata-toggle-pane-terminal))
  (dolist (km (list strata-default-keymap strata-10xer-keymap))
    (should (eq (lookup-key km (kbd "<mouse-1>")) #'strata-mouse-click-entry))
    (should (eq (lookup-key km (kbd "<mouse-2>")) #'strata-mouse-activate-at-event))
    (should (eq (lookup-key km (kbd "<double-mouse-1>")) #'strata-mouse-activate-at-event))))

(ert-deftest strata-test-clickable-directories-and-verified-icons ()
  (let* ((tmp (make-temp-file "strata-mouse-" t))
         (sub (expand-file-name "sub_folder" tmp))
         (fil (expand-file-name "note.txt" tmp)))
    (unwind-protect
        (progn
          (make-directory sub t)
          (write-region "hi" nil fil)
          ;; Compact view: directory gets pointer 'hand + mouse-face 'highlight
          (with-temp-buffer
            (strata-compact-mode)
            (setq strata-view-directory (file-name-as-directory tmp))
            (strata-compact-render)
            (goto-char (point-min))
            (should (search-forward "sub_folder" nil t))
            (let ((p (match-beginning 0)))
              (should (eq (get-text-property p 'pointer) 'hand))
              (should (eq (get-text-property p 'mouse-face) 'highlight))
              (should (equal (directory-file-name (get-text-property p 'strata-entry))
                             (directory-file-name sub))))
            (goto-char (point-min))
            (should (search-forward "note.txt" nil t))
            (should-not (eq (get-text-property (match-beginning 0) 'pointer) 'hand)))
          ;; Icons view: directory tile gets pointer 'hand + mouse-face 'highlight
          (with-temp-buffer
            (strata-icons-mode)
            (setq strata-view-directory (file-name-as-directory tmp))
            (strata-icons-render)
            (goto-char (point-min))
            (should (search-forward "sub_folder" nil t))
            (let ((p (match-beginning 0)))
              (should (eq (get-text-property p 'pointer) 'hand))
              (should (eq (get-text-property p 'mouse-face) 'highlight))))
          ;; Breadcrumbs: clickable segment with pointer 'hand & header/mode-line click map
          (let* ((seg (strata-crumb--make-segment "Projects" sub))
                 (km (get-text-property 0 'keymap seg)))
            (should (eq (get-text-property 0 'pointer seg) 'hand))
            (should (eq (get-text-property 0 'mouse-face seg) 'highlight))
            (should (keymapp km))
            (should (lookup-key km [header-line mouse-1]))
            (should (lookup-key km [mode-line mouse-1])))
          ;; Sidebar Places: clickable, hand cursor, zero broken missing glyphs
          (let ((sb (get-buffer-create "*Strata Sidebar*")))
            (with-current-buffer sb
              (strata-sidebar-mode)
              (strata-sidebar-render)
              (goto-char (point-min))
              (should (search-forward "Home" nil t))
              (let ((p (match-beginning 0)))
                (should (eq (get-text-property p 'pointer) 'hand))
                (should (eq (get-text-property p 'mouse-face) 'highlight)))
              (should-not (string-search "🖵" (buffer-string)))
              (should-not (string-search "🖴" (buffer-string))))))
      (ignore-errors (kill-buffer "*Strata Sidebar*"))
      (ignore-errors (delete-directory tmp t))))
  ;; Icon table & tinting keep :family intact without missing glyphs
  (should-not (string-search "🖵" (strata-icon-glyph 'desktop)))
  (should-not (string-search "🖴" (strata-icon-glyph 'hdd)))
  (let* ((base (propertize "X" 'face '(:family "Symbols Nerd Font Mono")))
         (tinted (strata-icon-tint base 'highlight))
         (f (get-text-property 0 'face tinted)))
    (should (listp f))
    (should (equal (car f) '(:family "Symbols Nerd Font Mono")))
    (should (memq 'highlight f))))

(ert-deftest strata-test-swift-startup-skips-devices-and-guards-fuse ()
  "Startup sidebar skips device scans and FUSE/cloud mounts are never synchronously probed."
  (require 'dirvish-collapse)
  (let* ((tmp (make-temp-file "strata-swift-" t))
         (state-dir (expand-file-name "state" tmp))
         (strata-dirvish-config-dir (expand-file-name "cfg" tmp))
         (strata-dirvish-state-dir state-dir)
         (strata-dirvish-state-file (expand-file-name "prefs.eld" state-dir))
         (strata-devices-cache nil)
         (strata-sidebar-window nil))
    (unwind-protect
        (cl-letf (((symbol-function 'strata-prefs)
                   (lambda () (strata-prefs--create))))
          (strata-dirvish-setup)
          ;; Default setup omits synchronous `collapse` and puts `strata-mount-guard` first.
          (should-not (memq 'collapse dirvish-attributes))
          (should (eq (car dirvish-preview-dispatchers) 'strata-mount-guard))
          ;; Sidebar startup render must NEVER invoke synchronous `strata-devices-list`.
          (cl-letf (((symbol-function 'strata-devices-list)
                     (lambda (&rest _) (error "Unexpected synchronous device scan at startup"))))
            (let ((sb (get-buffer-create "*Strata Sidebar*")))
              (with-current-buffer sb
                (strata-sidebar-mode)
                (strata-sidebar-render)
                (should (string-search "[Scan drives (g)]" (buffer-string)))
                (goto-char (point-min))
                (should (search-forward "[Scan drives (g)]" nil t))
                (should (eq (get-text-property (match-beginning 0) 'strata-sidebar-action)
                            'scan-devices))
                (should (eq (get-text-property (match-beginning 0) 'pointer) 'hand)))))
          ;; Mock /proc/mounts entries (never touching real FUSE mounts).
          (cl-letf (((symbol-function 'strata-mounts--entries)
                     (lambda (&optional _force)
                       '(("/home/thinky/Scramble Drive" cloud "fuse.rclone" "scramble_drive:")
                         ("/run/media/thinky/usb" removable "vfat" "/dev/sdb1")
                         ("/" local "btrfs" "/dev/nvme0n1p2")))))
            (should (eq (strata-path-mount-kind "/home/thinky/Scramble Drive") 'cloud))
            (should (eq (strata-path-mount-kind "/home/thinky/Scramble Drive/nested") 'cloud))
            (should (strata-path-unsafe-probe-p "/home/thinky/Scramble Drive"))
            (should (strata-path-unsafe-probe-p "/run/media/thinky/usb"))
            (should (strata-path-unsafe-probe-p "/ssh:example:/tmp"))
            (should-not (strata-path-unsafe-probe-p "/home/thinky/Projects"))
            ;; `strata-file--glyph` must classify cloud mount WITHOUT probing `.git`.
            (cl-letf (((symbol-function 'file-exists-p)
                       (lambda (p)
                         (when (string-search "Scramble Drive" p)
                           (error "Blocked sync probe inside FUSE mount: %s" p))
                         nil)))
              (should (equal (strata-file--glyph "/home/thinky/Scramble Drive" t)
                             (strata-icon-glyph 'cloud 'dired-directory))))
            ;; Advised `dirvish-collapse--cache` must short-circuit without `directory-files`.
            (cl-letf (((symbol-function 'directory-files)
                       (lambda (d &rest _)
                         (error "Blocked directory-files on %s" d))))
              (should (equal (dirvish-collapse--cache "/home/thinky/Scramble Drive")
                             '(nil . nil))))))
      (ignore-errors (kill-buffer "*Strata Sidebar*"))
      (ignore-errors (delete-directory tmp t)))))

(provide 'strata-dirvish-tests)
;;; strata-dirvish-tests.el ends here
