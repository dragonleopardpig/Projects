;;; strata-dirvish-ui.el --- Mouse dialogs and keyboard prompts -*- lexical-binding: t; -*-

;;; Commentary:
;; File actions retain their input method through all follow-up questions.
;; Mouse actions use native menus, file choosers and GTK text/password dialogs;
;; keyboard actions use the original Emacs prompts.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar strata-ui-input-method nil
  "Input method for the active action: `mouse', `keyboard', or nil to detect.
Dynamically bound for an entire mouse action, including follow-up dialogs.")

(defun strata-ui-mouse-p ()
  "Return non-nil when the current action should ask questions graphically."
  (and (display-graphic-p) (display-popup-menus-p)
       (pcase strata-ui-input-method
         ('mouse t)
         ('keyboard nil)
         (_ (or (mouse-event-p last-input-event)
                (mouse-event-p last-nonmenu-event))))))

(defun strata-ui--mouse-command (original &rest args)
  "Run mouse command ORIGINAL with ARGS, preserving its interaction method."
  (let ((strata-ui-input-method 'mouse)
        (use-dialog-box t)
        (use-file-dialog t))
    (apply original args)))

(defun strata-ui-install-mouse-routing ()
  "Keep follow-up prompts graphical for all Strata mouse file entry points."
  (dolist (command '(strata-mouse-context-menu strata-mouse-drag-drop
                    strata-mouse-click-entry strata-mouse-activate-at-event
                    strata-sidebar-mouse-activate strata-computer-mouse-open
                    strata-trash-mouse-restore strata-recent-mouse-click
                    strata-recent-mouse-activate))
    (advice-add command :around #'strata-ui--mouse-command)))

(defun strata-ui-choice (prompt choices &optional menu-p)
  "Ask PROMPT graphically, returning a value from labeled CHOICES.
Each choice is (LABEL . VALUE).  MENU-P requests a popup menu instead of a
button dialog.  Closing or cancelling the dialog aborts the action."
  (if menu-p
      (or (x-popup-menu t (list prompt (cons "" choices)))
          (signal 'quit nil))
    (x-popup-dialog t (cons prompt choices))))

(defun strata-ui--gtk-entry (prompt &optional initial password-p)
  "Read text for PROMPT in a GTK entry dialog, with optional INITIAL text.
PASSWORD-P hides the text.  Cancel, close and C-g abort without returning a
value.  The process is reaped and temporary output erased on every exit."
  (let ((program (or (executable-find "zenity")
                     (user-error "GTK text dialogs require Zenity")))
        (output (generate-new-buffer " *Strata dialog output*"))
        (errors (generate-new-buffer " *Strata dialog errors*"))
        process)
    (unwind-protect
        (progn
          (setq process
                (make-process
                 :name "strata-dialog" :buffer output :stderr errors :noquery t
                 :connection-type 'pipe :coding 'utf-8-unix :sentinel #'ignore
                 :command (append
                           (list program "--entry" "--modal" "--no-markup"
                                 "--title=Strata Files" (concat "--text=" prompt))
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

(defun strata-ui-read-string (prompt &optional initial history default inherit)
  "Read text for PROMPT using the action's input method.
INITIAL, HISTORY, DEFAULT and INHERIT have the meanings used by `read-string'."
  (if (strata-ui-mouse-p)
      (strata-ui--gtk-entry prompt (or (if (consp initial) (car initial) initial)
                                      (if (consp default) (car default) default)))
    (read-string prompt initial history default inherit)))

(defun strata-ui-completing-read (prompt collection &optional predicate require-match initial history default inherit)
  "Choose from COLLECTION using GUI menus for mouse actions.
Other arguments have the meanings used by `completing-read'."
  (if (not (strata-ui-mouse-p))
      (completing-read prompt collection predicate require-match initial history default inherit)
    (if (functionp collection)
        ;; Dynamic path completion tables can probe remote directories.  Let
        ;; the mouse user enter a location without enumerating that table.
        (strata-ui-read-string prompt initial history default)
      (let* ((candidates (all-completions "" collection predicate))
             (other (make-symbol "enter-value"))
             (choices (mapcar (lambda (value)
                               (cons (if (string-empty-p value) "(empty / clear)" value) value))
                             candidates)))
        (unless require-match
          (setq choices (append choices (list (cons "Enter another value…" other)))))
        (unless choices (user-error "No choices available"))
        (let ((choice (strata-ui-choice prompt choices t)))
          (if (eq choice other)
              (strata-ui-read-string prompt initial history default)
            choice))))))

(defun strata-ui-read-directory-name (prompt &optional dir default mustmatch initial)
  "Select a directory graphically for mouse actions, or use a keyboard prompt."
  (if (strata-ui-mouse-p)
      (or (x-file-dialog prompt (expand-file-name (or dir default-directory))
                         (or initial default) mustmatch t)
          (signal 'quit nil))
    (read-directory-name prompt dir default mustmatch initial)))

(defun strata-ui-y-or-n-p (prompt)
  "Ask PROMPT with GUI buttons for mouse actions, or `y-or-n-p' for keyboard."
  (if (strata-ui-mouse-p)
      (strata-ui-choice prompt '(("Yes" . t) ("No" . nil)))
    (y-or-n-p prompt)))

(defun strata-ui-yes-or-no-p (prompt)
  "Ask PROMPT with GUI buttons for mouse actions, or `yes-or-no-p' for keyboard."
  (if (strata-ui-mouse-p)
      (strata-ui-choice prompt '(("Yes" . t) ("No" . nil)))
    (yes-or-no-p prompt)))

(defun strata-ui-read-passwd (prompt &optional confirm default)
  "Read a hidden password graphically for mouse actions or with `read-passwd'."
  (if (not (strata-ui-mouse-p))
      (read-passwd prompt confirm default)
    (let ((password (strata-ui--gtk-entry prompt nil t)))
      (when confirm
        (let ((again (strata-ui--gtk-entry "Confirm password:" nil t)))
          (unwind-protect
              (unless (string= password again)
                (clear-string password)
                (user-error "Passwords do not match"))
            (clear-string again))))
      password)))

(provide 'strata-dirvish-ui)
;;; strata-dirvish-ui.el ends here
