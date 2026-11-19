;;; enhanced-dirvish-devices.el --- Async devices, capacity bars, cloud/GVfs, and virtual locations -*- lexical-binding: t; -*-

;; Copyright (C) 2026 dragonleopardpig
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.  It is part of Enhanced Dirvish;
;; see enhanced-dirvish.el for the full license notice.

;;; Commentary:
;; Device discovery, async non-blocking FUSE/cloud capacity probing,
;; synthetic placeholder capacity filtering (>= 1 PiB), custom per-drive
;; icons, LUKS/udisksctl/gio mount actions, and interactive virtual buffers for
;; `computer:///', `trash:///', `recent:///', `network:///', and `admin:///'.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'enhanced-dirvish-prefs)

(defconst enhanced-dirvish-synthetic-capacity-threshold (expt 2 50)
  "Capacities >= 1 PiB reported by FUSE/rclone placeholders are treated as unknown.")

(defconst enhanced-dirvish-usage-valid-ttl 60.0
  "Seconds to cache valid disk capacity measurements for remote/FUSE mounts.")

(defconst enhanced-dirvish-usage-unknown-ttl 5.0
  "Seconds before retrying an unknown/unmeasured FUSE/remote capacity probe.")

(defvar enhanced-dirvish-devices-usage-cache (make-hash-table :test #'equal)
  "Cache mapping mount-point -> (USAGE . FLOAT-TIMESTAMP).
USAGE is nil or (TOTAL-BYTES . AVAIL-BYTES).")

(defvar enhanced-dirvish-devices-pending-probes (make-hash-table :test #'equal)
  "Set of mount-points currently being probed asynchronously.")

(defvar enhanced-dirvish-devices-refresh-hook nil
  "Hook run after async mount capacity probes or mount operations complete.")

(cl-defstruct enhanced-dirvish-device
  id                ; unique key (uuid or kname or mountpoint)
  name              ; display name
  device            ; e.g. /dev/nvme0n1p2 or rclone remote
  pkname            ; parent physical disk kname for grouping
  fstype            ; ext4, vfat, btrfs, crypto_LUKS, fuse.rclone, etc.
  mountpoint        ; local path or nil if unmounted/locked
  uuid
  model
  tran              ; nvme, usb, sata, etc.
  size              ; block size in bytes from lsblk
  placement         ; fixed | removable | cloud | network
  mounted-p
  locked-p          ; crypto_LUKS not unlocked yet
  fusermount-p      ; FUSE/network/cloud filesystem requiring async df probe
  usage)            ; nil or (TOTAL . AVAIL)

;;;; Synthetic Capacity Filtering & Formatting

(defun enhanced-dirvish-sanitize-capacity (total avail)
  "Sanitize raw filesystem capacity (TOTAL AVAIL).
Returns nil when TOTAL <= 0 or TOTAL >=
`enhanced-dirvish-synthetic-capacity-threshold'."
  (when (and (numberp total) (numberp avail)
             (> total 0)
             (< total enhanced-dirvish-synthetic-capacity-threshold))
    (cons (truncate total) (truncate (min (max 0 avail) total)))))

(defun enhanced-dirvish-format-capacity-bar (usage &optional width compact)
  "Render a color-coded disk space capacity bar for USAGE = (TOTAL . AVAIL)."
  (when usage
    (pcase-let ((`(,total . ,avail) usage))
      (when (> total 0)
        (let* ((used (max 0 (- total avail)))
               (ratio (min 1.0 (/ (float used) (float total))))
               (pct (* 100.0 ratio))
               (bar-w (or width 12))
               (filled (min bar-w (max 0 (round (* ratio bar-w)))))
               (empty (- bar-w filled))
               (face (cond
                      ((>= pct 90.0) 'enhanced-dirvish-bar-danger)
                      ((>= pct 80.0) 'enhanced-dirvish-bar-warn)
                      (t 'enhanced-dirvish-bar-ok)))
               (bar (concat
                     (propertize (make-string filled ?█) 'face face)
                     (propertize (make-string empty ?░) 'face 'shadow)))
               (free-str (enhanced-dirvish-format-drive-free-size avail total))
               (tot-str (enhanced-dirvish-format-bytes total)))
          (if compact
              (format "%s %s" bar free-str)
            (format "%s  %s free of %s (%.0f%%)" bar free-str tot-str pct)))))))

;;;; Custom Per-Drive / Cloud Icons

(defun enhanced-dirvish-nixos-system-p ()
  "Return non-nil when running on NixOS."
  (or (file-exists-p "/etc/NIXOS") (file-directory-p "/nix/store")))

(defun enhanced-dirvish-device-icon (dev)
  "Return a crisp icon glyph for `enhanced-dirvish-device' DEV."
  (let* ((name (downcase (or (enhanced-dirvish-device-name dev) "")))
         (mp (downcase (or (enhanced-dirvish-device-mountpoint dev) "")))
         (fstype (downcase (or (enhanced-dirvish-device-fstype dev) "")))
         (tran (downcase (or (enhanced-dirvish-device-tran dev) "")))
         (blob (concat name " " mp " " (downcase (or (enhanced-dirvish-device-device dev) ""))))
         (matches (lambda (needles)
                    (cl-some (lambda (n) (string-search n blob)) needles))))
    (cond
     ((enhanced-dirvish-device-locked-p dev) (enhanced-dirvish-icon-glyph 'lock))
     ((funcall matches '("google drive" "google-drive" "gdrive")) (enhanced-dirvish-icon-glyph 'gdrive))
     ((funcall matches '("proton drive" "proton-drive" "protondrive")) (enhanced-dirvish-icon-glyph 'proton))
     ((funcall matches '("filelu")) (enhanced-dirvish-icon-glyph 'cloud))
     ((or (funcall matches '("mega" "filen" "onedrive" "dropbox" "nextcloud" "rclone" "cloud"))
          (string-search "rclone" fstype)
          (eq (enhanced-dirvish-device-placement dev) 'cloud))
      (enhanced-dirvish-icon-glyph 'cloud))
     ((string= mp "/") (if (enhanced-dirvish-nixos-system-p)
                           (enhanced-dirvish-icon-glyph 'nixos)
                         (enhanced-dirvish-icon-glyph 'linux)))
     ((eq (enhanced-dirvish-device-placement dev) 'network) (enhanced-dirvish-icon-glyph 'globe))
     ((string= fstype "iso9660") (enhanced-dirvish-icon-glyph 'optical))
     ((or (string= tran "usb") (eq (enhanced-dirvish-device-placement dev) 'removable))
      (enhanced-dirvish-icon-glyph 'usb))
     ((string-search "nvme" (concat tran " " (or (enhanced-dirvish-device-device dev) "")))
      (enhanced-dirvish-icon-glyph 'nvme))
     (t (enhanced-dirvish-icon-glyph 'hdd)))))

;;;; Safe Mount Table Parsing & Async Probing

(defun enhanced-dirvish-parse-proc-mounts ()
  "Read /proc/mounts and return list of plists (:device :mount :fstype)."
  (when (file-readable-p "/proc/mounts")
    (with-temp-buffer
      (insert-file-contents "/proc/mounts")
      (let (res)
        (dolist (line (split-string (buffer-string) "\n" t))
          (let ((cols (split-string line " " t)))
            (when (>= (length cols) 3)
              (let ((dev (car cols))
                    (mp (cadr cols))
                    (fs (caddr cols)))
                ;; Decode octal escapes such as \040 for spaces
                (setq mp (replace-regexp-in-string
                          "\\\\040" " "
                          (replace-regexp-in-string "\\\\011" "\t" mp)))
                (push (list :device dev :mount mp :fstype fs) res)))))
        (nreverse res)))))

(defun enhanced-dirvish-mount--hidden-system-p (dev mp fstype)
  "Return non-nil if mount DEV at MP with FSTYPE should be hidden."
  (or (string-prefix-p "/dev/loop" dev)
      (string-prefix-p "/dev/zram" dev)
      (string-prefix-p "/dev/ram" dev)
      (member fstype '("proc" "sysfs" "devtmpfs" "devpts" "tmpfs" "cgroup" "cgroup2"
                       "pstore" "bpf" "tracefs" "debugfs" "securityfs" "efivarfs"
                       "configfs" "fusectl" "mqueue" "hugetlbfs" "ramfs" "autofs"
                       "squashfs" "overlay" "rpc_pipefs" "binfmt_misc" "nsfs"
                       "fuse.portal" "fuse.gvfsd-fuse"))
      (string-prefix-p "/proc" mp)
      (string-prefix-p "/sys" mp)
      (string-prefix-p "/dev" mp)
      (string-prefix-p "/nix/" mp)
      (and (string-prefix-p "/run/" mp)
           (not (string-prefix-p "/run/media/" mp))
           (not (string-prefix-p (format "/run/user/%d/gvfs/" (user-uid)) mp)))
      (string= mp "/boot")
      (string= mp "/boot/efi")))

(defvar enhanced-dirvish-mounts--cache nil
  "Cached parsed mount list (TIMESTAMP . ENTRIES) from /proc/mounts.")

(defconst enhanced-dirvish-mounts--cache-ttl 10.0
  "Seconds to cache /proc/mounts entries for instant path safety checks.")

(defvar enhanced-dirvish-devices-cache nil
  "Cached `enhanced-dirvish-device' structs, so startup and browsing are instant.")

(defvar enhanced-dirvish-devices-cache-time 0.0
  "Timestamp when `enhanced-dirvish-devices-cache' was last populated.")

(defvar enhanced-dirvish-devices-async-proc nil
  "Active background `lsblk' process if currently refreshing devices.")

(defun enhanced-dirvish-mounts--classify (dev mp fs)
  "Classify mount at MP of FSTYPE FS from DEV into cloud/network/removable/local."
  (cond
   ((or (member fs '("cifs" "smbfs" "nfs" "nfs4" "sshfs" "davfs"))
        (string-prefix-p (format "/run/user/%d/gvfs/sftp" (user-uid)) mp)
        (string-prefix-p (format "/run/user/%d/gvfs/smb" (user-uid)) mp))
    'network)
   ((enhanced-dirvish-mount--fuse-or-remote-p dev mp fs)
    'cloud)
   ((or (string-prefix-p "/run/media/" mp)
        (string-prefix-p "/media/" mp))
    'removable)
   (t 'local)))

(defun enhanced-dirvish-mounts--entries (&optional force)
  "Return cached mount entries ((CLEAN-MP KIND FS DEV) ...) from /proc/mounts."
  (let ((now (float-time)))
    (if (and (not force)
             enhanced-dirvish-mounts--cache
             (< (- now (car enhanced-dirvish-mounts--cache)) enhanced-dirvish-mounts--cache-ttl))
        (cdr enhanced-dirvish-mounts--cache)
      (let (out)
        (dolist (m (enhanced-dirvish-parse-proc-mounts))
          (let ((dev (plist-get m :device))
                (mp (plist-get m :mount))
                (fs (plist-get m :fstype)))
            (unless (enhanced-dirvish-mount--hidden-system-p dev mp fs)
              (push (list (if (string= mp "/") "/" (directory-file-name mp))
                          (enhanced-dirvish-mounts--classify dev mp fs)
                          fs dev)
                    out))))
        (setq enhanced-dirvish-mounts--cache (cons now out))
        out))))

(defun enhanced-dirvish-path-mount-kind (path)
  "Return the mount kind of PATH as a symbol.
One of `cloud', `network', `removable', `remote' or `local'.
Reads only cached /proc/mounts entries cleanly with zero blocking I/O."
  (cond
   ((not (and (stringp path) (not (string-empty-p path)))) 'local)
   ((file-remote-p path) 'remote)
   (t
    (let* ((norm (let ((p (directory-file-name (expand-file-name path))))
                   (if (string-empty-p p) "/" p)))
           (best-kind 'local)
           (best-len 0))
      (dolist (e (enhanced-dirvish-mounts--entries))
        (let* ((mp (nth 0 e))
               (len (length mp)))
          (when (and (> len best-len)
                     (or (string= norm mp)
                         (string-prefix-p (if (string= mp "/") "/" (concat mp "/"))
                                          norm)))
            (setq best-len len
                  best-kind (nth 1 e)))))
      best-kind))))

(defun enhanced-dirvish-path-unsafe-probe-p (path)
  "Return non-nil if probing inside PATH could hang.
That is the case on FUSE, network and removable mounts."
  (when (and (stringp path) (not (string-empty-p path)))
    (or (file-remote-p path)
        (memq (enhanced-dirvish-path-mount-kind path) '(cloud network remote removable))
        (when-let ((target (ignore-errors (file-symlink-p path))))
          (when (stringp target)
            (let ((resolved (expand-file-name target (or (file-name-directory path) "/"))))
              (memq (enhanced-dirvish-path-mount-kind resolved) '(cloud network remote removable))))))))

(defun enhanced-dirvish-path-writable-p (dir)
  "Return non-nil when DIR is writable, without statting remote or cloud mounts."
  (and dir (not (enhanced-dirvish-location-virtual-p dir))
       (or (not (eq (enhanced-dirvish-path-mount-kind dir) 'local))
           (ignore-errors (file-writable-p dir)))))

(defun enhanced-dirvish-archive-file-p (path)
  "Return non-nil when PATH has a supported archive filename extension."
  (and (stringp path)
       (string-match-p
        "\\.\\(?:zip\\|7z\\|tar\\|tgz\\|tbz2?\\|txz\\|tzst\\|gz\\|bz2\\|xz\\|zst\\|rar\\)\\'"
        (downcase (directory-file-name path)))))

(defun enhanced-dirvish-mount--fuse-or-remote-p (dev mp fstype)
  "Return non-nil if the mount needs a non-blocking async probe.
A synchronous statvfs could hang on it."
  (or (string-prefix-p "fuse." fstype)
      (member fstype '("fuse" "cifs" "smbfs" "nfs" "nfs4" "sshfs" "davfs" "9p"))
      (string-search ":" dev)
      (string-prefix-p (format "/run/user/%d/gvfs" (user-uid)) mp)))

(defun enhanced-dirvish-local-statvfs (path)
  "Query disk capacity cleanly ONLY for fast local block filesystems at PATH."
  (condition-case nil
      (when (and path (file-directory-p path))
        (let ((info (file-system-info path)))
          (when (and (listp info) (= (length info) 3))
            (enhanced-dirvish-sanitize-capacity (car info) (caddr info)))))
    (error nil)))

(defun enhanced-dirvish-probe-mount-async (mountpoint)
  "Launch non-blocking background capacity probe for MOUNTPOINT via `timeout -k'."
  (when (and mountpoint
             (not (gethash mountpoint enhanced-dirvish-devices-pending-probes))
             (executable-find "df")
             (executable-find "timeout"))
    (puthash mountpoint t enhanced-dirvish-devices-pending-probes)
    (let ((buf (generate-new-buffer (format " *enhanced-dirvish-df-%s*" (md5 mountpoint)))))
      (make-process
       :name (format "enhanced-dirvish-df-%s" mountpoint)
       :buffer buf
       :noquery t
       :command (list "timeout" "-k" "0.5" "2" "df" "-B1" "--output=size,avail" mountpoint)
       :sentinel
       (lambda (proc _event)
         (when (memq (process-status proc) '(exit signal))
           (unwind-protect
               (let ((usage nil))
                 (when (and (= (process-exit-status proc) 0)
                            (buffer-live-p (process-buffer proc)))
                   (with-current-buffer (process-buffer proc)
                     (let ((lines (split-string (buffer-string) "\n" t)))
                       (when (>= (length lines) 2)
                         (let ((cols (split-string (string-trim (cadr lines)) "[ \t]+" t)))
                           (when (= (length cols) 2)
                             (setq usage
                                   (enhanced-dirvish-sanitize-capacity
                                    (string-to-number (car cols))
                                    (string-to-number (cadr cols))))))))))
                 (puthash mountpoint (cons usage (float-time)) enhanced-dirvish-devices-usage-cache))
             (remhash mountpoint enhanced-dirvish-devices-pending-probes)
             (when (buffer-live-p (process-buffer proc))
               (kill-buffer (process-buffer proc)))
             (run-hooks 'enhanced-dirvish-devices-refresh-hook))))))))

(defun enhanced-dirvish-filesystem-usage (path &optional fusermount-p allow-async-probe)
  "Return (TOTAL . AVAIL) for PATH cleanly without ever blocking on FUSE/cloud.
If FUSERMOUNT-P is non-nil (or PATH matches FUSE/GVfs), uses cache and triggers
async background probe only when ALLOW-ASYNC-PROBE is non-nil."
  (when (and path (stringp path) (not (string-empty-p path)))
    (if (and (not fusermount-p)
             (not (string-prefix-p (format "/run/user/%d/gvfs" (user-uid)) path))
             (not (string-search "Drive" path))
             (or (string= path "/") (string-prefix-p "/run/media/" path)))
        (enhanced-dirvish-local-statvfs path)
      (let* ((now (float-time))
             (cached (gethash path enhanced-dirvish-devices-usage-cache))
             (usage (car cached))
             (ts (or (cdr cached) 0.0))
             (ttl (if usage enhanced-dirvish-usage-valid-ttl enhanced-dirvish-usage-unknown-ttl)))
        (when (and allow-async-probe
                   (or (null cached) (>= (- now ts) ttl)))
          (enhanced-dirvish-probe-mount-async path))
        usage))))

;;;; Device Discovery & Drive Grouping

(defconst enhanced-dirvish-devices--lsblk-cols
  "NAME,KNAME,PKNAME,TYPE,FSTYPE,LABEL,PARTLABEL,PARTTYPE,MOUNTPOINT,SIZE,RM,HOTPLUG,TRAN,MODEL,UUID,FSSIZE,FSAVAIL"
  "Columns queried from `lsblk -J -b'.")

(defun enhanced-dirvish-devices--lsblk ()
  "Run `lsblk -J -b' synchronously (<50ms) and return parsed blockdevices list."
  (when (executable-find "lsblk")
    (condition-case nil
        (with-temp-buffer
          (when (= 0 (process-file
                      "lsblk" nil t nil
                      "-J" "-b" "-o" enhanced-dirvish-devices--lsblk-cols))
            (let* ((json-object-type 'alist)
                   (json-array-type 'list)
                   (json-key-type 'symbol)
                   (data (json-read-from-string (buffer-string))))
              (alist-get 'blockdevices data))))
      (error nil))))

(defun enhanced-dirvish-devices--custom-label (id default-name)
  "Return user's custom label for device ID, or DEFAULT-NAME."
  (or (cdr (assoc id (enhanced-dirvish-prefs-device-labels (enhanced-dirvish-prefs))))
      default-name))

(defun enhanced-dirvish-devices-set-label (id label)
  "Set custom display LABEL for device ID (blank clears custom label)."
  (let* ((p (enhanced-dirvish-prefs))
         (tbl (assoc-delete-all id (enhanced-dirvish-prefs-device-labels p))))
    (unless (string-empty-p (string-trim label))
      (push (cons id (string-trim label)) tbl))
    (setf (enhanced-dirvish-prefs-device-labels p) tbl)
    (enhanced-dirvish-prefs-save)
    (setq enhanced-dirvish-devices-cache nil)
    (run-hooks 'enhanced-dirvish-devices-refresh-hook)))

(defconst enhanced-dirvish-devices--hidden-parttypes
  '("c12a7328-f81f-11d2-ba4b-00a0c93ec93b"  ; EFI System Partition
    "e3c9e316-0b5c-4db8-817d-f92df00215ae"  ; Microsoft Reserved Partition
    "de94bba4-06d1-4d40-a16a-bfd50179d6ac") ; Windows Recovery Environment
  "GPT PARTTYPE UUIDs for OS partitions omitted from drive lists.")

(defconst enhanced-dirvish-devices--generic-partlabels
  '("basic data partition" "linux filesystem" "efi system partition"
    "microsoft reserved partition" "primary" "data")
  "Generic GPT PARTLABEL strings not used as volume names.")

(defun enhanced-dirvish-devices--hash-name-p (s &optional uuid)
  "Return non-nil when S looks like a raw UUID, FAT/NTFS serial, or mapper hash."
  (let ((trim (and (stringp s) (string-trim s))))
    (when (and trim (not (string-empty-p trim)))
      (let ((case-fold-search t))
        (or (and uuid (not (string-empty-p uuid))
                 (string-equal-ignore-case trim (string-trim uuid)))
            (string-match-p "\\`[0-9a-f]\\{8\\}\\(-[0-9a-f]\\{4\\}\\)\\{3\\}-[0-9a-f]\\{12\\}\\'" trim)
            (string-match-p "\\`[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}\\'" trim)
            (string-match-p "\\`luks-[0-9a-f-]+\\'" trim)
            (string-match-p "\\`dm-[0-9]+\\'" trim)
            (and (>= (length trim) 16)
                 (string-match-p "\\`[0-9a-f-]+\\'" trim)))))))

(defun enhanced-dirvish-devices--readable-name (mp label partlabel size uuid model dev-name)
  "Compute a short, human-readable volume name instead of UUID or hash paths."
  (let* ((lbl (and (stringp label) (string-trim label)))
         (plbl (and (stringp partlabel) (string-trim partlabel)))
         (mp-base (and (stringp mp) (not (string-empty-p mp))
                       (file-name-nondirectory (directory-file-name mp))))
         (mdl (and (stringp model) (string-trim model))))
    (cond
     ((string= mp "/") "File System")
     ((and lbl (not (string-empty-p lbl))
           (not (enhanced-dirvish-devices--hash-name-p lbl uuid)))
      lbl)
     ((and plbl (not (string-empty-p plbl))
           (not (member (downcase plbl) enhanced-dirvish-devices--generic-partlabels))
           (not (enhanced-dirvish-devices--hash-name-p plbl uuid)))
      plbl)
     ((and mp-base (not (string-empty-p mp-base))
           (not (enhanced-dirvish-devices--hash-name-p mp-base uuid)))
      mp-base)
     ((and (numberp size) (> size 0))
      (format "%s Volume" (enhanced-dirvish-format-bytes size 'metric)))
     ((and mdl (not (string-empty-p mdl))) mdl)
     ((and (stringp dev-name) (not (string-empty-p dev-name))) dev-name)
     (t "Volume"))))

(defun enhanced-dirvish-devices--flatten-lsblk (nodes &optional parent-tran parent-rm parent-model parent-pk)
  "Flatten nested `lsblk' tree NODES into usable `enhanced-dirvish-device' structs."
  (let (out)
    (dolist (node nodes)
      (let* ((name (alist-get 'name node))
             (kname (or (alist-get 'kname node) name))
             (pk (or (alist-get 'pkname node) parent-pk kname))
             (dtype (alist-get 'type node))
             (fstype (or (alist-get 'fstype node) ""))
             (label (alist-get 'label node))
             (partlabel (alist-get 'partlabel node))
             (parttype (alist-get 'parttype node))
             (mp (alist-get 'mountpoint node))
             (size (alist-get 'size node))
             (fssize (alist-get 'fssize node))
             (fsavail (alist-get 'fsavail node))
             (rm (or (alist-get 'rm node) parent-rm))
             (hotplug (alist-get 'hotplug node))
             (tran (or (alist-get 'tran node) parent-tran ""))
             (model (or (alist-get 'model node) parent-model ""))
             (uuid (alist-get 'uuid node))
             (children (alist-get 'children node))
             (devpath (when kname (concat "/dev/" kname)))
             (removable (or (eq rm t) (equal rm 1) (eq hotplug t) (equal hotplug 1)
                            (string= tran "usb")))
             (encrypted (member fstype '("crypto_LUKS" "BitLocker")))
             (locked (and encrypted (null children)))
             (unlocked-container (and encrypted (not (null children))))
             (hidden-part (and (not mp)
                               (member (downcase (or parttype ""))
                                       enhanced-dirvish-devices--hidden-parttypes)))
             (interesting (and (not (member dtype '("loop" "zram" "ram" "rom")))
                               (not (string= fstype "swap"))
                               (not unlocked-container)
                               (not hidden-part)
                               (or (and mp (not (enhanced-dirvish-mount--hidden-system-p (or devpath "") mp fstype)))
                                   locked
                                   (and (member dtype '("part" "crypt"))
                                        (not (string-empty-p fstype))
                                        (not (member mp '("/boot" "/boot/efi" "[SWAP]"))))))))
        (when interesting
          (let* ((id (or uuid kname mp))
                 (usage (cond
                         ((and (numberp fssize) (numberp fsavail))
                          (enhanced-dirvish-sanitize-capacity fssize fsavail))
                         ((and mp (string= mp "/"))
                          (enhanced-dirvish-local-statvfs mp))
                         (t nil)))
                 (cap-bytes (or (and (numberp size) (> size 0) size)
                                (and (numberp fssize) (> fssize 0) fssize)
                                (car usage)))
                 (raw-name (enhanced-dirvish-devices--readable-name
                            mp label partlabel cap-bytes uuid model name))
                 (placement (if removable 'removable 'fixed)))
            (push (make-enhanced-dirvish-device
                   :id id
                   :name (enhanced-dirvish-devices--custom-label id raw-name)
                   :device devpath
                   :pkname pk
                   :fstype fstype
                   :mountpoint mp
                   :uuid uuid
                   :model (and model (string-trim model))
                   :tran tran
                   :size (and (numberp size) size)
                   :placement placement
                   :mounted-p (not (null mp))
                   :locked-p locked
                   :fusermount-p nil
                   :usage usage)
                  out)))
        (when children
          (setq out (append out (enhanced-dirvish-devices--flatten-lsblk
                                 children tran rm model (or pk parent-pk kname name)))))))
    (nreverse out)))

(defun enhanced-dirvish-devices--assemble (raw-block-devs &optional probe-fuse)
  "Sorted `enhanced-dirvish-device' list from RAW-BLOCK-DEVS and /proc/mounts."
  (let* ((block-devs (enhanced-dirvish-devices--flatten-lsblk raw-block-devs))
         (seen-mps (let ((ht (make-hash-table :test #'equal)))
                     (dolist (d block-devs)
                       (when (enhanced-dirvish-device-mountpoint d)
                         (puthash (enhanced-dirvish-device-mountpoint d) t ht)))
                     ht))
         (extra-devs nil))
    (unless (gethash "/" seen-mps)
      (puthash "/" t seen-mps)
      (push (make-enhanced-dirvish-device
             :id "root-fs"
             :name (enhanced-dirvish-devices--custom-label "root-fs" "File System")
             :device "/"
             :pkname "root"
             :fstype "root"
             :mountpoint "/"
             :placement 'fixed
             :mounted-p t
             :usage (enhanced-dirvish-local-statvfs "/"))
            extra-devs))
    (dolist (m (enhanced-dirvish-parse-proc-mounts))
      (let ((dev (plist-get m :device))
            (mp (plist-get m :mount))
            (fs (plist-get m :fstype)))
        (unless (or (gethash mp seen-mps)
                    (enhanced-dirvish-mount--hidden-system-p dev mp fs))
          (when (or (enhanced-dirvish-mount--fuse-or-remote-p dev mp fs)
                    (string-prefix-p "/run/media/" mp))
            (puthash mp t seen-mps)
            (let* ((fusep (enhanced-dirvish-mount--fuse-or-remote-p dev mp fs))
                   (netp (or (member fs '("cifs" "smbfs" "nfs" "nfs4" "sshfs" "davfs"))
                             (string-prefix-p (format "/run/user/%d/gvfs/sftp" (user-uid)) mp)
                             (string-prefix-p (format "/run/user/%d/gvfs/smb" (user-uid)) mp)))
                   (placement (cond (netp 'network) (fusep 'cloud) (t 'removable)))
                   (usage (enhanced-dirvish-filesystem-usage mp fusep probe-fuse))
                   (base-name (file-name-nondirectory (directory-file-name mp)))
                   (readable (enhanced-dirvish-devices--readable-name
                              mp nil nil (car usage) nil nil base-name))
                   (id (concat "mp:" mp)))
              (push (make-enhanced-dirvish-device
                     :id id
                     :name (enhanced-dirvish-devices--custom-label id readable)
                     :device dev
                     :pkname id
                     :fstype fs
                     :mountpoint mp
                     :placement placement
                     :mounted-p t
                     :fusermount-p fusep
                     :usage usage)
                    extra-devs))))))
    (let* ((all (append block-devs (nreverse extra-devs)))
           (rank (lambda (pl)
                   (pcase pl
                     ('fixed 0)
                     ('removable 1)
                     ('cloud 2)
                     ('network 3)
                     (_ 4))))
           (sorted
            (cl-stable-sort
             all
             (lambda (a b)
               (let ((ra (funcall rank (enhanced-dirvish-device-placement a)))
                     (rb (funcall rank (enhanced-dirvish-device-placement b))))
                 (if (/= ra rb)
                     (< ra rb)
                   (if (equal (enhanced-dirvish-device-mountpoint a) "/")
                       t
                     (if (equal (enhanced-dirvish-device-mountpoint b) "/")
                         nil
                       (string-lessp (or (enhanced-dirvish-device-pkname a) "")
                                     (or (enhanced-dirvish-device-pkname b) ""))))))))))
      (setq enhanced-dirvish-devices-cache sorted
            enhanced-dirvish-devices-cache-time (float-time))
      sorted)))

(defun enhanced-dirvish-devices-list (&optional probe-fuse)
  "Return `enhanced-dirvish-device' objects in order, grouped by placement.
Updates `enhanced-dirvish-devices-cache'. FUSE/cloud mounts only probe async
when
PROBE-FUSE is non-nil."
  (enhanced-dirvish-devices--assemble (enhanced-dirvish-devices--lsblk) probe-fuse))

(defun enhanced-dirvish-devices-refresh-async (&optional probe-fuse callback)
  "Fill `enhanced-dirvish-devices-cache' asynchronously via non-blocking `lsblk'."
  (when (and (not (process-live-p enhanced-dirvish-devices-async-proc))
             (executable-find "lsblk"))
    (let ((buf (generate-new-buffer " *enhanced-dirvish-lsblk*")))
      (setq enhanced-dirvish-devices-async-proc
            (make-process
             :name "enhanced-dirvish-lsblk"
             :buffer buf
             :noquery t
             :connection-type 'pipe
             :command (list "lsblk" "-J" "-b" "-o" enhanced-dirvish-devices--lsblk-cols)
             :sentinel
             (lambda (proc _ev)
               (when (memq (process-status proc) '(exit signal))
                 (unwind-protect
                     (when (and (= 0 (process-exit-status proc))
                                (buffer-live-p (process-buffer proc)))
                       (let* ((json-object-type 'alist)
                              (json-array-type 'list)
                              (json-key-type 'symbol)
                              (data (ignore-errors
                                      (with-current-buffer (process-buffer proc)
                                        (json-read-from-string (buffer-string)))))
                              (raw (alist-get 'blockdevices data)))
                         (enhanced-dirvish-devices--assemble raw probe-fuse)
                         (run-hooks 'enhanced-dirvish-devices-refresh-hook)
                         (when callback (funcall callback enhanced-dirvish-devices-cache))))
                   (setq enhanced-dirvish-devices-async-proc nil)
                   (when (buffer-live-p (process-buffer proc))
                     (kill-buffer (process-buffer proc)))))))))))

;;;; Device Actions (Mount / Unmount / Eject / Unlock / Lock with GVfs Fallback)

(defun enhanced-dirvish-device--run-async (label cmd on-done &optional stdin-text env-extra)
  "Run external device command CMD asynchronously.
Optional STDIN-TEXT and ENV-EXTRA are passed on to it."
  (let* ((process-environment (if env-extra
                                  (append env-extra process-environment)
                                process-environment))
         (buf (generate-new-buffer (format " *enhanced-dirvish-dev-%s*" label)))
         (proc (make-process
                :name (format "enhanced-dirvish-%s" label)
                :buffer buf
                :noquery t
                :connection-type 'pipe
                :command cmd
                :sentinel
                (lambda (p _ev)
                  (when (memq (process-status p) '(exit signal))
                    (let ((ok (= 0 (process-exit-status p)))
                          (out (if (buffer-live-p (process-buffer p))
                                   (with-current-buffer (process-buffer p)
                                     (string-trim (buffer-string)))
                                 "")))
                      (when (buffer-live-p (process-buffer p))
                        (kill-buffer (process-buffer p)))
                      (run-hooks 'enhanced-dirvish-devices-refresh-hook)
                      (when on-done (funcall on-done ok out))))))))
    (when stdin-text
      (process-send-string proc (concat stdin-text "\n"))
      (process-send-eof proc))
    proc))

(defun enhanced-dirvish-device-mount (dev &optional callback)
  "Mount or unlock `enhanced-dirvish-device' DEV cleanly without freezing Emacs."
  (cond
   ((enhanced-dirvish-device-mounted-p dev)
    (when callback (funcall callback (enhanced-dirvish-device-mountpoint dev))))
   ((enhanced-dirvish-device-locked-p dev)
    (let ((pw (enhanced-dirvish-ui-read-passwd (format "Unlock passphrase for %s (%s): "
                                   (enhanced-dirvish-device-name dev)
                                   (enhanced-dirvish-device-device dev)))))
      (when (executable-find "udisksctl")
        (enhanced-dirvish-device--run-async
         "unlock"
         (list "udisksctl" "unlock" "-b" (enhanced-dirvish-device-device dev) "--no-user-interaction")
         (lambda (ok out)
           (if (not ok)
               (progn
                 (clear-string pw)
                 (message "Unlock failed: %s%s" out
                          (if (string= (enhanced-dirvish-device-fstype dev) "BitLocker")
                              " (BitLocker requires cryptsetup bitlkOpen)"
                            "")))
             (message "Unlocked %s" (enhanced-dirvish-device-name dev))
             (clear-string pw)
             ;; Auto-mount the newly unlocked mapper device after short delay
             (run-at-time 0.4 nil
                          (lambda ()
                            (when-let ((found (cl-find-if
                                               (lambda (d)
                                                 (and (not (enhanced-dirvish-device-locked-p d))
                                                      (string-search (or (file-name-nondirectory
                                                                          (enhanced-dirvish-device-device dev))
                                                                         "")
                                                                     (or (enhanced-dirvish-device-pkname d) ""))))
                                               (enhanced-dirvish-devices-list))))
                              (if (enhanced-dirvish-device-mountpoint found)
                                  (when callback (funcall callback (enhanced-dirvish-device-mountpoint found)))
                                (enhanced-dirvish-device-mount found callback)))))))
         pw))))
   ((and (enhanced-dirvish-device-device dev) (executable-find "udisksctl"))
    (enhanced-dirvish-device--run-async
     "mount"
     (list "udisksctl" "mount" "-b" (enhanced-dirvish-device-device dev) "--no-user-interaction")
     (lambda (ok out)
       (if (not ok)
           (message "Mount failed: %s" out)
         (let ((mp (when (string-match "Mounted .* at \\(.+\\)\\.?\\'" out)
                     (string-trim-right (match-string 1 out) "."))))
           (message "Mounted %s%s" (enhanced-dirvish-device-name dev)
                    (if mp (format " at %s" mp) ""))
           (when (and mp callback) (funcall callback mp)))))))))

(defun enhanced-dirvish-device-unmount (dev)
  "Unmount `enhanced-dirvish-device' DEV, falling back to the GVfs unix monitor."
  (let ((mp (enhanced-dirvish-device-mountpoint dev))
        (blk (enhanced-dirvish-device-device dev)))
    (cond
     ((not (enhanced-dirvish-device-mounted-p dev))
      (message "%s is not mounted" (enhanced-dirvish-device-name dev)))
     ((string= mp "/")
      (user-error "Cannot unmount root File System"))
     ((and (enhanced-dirvish-device-fusermount-p dev) mp)
      (if (executable-find "gio")
          (enhanced-dirvish-device--run-async
           "gio-unmount"
           (list "gio" "mount" "-u" mp)
           (lambda (ok out)
             (if ok
                 (message "Unmounted %s" (enhanced-dirvish-device-name dev))
               (if (executable-find "fusermount3")
                   (enhanced-dirvish-device--run-async
                    "fusermount" (list "fusermount3" "-u" mp)
                    (lambda (ok2 out2)
                      (message "%s" (if ok2 (format "Unmounted %s" (enhanced-dirvish-device-name dev)) out2))))
                 (message "Unmount failed: %s" out))))
           nil '("GIO_USE_VOLUME_MONITOR=unix"))
        (enhanced-dirvish-device--run-async
         "fusermount" (list "fusermount" "-u" mp)
         (lambda (ok out) (message "%s" (if ok "Unmounted" out))))))
     ((and blk (string-prefix-p "/dev/" blk) (executable-find "udisksctl"))
      (enhanced-dirvish-device--run-async
       "unmount"
       (list "udisksctl" "unmount" "-b" blk "--no-user-interaction")
       (lambda (ok out)
         (message "%s" (if ok (format "Unmounted %s" (enhanced-dirvish-device-name dev)) out))))))))

(defun enhanced-dirvish-device-eject (dev)
  "Unmount and safely power off removable drive DEV."
  (let ((blk (enhanced-dirvish-device-device dev)))
    (if (not (and blk (string-prefix-p "/dev/" blk) (executable-find "udisksctl")))
        (enhanced-dirvish-device-unmount dev)
      (let ((eject-fn (lambda ()
                        (enhanced-dirvish-device--run-async
                         "power-off"
                         (list "udisksctl" "power-off" "-b" blk)
                         (lambda (ok out)
                           (message "%s" (if ok (format "Safely removed %s" (enhanced-dirvish-device-name dev)) out)))))))
        (if (enhanced-dirvish-device-mounted-p dev)
            (enhanced-dirvish-device--run-async
             "unmount-eject"
             (list "udisksctl" "unmount" "-b" blk "--no-user-interaction")
             (lambda (ok out)
               (if ok (funcall eject-fn) (message "Unmount failed: %s" out))))
          (funcall eject-fn))))))

;;;; URI / Virtual Location Helpers

(defconst enhanced-dirvish-virtual-locations
  '("computer:///" "trash:///" "recent:///" "network:///")
  "Virtual URIs supported natively inside `enhanced-dirvish'.")

(defun enhanced-dirvish-location-virtual-p (loc)
  "Return non-nil if LOC is a virtual location (not a writable directory)."
  (and (stringp loc)
       (or (string-prefix-p "computer://" loc)
           (string-prefix-p "trash://" loc)
           (string-prefix-p "recent://" loc)
           (string-prefix-p "network://" loc))))

(defun enhanced-dirvish-computer-location-p (loc)
  "Return non-nil when LOC is inside `computer:///'."
  (and (stringp loc) (string-prefix-p "computer://" loc)))

(defun enhanced-dirvish-guard-writable-location (loc &optional op-name)
  "Signal a clear `user-error' if LOC is read-only / virtual for OP-NAME."
  (when (enhanced-dirvish-location-virtual-p loc)
    (user-error "%s is not allowed inside virtual view %s"
                (or op-name "This action") loc)))

(defun enhanced-dirvish-resolve-location-uri (uri)
  "Translate URI to a target that can be opened.
URI may be `~', `admin:///', `sftp://', `smb://' or a virtual URI."
  (let ((u (string-trim (or uri ""))))
    (cond
     ((member u '("computer://" "computer:///")) "computer:///")
     ((member u '("trash://" "trash:///")) "trash:///")
     ((member u '("recent://" "recent:///")) "recent:///")
     ((member u '("network://" "network:///")) "network:///")
     ((string-prefix-p "admin:///" u)
      (concat "/sudo::/" (string-remove-prefix "admin:///" u)))
     ((string-prefix-p "file:///" u)
      (url-unhex-string (string-remove-prefix "file://" u)))
     ((string-match "\\`\\(sftp\\|ssh\\)://\\([^/@]+@\\)?\\([^/:]+\\)\\(:[0-9]+\\)?\\(/.*\\)?\\'" u)
      (let ((user (or (match-string 2 u) ""))
            (host (match-string 3 u))
            (port (let ((p (match-string 4 u)))
                    (if p (concat "#" (substring p 1)) "")))
            (path (or (match-string 5 u) "/")))
        (format "/ssh:%s%s%s:%s" user host port path)))
     ((string-match "\\`smb://\\([^/@]+@\\)?\\([^/]+\\)\\(/.*\\)?\\'" u)
      (let* ((gvfs-dir (format "/run/user/%d/gvfs" (user-uid)))
             (host (match-string 2 u))
             (path (or (match-string 3 u) "")))
        ;; Prefer mounted gvfs smb share if present, else try gio mount
        (or (car (directory-files gvfs-dir t (format "smb-share.*server=%s" (regexp-quote host)) t))
            (progn
              (when (executable-find "gio")
                (ignore-errors (process-file "gio" nil nil nil "mount" u)))
              (or (car (directory-files gvfs-dir t (format "smb-share.*server=%s" (regexp-quote host)) t))
                  (concat "/smb:" host ":" path))))))
     (t (expand-file-name u)))))

;;;; Virtual Buffer Modes: computer:///, trash:///, recent:///, network:///

(declare-function enhanced-dirvish-open-location "enhanced-dirvish-panes" (loc &optional record-history))
(declare-function enhanced-dirvish-show-properties-for-path "enhanced-dirvish-ops" (path &optional device))

(defvar enhanced-dirvish-computer-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'enhanced-dirvish-computer-open-at-point)
    (define-key map (kbd "l") #'enhanced-dirvish-computer-open-at-point)
    (define-key map (kbd "<right>") #'enhanced-dirvish-computer-open-at-point)
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "m") #'enhanced-dirvish-computer-mount-at-point)
    (define-key map (kbd "u") #'enhanced-dirvish-computer-unmount-at-point)
    (define-key map (kbd "E") #'enhanced-dirvish-computer-eject-at-point)
    (define-key map (kbd "e") #'enhanced-dirvish-computer-rename-label-at-point)
    (define-key map (kbd "P") #'enhanced-dirvish-computer-properties-at-point)
    (define-key map (kbd "M-RET") #'enhanced-dirvish-computer-properties-at-point)
    (define-key map (kbd "<mouse-1>") #'enhanced-dirvish-computer-mouse-open)
    (define-key map (kbd "<mouse-2>") #'enhanced-dirvish-computer-mouse-open)
    (define-key map (kbd "<double-mouse-1>") #'enhanced-dirvish-computer-mouse-open)
    (define-key map (kbd "g") #'enhanced-dirvish-computer-refresh)
    map)
  "Keymap for `computer:///' buffer.")

(defun enhanced-dirvish-computer-mouse-open (event)
  "Select device entry at EVENT and open or mount it."
  (interactive "e")
  (mouse-set-point event)
  (when (get-text-property (line-beginning-position) 'enhanced-dirvish-device)
    (enhanced-dirvish-computer-open-at-point)))

(defvar enhanced-dirvish-computer--row-keymap
  (let ((km (make-sparse-keymap)))
    (define-key km (kbd "<mouse-1>") #'enhanced-dirvish-computer-mouse-open)
    (define-key km (kbd "<mouse-2>") #'enhanced-dirvish-computer-mouse-open)
    (define-key km (kbd "<double-mouse-1>") #'enhanced-dirvish-computer-mouse-open)
    km)
  "Row-level mouse keymap for clickable drive entries.")

(define-derived-mode enhanced-dirvish-computer-mode special-mode "Enhanced-Dirvish-Computer"
  "Interactive `computer:///' view with drive grouping & live capacity bars."
  (setq-local truncate-lines t)
  (setq-local header-line-format
              (concat "  "
                      (enhanced-dirvish-icon-glyph 'computer 'enhanced-dirvish-header-accent)
                      (propertize "  Computer (computer:///)  —  Click/RET: Open  m: Mount/Unlock  u: Unmount  E: Eject  e: Rename Label  g: Refresh"
                                  'face 'enhanced-dirvish-header-accent)))
  (hl-line-mode 1)
  (add-hook 'enhanced-dirvish-devices-refresh-hook #'enhanced-dirvish-computer-refresh-all nil t))

(defun enhanced-dirvish-computer-render ()
  "Render grouped drives and capacity bars into current `computer:///' buffer."
  (let ((inhibit-read-only t)
        (pt (point))
        (devs (enhanced-dirvish-devices-list t))
        (last-group nil))
    (erase-buffer)
    (insert (propertize "  Locations & Drives\n" 'face 'enhanced-dirvish-section-heading))
    (dolist (dev devs)
      (let* ((grp (pcase (enhanced-dirvish-device-placement dev)
                    ('fixed "Internal Drives")
                    ('removable "Removable Drives")
                    ('cloud "Cloud Drives")
                    ('network "Network Shares")
                    (_ "Other Drives"))))
        (unless (equal grp last-group)
          (setq last-group grp)
          (insert "\n  " (propertize (upcase grp) 'face 'enhanced-dirvish-section-heading) "\n"))
        (let* ((icon (enhanced-dirvish-device-icon dev))
               (name (enhanced-dirvish-device-name dev))
               (mp (enhanced-dirvish-device-mountpoint dev))
               (sub (cond
                     ((enhanced-dirvish-device-locked-p dev)
                      (propertize (format "%s (%s%s) — press [m] to unlock"
                                          (if (string= (enhanced-dirvish-device-fstype dev) "BitLocker")
                                              "BitLocker Encrypted"
                                            "Encrypted")
                                          (or (enhanced-dirvish-device-device dev) "")
                                          (if (enhanced-dirvish-device-size dev)
                                              (format " · %s" (enhanced-dirvish-format-bytes (enhanced-dirvish-device-size dev) 'metric))
                                            ""))
                                  'face 'warning))
                     ((not (enhanced-dirvish-device-mounted-p dev))
                      (propertize (format "Unmounted · %s%s — press [m] to mount"
                                          (or (enhanced-dirvish-device-device dev) "")
                                          (if (enhanced-dirvish-device-size dev)
                                              (format " · %s" (enhanced-dirvish-format-bytes (enhanced-dirvish-device-size dev)))
                                            ""))
                                  'face 'shadow))
                     ((enhanced-dirvish-device-usage dev)
                      (enhanced-dirvish-format-capacity-bar (enhanced-dirvish-device-usage dev) 18 nil))
                     ((enhanced-dirvish-device-fusermount-p dev)
                      (propertize (format "Mounted at %s (probing capacity…)" mp) 'face 'shadow))
                     (t (propertize (format "Mounted at %s" mp) 'face 'shadow))))
               (line (format "   %s  %-26s  %s\n"
                             icon
                             (propertize name 'face (if (enhanced-dirvish-device-mounted-p dev)
                                                       'dired-directory
                                                     'default))
                             sub)))
          (insert (enhanced-dirvish-add-row-properties
                   line (list 'enhanced-dirvish-device dev
                              'mouse-face 'highlight
                              'pointer 'hand
                              'keymap enhanced-dirvish-computer--row-keymap
                              'help-echo (or mp (enhanced-dirvish-device-device dev) name)))))))
    (goto-char (min pt (point-max)))))

(defun enhanced-dirvish-computer-refresh ()
  "Refresh current `computer:///' buffer."
  (interactive)
  (when (derived-mode-p 'enhanced-dirvish-computer-mode)
    (enhanced-dirvish-computer-render)))

(defun enhanced-dirvish-computer-refresh-all ()
  "Refresh all open `computer:///' buffers silently."
  (dolist (b (buffer-list))
    (when (and (buffer-live-p b)
               (with-current-buffer b (derived-mode-p 'enhanced-dirvish-computer-mode)))
      (with-current-buffer b
        (enhanced-dirvish-computer-render)))))

(defun enhanced-dirvish-computer--device-at-point ()
  "Return `enhanced-dirvish-device' on current line."
  (or (get-text-property (line-beginning-position) 'enhanced-dirvish-device)
      (user-error "No drive on this line")))

(defun enhanced-dirvish-computer-open-at-point ()
  "Open mounted drive at point or mount/unlock it first then open."
  (interactive)
  (let ((dev (enhanced-dirvish-computer--device-at-point)))
    (if (enhanced-dirvish-device-mounted-p dev)
        (enhanced-dirvish-open-location (enhanced-dirvish-device-mountpoint dev))
      (enhanced-dirvish-device-mount dev #'enhanced-dirvish-open-location))))

(defun enhanced-dirvish-computer-mount-at-point ()
  "Mount or unlock drive at point."
  (interactive)
  (enhanced-dirvish-device-mount (enhanced-dirvish-computer--device-at-point)))

(defun enhanced-dirvish-computer-unmount-at-point ()
  "Unmount drive at point."
  (interactive)
  (enhanced-dirvish-device-unmount (enhanced-dirvish-computer--device-at-point)))

(defun enhanced-dirvish-computer-eject-at-point ()
  "Safely eject drive at point."
  (interactive)
  (enhanced-dirvish-device-eject (enhanced-dirvish-computer--device-at-point)))

(defun enhanced-dirvish-computer-rename-label-at-point ()
  "Set a custom display label for drive at point."
  (interactive)
  (let* ((dev (enhanced-dirvish-computer--device-at-point))
         (lbl (enhanced-dirvish-ui-read-string (format "Custom label for %s (empty resets): "
                                   (enhanced-dirvish-device-name dev))
                           (cdr (assoc (enhanced-dirvish-device-id dev)
                                       (enhanced-dirvish-prefs-device-labels (enhanced-dirvish-prefs)))))))
    (enhanced-dirvish-devices-set-label (enhanced-dirvish-device-id dev) lbl)
    (enhanced-dirvish-computer-refresh)))

(defun enhanced-dirvish-computer-properties-at-point ()
  "Show properties for drive at point."
  (interactive)
  (let ((dev (enhanced-dirvish-computer--device-at-point)))
    (if (fboundp 'enhanced-dirvish-show-properties-for-path)
        (enhanced-dirvish-show-properties-for-path (enhanced-dirvish-device-mountpoint dev) dev)
      (message "%s: %s (%s)"
               (enhanced-dirvish-device-name dev)
               (or (enhanced-dirvish-device-mountpoint dev) "unmounted")
               (or (enhanced-dirvish-device-fstype dev) "unknown")))))

(defun enhanced-dirvish-open-computer-buffer ()
  "Create/display `*Enhanced Dirvish Computer*' buffer and return it."
  (let ((buf (get-buffer-create "*Enhanced Dirvish Computer*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'enhanced-dirvish-computer-mode)
        (enhanced-dirvish-computer-mode))
      (setq default-directory (expand-file-name "~/"))
      (enhanced-dirvish-computer-render)
      (goto-char (point-min)))
    buf))

;;;; Virtual Buffer: trash:///

(defun enhanced-dirvish-trash--dir ()
  "Return XDG Trash base directory."
  (expand-file-name "Trash" (or (getenv "XDG_DATA_HOME") "~/.local/share")))

(defun enhanced-dirvish-trash-items ()
  "List trashed items as plists (:name :file :info :orig :deleted :size :dir-p)."
  (let* ((base (enhanced-dirvish-trash--dir))
         (files-dir (expand-file-name "files" base))
         (info-dir (expand-file-name "info" base))
         out)
    (when (file-directory-p files-dir)
      (dolist (f (directory-files files-dir nil "\\`[^.]" t))
        (let* ((fpath (expand-file-name f files-dir))
               (ipath (expand-file-name (concat f ".trashinfo") info-dir))
               (orig f)
               (del "")
               (attrs (file-attributes fpath)))
          (when (file-readable-p ipath)
            (with-temp-buffer
              (insert-file-contents ipath)
              (goto-char (point-min))
              (when (re-search-forward "^Path=\\(.+\\)$" nil t)
                (setq orig (url-unhex-string (match-string 1))))
              (goto-char (point-min))
              (when (re-search-forward "^DeletionDate=\\(.+\\)$" nil t)
                (setq del (match-string 1)))))
          (push (list :name f :file fpath :info ipath :orig orig :deleted del
                      :size (or (file-attribute-size attrs) 0)
                      :dir-p (eq t (file-attribute-type attrs)))
                out))))
    (sort out (lambda (a b) (string-greaterp (plist-get a :deleted) (plist-get b :deleted))))))

(defvar enhanced-dirvish-trash-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    (define-key map (kbd "R") #'enhanced-dirvish-trash-restore-at-point)
    (define-key map (kbd "D") #'enhanced-dirvish-trash-delete-at-point)
    (define-key map (kbd "X") #'enhanced-dirvish-trash-empty)
    (define-key map (kbd "RET") #'enhanced-dirvish-trash-restore-at-point)
    (define-key map (kbd "<mouse-1>") #'enhanced-dirvish-trash-mouse-select)
    (define-key map (kbd "<mouse-2>") #'enhanced-dirvish-trash-mouse-restore)
    (define-key map (kbd "<double-mouse-1>") #'enhanced-dirvish-trash-mouse-restore)
    (define-key map (kbd "g") #'enhanced-dirvish-trash-refresh)
    map))

(defun enhanced-dirvish-trash-mouse-select (event)
  "Select trashed entry at EVENT."
  (interactive "e")
  (mouse-set-point event))

(defun enhanced-dirvish-trash-mouse-restore (event)
  "Restore trashed entry at EVENT."
  (interactive "e")
  (mouse-set-point event)
  (when (get-text-property (line-beginning-position) 'enhanced-dirvish-trash-item)
    (enhanced-dirvish-trash-restore-at-point)))

(defvar enhanced-dirvish-trash--row-keymap
  (let ((km (make-sparse-keymap)))
    (define-key km (kbd "<mouse-1>") #'enhanced-dirvish-trash-mouse-select)
    (define-key km (kbd "<mouse-2>") #'enhanced-dirvish-trash-mouse-restore)
    (define-key km (kbd "<double-mouse-1>") #'enhanced-dirvish-trash-mouse-restore)
    km)
  "Row-level mouse keymap for `trash:///' entries.")

(define-derived-mode enhanced-dirvish-trash-mode special-mode "Enhanced-Dirvish-Trash"
  "Interactive Enhanced Dirvish `trash:///' buffer."
  (setq-local truncate-lines t)
  (setq-local header-line-format
              (concat "  "
                      (enhanced-dirvish-icon-glyph 'trash 'enhanced-dirvish-header-accent)
                      (propertize "  Trash (trash:///)  —  R/RET: Restore  D: Delete Permanently  X: Empty Trash  g: Refresh"
                                  'face 'enhanced-dirvish-header-accent)))
  (hl-line-mode 1))

(defun enhanced-dirvish-trash-refresh ()
  "Re-render `trash:///' buffer."
  (interactive)
  (when (derived-mode-p 'enhanced-dirvish-trash-mode)
    (let ((inhibit-read-only t)
          (items (enhanced-dirvish-trash-items)))
      (erase-buffer)
      (if (null items)
          (insert "\n   Trash is empty.\n")
        (dolist (it items)
          (let* ((dirp (plist-get it :dir-p))
                 (line (format "   %s  %-28s  %-10s  %-19s  <- %s\n"
                               (enhanced-dirvish-icon-glyph (if dirp 'folder 'file))
                               (truncate-string-to-width (plist-get it :name) 28 nil nil "…")
                               (enhanced-dirvish-format-bytes (plist-get it :size))
                               (replace-regexp-in-string "T" " " (plist-get it :deleted))
                               (abbreviate-file-name (plist-get it :orig)))))
            (insert (enhanced-dirvish-add-row-properties
                     line (list 'enhanced-dirvish-trash-item it
                                'mouse-face 'highlight
                                'keymap enhanced-dirvish-trash--row-keymap)))))))
    (when (fboundp 'enhanced-dirvish-watch-sync)
      (enhanced-dirvish-watch-sync (current-buffer)))))

(defun enhanced-dirvish-trash--item-at-point ()
  "Return trash plist on current line."
  (or (get-text-property (line-beginning-position) 'enhanced-dirvish-trash-item)
      (user-error "No trashed item on this line")))

(defun enhanced-dirvish-trash-restore-item (item)
  "Restore trashed ITEM to its original path, asking before replacing a file."
  (let* ((src (plist-get item :file))
         (info (plist-get item :info))
         (dest (plist-get item :orig))
         (parent (file-name-directory dest)))
    (unless (file-exists-p src)
      (user-error "Trashed item no longer exists: %s" src))
    (make-directory parent t)
    (when (file-exists-p dest)
      (unless (enhanced-dirvish-ui-y-or-n-p (format "Target %s already exists. Replace? " dest))
        (user-error "Restore cancelled")))
    (rename-file src dest t)
    (when (file-exists-p info) (delete-file info))
    (message "Restored -> %s" dest)))

(defun enhanced-dirvish-trash-restore-at-point ()
  "Restore trashed item at point."
  (interactive)
  (enhanced-dirvish-trash-restore-item (enhanced-dirvish-trash--item-at-point))
  (enhanced-dirvish-trash-refresh))

(defun enhanced-dirvish-trash-delete-at-point ()
  "Permanently delete trashed item at point."
  (interactive)
  (let ((it (enhanced-dirvish-trash--item-at-point)))
    (when (enhanced-dirvish-ui-yes-or-no-p (format "Permanently delete '%s'? " (plist-get it :name)))
      (let ((f (plist-get it :file))
            (i (plist-get it :info)))
        (when (file-exists-p f)
          (if (file-directory-p f) (delete-directory f t) (delete-file f)))
        (when (file-exists-p i) (delete-file i))
        (enhanced-dirvish-trash-refresh)))))

(defun enhanced-dirvish-trash-empty ()
  "Empty XDG Trash safely."
  (interactive)
  (let ((items (enhanced-dirvish-trash-items)))
    (if (null items)
        (message "Trash is already empty")
      (when (enhanced-dirvish-ui-yes-or-no-p (format "Permanently delete all %d items in Trash? " (length items)))
        (dolist (it items)
          (ignore-errors
            (let ((f (plist-get it :file)) (i (plist-get it :info)))
              (when (file-exists-p f)
                (if (file-directory-p f) (delete-directory f t) (delete-file f)))
              (when (file-exists-p i) (delete-file i)))))
        (enhanced-dirvish-trash-refresh)
        (message "Trash emptied")))))

(defun enhanced-dirvish-open-trash-buffer ()
  "Return populated `*Enhanced Dirvish Trash*' buffer."
  (let ((buf (get-buffer-create "*Enhanced Dirvish Trash*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'enhanced-dirvish-trash-mode)
        (enhanced-dirvish-trash-mode))
      (setq default-directory (expand-file-name "~/"))
      (enhanced-dirvish-trash-refresh)
      (goto-char (point-min)))
    buf))

;;;; Virtual Buffer: recent:///

(defun enhanced-dirvish-recent-files ()
  "Collect recent existing local files.
They come from `recently-used.xbel' and `recentf-list'."
  (let ((seen (make-hash-table :test #'equal))
        out
        (xbel (expand-file-name "recently-used.xbel"
                                (or (getenv "XDG_DATA_HOME") "~/.local/share"))))
    (when (file-readable-p xbel)
      (with-temp-buffer
        (insert-file-contents xbel)
        (goto-char (point-min))
        (while (re-search-forward "bookmark href=\"file://\\([^\"]+\\)\"" nil t)
          (let ((path (url-unhex-string (match-string 1))))
            (when (and (not (gethash path seen)) (file-exists-p path))
              (puthash path t seen)
              (push path out))))))
    (when (boundp 'recentf-list)
      (dolist (f recentf-list)
        (let ((path (expand-file-name f)))
          (when (and (not (gethash path seen)) (file-exists-p path))
            (puthash path t seen)
            (push path out)))))
    (nreverse out)))

(defvar enhanced-dirvish-recent-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    (define-key map (kbd "RET") #'enhanced-dirvish-recent-open-at-point)
    (define-key map (kbd "M-RET") #'enhanced-dirvish-recent-open-folder-at-point)
    (define-key map (kbd "<mouse-1>") #'enhanced-dirvish-recent-mouse-click)
    (define-key map (kbd "<mouse-2>") #'enhanced-dirvish-recent-mouse-activate)
    (define-key map (kbd "<double-mouse-1>") #'enhanced-dirvish-recent-mouse-activate)
    (define-key map (kbd "g") #'enhanced-dirvish-recent-refresh)
    map))

(defun enhanced-dirvish-recent-mouse-click (event)
  "Handle `<mouse-1>' in `recent:///': open clicked directory, select files."
  (interactive "e")
  (mouse-set-point event)
  (when-let ((p (get-text-property (line-beginning-position) 'enhanced-dirvish-recent-path)))
    (when (file-directory-p p)
      (enhanced-dirvish-open-location p))))

(defun enhanced-dirvish-recent-mouse-activate (event)
  "Open clicked recent entry at EVENT."
  (interactive "e")
  (mouse-set-point event)
  (when (get-text-property (line-beginning-position) 'enhanced-dirvish-recent-path)
    (enhanced-dirvish-recent-open-at-point)))

(defvar enhanced-dirvish-recent--row-keymap
  (let ((km (make-sparse-keymap)))
    (define-key km (kbd "<mouse-1>") #'enhanced-dirvish-recent-mouse-click)
    (define-key km (kbd "<mouse-2>") #'enhanced-dirvish-recent-mouse-activate)
    (define-key km (kbd "<double-mouse-1>") #'enhanced-dirvish-recent-mouse-activate)
    km)
  "Row-level mouse keymap for `recent:///' entries.")

(define-derived-mode enhanced-dirvish-recent-mode special-mode "Enhanced-Dirvish-Recent"
  "Interactive Enhanced Dirvish `recent:///' view."
  (setq-local truncate-lines t)
  (setq-local header-line-format
              (concat "  "
                      (enhanced-dirvish-icon-glyph 'recent 'enhanced-dirvish-header-accent)
                      (propertize "  Recent Files (recent:///)  —  RET: Open  M-RET: Open Containing Folder  g: Refresh"
                                  'face 'enhanced-dirvish-header-accent)))
  (hl-line-mode 1))

(defun enhanced-dirvish-recent-refresh ()
  "Refresh `recent:///' buffer."
  (interactive)
  (when (derived-mode-p 'enhanced-dirvish-recent-mode)
    (let ((inhibit-read-only t)
          (files (seq-take (enhanced-dirvish-recent-files) 150)))
      (erase-buffer)
      (if (null files)
          (insert "\n   No recent files recorded.\n")
        (dolist (f files)
          (let* ((dirp (file-directory-p f))
                 (attrs (file-attributes f))
                 (line (format "   %s  %-34s  %-9s  %s\n"
                               (enhanced-dirvish-icon-glyph (if dirp 'folder 'file))
                               (truncate-string-to-width (file-name-nondirectory f) 34 nil nil "…")
                               (if dirp "<dir>" (enhanced-dirvish-format-bytes (or (file-attribute-size attrs) 0)))
                               (propertize (abbreviate-file-name (or (file-name-directory f) "/"))
                                           'face 'shadow))))
            (insert (enhanced-dirvish-add-row-properties
                     line (append (list 'enhanced-dirvish-recent-path f
                                        'mouse-face 'highlight
                                        'keymap enhanced-dirvish-recent--row-keymap)
                                  (when dirp (list 'pointer 'hand 'help-echo f)))))))))
    (when (fboundp 'enhanced-dirvish-watch-sync)
      (enhanced-dirvish-watch-sync (current-buffer)))))

(defun enhanced-dirvish-recent-open-at-point ()
  "Open recent file or folder at point."
  (interactive)
  (let ((p (or (get-text-property (line-beginning-position) 'enhanced-dirvish-recent-path)
               (user-error "No entry on this line"))))
    (if (file-directory-p p)
        (enhanced-dirvish-open-location p)
      (find-file p))))

(defun enhanced-dirvish-recent-open-folder-at-point ()
  "Open containing folder for recent file at point."
  (interactive)
  (let ((p (or (get-text-property (line-beginning-position) 'enhanced-dirvish-recent-path)
               (user-error "No entry on this line"))))
    (enhanced-dirvish-open-location (file-name-directory p))))

(defun enhanced-dirvish-open-recent-buffer ()
  "Return populated `*Enhanced Dirvish Recent*' buffer."
  (let ((buf (get-buffer-create "*Enhanced Dirvish Recent*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'enhanced-dirvish-recent-mode)
        (enhanced-dirvish-recent-mode))
      (setq default-directory (expand-file-name "~/"))
      (enhanced-dirvish-recent-refresh)
      (goto-char (point-min)))
    buf))

;;;; Network View: network:///

(defun enhanced-dirvish-connect-server (&optional uri)
  "Prompt for a network or admin URI and open it.
The URI is `sftp://', `smb://', `ssh://' or `admin:///'."
  (interactive)
  (let ((raw (or uri (enhanced-dirvish-ui-read-string "Connect to server (sftp://, smb://, ssh://, admin:///): "
                                  "sftp://"))))
    (enhanced-dirvish-open-location (enhanced-dirvish-resolve-location-uri raw))))

(defun enhanced-dirvish-open-network-buffer ()
  "Return `*Enhanced Dirvish Network*': GVfs/TRAMP mounts and quick connect."
  (let ((buf (get-buffer-create "*Enhanced Dirvish Network*"))
        (devs (cl-remove-if-not (lambda (d)
                                  (memq (enhanced-dirvish-device-placement d) '(network cloud)))
                                (enhanced-dirvish-devices-list t))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (setq-local header-line-format
                    (concat "  "
                            (enhanced-dirvish-icon-glyph 'network 'enhanced-dirvish-header-accent)
                            (propertize "  Network & Cloud (network:///)  —  Click/RET: Open  c: Connect to Server"
                                        'face 'enhanced-dirvish-header-accent)))
        (local-set-key (kbd "c") #'enhanced-dirvish-connect-server)
        (local-set-key (kbd "RET") #'enhanced-dirvish-computer-open-at-point)
        (insert (propertize "\n  Mounted Network & Cloud Shares\n\n" 'face 'enhanced-dirvish-section-heading))
        (if (null devs)
            (insert "   No active network/cloud mounts found. Press [c] to connect via sftp:// or smb://\n")
          (dolist (d devs)
            (let ((line (format "   %s  %-26s  %s\n"
                                (enhanced-dirvish-device-icon d)
                                (enhanced-dirvish-device-name d)
                                (propertize (or (enhanced-dirvish-device-mountpoint d) "") 'face 'shadow))))
              (insert (enhanced-dirvish-add-row-properties
                       line (list 'enhanced-dirvish-device d
                                  'mouse-face 'highlight
                                  'pointer 'hand
                                  'keymap enhanced-dirvish-computer--row-keymap
                                  'help-echo (or (enhanced-dirvish-device-mountpoint d) (enhanced-dirvish-device-name d))))))))
        (goto-char (point-min))))
    buf))

(provide 'enhanced-dirvish-devices)
;;; enhanced-dirvish-devices.el ends here
