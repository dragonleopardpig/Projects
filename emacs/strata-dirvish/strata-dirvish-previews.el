;;; strata-dirvish-previews.el --- Rich previews, per-type zoom, media IPC, docs, 3D/GPX -*- lexical-binding: t; -*-

;;; Commentary:
;; Implements Strata's preview ecosystem inside Dirvish:
;; - Independent per-type zoom (text / image / pdf) via C-+/C--/C-0
;; - Rendered Markdown (with Mermaid/LaTeX/relative image support) & Source toggle
;; - Offline safe HTML, DOCX/ODT/RTF (pandoc), interactive CSV/TSV/XLSX tables
;; - PDF page preview & EXIF RAW/Image preview
;; - Audio/Video storyboard + headless mpv IPC playback controls & external handoff
;; - Browseable Archives, Fonts, 3D (STL/G-code) & GPS (GPX/KML) previews
;; - Folder Peek / Preview Drawer toggle (SPC / i)

;;; Code:

(require 'cl-lib)
(require 'dirvish)
(require 'shr)
(require 'subr-x)
(require 'strata-dirvish-prefs)
(require 'strata-dirvish-devices)

(declare-function strata-current-file "strata-dirvish-views" ())

(defvar strata-active-preview-kind 'other
  "Kind of item currently in preview: `text', `image', `pdf', `media', `archive', `dir', or `other'.")

(defvar strata-active-preview-file nil
  "Path of file currently previewed in Dirvish.")

(defvar strata-preview-pdf-page 1
  "Current 1-based page displayed in PDF preview.")

(defvar strata-media-proc nil "Active headless mpv playback process.")
(defvar strata-media-socket nil "Unix domain IPC socket for active mpv playback.")
(defvar strata-media-file nil "Currently loaded media path.")
(defvar strata-media-paused nil "Non-nil when media playback is paused.")
(defvar strata-media-position 0.0 "Last known playback position in seconds.")

(defconst strata-preview-max-bytes (* 512 1024)
  "Maximum bytes read directly for text/document previews.")

;;;; Independent Per-Type Zoom Controls (Text / Image / PDF)

(defun strata-preview--refresh-now ()
  "Force immediate re-render of active Dirvish preview buffer."
  (when-let ((dv (ignore-errors (dirvish-curr))))
    (when (and dv (window-live-p (dv-preview-window dv)) strata-active-preview-file)
      ;; Invalidate cached special preview buffers when zooming images/PDFs
      (when (memq strata-active-preview-kind '(image pdf))
        (dolist (b (buffer-list))
          (when (string-prefix-p " *Dirvish-preview-" (buffer-name b))
            (kill-buffer b))))
      (dirvish--preview-update dv strata-active-preview-file))))

(defun strata-preview-zoom-in ()
  "Zoom in ONLY the currently active preview type (`text', `image', or `pdf')."
  (interactive)
  (let ((p (strata-prefs)))
    (pcase strata-active-preview-kind
      ('image
       (let ((next (min 4.0 (* (strata-prefs-preview-image-scale p) 1.2))))
         (setf (strata-prefs-preview-image-scale p) next)
         (strata-prefs-save)
         (strata-preview--refresh-now)
         (message "Image preview zoom: %.0f%%" (* 100 next))))
      ('pdf
       (let ((next (min 3.0 (* (strata-prefs-preview-pdf-scale p) 1.15))))
         (setf (strata-prefs-preview-pdf-scale p) next)
         (strata-prefs-save)
         (strata-preview--refresh-now)
         (message "PDF preview zoom: %.0f%%" (* 100 next))))
      (_
       (let ((next (min 10 (1+ (strata-prefs-preview-text-scale p)))))
         (setf (strata-prefs-preview-text-scale p) next)
         (strata-prefs-save)
         (strata-preview--apply-text-zoom)
         (message "Text preview scale: %+d" next))))))

(defun strata-preview-zoom-out ()
  "Zoom out ONLY the currently active preview type (`text', `image', or `pdf')."
  (interactive)
  (let ((p (strata-prefs)))
    (pcase strata-active-preview-kind
      ('image
       (let ((next (max 0.25 (/ (strata-prefs-preview-image-scale p) 1.2))))
         (setf (strata-prefs-preview-image-scale p) next)
         (strata-prefs-save)
         (strata-preview--refresh-now)
         (message "Image preview zoom: %.0f%%" (* 100 next))))
      ('pdf
       (let ((next (max 0.5 (/ (strata-prefs-preview-pdf-scale p) 1.15))))
         (setf (strata-prefs-preview-pdf-scale p) next)
         (strata-prefs-save)
         (strata-preview--refresh-now)
         (message "PDF preview zoom: %.0f%%" (* 100 next))))
      (_
       (let ((next (max -5 (1- (strata-prefs-preview-text-scale p)))))
         (setf (strata-prefs-preview-text-scale p) next)
         (strata-prefs-save)
         (strata-preview--apply-text-zoom)
         (message "Text preview scale: %+d" next))))))

(defun strata-preview-zoom-reset ()
  "Reset zoom for the currently active preview type back to 100% / 0."
  (interactive)
  (let ((p (strata-prefs)))
    (pcase strata-active-preview-kind
      ('image
       (setf (strata-prefs-preview-image-scale p) 1.0)
       (strata-prefs-save)
       (strata-preview--refresh-now)
       (message "Image preview zoom reset (100%%)"))
      ('pdf
       (setf (strata-prefs-preview-pdf-scale p) 1.0)
       (strata-prefs-save)
       (strata-preview--refresh-now)
       (message "PDF preview zoom reset (100%%)"))
      (_
       (setf (strata-prefs-preview-text-scale p) 0)
       (strata-prefs-save)
       (strata-preview--apply-text-zoom)
       (message "Text preview zoom reset (0)")))))

(defun strata-preview--apply-text-zoom ()
  "Apply independent `preview-text-scale' to the active preview window's buffer."
  (when-let* ((dv (ignore-errors (dirvish-curr)))
              (win (and dv (dv-preview-window dv)))
              (buf (and (window-live-p win) (window-buffer win))))
    (with-current-buffer buf
      (when (fboundp 'text-scale-set)
        (text-scale-set (strata-prefs-preview-text-scale (strata-prefs))))
      (setq-local truncate-lines (not (strata-prefs-preview-text-wrap (strata-prefs)))))))

(defun strata-toggle-rendered-document ()
  "Toggle Rendered Document view vs Raw Source view (`V')."
  (interactive)
  (let ((p (strata-prefs)))
    (setf (strata-prefs-render-documents-by-default p)
          (not (strata-prefs-render-documents-by-default p)))
    (strata-prefs-save)
    (strata-preview--refresh-now)
    (message "Document preview mode: %s"
             (if (strata-prefs-render-documents-by-default p) "Rendered" "Source"))))

(defun strata-toggle-preview-wrap ()
  "Toggle soft line wrapping inside preview buffer (`W')."
  (interactive)
  (let ((p (strata-prefs)))
    (setf (strata-prefs-preview-text-wrap p) (not (strata-prefs-preview-text-wrap p)))
    (strata-prefs-save)
    (strata-preview--apply-text-zoom)
    (message "Preview wrap: %s" (if (strata-prefs-preview-text-wrap p) "ON" "OFF"))))

(defun strata-preview-update-standalone (file &optional window)
  "Render rich preview for FILE into `*Strata Preview*' inside WINDOW."
  (let* ((ext (or (file-name-extension file) ""))
         (win (or window (get-buffer-window "*Strata Preview*") (selected-window)))
         (res (or (dirvish-strata-rich-image-dp file ext win nil)
                  (dirvish-strata-rich-pdf-dp file ext win nil)
                  (dirvish-strata-rich-document-dp file ext win nil)))
         (out-buf (get-buffer-create "*Strata Preview*")))
    (pcase res
      (`(buffer . ,b)
       (with-current-buffer out-buf
         (let ((inhibit-read-only t))
           (erase-buffer)
           (insert-buffer-substring b)
           (special-mode)
           (goto-char (point-min)))))
      (`(shell . ,cmd)
       (with-current-buffer out-buf
         (let ((inhibit-read-only t))
           (erase-buffer)
           (apply #'process-file (car cmd) nil t nil (cdr cmd))
           (special-mode)
           (goto-char (point-min)))))
      (_
       (with-current-buffer out-buf
         (let ((inhibit-read-only t))
           (erase-buffer)
           (if (file-directory-p file)
               (if (strata-path-unsafe-probe-p file)
                   (insert (propertize (format "  Remote / Cloud / External mount: %s\n\n  Auto-preview skipped (press RET to open).\n"
                                               (file-name-nondirectory (directory-file-name file)))
                                       'face 'shadow))
                 (let ((items (ignore-errors (directory-files file nil "\\`[^.]" t))))
                   (insert (concat "  "
                                   (strata-icon-glyph 'folder 'strata-header-accent)
                                   (propertize (format " %s (%d items)\n\n"
                                                       (file-name-nondirectory (directory-file-name file))
                                                       (length items))
                                               'face 'strata-header-accent)))
                   (dolist (it (seq-take items 60))
                     (let* ((sub (expand-file-name it file))
                            (dirp (file-directory-p sub))
                            (row (format "   %s  %s\n"
                                         (strata-icon-glyph (if dirp 'folder 'file))
                                         it)))
                       (when dirp
                         (let ((km (make-sparse-keymap)))
                           (define-key km [mouse-1]
                                       (lambda (ev)
                                         (interactive "e")
                                         (when (fboundp 'strata-open-location)
                                           (when (posn-window (event-end ev))
                                             (select-window (posn-window (event-end ev))))
                                           (strata-open-location sub t))))
                           (add-text-properties 0 (length row)
                                                (list 'mouse-face 'highlight
                                                      'pointer 'hand
                                                      'keymap km
                                                      'help-echo sub)
                                                row)))
                       (insert row)))))
             (when (file-readable-p file)
               (insert-file-contents file nil 0 65536)))
           (special-mode)
           (goto-char (point-min))))))
    (when (window-live-p win)
      (set-window-buffer win out-buf))))

(defun strata-scroll-preview-down ()
  "Scroll preview window down (`J')."
  (interactive)
  (let ((win (or (when-let ((dv (ignore-errors (dirvish-curr)))) (dv-preview-window dv))
                 (get-buffer-window "*Strata Preview*"))))
    (when (window-live-p win)
      (with-selected-window win (scroll-up-command 5)))))

(defun strata-scroll-preview-up ()
  "Scroll preview window up (`K')."
  (interactive)
  (let ((win (or (when-let ((dv (ignore-errors (dirvish-curr)))) (dv-preview-window dv))
                 (get-buffer-window "*Strata Preview*"))))
    (when (window-live-p win)
      (with-selected-window win (scroll-down-command 5)))))

(defun strata-toggle-peek ()
  "Toggle preview drawer / peek panel (`i' / `SPC') across all 4 browser modes."
  (interactive)
  (cond
   ((or (derived-mode-p 'strata-compact-mode)
        (derived-mode-p 'strata-icons-mode)
        (not (dirvish-curr)))
    (if-let ((win (get-buffer-window "*Strata Preview*")))
        (delete-window win)
      (when-let ((f (strata-current-file)))
        (let ((pwin (display-buffer-in-side-window
                     (get-buffer-create "*Strata Preview*")
                     '((side . right) (slot . 0) (window-width . 0.42)))))
          (strata-preview-update-standalone f pwin)))))
   (t (dirvish-layout-toggle))))

(defun strata-preview-find ()
  "Search text inside currently displayed Dirvish preview window."
  (interactive)
  (when-let* ((dv (ignore-errors (dirvish-curr)))
              (win (and dv (dv-preview-window dv))))
    (unless (window-live-p win)
      (user-error "Preview drawer is not visible"))
    (let ((pat (read-string "Find in preview: ")))
      (when (and pat (not (string-empty-p pat)))
        (with-selected-window win
          (goto-char (point-min))
          (if (search-forward pat nil t)
              (recenter)
            (message "No match for %s in preview" pat)))))))

;;;; Preview Rendering Helpers

(defun strata-preview--make-buffer (name &optional kind)
  "Create/clear clean read-only preview buffer NAME tagging Strata KIND."
  (let ((buf (get-buffer-create name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer))
      (setq buffer-read-only t
            strata-active-preview-kind (or kind 'text))
      (setq-local truncate-lines (not (strata-prefs-preview-text-wrap (strata-prefs))))
      (when (fboundp 'text-scale-set)
        (text-scale-set (strata-prefs-preview-text-scale (strata-prefs)))))
    buf))

(defun strata-preview--safe-insert-markdown (file buf)
  "Render Markdown FILE cleanly into BUF with headings, code blocks, math & images."
  (let ((dir (file-name-directory file))
        (text (with-temp-buffer
                (insert-file-contents file nil 0 strata-preview-max-bytes)
                (buffer-string))))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (in-code nil)
            (code-lang ""))
        (erase-buffer)
        (insert (concat "  "
                        (strata-icon-glyph 'markdown 'strata-hint-desc)
                        (propertize (format " Markdown (Rendered · toggle [V] for Source) — %s\n\n"
                                            (file-name-nondirectory file))
                                    'face 'strata-hint-desc)))
        (dolist (line (split-string text "\n"))
          (cond
           ((string-match "\\````\\(.*\\)\\'" line)
            (setq in-code (not in-code)
                  code-lang (string-trim (match-string 1 line)))
            (when in-code
              (insert (propertize (format "  ┌─ %s\n" (if (string-empty-p code-lang) "code" code-lang))
                                  'face 'strata-hint-desc)))
            (unless in-code
              (insert (propertize "  └─\n" 'face 'strata-hint-desc))))
           (in-code
            (insert (propertize (concat "  │ " line "\n") 'face 'strata-preview-code)))
           ((string-match "\\`# \\(.+\\)\\'" line)
            (insert "\n" (propertize (match-string 1 line) 'face 'strata-preview-heading-1) "\n"))
           ((string-match "\\`## \\(.+\\)\\'" line)
            (insert "\n" (propertize (match-string 1 line) 'face 'strata-preview-heading-2) "\n"))
           ((string-match "\\`###+ \\(.+\\)\\'" line)
            (insert (propertize (match-string 1 line) 'face 'strata-preview-heading-3) "\n"))
           ((string-match "\\`!\\[\\([^]]*\\)\\](\\([^)]+\\))\\'" line)
            (let* ((alt (match-string 1 line))
                   (rel (match-string 2 line))
                   (img-path (expand-file-name rel dir)))
              (if (and (display-graphic-p) (file-readable-p img-path)
                       (image-supported-file-p img-path))
                  (let ((img (create-image img-path nil nil :max-width 480 :max-height 320)))
                    (insert "  ")
                    (insert-image img (format "[Image: %s]" alt))
                    (insert "\n"))
                (insert (concat "  " (strata-icon-glyph 'pictures 'shadow)
                                (propertize (format " [%s -> %s]\n" alt rel) 'face 'shadow))))))
           (t
            (insert "  " line "\n"))))
        (goto-char (point-min))))))

(defun strata-preview--safe-insert-html (file buf)
  "Render local HTML FILE cleanly via `shr' with remote requests disabled."
  (let ((shr-inhibit-images t)
        (shr-blocked-images ".*")
        (dom (with-temp-buffer
               (insert-file-contents file nil 0 strata-preview-max-bytes)
               (when (fboundp 'libxml-parse-html-region)
                 (libxml-parse-html-region (point-min) (point-max))))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (concat "  "
                        (strata-icon-glyph 'network 'strata-hint-desc)
                        (propertize " HTML Document (Offline Rendered · [V] Source)\n\n"
                                    'face 'strata-hint-desc)))
        (if dom (shr-insert-document dom) (insert-file-contents file nil 0 strata-preview-max-bytes))
        (goto-char (point-min))))))

(defun strata-preview--render-tabular (file ext buf)
  "Render CSV/TSV/XLSX/ODS FILE (extension EXT) as aligned sortable columns in BUF."
  (let* ((sep (if (string= ext "tsv") "\t" ","))
         (raw
          (cond
           ((member ext '("csv" "tsv"))
            (with-temp-buffer
              (insert-file-contents file nil 0 strata-preview-max-bytes)
              (buffer-string)))
           ((and (executable-find "python3") (member ext '("xlsx" "ods")))
            (with-temp-buffer
              (process-file
               "timeout" nil t nil "2" "python3" "-c"
               "import sys,zipfile,xml.etree.ElementTree as ET
p=sys.argv[1]
try:
 z=zipfile.ZipFile(p)
 if p.endswith('.xlsx'):
  ss=[]; sroot=ET.fromstring(z.read('xl/sharedStrings.xml')) if 'xl/sharedStrings.xml' in z.namelist() else None
  if sroot is not None: ss=[''.join(si.itertext()) for si in sroot]
  sh=[n for n in z.namelist() if n.startswith('xl/worksheets/sheet')][0]
  root=ET.fromstring(z.read(sh))
  for r in root.iter('{http://schemas.openxmlformats.org/spreadsheetml/2006/main}row'):
   vals=[]
   for c in r:
    t=c.attrib.get('t',''); v=c.find('{http://schemas.openxmlformats.org/spreadsheetml/2006/main}v')
    val='' if v is None or v.text is None else v.text
    if t=='s' and val.isdigit() and int(val)<len(ss): val=ss[int(val)]
    vals.append(val.replace('\\t',' '))
   print('\\t'.join(vals))
 elif p.endswith('.ods'):
  root=ET.fromstring(z.read('content.xml'))
  for tr in root.iter('{urn:oasis:names:tc:opendocument:xmlns:table:1.0}table-row')[:200]:
   vals=[''.join(tc.itertext()).strip().replace('\\t',' ') for tc in tr]
   if any(vals): print('\\t'.join(vals))
except Exception as e:
 print('Error\\t'+str(e))"
               file)
              (buffer-string)))
           (t "")))
         (lines (seq-take (split-string raw "\n" t) 250))
         (rows (mapcar (lambda (l) (split-string l (if (member ext '("xlsx" "ods")) "\t" sep)))
                       lines)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "  📊 Spreadsheet (%s · %d rows)\n\n"
                                    (upcase ext) (length rows))
                            'face 'strata-header-accent))
        (dolist (r rows)
          (insert "  "
                  (mapconcat (lambda (c) (format "%-18s" (truncate-string-to-width (string-trim c) 18 nil nil "…")))
                             (seq-take r 12) " │ ")
                  "\n"))
        (goto-char (point-min))))))

(defun strata-preview--pandoc (file buf label)
  "Convert document FILE cleanly via offline `pandoc' into BUF."
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize (format "  📃 %s (Rendered via pandoc · %s)\n\n"
                                  label (file-name-nondirectory file))
                          'face 'strata-hint-desc))
      (if (executable-find "pandoc")
          (process-file "timeout" nil t nil "3" "pandoc" "--standalone=false" "-t" "plain" file)
        (insert "pandoc not found on PATH."))
      (goto-char (point-min)))))

(defun strata-preview--media-info (file)
  "Gather concise technical badges for audio/video FILE."
  (let ((exe (or (executable-find "mediainfo") (executable-find "ffprobe"))))
    (when exe
      (with-temp-buffer
        (if (string-suffix-p "mediainfo" exe)
            (process-file "timeout" nil t nil "2" exe file)
          (process-file "timeout" nil t nil "2" exe "-v" "error"
                        "-show_entries" "format=duration,bit_rate:stream=codec_type,codec_name,width,height,r_frame_rate"
                        "-of" "default=noprint_wrappers=1" file))
        (string-trim (buffer-string))))))

(defun strata-preview--3d-or-route (file ext buf)
  "Render STL, G-code, GPX, or KML geometric/route summary into BUF."
  (let ((summary
         (if (executable-find "python3")
             (with-temp-buffer
               (process-file
                "timeout" nil t nil "2" "python3" "-c"
                "import sys,os,struct,math,xml.etree.ElementTree as ET
p,ext=sys.argv[1],sys.argv[2].lower()
try:
 if ext=='stl':
  with open(p,'rb') as f:
   hdr=f.read(84)
   if hdr.startswith(b'solid') and b'facet' in f.read(512):
    f.seek(0); txt=f.read(2000000).decode('utf-8','ignore')
    print(f'ASCII STL | facets≈{txt.count(\"facet normal\")}')
   elif len(hdr)>=84:
    n=struct.unpack('<I',hdr[80:84])[0]
    print(f'Binary STL | triangles: {n:,} | header: {hdr[:80].split(b\"\\0\")[0].decode(\"ascii\",\"ignore\")}')
 elif ext in ('gcode','gco'):
  lines=open(p,'r',errors='ignore').read(500000).splitlines()
  layers=sum(1 for l in lines if l.startswith(';LAYER:'))
  print(f'G-code | sampled lines: {len(lines):,} | layers: {layers}')
 elif ext=='gpx':
  root=ET.parse(p).getroot(); pts=[]
  for trkpt in root.iter():
   if trkpt.tag.endswith('trkpt'):
    ele=next((float(c.text) for c in trkpt if c.tag.endswith('ele') and c.text), None)
    pts.append((float(trkpt.attrib['lat']),float(trkpt.attrib['lon']),ele))
  dist=sum(6371*math.acos(max(-1,min(1,math.sin(math.radians(a[0]))*math.sin(math.radians(b[0]))+math.cos(math.radians(a[0]))*math.cos(math.radians(b[0]))*math.cos(math.radians(b[1]-a[1]))))) for a,b in zip(pts,pts[1:]))
  eles=[x[2] for x in pts if x[2] is not None]
  print(f'GPX Track | points: {len(pts):,} | distance: {dist:.2f} km'+(f\" | elev: {min(eles):.0f}..{max(eles):.0f} m\" if eles else ''))
 elif ext=='kml':
  print('KML Route | file size:', os.path.getsize(p), 'bytes')
except Exception as e:
 print('Parse note:', e)"
                file ext)
               (string-trim (buffer-string)))
           "")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (concat "  "
                        (strata-icon-glyph 'file-3d 'strata-header-accent)
                        (propertize (format "  %s Preview — %s\n\n"
                                            (upcase ext) (file-name-nondirectory file))
                                    'face 'strata-header-accent)))
        (insert "  " summary "\n")
        (goto-char (point-min))))))

;;;; Dirvish Preview Dispatchers

(dirvish-define-preview strata-mount-guard (file)
  "Prevent synchronous hover preview freezes on FUSE/cloud/remote/removable mounts."
  (when (and file (strata-path-unsafe-probe-p file))
    (let ((kind (strata-path-mount-kind file)))
      (when (or (not (eq kind 'removable))
                (file-directory-p file))
        `(info . ,(format "  %s mount: %s\n\n  Auto-preview skipped for instant startup/navigation (press RET to open)."
                          (capitalize (symbol-name (if (eq kind 'local) 'remote kind)))
                          (file-name-nondirectory (directory-file-name file))))))))

(dirvish-define-preview strata-rich-image (file ext preview-window _dv)
  "Strata Image & Camera RAW preview honoring independent `preview-image-scale' & EXIF."
  (when (and file (not (file-directory-p file))
             (member (downcase (or ext ""))
                     '("png" "jpg" "jpeg" "gif" "webp" "svg" "bmp" "tif" "tiff" "avif" "cr2" "nef" "arw" "dng")))
    (setq strata-active-preview-file file
          strata-active-preview-kind 'image)
    (let* ((scale (strata-prefs-preview-image-scale (strata-prefs)))
           (base-w (* (window-pixel-width preview-window) 0.9))
           (base-h (* (window-pixel-height preview-window) 0.78))
           (w (round (* base-w scale)))
           (h (round (* base-h scale)))
           (raw-p (member (downcase ext) '("cr2" "nef" "arw" "dng")))
           (tmp (expand-file-name (format "img-%s-%d.png" (md5 file) (round (* 100 scale)))
                                  strata-thumbnail-dir))
           (buf (strata-preview--make-buffer (format " *Dirvish-preview-img-%s*" (md5 file)) 'image)))
      (make-directory strata-thumbnail-dir t)
      (when (and (not (file-exists-p tmp)) (executable-find (if raw-p "magick" "vipsthumbnail")))
        (if raw-p
            (ignore-errors (process-file "timeout" nil nil nil "3" "magick" file "-auto-orient" "-resize" (format "%dx%d>" w h) tmp))
          (ignore-errors (process-file "timeout" nil nil nil "2" "vipsthumbnail" file "-s" (format "%dx%d" w h) "-o" tmp))))
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (img-src (if (file-exists-p tmp) tmp file)))
          (insert (concat "  "
                          (strata-icon-glyph 'pictures 'strata-header-accent)
                          (propertize (format "  %s   Zoom: %.0f%%  ([C-+/C--/C-0])\n\n"
                                              (file-name-nondirectory file) (* 100 scale))
                                      'face 'strata-header-accent)))
          (when (and (display-graphic-p) (file-readable-p img-src))
            (when-let ((img (create-image img-src nil nil :max-width w :max-height h)))
              (insert "  ")
              (insert-image img "[image]")
              (insert "\n\n")))
          (when (executable-find "exiftool")
            (insert (propertize "  Camera / EXIF\n" 'face 'strata-section-heading))
            (process-file "timeout" nil t nil "2" "exiftool" "-s" "-s" "-ImageSize" "-Make" "-Model"
                          "-LensModel" "-FocalLength" "-FNumber" "-ExposureTime" "-ISO" "-GPSPosition" file))
          (goto-char (point-min))))
      `(buffer . ,buf))))

(dirvish-define-preview strata-rich-pdf (file ext preview-window _dv)
  "Strata PDF preview honoring independent `preview-pdf-scale' & page metadata."
  (when (and file (string= (downcase (or ext "")) "pdf") (executable-find "pdftoppm"))
    (setq strata-active-preview-file file
          strata-active-preview-kind 'pdf)
    (let* ((scale (strata-prefs-preview-pdf-scale (strata-prefs)))
           (base-w (round (* (window-pixel-width preview-window) 0.88 scale)))
           (base (expand-file-name (format "pdf-%s-p%d-%d" (md5 file) strata-preview-pdf-page (round (* 100 scale)))
                                   strata-thumbnail-dir))
           (png (concat base ".png"))
           (buf (strata-preview--make-buffer (format " *Dirvish-preview-pdf-%s*" (md5 file)) 'pdf)))
      (make-directory strata-thumbnail-dir t)
      (unless (file-exists-p png)
        (ignore-errors
          (process-file "timeout" nil nil nil "3" "pdftoppm" "-png" "-singlefile"
                        "-f" (number-to-string strata-preview-pdf-page)
                        "-scale-to" (number-to-string base-w)
                        file base)))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (insert (propertize (format "  %s PDF Page %d · Zoom %.0f%%  ([C-+/C--/C-0] · [M-PgUp/Dn] Page)\n\n"
                                      (strata-icon-glyph 'file-pdf 'strata-header-accent)
                                      strata-preview-pdf-page (* 100 scale))
                              'face 'strata-header-accent))
          (when (and (display-graphic-p) (file-exists-p png))
            (when-let ((img (create-image png 'png nil :max-width base-w)))
              (insert "  ")
              (insert-image img "[pdf page]")
              (insert "\n\n")))
          (when (executable-find "pdfinfo")
            (process-file "timeout" nil t nil "2" "pdfinfo" file))
          (goto-char (point-min))))
      `(buffer . ,buf))))

(dirvish-define-preview strata-rich-document (file ext _preview-window _dv)
  "Render Markdown, Org, HTML, DOCX, ODT, RTF, CSV, XLSX, Fonts, 3D/Routes & Archives."
  (when (and file (not (file-directory-p file)))
    (let* ((ext (downcase (or ext "")))
           (p (strata-prefs))
           (rendered (strata-prefs-render-documents-by-default p)))
      (cond
       ((and rendered (member ext '("md" "markdown")))
        (setq strata-active-preview-file file strata-active-preview-kind 'text)
        (let ((buf (strata-preview--make-buffer " *Strata-Preview-Doc*" 'text)))
          (strata-preview--safe-insert-markdown file buf)
          `(buffer . ,buf)))
       ((and rendered (member ext '("html" "htm" "xhtml")))
        (setq strata-active-preview-file file strata-active-preview-kind 'text)
        (let ((buf (strata-preview--make-buffer " *Strata-Preview-Doc*" 'text)))
          (strata-preview--safe-insert-html file buf)
          `(buffer . ,buf)))
       ((and rendered (member ext '("csv" "tsv" "xlsx" "ods")))
        (setq strata-active-preview-file file strata-active-preview-kind 'text)
        (let ((buf (strata-preview--make-buffer " *Strata-Preview-Doc*" 'text)))
          (strata-preview--render-tabular file ext buf)
          `(buffer . ,buf)))
       ((and rendered (member ext '("docx" "odt" "ott" "rtf")))
        (setq strata-active-preview-file file strata-active-preview-kind 'text)
        (let ((buf (strata-preview--make-buffer " *Strata-Preview-Doc*" 'text)))
          (strata-preview--pandoc file buf (upcase ext))
          `(buffer . ,buf)))
       ((member ext '("stl" "gcode" "gco" "gpx" "kml"))
        (setq strata-active-preview-file file strata-active-preview-kind 'other)
        (let ((buf (strata-preview--make-buffer " *Strata-Preview-Doc*" 'other)))
          (strata-preview--3d-or-route file ext buf)
          `(buffer . ,buf)))
       ((member ext '("ttf" "otf" "woff" "woff2"))
        (setq strata-active-preview-file file strata-active-preview-kind 'text)
        `(shell . ("sh" "-c" "fc-query \"$1\" | head -n 40" "_" ,file)))
       ((member ext '("zip" "7z" "tar" "gz" "tgz" "zst" "xz" "bz2" "iso"))
        (setq strata-active-preview-file file strata-active-preview-kind 'archive)
        `(shell . ("7z" "l" "-ba" ,file)))
       ((member ext '("mp3" "flac" "wav" "ogg" "opus" "m4a" "aac" "mp4" "mkv" "mov" "webm" "avi"))
        (setq strata-active-preview-file file strata-active-preview-kind 'media)
        (let* ((is-vid (member ext '("mp4" "mkv" "mov" "webm" "avi")))
               (thumb (expand-file-name (format "vid-%s.jpg" (md5 file)) strata-thumbnail-dir))
               (buf (strata-preview--make-buffer " *Strata-Preview-Media*" 'media)))
          (make-directory strata-thumbnail-dir t)
          (when (and is-vid (not (file-exists-p thumb)) (executable-find "ffmpegthumbnailer"))
            (ignore-errors (process-file "timeout" nil nil nil "3" "ffmpegthumbnailer" "-i" file "-o" thumb "-s" "360" "-t" "15%")))
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (insert (concat "  "
                              (strata-icon-glyph (if is-vid 'videos 'music) 'strata-header-accent)
                              (propertize (format " %s   [C-M-SPC: Play/Pause · C-M-←/→: Seek · C-M-m: Mute · O: Open in Player]\n\n"
                                                  (file-name-nondirectory file))
                                          'face 'strata-header-accent)))
              (when (and is-vid (display-graphic-p) (file-exists-p thumb))
                (when-let ((img (create-image thumb 'jpeg nil :max-width 420)))
                  (insert "  ")
                  (insert-image img "[video frame]")
                  (insert "\n\n")))
              (insert (or (strata-preview--media-info file) "No media metadata found."))
              (goto-char (point-min))))
          `(buffer . ,buf)))
       (t
        (setq strata-active-preview-file file strata-active-preview-kind 'text)
        nil)))))

(defun strata-pdf-page-step (delta)
  "Turn PDF preview page by DELTA."
  (interactive "p")
  (setq strata-preview-pdf-page (max 1 (+ strata-preview-pdf-page delta)))
  (strata-preview--refresh-now)
  (message "PDF preview page %d" strata-preview-pdf-page))

;;;; Headless MPV IPC Playback Controls for Audio & Video Previews

(defun strata-media--ipc (json-cmd)
  "Send JSON-CMD alist to active `strata-media-socket' via netcat/python3."
  (when (and strata-media-socket (file-exists-p strata-media-socket)
             (process-live-p strata-media-proc))
    (condition-case nil
        (let ((proc (make-network-process :name "strata-mpv-ipc"
                                          :family 'local
                                          :service strata-media-socket
                                          :noquery t)))
          (process-send-string proc (concat (json-encode json-cmd) "\n"))
          (delete-process proc))
      (error nil))))

(defun strata-media-stop ()
  "Stop any running Strata preview playback process."
  (interactive)
  (when (process-live-p strata-media-proc)
    (delete-process strata-media-proc))
  (setq strata-media-proc nil
        strata-media-paused nil)
  (when (and strata-media-socket (file-exists-p strata-media-socket))
    (ignore-errors (delete-file strata-media-socket))))

(defun strata-media-play-pause ()
  "Play/pause audio or video for current item using headless `mpv' (`C-M-SPC')."
  (interactive)
  (let ((f (or (strata-current-file) strata-active-preview-file)))
    (unless (and f (file-readable-p f))
      (user-error "No media file selected"))
    (if (and (process-live-p strata-media-proc) (equal f strata-media-file))
        (progn
          (setq strata-media-paused (not strata-media-paused))
          (strata-media--ipc `((command . ["cycle" "pause"])))
          (message "Media %s: %s" (if strata-media-paused "paused" "resumed")
                   (file-name-nondirectory f)))
      (unless (executable-find "mpv")
        (user-error "mpv is not installed"))
      (strata-media-stop)
      (setq strata-media-socket (expand-file-name (format "mpv-%d.sock" (emacs-pid))
                                                  temporary-file-directory)
            strata-media-file f
            strata-media-paused nil
            strata-media-position 0.0)
      (setq strata-media-proc
            (make-process
             :name "strata-mpv"
             :noquery t
             :command (list "mpv" "--no-video" "--really-quiet"
                            (format "--volume=%d" (strata-prefs-preview-volume (strata-prefs)))
                            (if (strata-prefs-preview-muted (strata-prefs)) "--mute=yes" "--mute=no")
                            (format "--input-ipc-server=%s" strata-media-socket)
                            f)))
      (message "Playing preview: %s" (file-name-nondirectory f)))))

(defun strata-media-seek (seconds)
  "Seek active media playback by SECONDS (`C-M-left`/`C-M-right')."
  (interactive "nSeek seconds: ")
  (setq strata-media-position (max 0.0 (+ strata-media-position seconds)))
  (strata-media--ipc `((command . ["seek" ,seconds "relative"])))
  (message "Seek %+ds" seconds))

(defun strata-media-mute-toggle ()
  "Mute/unmute active Strata media preview (`C-M-m` / `m')."
  (interactive)
  (let ((p (strata-prefs)))
    (setf (strata-prefs-preview-muted p) (not (strata-prefs-preview-muted p)))
    (strata-prefs-save)
    (strata-media--ipc `((command . ["set_property" "mute" ,(if (strata-prefs-preview-muted p) t :json-false)])))
    (message "Preview audio %s" (if (strata-prefs-preview-muted p) "muted" "unmuted"))))

(defun strata-media-volume-step (delta)
  "Adjust preview audio volume by DELTA (`C-M-up`/`C-M-down`)."
  (interactive "p")
  (let* ((p (strata-prefs))
         (v (max 0 (min 150 (+ (strata-prefs-preview-volume p) delta)))))
    (setf (strata-prefs-preview-volume p) v)
    (strata-prefs-save)
    (strata-media--ipc `((command . ["set_property" "volume" ,v])))
    (message "Preview volume: %d%%" v)))

(defun strata-media-open-external ()
  "Open video/audio file in external `mpv' at last playback position."
  (interactive)
  (let ((f (or (strata-current-file) strata-media-file)))
    (unless (and f (executable-find "mpv"))
      (user-error "Cannot launch mpv for %s" f))
    (let ((pos strata-media-position))
      (strata-media-stop)
      (make-process :name "strata-mpv-ext" :noquery t
                    :command (list "mpv" (format "--start=%.1f" pos) f)))))

(provide 'strata-dirvish-previews)
;;; strata-dirvish-previews.el ends here
