;;; enhanced-dirvish-ui.el --- Mouse dialogs and keyboard prompts -*- lexical-binding: t; -*-

;;; Commentary:
;; File actions retain their input method through all follow-up questions.
;; Mouse actions use native menus, file choosers and GTK text/password dialogs;
;; keyboard actions use the original Emacs prompts.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar enhanced-dirvish-ui-input-method nil
  "Input method for the active action: `mouse', `keyboard', or nil to detect.
Dynamically bound for an entire mouse action, including follow-up dialogs.")

(defun enhanced-dirvish-ui-mouse-p ()
  "Return non-nil when the current action should ask questions graphically."
  (and (display-graphic-p) (display-popup-menus-p)
       (pcase enhanced-dirvish-ui-input-method
         ('mouse t)
         ('keyboard nil)
         (_ (let ((use-dialog-box t)) (use-dialog-box-p))))))

(defun enhanced-dirvish-ui--mouse-command (original &rest args)
  "Run mouse command ORIGINAL with ARGS, preserving its interaction method."
  (let ((enhanced-dirvish-ui-input-method 'mouse)
        (use-dialog-box t)
        (use-file-dialog t))
    (apply original args)))

(defun enhanced-dirvish-ui-install-mouse-routing ()
  "Keep follow-up prompts graphical for all mouse file entry points."
  (dolist (command '(enhanced-dirvish-mouse-context-menu enhanced-dirvish-mouse-drag-drop
                    enhanced-dirvish-mouse-drag-copy enhanced-dirvish-mouse-drag-move
                    enhanced-dirvish-mouse-click-entry enhanced-dirvish-mouse-activate-at-event
                    enhanced-dirvish-mouse-toggle-select enhanced-dirvish-mouse-range-select
                    enhanced-dirvish-mouse-add-range-select
                    enhanced-dirvish-view-menu enhanced-dirvish-sort-menu
                    enhanced-dirvish-sidebar-mouse-activate enhanced-dirvish-computer-mouse-open
                    enhanced-dirvish-trash-mouse-select enhanced-dirvish-trash-mouse-restore
                    enhanced-dirvish-recent-mouse-click enhanced-dirvish-recent-mouse-activate
                    enhanced-dirvish-search-mouse-click enhanced-dirvish-search-mouse-activate))
    (advice-add command :around #'enhanced-dirvish-ui--mouse-command)))

(defun enhanced-dirvish-ui-choice (prompt choices &optional menu-p)
  "Ask PROMPT graphically, returning a value from labeled CHOICES.
Each choice is (LABEL . VALUE).  MENU-P requests a popup menu instead of a
button dialog.  Closing or cancelling the dialog aborts the action."
  (if menu-p
      (or (x-popup-menu t (list prompt (cons "" choices)))
          (signal 'quit nil))
    (x-popup-dialog t (cons prompt choices))))

(defun enhanced-dirvish-ui--gtk-entry (prompt &optional initial password-p)
  "Read text for PROMPT in a GTK entry dialog, with optional INITIAL text.
PASSWORD-P hides the text.  Cancel, close and C-g abort without returning a
value.  The process is reaped and temporary output erased on every exit."
  (let ((program (or (executable-find "zenity")
                     (user-error "GTK text dialogs require Zenity")))
        (output (generate-new-buffer " *Enhanced Dirvish dialog output*"))
        (errors (generate-new-buffer " *Enhanced Dirvish dialog errors*"))
        process)
    (unwind-protect
        (progn
          (setq process
                (make-process
                 :name "enhanced-dirvish-dialog" :buffer output :stderr errors :noquery t
                 :connection-type 'pipe :coding 'utf-8-unix :sentinel #'ignore
                 :command (append
                           (list program "--entry" "--modal" "--no-markup"
                                 "--title=Enhanced Dirvish Files" (concat "--text=" prompt))
                           (when password-p '("--hide-text"))
                           (when (and initial (not password-p))
                             (list (concat "--entry-text=" initial))))))
          ;; Wait for this modal dialog's process, without reading or draining
          ;; Emacs input.  C-g still unwinds and terminates the dialog.
          (while (process-live-p process) (accept-process-output process 0.05))
          (pcase (process-exit-status process)
            (0 (with-current-buffer output
                 (string-remove-suffix "\n" (buffer-string))))
            (1 (signal 'quit nil))
            (_ (user-error "The GTK dialog could not be opened"))))
      (when (and process (process-live-p process)) (delete-process process))
      (dolist (buffer (list output errors))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (erase-buffer))
          (kill-buffer buffer))))))

(defun enhanced-dirvish-ui-read-string (prompt &optional initial history default inherit)
  "Read text for PROMPT using the action's input method.
INITIAL, HISTORY, DEFAULT and INHERIT have the meanings used by `read-string'."
  (if (enhanced-dirvish-ui-mouse-p)
      (enhanced-dirvish-ui--gtk-entry prompt (or (if (consp initial) (car initial) initial)
                                      (if (consp default) (car default) default)))
    (read-string prompt initial history default inherit)))

(defun enhanced-dirvish-ui-completing-read (prompt collection &optional predicate require-match initial history default inherit)
  "Choose from COLLECTION using GUI menus for mouse actions.
Other arguments have the meanings used by `completing-read'."
  (if (not (enhanced-dirvish-ui-mouse-p))
      (completing-read prompt collection predicate require-match initial history default inherit)
    (if (functionp collection)
        ;; Dynamic path completion tables can probe remote directories.  Let
        ;; the mouse user enter a location without enumerating that table.
        (enhanced-dirvish-ui-read-string prompt initial history default)
      (let* ((candidates (all-completions "" collection predicate))
             (other (make-symbol "enter-value"))
             (choices (mapcar (lambda (value)
                               (cons (if (string-empty-p value) "(empty / clear)" value) value))
                             candidates)))
        (unless require-match
          (setq choices (append choices (list (cons "Enter another value…" other)))))
        (unless choices (user-error "No choices available"))
        (let ((choice (enhanced-dirvish-ui-choice prompt choices t)))
          (if (eq choice other)
              (enhanced-dirvish-ui-read-string prompt initial history default)
            choice))))))

(defun enhanced-dirvish-ui-read-directory-name (prompt &optional dir default mustmatch initial)
  "Select a directory graphically for mouse actions, or use a keyboard prompt."
  (if (enhanced-dirvish-ui-mouse-p)
      (or (x-file-dialog prompt (expand-file-name (or dir default-directory))
                         (or initial default) mustmatch t)
          (signal 'quit nil))
    (read-directory-name prompt dir default mustmatch initial)))

(defun enhanced-dirvish-ui-y-or-n-p (prompt)
  "Ask PROMPT with GUI buttons for mouse actions, or `y-or-n-p' for keyboard."
  (if (enhanced-dirvish-ui-mouse-p)
      (enhanced-dirvish-ui-choice prompt '(("Yes" . t) ("No" . nil)))
    (y-or-n-p prompt)))

(defun enhanced-dirvish-ui-yes-or-no-p (prompt)
  "Ask PROMPT with GUI buttons for mouse actions, or `yes-or-no-p' for keyboard."
  (if (enhanced-dirvish-ui-mouse-p)
      (enhanced-dirvish-ui-choice prompt '(("Yes" . t) ("No" . nil)))
    (yes-or-no-p prompt)))

(defun enhanced-dirvish-ui-read-passwd (prompt &optional confirm default)
  "Read a hidden password graphically for mouse actions or with `read-passwd'."
  (if (not (enhanced-dirvish-ui-mouse-p))
      (read-passwd prompt confirm default)
    (let ((password (enhanced-dirvish-ui--gtk-entry prompt nil t)))
      (when confirm
        (let ((again (enhanced-dirvish-ui--gtk-entry "Confirm password:" nil t)))
          (unwind-protect
              (unless (string= password again)
                (clear-string password)
                (user-error "Passwords do not match"))
            (clear-string again))))
      password)))

(provide 'enhanced-dirvish-ui)
;;; enhanced-dirvish-ui.el ends here
