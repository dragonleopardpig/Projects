;;; enhanced-dirvish-watch.el --- Live filesystem watchers across all Enhanced Dirvish views & previews -*- lexical-binding: t; -*-

;;; Commentary:
;; Extends kernel-backed `filenotify' live updates uniformly across all local
;; Enhanced Dirvish browser views (Columns/List `dired-mode', `enhanced-dirvish-compact-mode',
;; `enhanced-dirvish-icons-mode'), Miller parent columns (`dirvish-directory-view-mode'),
;; expanded subtrees (`dirvish-subtree'), hovered subfolder previews, virtual
;; Trash/Recent views (`enhanced-dirvish-trash-mode', `enhanced-dirvish-recent-mode'), and
;; `*Enhanced Dirvish Sidebar*' (`Trash (N)' / Pinned Bookmarks).
;;
;; Skips TRAMP remote paths and mounts flagged by `enhanced-dirvish-path-unsafe-probe-p'
;; (cloud/FUSE/network/removable) to avoid blocking I/O or UI stalls, and always
;; invalidates thumbnail + fallback text-preview caches while preserving
;; `enhanced-dirvish-preview-edit-mode' buffers and `enhanced-dirvish-preview-read-mode' reading
;; position.

;;; Code:

(require 'cl-lib)
(require 'filenotify)
(require 'subr-x)
(require 'enhanced-dirvish-prefs)
(require 'enhanced-dirvish-devices)
(require 'enhanced-dirvish-views)
(require 'enhanced-dirvish-panes)
(require 'enhanced-dirvish-previews)

(defvar dirvish-cache-dir)
(defvar dirvish--sessions)
(declare-function dirvish-curr "dirvish")
(declare-function dirvish--redisplay "dirvish")
(declare-function dirvish--preview-update "dirvish")
(declare-function dirvish-preview-dispatch "dirvish")
(declare-function dirvish--render-attrs "dirvish")
(declare-function dv-preview-window "dirvish")
(declare-function dv-preview-hash "dirvish")
(declare-function dv-parent-hash "dirvish")
(declare-function dv-index "dirvish")
(declare-function dv-timestamp "dirvish")
(declare-function dv-preview-buffers "dirvish")
(declare-function enhanced-dirvish--parent-buffer-filter "enhanced-dirvish")

;;;; State & Compatibility Aliases

;; Legacy compatibility aliases expected by user config and ERT tests.
(defvaralias 'my/dired-fn-debug 'enhanced-dirvish-watch-debug)
(defvaralias 'my/dired-fn-table 'enhanced-dirvish-watch--table)

(defvar enhanced-dirvish-watch-debug nil
  "Non-nil logs watch events handled by `enhanced-dirvish-watch--handler'.")

(defvar enhanced-dirvish-watch--table (make-hash-table :test #'equal)
  "Map `file-notify' descriptor -> list `(BUFFER KIND DIR)'.")

(defvar enhanced-dirvish-watch--max-pending-files 64
  "Maximum per-buffer changed file paths retained per debounce cycle.")

(defvar-local enhanced-dirvish-watch--entries nil
  "Buffer-local alist of `((KIND . DIR) . DESCRIPTOR)' watches.")

(defvar-local enhanced-dirvish-watch--timer nil
  "Buffer-local debounce timer for pending `filenotify' refreshes.")

(defvar-local enhanced-dirvish-watch--pending-targets nil
  "Pending `(KIND . DIR)' pairs queued for the next debounced refresh.")

(defvar-local enhanced-dirvish-watch--pending-files nil
  "Pending changed file paths queued for preview cache invalidation.")

(defvar-local enhanced-dirvish-watch--dirty nil
  "Non-nil when a hidden view buffer needs re-render upon next display.")

(defvar-local enhanced-dirvish-watch--last-hover nil
  "Cached hovered path string from last `post-command-hook' watch sync.")

(defvar-local enhanced-dirvish-watch--last-subtree-count nil
  "Cached count of expanded subtree overlays from last watch sync.")

;;;; Path & State Predicates

(defun enhanced-dirvish-watch--safe-dir-p (dir)
  "Return canonical directory string when DIR is local and safe to watch."
  (when (and (stringp dir) (not (string-empty-p dir)))
    (let ((abs (ignore-errors (file-name-as-directory (expand-file-name dir)))))
      (when (and abs
                 (not (file-remote-p abs))
                 (not (and (fboundp 'enhanced-dirvish-path-unsafe-probe-p)
                           (enhanced-dirvish-path-unsafe-probe-p abs)))
                 (file-directory-p abs))
        abs))))

(defun enhanced-dirvish-watch--xdg-trash-dirs ()
  "Return `(FILES-DIR . INFO-DIR)' for XDG Trash directories."
  (let ((base (expand-file-name "Trash" (or (getenv "XDG_DATA_HOME") "~/.local/share"))))
    (cons (expand-file-name "files" base)
          (expand-file-name "info" base))))

(defun enhanced-dirvish-watch--file-editing-p (file)
  "Non-nil if a live `enhanced-dirvish-preview-edit-mode' buffer edits FILE."
  (when (stringp file)
    (let ((abs (ignore-errors (expand-file-name file)))
          (true (ignore-errors (file-truename (expand-file-name file)))))
      (cl-some
       (lambda (b)
         (when (buffer-live-p b)
           (with-current-buffer b
             (when (bound-and-true-p enhanced-dirvish-preview-edit-mode)
               (let ((bf (or buffer-file-name enhanced-dirvish-preview--file)))
                 (and bf
                      (or (equal (ignore-errors (expand-file-name bf)) abs)
                          (and true
                               (equal (ignore-errors (file-truename bf)) true)))))))))
       (buffer-list)))))

(defun enhanced-dirvish-watch--same-file-p (a b)
  "Return non-nil when paths A and B refer to the same file."
  (when (and (stringp a) (stringp b))
    (or (equal (expand-file-name a) (expand-file-name b))
        (equal (directory-file-name (expand-file-name a))
               (directory-file-name (expand-file-name b)))
        (let ((ta (ignore-errors (file-truename a)))
              (tb (ignore-errors (file-truename b))))
          (and ta tb (equal (directory-file-name ta) (directory-file-name tb)))))))

;;;; Thumbnail & Preview Cache Invalidation

(defun enhanced-dirvish-watch--delete-matching-files (dir prefix)
  "Delete files in DIR whose basename starts with PREFIX."
  (when (and (stringp dir) (file-directory-p dir) (stringp prefix))
    (dolist (f (ignore-errors
                 (directory-files dir t (concat "\\`" (regexp-quote prefix)))))
      (ignore-errors (delete-file f)))))

(defun enhanced-dirvish-watch--invalidate-file-caches (file)
  "Invalidate cached thumbnails, rich previews, and fallback previews for FILE."
  (when (stringp file)
    (let* ((abs (ignore-errors (expand-file-name file)))
           (true (ignore-errors (file-truename abs)))
           (hashes (cl-delete-duplicates
                    (delq nil (list (and abs (md5 abs))
                                    (and true (md5 true))))
                    :test #'equal)))
      ;; 1. Dirvish built-in thumbnail cache.
      (when (and (boundp 'dirvish-cache-dir) abs)
        (let ((thumb-dir (expand-file-name "thumbnails" dirvish-cache-dir))
              (dmd5 (secure-hash 'md5 (concat "file://" abs))))
          (when (file-directory-p thumb-dir)
            (dolist (sub (ignore-errors
                           (directory-files thumb-dir t directory-files-no-dot-files-regexp)))
              (enhanced-dirvish-watch--delete-matching-files sub dmd5)))))
      ;; 2. Enhanced Dirvish Icons + rich image/PDF/video thumbnail caches & buffers.
      (when (boundp 'enhanced-dirvish-thumbnail-dir)
        (dolist (h hashes)
          (enhanced-dirvish-watch--delete-matching-files enhanced-dirvish-thumbnail-dir (concat h "-"))
          (enhanced-dirvish-watch--delete-matching-files enhanced-dirvish-thumbnail-dir (concat "img-" h "-"))
          (enhanced-dirvish-watch--delete-matching-files enhanced-dirvish-thumbnail-dir (concat "pdf-" h "-"))
          (enhanced-dirvish-watch--delete-matching-files enhanced-dirvish-thumbnail-dir (concat "vid-" h))
          (dolist (bname (list (format " *Dirvish-preview-img-%s*" h)
                               (format " *Dirvish-preview-pdf-%s*" h)))
            (when-let ((b (get-buffer bname)))
              (unless (or (buffer-modified-p b)
                          (buffer-local-value 'enhanced-dirvish-preview-read-mode b))
                (let (kill-buffer-query-functions)
                  (kill-buffer b)))))))
      ;; 3. Dirvish `dv-preview-hash' + unmodified non-read preview buffers.
      (when (and (boundp 'dirvish--sessions)
                 (hash-table-p dirvish--sessions)
                 (not (enhanced-dirvish-watch--file-editing-p abs)))
        (maphash
         (lambda (_id dv)
           (when (hash-table-p (dv-preview-hash dv))
             (remhash file (dv-preview-hash dv))
             (when abs (remhash abs (dv-preview-hash dv)))
             (when true (remhash true (dv-preview-hash dv))))
           (when-let ((pbuf (get-buffer (format "PREVIEW :: %s :: %s"
                                                (dv-timestamp dv)
                                                (file-name-nondirectory file)))))
             (unless (or (buffer-modified-p pbuf)
                         (buffer-local-value 'enhanced-dirvish-preview-read-mode pbuf))
               (enhanced-dirvish-preview--invalidate-cache dv abs t))))
         dirvish--sessions))
      (when (and (fboundp 'clear-image-cache)
                 (or (display-graphic-p)
                     (cl-some #'display-graphic-p (frame-list))))
        (ignore-errors (clear-image-cache))))))

(defalias 'my/dired-fn--invalidate-thumb #'enhanced-dirvish-watch--invalidate-file-caches)

;;;; Desired Watch Target Discovery

(defun enhanced-dirvish-watch--has-live-preview-p (buf)
  "Return non-nil if browser buffer BUF currently has an active preview window."
  (let ((dv (with-current-buffer buf (ignore-errors (dirvish-curr)))))
    (or (and dv (window-live-p (dv-preview-window dv)))
        (window-live-p (bound-and-true-p enhanced-dirvish-preview-standalone-window))
        (window-live-p (get-buffer-window "*Enhanced Dirvish Preview*" t)))))

(defun enhanced-dirvish-watch--desired-targets (buf)
  "Compute list of `(KIND . ABS-DIR)' watch targets needed for buffer BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let (targets primary)
        (cond
         ;; Dired / Dirvish Columns / List
         ((derived-mode-p 'dired-mode)
          (when-let ((d (enhanced-dirvish-watch--safe-dir-p default-directory)))
            (setq primary d)
            (push (cons 'primary d) targets))
          (when (boundp 'dirvish-subtree--overlays)
            (dolist (ov dirvish-subtree--overlays)
              (when (overlayp ov)
                (when-let ((sd (enhanced-dirvish-watch--safe-dir-p
                                (overlay-get ov 'dired-subtree-name))))
                  (unless (equal sd primary)
                    (push (cons 'subtree sd) targets)))))))
         ;; Enhanced Dirvish Compact & Icons views
         ((derived-mode-p 'enhanced-dirvish-compact-mode 'enhanced-dirvish-icons-mode)
          (when-let ((d (enhanced-dirvish-watch--safe-dir-p
                         (or (bound-and-true-p enhanced-dirvish-view-directory) default-directory))))
            (setq primary d)
            (push (cons 'primary d) targets)))
         ;; Dirvish Miller parent columns (*dirvish-parent-N@...*)
         ((and (derived-mode-p 'dirvish-directory-view-mode)
               (string-match-p "\\` ?\\*dirvish-parent-" (buffer-name buf)))
          (when-let ((d (enhanced-dirvish-watch--safe-dir-p
                         (or (car-safe (car-safe dired-subdir-alist))
                             default-directory))))
            (push (cons 'parent d) targets)))
         ;; Virtual Trash buffer
         ((derived-mode-p 'enhanced-dirvish-trash-mode)
          (let ((dirs (enhanced-dirvish-watch--xdg-trash-dirs)))
            (when-let ((fd (enhanced-dirvish-watch--safe-dir-p (car dirs))))
              (push (cons 'trash fd) targets))
            (when-let ((id (enhanced-dirvish-watch--safe-dir-p (cdr dirs))))
              (push (cons 'trash-info id) targets))))
         ;; Virtual Recent buffer
         ((derived-mode-p 'enhanced-dirvish-recent-mode)
          (let ((xbel (expand-file-name "recently-used.xbel"
                                        (or (getenv "XDG_DATA_HOME") "~/.local/share"))))
            (when-let ((xd (enhanced-dirvish-watch--safe-dir-p (file-name-directory xbel))))
              (push (cons 'recent xd) targets))))
         ;; Left Sidebar (*Enhanced Dirvish Sidebar*)
         ((derived-mode-p 'enhanced-dirvish-sidebar-mode)
          (let ((tfiles (car (enhanced-dirvish-watch--xdg-trash-dirs)))
                (bdir (file-name-directory enhanced-dirvish-gtk-bookmarks-file)))
            (when-let ((fd (enhanced-dirvish-watch--safe-dir-p tfiles)))
              (push (cons 'trash fd) targets))
            (when-let ((bd (enhanced-dirvish-watch--safe-dir-p bdir)))
              (push (cons 'bookmarks bd) targets)))))
        ;; Hovered subdirectory preview watch when browser is displayed & preview open.
        (when (and (derived-mode-p 'dired-mode 'enhanced-dirvish-compact-mode 'enhanced-dirvish-icons-mode)
                   (get-buffer-window buf t)
                   (enhanced-dirvish-watch--has-live-preview-p buf))
          (when-let ((cur (and (fboundp 'enhanced-dirvish-current-file) (enhanced-dirvish-current-file))))
            (when (and (stringp cur)
                       (not (file-remote-p cur))
                       (not (and (fboundp 'enhanced-dirvish-path-unsafe-probe-p)
                                 (enhanced-dirvish-path-unsafe-probe-p cur)))
                       (file-directory-p cur))
              (when-let ((sub (enhanced-dirvish-watch--safe-dir-p cur)))
                (unless (equal sub primary)
                  (push (cons 'preview-subdir sub) targets))))))
        (cl-delete-duplicates (nreverse targets) :test #'equal)))))

;;;; Watch Setup, Sync & Teardown

(defun enhanced-dirvish-watch--remove-entry (key descr)
  "Detach file-notify DESCR; drop KEY from `enhanced-dirvish-watch--entries'."
  (when descr
    (remhash descr enhanced-dirvish-watch--table)
    (ignore-errors (file-notify-rm-watch descr)))
  (setq enhanced-dirvish-watch--entries
        (cl-remove-if (lambda (pair)
                        (and (equal (car pair) key)
                             (equal (cdr pair) descr)))
                      enhanced-dirvish-watch--entries)))

(defun enhanced-dirvish-watch-teardown (&optional buf)
  "Remove all active filesystem watches and timers for BUF (default current)."
  (let ((target (or buf (current-buffer))))
    (when (buffer-live-p target)
      (with-current-buffer target
        (when (timerp enhanced-dirvish-watch--timer)
          (cancel-timer enhanced-dirvish-watch--timer)
          (setq enhanced-dirvish-watch--timer nil))
        (setq enhanced-dirvish-watch--pending-targets nil
              enhanced-dirvish-watch--pending-files nil)
        (dolist (pair (copy-sequence enhanced-dirvish-watch--entries))
          (enhanced-dirvish-watch--remove-entry (car pair) (cdr pair)))
        (setq enhanced-dirvish-watch--entries nil)))))

(defalias 'my/dired-fn-teardown #'enhanced-dirvish-watch-teardown)

(defun enhanced-dirvish-watch-sync (&optional buf)
  "Synchronize `file-notify' watches on BUF (default current) with desired targets."
  (let ((target (or buf (current-buffer))))
    (when (buffer-live-p target)
      (with-current-buffer target
        (let ((desired (enhanced-dirvish-watch--desired-targets target)))
          ;; Drop watches no longer desired.
          (dolist (pair (copy-sequence enhanced-dirvish-watch--entries))
            (unless (member (car pair) desired)
              (enhanced-dirvish-watch--remove-entry (car pair) (cdr pair))))
          ;; Add missing watches cleanly.
          (dolist (key desired)
            (unless (assoc key enhanced-dirvish-watch--entries)
              (let ((descr (ignore-errors
                             (file-notify-add-watch
                              (cdr key) '(change) #'enhanced-dirvish-watch--handler))))
                (when descr
                  (push (cons key descr) enhanced-dirvish-watch--entries)
                  (puthash descr (list target (car key) (cdr key)) enhanced-dirvish-watch--table)))))
          (when enhanced-dirvish-watch--entries
            (add-hook 'kill-buffer-hook #'enhanced-dirvish-watch-teardown nil t))
          (setq enhanced-dirvish-watch--last-hover
                (and (derived-mode-p 'dired-mode 'enhanced-dirvish-compact-mode 'enhanced-dirvish-icons-mode)
                     (fboundp 'enhanced-dirvish-current-file)
                     (enhanced-dirvish-current-file))
                enhanced-dirvish-watch--last-subtree-count
                (and (boundp 'dirvish-subtree--overlays)
                     (length dirvish-subtree--overlays))))))))

(defun enhanced-dirvish-watch-setup ()
  "Enable live filesystem watching hooks for the current buffer."
  (interactive)
  (when (fboundp 'enhanced-dirvish--sync-auto-revert)
    (enhanced-dirvish--sync-auto-revert))
  (enhanced-dirvish-watch-sync (current-buffer)))

(defalias 'my/dired-fn-setup #'enhanced-dirvish-watch-setup)

(defun enhanced-dirvish-watch--post-command-sync ()
  "Keep hovered-subdir and subtree watches synced after cursor motion or toggle."
  (when (derived-mode-p 'dired-mode 'enhanced-dirvish-compact-mode 'enhanced-dirvish-icons-mode)
    (let ((cur (and (fboundp 'enhanced-dirvish-current-file) (enhanced-dirvish-current-file)))
          (sc (and (boundp 'dirvish-subtree--overlays)
                   (length dirvish-subtree--overlays))))
      (unless (and (equal cur enhanced-dirvish-watch--last-hover)
                   (eql sc enhanced-dirvish-watch--last-subtree-count))
        (enhanced-dirvish-watch-sync (current-buffer))))))

;;;; Refresh Execution (Views, Parent Columns, Previews, Virtual Buffers)

(defun enhanced-dirvish-watch--refresh-standalone-preview (file &optional buf-files subdir-only-p)
  "Refresh `*Enhanced Dirvish Preview*' when visible and displaying FILE or its directory."
  (let* ((swin (or (and (boundp 'enhanced-dirvish-preview-standalone-window)
                        (window-live-p enhanced-dirvish-preview-standalone-window)
                        (eq (window-buffer enhanced-dirvish-preview-standalone-window)
                            (get-buffer "*Enhanced Dirvish Preview*"))
                        enhanced-dirvish-preview-standalone-window)
                   (get-buffer-window "*Enhanced Dirvish Preview*" t)))
         (sbuf (and (window-live-p swin) (window-buffer swin))))
    (when (and (window-live-p swin) (buffer-live-p sbuf)
               (not (buffer-local-value 'enhanced-dirvish-preview-edit-mode sbuf)))
      (let* ((was-read (buffer-local-value 'enhanced-dirvish-preview-read-mode sbuf))
             (was-selected (eq (selected-window) swin))
             (old-pt (with-current-buffer sbuf (point)))
             (old-ws (window-start swin))
             (ctx (with-current-buffer sbuf
                    (list :win enhanced-dirvish-preview-edit--browser-window
                          :buf enhanced-dirvish-preview-edit--browser-buffer
                          :dir enhanced-dirvish-preview-edit--browser-dir
                          :view enhanced-dirvish-preview-edit--browser-view)))
             (active-match (or (null enhanced-dirvish-active-preview-file)
                               (and subdir-only-p file (file-directory-p file))
                               (and file (enhanced-dirvish-watch--same-file-p enhanced-dirvish-active-preview-file file))
                               (cl-some (lambda (f)
                                          (enhanced-dirvish-watch--same-file-p enhanced-dirvish-active-preview-file f))
                                        buf-files))))
        (when active-match
          (if file
              (enhanced-dirvish-preview-update-standalone file swin)
            (setq enhanced-dirvish-active-preview-file nil
                  enhanced-dirvish-active-preview-kind nil)
            (with-current-buffer sbuf
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert "\n  Folder is empty.\n"))))
          (when (and was-read (window-live-p swin))
            (let ((nbuf (window-buffer swin)))
              (when (buffer-live-p nbuf)
                (enhanced-dirvish-preview--sync-read-buffer swin nbuf ctx)
                (with-current-buffer nbuf
                  (goto-char (min old-pt (point-max))))
                (set-window-start swin (min old-ws (with-current-buffer nbuf (point-max))) t)
                (when was-selected
                  (select-window swin t))))))))))

(defun enhanced-dirvish-watch--refresh-dirvish-preview (dv file &optional changed-files)
  "Refresh DV's preview window for FILE unless editing or stale."
  (let* ((pwin (and dv (dv-preview-window dv)))
         (pbuf (and (window-live-p pwin) (window-buffer pwin)))
         (idx-buf (and dv (cdr (dv-index dv)))))
    (when (and dv (window-live-p pwin)
               (or (null idx-buf) (eq idx-buf (current-buffer)))
               (or (not (buffer-live-p pbuf))
                   (not (with-current-buffer pbuf
                          (bound-and-true-p enhanced-dirvish-preview-edit-mode)))))
      (if (null file)
          (ignore-errors (dirvish-preview-dispatch '(info . "Empty folder") dv))
        (let* ((was-read (and (buffer-live-p pbuf)
                              (buffer-local-value 'enhanced-dirvish-preview-read-mode pbuf)))
               (was-selected (eq (selected-window) pwin))
               (old-pt (if (buffer-live-p pbuf) (with-current-buffer pbuf (point)) 1))
               (old-ws (window-start pwin))
               (ctx (when (buffer-live-p pbuf)
                      (with-current-buffer pbuf
                        (list :win enhanced-dirvish-preview-edit--browser-window
                              :buf enhanced-dirvish-preview-edit--browser-buffer
                              :dir enhanced-dirvish-preview-edit--browser-dir
                              :view enhanced-dirvish-preview-edit--browser-view)))))
          (enhanced-dirvish-preview--invalidate-cache dv file nil)
          (dolist (cf changed-files)
            (enhanced-dirvish-preview--invalidate-cache dv cf nil))
          (when (and was-read (buffer-live-p pbuf)
                     (let ((nm (buffer-name pbuf)))
                       (or (string-prefix-p "PREVIEW :: " nm)
                           (string-prefix-p " *preview-temp*" nm))))
            (enhanced-dirvish-preview--invalidate-cache dv file t))
          (let ((enhanced-dirvish-preview--force-update t))
            (ignore-errors (dirvish--preview-update dv file)))
          (when (and was-read (window-live-p pwin))
            (let ((nbuf (window-buffer pwin)))
              (when (buffer-live-p nbuf)
                (enhanced-dirvish-preview--sync-read-buffer pwin nbuf ctx)
                (with-current-buffer nbuf
                  (goto-char (min old-pt (point-max))))
                (set-window-start pwin
                                  (min old-ws (with-current-buffer nbuf (point-max)))
                                  t)
                (when was-selected
                  (select-window pwin t))))))))))

(defun enhanced-dirvish-watch--refresh-preview-for-buffer (buf &optional changed-files subdir-only-p)
  "Refresh active Dirvish or standalone preview associated with BUF."
  (with-current-buffer buf
    (let* ((file (if (derived-mode-p 'dired-mode)
                     (dired-get-filename nil t)
                   (and (fboundp 'enhanced-dirvish-current-file) (enhanced-dirvish-current-file))))
           (dv (and (fboundp 'dirvish-curr) (ignore-errors (dirvish-curr)))))
      (cond
       ((and dv (window-live-p (dv-preview-window dv)))
        (when (or (not subdir-only-p)
                  (and file (file-directory-p file)))
          (enhanced-dirvish-watch--refresh-dirvish-preview dv file changed-files)))
       ((or (not (boundp 'enhanced-dirvish-split-active-p))
            (not (enhanced-dirvish-split-active-p))
            (when-let ((ap (and (fboundp 'enhanced-dirvish-active-pane) (enhanced-dirvish-active-pane))))
              (or (eq buf (enhanced-dirvish-pane-state-buffer ap))
                  (let ((aw (enhanced-dirvish-pane-state-window ap)))
                    (and (window-live-p aw) (eq buf (window-buffer aw)))))))
        (enhanced-dirvish-watch--refresh-standalone-preview file changed-files subdir-only-p))))))

(defun enhanced-dirvish-watch--refresh-parent-buffer (buf)
  "Refresh Dirvish Miller parent column BUF cleanly without moving focus."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (and (derived-mode-p 'dirvish-directory-view-mode)
                 (string-match-p "\\` ?\\*dirvish-parent-" (buffer-name buf)))
        (let* ((dv (and (fboundp 'dirvish-curr) (ignore-errors (dirvish-curr))))
               (dir (car-safe (car-safe dired-subdir-alist)))
               (abs (and dir (enhanced-dirvish-watch--safe-dir-p dir))))
          (when abs
            (when (and dv (hash-table-p (dv-parent-hash dv)))
              (remhash dir (dv-parent-hash dv))
              (remhash abs (dv-parent-hash dv))
              (remhash (directory-file-name abs) (dv-parent-hash dv)))
            (let* ((cur (or (ignore-errors (dired-get-filename nil t))
                            (when-let ((root (and dv (car (dv-index dv)))))
                              (let ((r (directory-file-name (expand-file-name root))))
                                (when (equal (file-name-as-directory (file-name-directory r)) abs)
                                  r)))))
                   (root-buf (and dv (cdr (dv-index dv))))
                   (flags (or (and (buffer-live-p root-buf)
                                   (buffer-local-value 'dired-actual-switches root-buf))
                              dired-actual-switches
                              dired-listing-switches
                              "-alh"))
                   (str (with-temp-buffer
                          (ignore-errors (dired-insert-directory abs flags))
                          (buffer-string))))
              (when (and dv (hash-table-p (dv-parent-hash dv)))
                (puthash dir str (dv-parent-hash dv)))
              (let ((inhibit-read-only t))
                (erase-buffer)
                (save-excursion (insert str)))
              (setq-local dired-subdir-alist (list (cons dir (point-min-marker))))
              (when cur
                (let ((cabs (directory-file-name cur)))
                  (if (fboundp 'dired-goto-file-1)
                      (ignore-errors
                        (dired-goto-file-1 (file-name-nondirectory cabs) cabs (point-max)))
                    (ignore-errors (dired-goto-file cabs)))))
              (when (fboundp 'enhanced-dirvish--parent-buffer-filter)
                (enhanced-dirvish--parent-buffer-filter buf))
              (when (fboundp 'dirvish--render-attrs)
                (dolist (w (get-buffer-window-list buf nil t))
                  (ignore-errors (dirvish--render-attrs w 'never)))))))))))

(defun enhanced-dirvish-watch--refresh-dired (buf files subdir-only-p)
  "Refresh Dired/Dirvish browser buffer BUF after filesystem changes."
  (if subdir-only-p
      (enhanced-dirvish-watch--refresh-preview-for-buffer buf files t)
    (with-current-buffer buf
      (when (and default-directory (file-directory-p default-directory))
        (let ((inhibit-message t))
          (ignore-errors (revert-buffer t t)))
        (when (fboundp 'dirvish--redisplay)
          (ignore-errors (dirvish--redisplay)))
        (enhanced-dirvish-watch--refresh-preview-for-buffer buf files nil)
        (when (fboundp 'enhanced-dirvish-view--update-selection-highlight)
          (ignore-errors (enhanced-dirvish-view--update-selection-highlight)))
        (enhanced-dirvish-watch-sync buf)
        (force-mode-line-update t)))))

(defun enhanced-dirvish-watch--refresh-compact-or-icons (buf files subdir-only-p)
  "Refresh Enhanced Dirvish Compact or Icons view BUF after filesystem changes."
  (if subdir-only-p
      (enhanced-dirvish-watch--refresh-preview-for-buffer buf files t)
    (with-current-buffer buf
      (let ((dir (or (bound-and-true-p enhanced-dirvish-view-directory) default-directory))
            (win (get-buffer-window buf t)))
        (if (and (not noninteractive) (not win))
            (setq-local enhanced-dirvish-watch--dirty t)
          (when (and dir (file-directory-p dir))
            (setq-local enhanced-dirvish-watch--dirty nil)
            (when (bound-and-true-p enhanced-dirvish-marked-entries)
              (setq enhanced-dirvish-marked-entries
                    (cl-remove-if-not #'file-exists-p enhanced-dirvish-marked-entries)))
            (let ((render-fn (lambda ()
                               (cond
                                ((derived-mode-p 'enhanced-dirvish-compact-mode)
                                 (enhanced-dirvish-compact-render dir))
                                ((derived-mode-p 'enhanced-dirvish-icons-mode)
                                 (enhanced-dirvish-icons-render dir))))))
              (if (window-live-p win)
                  (with-selected-window win (funcall render-fn))
                (funcall render-fn)))
            (enhanced-dirvish-watch--refresh-preview-for-buffer buf files nil)
            (enhanced-dirvish-watch-sync buf)
            (force-mode-line-update t)))))))

(defun enhanced-dirvish-watch--refresh-virtual-or-sidebar (buf)
  "Refresh Trash, Recent, or Sidebar buffer BUF preserving point cleanly."
  (with-current-buffer buf
    (cond
     ((derived-mode-p 'enhanced-dirvish-trash-mode)
      (let ((sel (ignore-errors (plist-get (enhanced-dirvish-trash--item-at-point) :file))))
        (enhanced-dirvish-trash-refresh)
        (when sel
          (goto-char (point-min))
          (while (and (not (eobp))
                      (not (equal (plist-get (get-text-property (point) 'enhanced-dirvish-trash-item) :file)
                                  sel)))
            (forward-line 1))))
      (when (fboundp 'enhanced-dirvish-sidebar-refresh)
        (enhanced-dirvish-sidebar-refresh)))
     ((derived-mode-p 'enhanced-dirvish-recent-mode)
      (let ((sel (get-text-property (line-beginning-position) 'enhanced-dirvish-recent-path)))
        (enhanced-dirvish-recent-refresh)
        (when sel
          (goto-char (point-min))
          (while (and (not (eobp))
                      (not (equal (get-text-property (point) 'enhanced-dirvish-recent-path) sel)))
            (forward-line 1)))))
     ((derived-mode-p 'enhanced-dirvish-sidebar-mode)
      (enhanced-dirvish-sidebar-refresh)))))

(defun enhanced-dirvish-watch--do-refresh (buf)
  "Execute debounced live refresh for buffer BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let* ((targets (prog1 (cl-delete-duplicates enhanced-dirvish-watch--pending-targets :test #'equal)
                        (setq enhanced-dirvish-watch--pending-targets nil)))
             (files (prog1 (cl-delete-duplicates enhanced-dirvish-watch--pending-files :test #'equal)
                      (setq enhanced-dirvish-watch--pending-files nil)))
             (subdir-only-p (and targets
                                 (cl-every (lambda (tk) (eq (car tk) 'preview-subdir))
                                           targets))))
        (setq enhanced-dirvish-watch--timer nil)
        (cond
         ((derived-mode-p 'dired-mode)
          (enhanced-dirvish-watch--refresh-dired buf files subdir-only-p))
         ((derived-mode-p 'enhanced-dirvish-compact-mode 'enhanced-dirvish-icons-mode)
          (enhanced-dirvish-watch--refresh-compact-or-icons buf files subdir-only-p))
         ((derived-mode-p 'dirvish-directory-view-mode)
          (enhanced-dirvish-watch--refresh-parent-buffer buf))
         ((derived-mode-p 'enhanced-dirvish-trash-mode 'enhanced-dirvish-recent-mode 'enhanced-dirvish-sidebar-mode)
          (enhanced-dirvish-watch--refresh-virtual-or-sidebar buf)))))))

(defun my/dired-fn--do-revert (buf)
  "Compatibility entrypoint refreshing browser buffer BUF safely."
  (enhanced-dirvish-watch--do-refresh buf))

;;;; Notify Event Handler & Global Hooks

(defun enhanced-dirvish-watch--relevant-event-p (kind file)
  "Return non-nil when notify event FILE matters for watcher KIND."
  (pcase kind
    ('recent (and (stringp file)
                  (string= (file-name-nondirectory file) "recently-used.xbel")))
    ('bookmarks (and (stringp file)
                     (string= (file-name-nondirectory file) "bookmarks")))
    (_ t)))

(defun enhanced-dirvish-watch--handler (event)
  "Handle `file-notify' EVENT `(DESCR ACTION FILE [FILE1])' after debounce."
  (let* ((descr (car event))
         (action (nth 1 event))
         (file (nth 2 event))
         (file1 (nth 3 event))
         (entry (gethash descr enhanced-dirvish-watch--table))
         (target (car entry))
         (kind (nth 1 entry))
         (dir (nth 2 entry)))
    (when enhanced-dirvish-watch-debug
      (message "[enhanced-dirvish-watch] %S -> buf=%S kind=%S live=%S"
               event target kind (and target (buffer-live-p target))))
    (cond
     ((eq action 'stopped)
      (remhash descr enhanced-dirvish-watch--table)
      (when (buffer-live-p target)
        (with-current-buffer target
          (setq enhanced-dirvish-watch--entries
                (cl-remove-if (lambda (pair) (equal (cdr pair) descr))
                              enhanced-dirvish-watch--entries)))))
     ((not (buffer-live-p target))
      (remhash descr enhanced-dirvish-watch--table)
      (ignore-errors (file-notify-rm-watch descr)))
     ((enhanced-dirvish-watch--relevant-event-p kind file)
      (when (memq action '(changed attribute-changed created renamed-to renamed deleted))
        (enhanced-dirvish-watch--invalidate-file-caches file)
        (when file1
          (enhanced-dirvish-watch--invalidate-file-caches file1)))
      (with-current-buffer target
        (push (cons kind dir) enhanced-dirvish-watch--pending-targets)
        (when (and (stringp file) (< (length enhanced-dirvish-watch--pending-files) enhanced-dirvish-watch--max-pending-files))
          (cl-pushnew file enhanced-dirvish-watch--pending-files :test #'equal))
        (when (and (stringp file1) (< (length enhanced-dirvish-watch--pending-files) enhanced-dirvish-watch--max-pending-files))
          (cl-pushnew file1 enhanced-dirvish-watch--pending-files :test #'equal))
        (when (timerp enhanced-dirvish-watch--timer)
          (cancel-timer enhanced-dirvish-watch--timer))
        ;; Short trailing debounce coalesces bulk copies into one crisp refresh.
        (setq enhanced-dirvish-watch--timer
              (run-with-timer 0.1 nil #'enhanced-dirvish-watch--do-refresh target)))))))

(defalias 'my/dired-fn-handler #'enhanced-dirvish-watch--handler)

(defun enhanced-dirvish-watch--on-window-buffer-change (&optional frame)
  "Re-render any Compact/Icons buffer in FRAME that changed while hidden."
  (dolist (win (window-list frame 'no-minibuf))
    (when (window-live-p win)
      (let ((buf (window-buffer win)))
        (when (and (buffer-live-p buf)
                   (buffer-local-value 'enhanced-dirvish-watch--dirty buf))
          (enhanced-dirvish-watch--refresh-compact-or-icons buf nil nil))))))

(defvar enhanced-dirvish-watch--installed nil
  "Non-nil once global Enhanced Dirvish filesystem watch hooks are installed.")

(defun enhanced-dirvish-watch-install ()
  "Install live filesystem watch hooks across views and existing buffers."
  (unless enhanced-dirvish-watch--installed
    (setq enhanced-dirvish-watch--installed t)
    (dolist (hook '(dired-mode-hook
                    dired-after-readin-hook
                    enhanced-dirvish-compact-mode-hook
                    enhanced-dirvish-icons-mode-hook
                    dirvish-directory-view-mode-hook
                    enhanced-dirvish-trash-mode-hook
                    enhanced-dirvish-recent-mode-hook
                    enhanced-dirvish-sidebar-mode-hook))
      (add-hook hook #'enhanced-dirvish-watch-setup))
    (add-hook 'post-command-hook #'enhanced-dirvish-watch--post-command-sync)
    (add-hook 'window-buffer-change-functions #'enhanced-dirvish-watch--on-window-buffer-change))
  ;; Retrofit any buffers created before installation (e.g. startup or reload).
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (derived-mode-p 'dired-mode
                              'enhanced-dirvish-compact-mode
                              'enhanced-dirvish-icons-mode
                              'dirvish-directory-view-mode
                              'enhanced-dirvish-trash-mode
                              'enhanced-dirvish-recent-mode
                              'enhanced-dirvish-sidebar-mode)
          (enhanced-dirvish-watch-setup))))))

(provide 'enhanced-dirvish-watch)
;;; enhanced-dirvish-watch.el ends here
