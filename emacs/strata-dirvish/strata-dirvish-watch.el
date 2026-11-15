;;; strata-dirvish-watch.el --- Live filesystem watchers across all Strata views & previews -*- lexical-binding: t; -*-

;;; Commentary:
;; Extends kernel-backed `filenotify' live updates uniformly across all local
;; Strata/Dirvish browser views (Columns/List `dired-mode', `strata-compact-mode',
;; `strata-icons-mode'), Miller parent columns (`dirvish-directory-view-mode'),
;; expanded subtrees (`dirvish-subtree'), hovered subfolder previews, virtual
;; Trash/Recent views (`strata-trash-mode', `strata-recent-mode'), and
;; `*Strata Sidebar*' (`Trash (N)' / Pinned Bookmarks).
;;
;; Skips TRAMP remote paths and mounts flagged by `strata-path-unsafe-probe-p'
;; (cloud/FUSE/network/removable) to avoid blocking I/O or UI stalls, and always
;; invalidates thumbnail + fallback text-preview caches while preserving
;; `strata-preview-edit-mode' buffers and `strata-preview-read-mode' reading
;; position.

;;; Code:

(require 'cl-lib)
(require 'filenotify)
(require 'subr-x)
(require 'strata-dirvish-prefs)
(require 'strata-dirvish-devices)
(require 'strata-dirvish-views)
(require 'strata-dirvish-panes)
(require 'strata-dirvish-previews)

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
(declare-function strata-dirvish--parent-buffer-filter "strata-dirvish")

;;;; State & Compatibility Aliases

;; Legacy compatibility aliases expected by user config and ERT tests.
(defvaralias 'my/dired-fn-debug 'strata-watch-debug)
(defvaralias 'my/dired-fn-table 'strata-watch--table)

(defvar strata-watch-debug nil
  "When non-nil, log filesystem watch events handled by `strata-watch--handler'.")

(defvar strata-watch--table (make-hash-table :test #'equal)
  "Map `file-notify' descriptor -> list `(BUFFER KIND DIR)'.")

(defvar strata-watch--max-pending-files 64
  "Maximum per-buffer changed file paths retained per debounce cycle.")

(defvar-local strata-watch--entries nil
  "Buffer-local alist of `((KIND . DIR) . DESCRIPTOR)' watches.")

(defvar-local strata-watch--timer nil
  "Buffer-local debounce timer for pending `filenotify' refreshes.")

(defvar-local strata-watch--pending-targets nil
  "Pending `(KIND . DIR)' pairs queued for the next debounced refresh.")

(defvar-local strata-watch--pending-files nil
  "Pending changed file paths queued for preview cache invalidation.")

(defvar-local strata-watch--dirty nil
  "Non-nil when a hidden view buffer needs re-render upon next display.")

(defvar-local strata-watch--last-hover nil
  "Cached hovered path string from last `post-command-hook' watch sync.")

(defvar-local strata-watch--last-subtree-count nil
  "Cached count of expanded subtree overlays from last watch sync.")

;;;; Path & State Predicates

(defun strata-watch--safe-dir-p (dir)
  "Return canonical directory string when DIR is local and safe to watch."
  (when (and (stringp dir) (not (string-empty-p dir)))
    (let ((abs (ignore-errors (file-name-as-directory (expand-file-name dir)))))
      (when (and abs
                 (not (file-remote-p abs))
                 (not (and (fboundp 'strata-path-unsafe-probe-p)
                           (strata-path-unsafe-probe-p abs)))
                 (file-directory-p abs))
        abs))))

(defun strata-watch--xdg-trash-dirs ()
  "Return `(FILES-DIR . INFO-DIR)' for XDG Trash directories."
  (let ((base (expand-file-name "Trash" (or (getenv "XDG_DATA_HOME") "~/.local/share"))))
    (cons (expand-file-name "files" base)
          (expand-file-name "info" base))))

(defun strata-watch--file-editing-p (file)
  "Return non-nil if any live `strata-preview-edit-mode' buffer edits FILE."
  (when (stringp file)
    (let ((abs (ignore-errors (expand-file-name file)))
          (true (ignore-errors (file-truename (expand-file-name file)))))
      (cl-some
       (lambda (b)
         (when (buffer-live-p b)
           (with-current-buffer b
             (when (bound-and-true-p strata-preview-edit-mode)
               (let ((bf (or buffer-file-name strata-preview--file)))
                 (and bf
                      (or (equal (ignore-errors (expand-file-name bf)) abs)
                          (and true
                               (equal (ignore-errors (file-truename bf)) true)))))))))
       (buffer-list)))))

(defun strata-watch--same-file-p (a b)
  "Return non-nil when paths A and B refer to the same file."
  (when (and (stringp a) (stringp b))
    (or (equal (expand-file-name a) (expand-file-name b))
        (equal (directory-file-name (expand-file-name a))
               (directory-file-name (expand-file-name b)))
        (let ((ta (ignore-errors (file-truename a)))
              (tb (ignore-errors (file-truename b))))
          (and ta tb (equal (directory-file-name ta) (directory-file-name tb)))))))

;;;; Thumbnail & Preview Cache Invalidation

(defun strata-watch--delete-matching-files (dir prefix)
  "Delete files in DIR whose basename starts with PREFIX."
  (when (and (stringp dir) (file-directory-p dir) (stringp prefix))
    (dolist (f (ignore-errors
                 (directory-files dir t (concat "\\`" (regexp-quote prefix)))))
      (ignore-errors (delete-file f)))))

(defun strata-watch--invalidate-file-caches (file)
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
              (strata-watch--delete-matching-files sub dmd5)))))
      ;; 2. Strata Icons + rich image/PDF/video thumbnail caches & buffers.
      (when (boundp 'strata-thumbnail-dir)
        (dolist (h hashes)
          (strata-watch--delete-matching-files strata-thumbnail-dir (concat h "-"))
          (strata-watch--delete-matching-files strata-thumbnail-dir (concat "img-" h "-"))
          (strata-watch--delete-matching-files strata-thumbnail-dir (concat "pdf-" h "-"))
          (strata-watch--delete-matching-files strata-thumbnail-dir (concat "vid-" h))
          (dolist (bname (list (format " *Dirvish-preview-img-%s*" h)
                               (format " *Dirvish-preview-pdf-%s*" h)))
            (when-let ((b (get-buffer bname)))
              (unless (or (buffer-modified-p b)
                          (buffer-local-value 'strata-preview-read-mode b))
                (let (kill-buffer-query-functions)
                  (kill-buffer b)))))))
      ;; 3. Dirvish `dv-preview-hash' + unmodified non-read preview buffers.
      (when (and (boundp 'dirvish--sessions)
                 (hash-table-p dirvish--sessions)
                 (not (strata-watch--file-editing-p abs)))
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
                         (buffer-local-value 'strata-preview-read-mode pbuf))
               (strata-preview--invalidate-cache dv abs t))))
         dirvish--sessions))
      (when (and (fboundp 'clear-image-cache)
                 (or (display-graphic-p)
                     (cl-some #'display-graphic-p (frame-list))))
        (ignore-errors (clear-image-cache))))))

(defalias 'my/dired-fn--invalidate-thumb #'strata-watch--invalidate-file-caches)

;;;; Desired Watch Target Discovery

(defun strata-watch--has-live-preview-p (buf)
  "Return non-nil if browser buffer BUF currently has an active preview window."
  (let ((dv (with-current-buffer buf (ignore-errors (dirvish-curr)))))
    (or (and dv (window-live-p (dv-preview-window dv)))
        (window-live-p (bound-and-true-p strata-preview-standalone-window))
        (window-live-p (get-buffer-window "*Strata Preview*" t)))))

(defun strata-watch--desired-targets (buf)
  "Compute list of `(KIND . ABS-DIR)' watch targets needed for buffer BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let (targets primary)
        (cond
         ;; Dired / Dirvish Columns / List
         ((derived-mode-p 'dired-mode)
          (when-let ((d (strata-watch--safe-dir-p default-directory)))
            (setq primary d)
            (push (cons 'primary d) targets))
          (when (boundp 'dirvish-subtree--overlays)
            (dolist (ov dirvish-subtree--overlays)
              (when (overlayp ov)
                (when-let ((sd (strata-watch--safe-dir-p
                                (overlay-get ov 'dired-subtree-name))))
                  (unless (equal sd primary)
                    (push (cons 'subtree sd) targets)))))))
         ;; Strata Compact & Icons views
         ((derived-mode-p 'strata-compact-mode 'strata-icons-mode)
          (when-let ((d (strata-watch--safe-dir-p
                         (or (bound-and-true-p strata-view-directory) default-directory))))
            (setq primary d)
            (push (cons 'primary d) targets)))
         ;; Dirvish Miller parent columns (*dirvish-parent-N@...*)
         ((and (derived-mode-p 'dirvish-directory-view-mode)
               (string-match-p "\\` ?\\*dirvish-parent-" (buffer-name buf)))
          (when-let ((d (strata-watch--safe-dir-p
                         (or (car-safe (car-safe dired-subdir-alist))
                             default-directory))))
            (push (cons 'parent d) targets)))
         ;; Virtual Trash buffer
         ((derived-mode-p 'strata-trash-mode)
          (let ((dirs (strata-watch--xdg-trash-dirs)))
            (when-let ((fd (strata-watch--safe-dir-p (car dirs))))
              (push (cons 'trash fd) targets))
            (when-let ((id (strata-watch--safe-dir-p (cdr dirs))))
              (push (cons 'trash-info id) targets))))
         ;; Virtual Recent buffer
         ((derived-mode-p 'strata-recent-mode)
          (let ((xbel (expand-file-name "recently-used.xbel"
                                        (or (getenv "XDG_DATA_HOME") "~/.local/share"))))
            (when-let ((xd (strata-watch--safe-dir-p (file-name-directory xbel))))
              (push (cons 'recent xd) targets))))
         ;; Left Sidebar (*Strata Sidebar*)
         ((derived-mode-p 'strata-sidebar-mode)
          (let ((tfiles (car (strata-watch--xdg-trash-dirs)))
                (bdir (file-name-directory strata-gtk-bookmarks-file)))
            (when-let ((fd (strata-watch--safe-dir-p tfiles)))
              (push (cons 'trash fd) targets))
            (when-let ((bd (strata-watch--safe-dir-p bdir)))
              (push (cons 'bookmarks bd) targets)))))
        ;; Hovered subdirectory preview watch when browser is displayed & preview open.
        (when (and (derived-mode-p 'dired-mode 'strata-compact-mode 'strata-icons-mode)
                   (get-buffer-window buf t)
                   (strata-watch--has-live-preview-p buf))
          (when-let ((cur (and (fboundp 'strata-current-file) (strata-current-file))))
            (when (and (stringp cur)
                       (not (file-remote-p cur))
                       (not (and (fboundp 'strata-path-unsafe-probe-p)
                                 (strata-path-unsafe-probe-p cur)))
                       (file-directory-p cur))
              (when-let ((sub (strata-watch--safe-dir-p cur)))
                (unless (equal sub primary)
                  (push (cons 'preview-subdir sub) targets))))))
        (cl-delete-duplicates (nreverse targets) :test #'equal)))))

;;;; Watch Setup, Sync & Teardown

(defun strata-watch--remove-entry (key descr)
  "Detach file-notify DESCR and remove KEY from `strata-watch--entries' and table."
  (when descr
    (remhash descr strata-watch--table)
    (ignore-errors (file-notify-rm-watch descr)))
  (setq strata-watch--entries
        (cl-remove-if (lambda (pair)
                        (and (equal (car pair) key)
                             (equal (cdr pair) descr)))
                      strata-watch--entries)))

(defun strata-watch-teardown (&optional buf)
  "Remove all active filesystem watches and timers for BUF (default current)."
  (let ((target (or buf (current-buffer))))
    (when (buffer-live-p target)
      (with-current-buffer target
        (when (timerp strata-watch--timer)
          (cancel-timer strata-watch--timer)
          (setq strata-watch--timer nil))
        (setq strata-watch--pending-targets nil
              strata-watch--pending-files nil)
        (dolist (pair (copy-sequence strata-watch--entries))
          (strata-watch--remove-entry (car pair) (cdr pair)))
        (setq strata-watch--entries nil)))))

(defalias 'my/dired-fn-teardown #'strata-watch-teardown)

(defun strata-watch-sync (&optional buf)
  "Synchronize `file-notify' watches on BUF (default current) with desired targets."
  (let ((target (or buf (current-buffer))))
    (when (buffer-live-p target)
      (with-current-buffer target
        (let ((desired (strata-watch--desired-targets target)))
          ;; Drop watches no longer desired.
          (dolist (pair (copy-sequence strata-watch--entries))
            (unless (member (car pair) desired)
              (strata-watch--remove-entry (car pair) (cdr pair))))
          ;; Add missing watches cleanly.
          (dolist (key desired)
            (unless (assoc key strata-watch--entries)
              (let ((descr (ignore-errors
                             (file-notify-add-watch
                              (cdr key) '(change) #'strata-watch--handler))))
                (when descr
                  (push (cons key descr) strata-watch--entries)
                  (puthash descr (list target (car key) (cdr key)) strata-watch--table)))))
          (when strata-watch--entries
            (add-hook 'kill-buffer-hook #'strata-watch-teardown nil t))
          (setq strata-watch--last-hover
                (and (derived-mode-p 'dired-mode 'strata-compact-mode 'strata-icons-mode)
                     (fboundp 'strata-current-file)
                     (strata-current-file))
                strata-watch--last-subtree-count
                (and (boundp 'dirvish-subtree--overlays)
                     (length dirvish-subtree--overlays))))))))

(defun strata-watch-setup ()
  "Enable live filesystem watching hooks for the current Strata/Dirvish buffer."
  (interactive)
  (when (fboundp 'strata-dirvish--sync-auto-revert)
    (strata-dirvish--sync-auto-revert))
  (strata-watch-sync (current-buffer)))

(defalias 'my/dired-fn-setup #'strata-watch-setup)

(defun strata-watch--post-command-sync ()
  "Keep hovered-subdir and subtree watches synced after cursor motion or toggle."
  (when (derived-mode-p 'dired-mode 'strata-compact-mode 'strata-icons-mode)
    (let ((cur (and (fboundp 'strata-current-file) (strata-current-file)))
          (sc (and (boundp 'dirvish-subtree--overlays)
                   (length dirvish-subtree--overlays))))
      (unless (and (equal cur strata-watch--last-hover)
                   (eql sc strata-watch--last-subtree-count))
        (strata-watch-sync (current-buffer))))))

;;;; Refresh Execution (Views, Parent Columns, Previews, Virtual Buffers)

(defun strata-watch--refresh-standalone-preview (file &optional buf-files subdir-only-p)
  "Refresh `*Strata Preview*' when visible and displaying FILE or its directory."
  (let* ((swin (or (and (boundp 'strata-preview-standalone-window)
                        (window-live-p strata-preview-standalone-window)
                        (eq (window-buffer strata-preview-standalone-window)
                            (get-buffer "*Strata Preview*"))
                        strata-preview-standalone-window)
                   (get-buffer-window "*Strata Preview*" t)))
         (sbuf (and (window-live-p swin) (window-buffer swin))))
    (when (and (window-live-p swin) (buffer-live-p sbuf)
               (not (buffer-local-value 'strata-preview-edit-mode sbuf)))
      (let* ((was-read (buffer-local-value 'strata-preview-read-mode sbuf))
             (was-selected (eq (selected-window) swin))
             (old-pt (with-current-buffer sbuf (point)))
             (old-ws (window-start swin))
             (ctx (with-current-buffer sbuf
                    (list :win strata-preview-edit--browser-window
                          :buf strata-preview-edit--browser-buffer
                          :dir strata-preview-edit--browser-dir
                          :view strata-preview-edit--browser-view)))
             (active-match (or (null strata-active-preview-file)
                               (and subdir-only-p file (file-directory-p file))
                               (and file (strata-watch--same-file-p strata-active-preview-file file))
                               (cl-some (lambda (f)
                                          (strata-watch--same-file-p strata-active-preview-file f))
                                        buf-files))))
        (when active-match
          (if file
              (strata-preview-update-standalone file swin)
            (setq strata-active-preview-file nil
                  strata-active-preview-kind nil)
            (with-current-buffer sbuf
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert "\n  Folder is empty.\n"))))
          (when (and was-read (window-live-p swin))
            (let ((nbuf (window-buffer swin)))
              (when (buffer-live-p nbuf)
                (strata-preview--sync-read-buffer swin nbuf ctx)
                (with-current-buffer nbuf
                  (goto-char (min old-pt (point-max))))
                (set-window-start swin (min old-ws (with-current-buffer nbuf (point-max))) t)
                (when was-selected
                  (select-window swin t))))))))))

(defun strata-watch--refresh-dirvish-preview (dv file &optional changed-files)
  "Refresh DV's preview window for FILE unless editing or stale."
  (let* ((pwin (and dv (dv-preview-window dv)))
         (pbuf (and (window-live-p pwin) (window-buffer pwin)))
         (idx-buf (and dv (cdr (dv-index dv)))))
    (when (and dv (window-live-p pwin)
               (or (null idx-buf) (eq idx-buf (current-buffer)))
               (or (not (buffer-live-p pbuf))
                   (not (with-current-buffer pbuf
                          (bound-and-true-p strata-preview-edit-mode)))))
      (if (null file)
          (ignore-errors (dirvish-preview-dispatch '(info . "Empty folder") dv))
        (let* ((was-read (and (buffer-live-p pbuf)
                              (buffer-local-value 'strata-preview-read-mode pbuf)))
               (was-selected (eq (selected-window) pwin))
               (old-pt (if (buffer-live-p pbuf) (with-current-buffer pbuf (point)) 1))
               (old-ws (window-start pwin))
               (ctx (when (buffer-live-p pbuf)
                      (with-current-buffer pbuf
                        (list :win strata-preview-edit--browser-window
                              :buf strata-preview-edit--browser-buffer
                              :dir strata-preview-edit--browser-dir
                              :view strata-preview-edit--browser-view)))))
          (strata-preview--invalidate-cache dv file nil)
          (dolist (cf changed-files)
            (strata-preview--invalidate-cache dv cf nil))
          (when (and was-read (buffer-live-p pbuf)
                     (let ((nm (buffer-name pbuf)))
                       (or (string-prefix-p "PREVIEW :: " nm)
                           (string-prefix-p " *preview-temp*" nm))))
            (strata-preview--invalidate-cache dv file t))
          (let ((strata-preview--force-update t))
            (ignore-errors (dirvish--preview-update dv file)))
          (when (and was-read (window-live-p pwin))
            (let ((nbuf (window-buffer pwin)))
              (when (buffer-live-p nbuf)
                (strata-preview--sync-read-buffer pwin nbuf ctx)
                (with-current-buffer nbuf
                  (goto-char (min old-pt (point-max))))
                (set-window-start pwin
                                  (min old-ws (with-current-buffer nbuf (point-max)))
                                  t)
                (when was-selected
                  (select-window pwin t))))))))))

(defun strata-watch--refresh-preview-for-buffer (buf &optional changed-files subdir-only-p)
  "Refresh active Dirvish or standalone preview associated with BUF."
  (with-current-buffer buf
    (let* ((file (if (derived-mode-p 'dired-mode)
                     (dired-get-filename nil t)
                   (and (fboundp 'strata-current-file) (strata-current-file))))
           (dv (and (fboundp 'dirvish-curr) (ignore-errors (dirvish-curr)))))
      (cond
       ((and dv (window-live-p (dv-preview-window dv)))
        (when (or (not subdir-only-p)
                  (and file (file-directory-p file)))
          (strata-watch--refresh-dirvish-preview dv file changed-files)))
       ((or (not (boundp 'strata-split-active-p))
            (not (strata-split-active-p))
            (when-let ((ap (and (fboundp 'strata-active-pane) (strata-active-pane))))
              (or (eq buf (strata-pane-state-buffer ap))
                  (let ((aw (strata-pane-state-window ap)))
                    (and (window-live-p aw) (eq buf (window-buffer aw)))))))
        (strata-watch--refresh-standalone-preview file changed-files subdir-only-p))))))

(defun strata-watch--refresh-parent-buffer (buf)
  "Refresh Dirvish Miller parent column BUF cleanly without moving focus."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (and (derived-mode-p 'dirvish-directory-view-mode)
                 (string-match-p "\\` ?\\*dirvish-parent-" (buffer-name buf)))
        (let* ((dv (and (fboundp 'dirvish-curr) (ignore-errors (dirvish-curr))))
               (dir (car-safe (car-safe dired-subdir-alist)))
               (abs (and dir (strata-watch--safe-dir-p dir))))
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
              (when (fboundp 'strata-dirvish--parent-buffer-filter)
                (strata-dirvish--parent-buffer-filter buf))
              (when (fboundp 'dirvish--render-attrs)
                (dolist (w (get-buffer-window-list buf nil t))
                  (ignore-errors (dirvish--render-attrs w 'never)))))))))))

(defun strata-watch--refresh-dired (buf files subdir-only-p)
  "Refresh Dired/Dirvish browser buffer BUF after filesystem changes."
  (if subdir-only-p
      (strata-watch--refresh-preview-for-buffer buf files t)
    (with-current-buffer buf
      (when (and default-directory (file-directory-p default-directory))
        (let ((inhibit-message t))
          (ignore-errors (revert-buffer t t)))
        (when (fboundp 'dirvish--redisplay)
          (ignore-errors (dirvish--redisplay)))
        (strata-watch--refresh-preview-for-buffer buf files nil)
        (when (fboundp 'strata-view--update-selection-highlight)
          (ignore-errors (strata-view--update-selection-highlight)))
        (strata-watch-sync buf)
        (force-mode-line-update t)))))

(defun strata-watch--refresh-compact-or-icons (buf files subdir-only-p)
  "Refresh Strata Compact or Icons view BUF after filesystem changes."
  (if subdir-only-p
      (strata-watch--refresh-preview-for-buffer buf files t)
    (with-current-buffer buf
      (let ((dir (or (bound-and-true-p strata-view-directory) default-directory))
            (win (get-buffer-window buf t)))
        (if (and (not noninteractive) (not win))
            (setq-local strata-watch--dirty t)
          (when (and dir (file-directory-p dir))
            (setq-local strata-watch--dirty nil)
            (when (bound-and-true-p strata-marked-entries)
              (setq strata-marked-entries
                    (cl-remove-if-not #'file-exists-p strata-marked-entries)))
            (let ((render-fn (lambda ()
                               (cond
                                ((derived-mode-p 'strata-compact-mode)
                                 (strata-compact-render dir))
                                ((derived-mode-p 'strata-icons-mode)
                                 (strata-icons-render dir))))))
              (if (window-live-p win)
                  (with-selected-window win (funcall render-fn))
                (funcall render-fn)))
            (strata-watch--refresh-preview-for-buffer buf files nil)
            (strata-watch-sync buf)
            (force-mode-line-update t)))))))

(defun strata-watch--refresh-virtual-or-sidebar (buf)
  "Refresh Trash, Recent, or Sidebar buffer BUF preserving point cleanly."
  (with-current-buffer buf
    (cond
     ((derived-mode-p 'strata-trash-mode)
      (let ((sel (ignore-errors (plist-get (strata-trash--item-at-point) :file))))
        (strata-trash-refresh)
        (when sel
          (goto-char (point-min))
          (while (and (not (eobp))
                      (not (equal (plist-get (get-text-property (point) 'strata-trash-item) :file)
                                  sel)))
            (forward-line 1))))
      (when (fboundp 'strata-sidebar-refresh)
        (strata-sidebar-refresh)))
     ((derived-mode-p 'strata-recent-mode)
      (let ((sel (get-text-property (line-beginning-position) 'strata-recent-path)))
        (strata-recent-refresh)
        (when sel
          (goto-char (point-min))
          (while (and (not (eobp))
                      (not (equal (get-text-property (point) 'strata-recent-path) sel)))
            (forward-line 1)))))
     ((derived-mode-p 'strata-sidebar-mode)
      (strata-sidebar-refresh)))))

(defun strata-watch--do-refresh (buf)
  "Execute debounced live refresh for buffer BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let* ((targets (prog1 (cl-delete-duplicates strata-watch--pending-targets :test #'equal)
                        (setq strata-watch--pending-targets nil)))
             (files (prog1 (cl-delete-duplicates strata-watch--pending-files :test #'equal)
                      (setq strata-watch--pending-files nil)))
             (subdir-only-p (and targets
                                 (cl-every (lambda (tk) (eq (car tk) 'preview-subdir))
                                           targets))))
        (setq strata-watch--timer nil)
        (cond
         ((derived-mode-p 'dired-mode)
          (strata-watch--refresh-dired buf files subdir-only-p))
         ((derived-mode-p 'strata-compact-mode 'strata-icons-mode)
          (strata-watch--refresh-compact-or-icons buf files subdir-only-p))
         ((derived-mode-p 'dirvish-directory-view-mode)
          (strata-watch--refresh-parent-buffer buf))
         ((derived-mode-p 'strata-trash-mode 'strata-recent-mode 'strata-sidebar-mode)
          (strata-watch--refresh-virtual-or-sidebar buf)))))))

(defun my/dired-fn--do-revert (buf)
  "Compatibility entrypoint refreshing browser buffer BUF safely."
  (strata-watch--do-refresh buf))

;;;; Notify Event Handler & Global Hooks

(defun strata-watch--relevant-event-p (kind file)
  "Return non-nil when notify event FILE matters for watcher KIND."
  (pcase kind
    ('recent (and (stringp file)
                  (string= (file-name-nondirectory file) "recently-used.xbel")))
    ('bookmarks (and (stringp file)
                     (string= (file-name-nondirectory file) "bookmarks")))
    (_ t)))

(defun strata-watch--handler (event)
  "Handle `file-notify' EVENT `(DESCR ACTION FILE [FILE1])' after debounce."
  (let* ((descr (car event))
         (action (nth 1 event))
         (file (nth 2 event))
         (file1 (nth 3 event))
         (entry (gethash descr strata-watch--table))
         (target (car entry))
         (kind (nth 1 entry))
         (dir (nth 2 entry)))
    (when strata-watch-debug
      (message "[strata-watch] %S -> buf=%S kind=%S live=%S"
               event target kind (and target (buffer-live-p target))))
    (cond
     ((eq action 'stopped)
      (remhash descr strata-watch--table)
      (when (buffer-live-p target)
        (with-current-buffer target
          (setq strata-watch--entries
                (cl-remove-if (lambda (pair) (equal (cdr pair) descr))
                              strata-watch--entries)))))
     ((not (buffer-live-p target))
      (remhash descr strata-watch--table)
      (ignore-errors (file-notify-rm-watch descr)))
     ((strata-watch--relevant-event-p kind file)
      (when (memq action '(changed attribute-changed created renamed-to renamed deleted))
        (strata-watch--invalidate-file-caches file)
        (when file1
          (strata-watch--invalidate-file-caches file1)))
      (with-current-buffer target
        (push (cons kind dir) strata-watch--pending-targets)
        (when (and (stringp file) (< (length strata-watch--pending-files) strata-watch--max-pending-files))
          (cl-pushnew file strata-watch--pending-files :test #'equal))
        (when (and (stringp file1) (< (length strata-watch--pending-files) strata-watch--max-pending-files))
          (cl-pushnew file1 strata-watch--pending-files :test #'equal))
        (when (timerp strata-watch--timer)
          (cancel-timer strata-watch--timer))
        ;; Short trailing debounce coalesces bulk copies into one crisp refresh.
        (setq strata-watch--timer
              (run-with-timer 0.1 nil #'strata-watch--do-refresh target)))))))

(defalias 'my/dired-fn-handler #'strata-watch--handler)

(defun strata-watch--on-window-buffer-change (&optional frame)
  "Re-render any Compact/Icons buffer in FRAME that changed while hidden."
  (dolist (win (window-list frame 'no-minibuf))
    (when (window-live-p win)
      (let ((buf (window-buffer win)))
        (when (and (buffer-live-p buf)
                   (buffer-local-value 'strata-watch--dirty buf))
          (strata-watch--refresh-compact-or-icons buf nil nil))))))

(defvar strata-watch--installed nil
  "Non-nil once global Strata/Dirvish filesystem watch hooks are installed.")

(defun strata-watch-install ()
  "Install live filesystem watch hooks across Strata views and existing buffers."
  (unless strata-watch--installed
    (setq strata-watch--installed t)
    (dolist (hook '(dired-mode-hook
                    dired-after-readin-hook
                    strata-compact-mode-hook
                    strata-icons-mode-hook
                    dirvish-directory-view-mode-hook
                    strata-trash-mode-hook
                    strata-recent-mode-hook
                    strata-sidebar-mode-hook))
      (add-hook hook #'strata-watch-setup))
    (add-hook 'post-command-hook #'strata-watch--post-command-sync)
    (add-hook 'window-buffer-change-functions #'strata-watch--on-window-buffer-change))
  ;; Retrofit any buffers created before installation (e.g. startup or reload).
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (derived-mode-p 'dired-mode
                              'strata-compact-mode
                              'strata-icons-mode
                              'dirvish-directory-view-mode
                              'strata-trash-mode
                              'strata-recent-mode
                              'strata-sidebar-mode)
          (strata-watch-setup))))))

(provide 'strata-dirvish-watch)
;;; strata-dirvish-watch.el ends here
