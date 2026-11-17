;;; emacs-collab-mirror.el --- Choose where a project is mirrored  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Package-Requires: ((emacs "30.1"))
;; Keywords: collaboration

;;; Commentary:

;; Workspaces that mirror a remote project into a local directory ask
;; `emacs-collab-read-mirror-dir' where.  The answer is remembered per
;; (SERVICE, PROJECT-KEY) in `emacs-collab-mirror-state-file', so the next
;; open of the same project goes to the same directory without a prompt.
;; A marker file `.emacs-collab' in the mirror records what it mirrors;
;; a directory that is marked as another project is refused.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup emacs-collab-mirror nil
  "Where emacs-collab workspaces keep their local copies."
  :group 'emacs-collab)

(defcustom emacs-collab-mirror-root nil
  "Directory below which suggested mirrors go, or nil for none.
When set, the prompt for a new project starts at ROOT/SERVICE/PROJECT."
  :type '(choice (const :tag "None" nil) directory))

(defcustom emacs-collab-mirror-state-file
  (expand-file-name "emacs-collab-mirrors.eld"
                    (if (and (boundp 'doom-cache-dir) (stringp (symbol-value 'doom-cache-dir)))
                        (symbol-value 'doom-cache-dir)
                      user-emacs-directory))
  "File remembering the chosen mirror directory of each project.
Defaults to a sibling of `emacs-collab-layout-state-file'."
  :type 'file)

(defconst emacs-collab-mirror-marker ".emacs-collab"
  "Name of the file in a mirror that says which project it mirrors.")

(defvar emacs-collab-mirror--table 'unloaded
  "Alist ((SERVICE . PROJECT-KEY) . DIRECTORY), or `unloaded'.")


(defun emacs-collab-mirror--load ()
  (when (eq emacs-collab-mirror--table 'unloaded)
    (setq emacs-collab-mirror--table nil)
    (when (file-readable-p emacs-collab-mirror-state-file)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents emacs-collab-mirror-state-file)
            (let ((data (read (current-buffer))))
              (when (listp data) (setq emacs-collab-mirror--table data))))
        (error (message "emacs-collab-mirror: unreadable %s"
                        emacs-collab-mirror-state-file)))))
  emacs-collab-mirror--table)

(defun emacs-collab-mirror--save ()
  "Write the table atomically (temp file, then rename)."
  (let* ((file emacs-collab-mirror-state-file)
         (tmp (concat file ".tmp")))
    (condition-case err
        (progn
          (make-directory (file-name-directory file) t)
          (with-temp-file tmp
            (insert ";; emacs-collab mirror directories\n")
            (let ((print-length nil) (print-level nil))
              (prin1 emacs-collab-mirror--table (current-buffer)))
            (insert "\n"))
          (rename-file tmp file t))
      (error (message "emacs-collab-mirror: could not save: %s"
                      (error-message-string err))))))

(defun emacs-collab-mirror--key (service project-key)
  (cons (format "%s" service) (format "%s" project-key)))

(defun emacs-collab-mirror-remembered (service project-key)
  "The remembered mirror directory of (SERVICE, PROJECT-KEY), or nil."
  (cdr (assoc (emacs-collab-mirror--key service project-key)
              (emacs-collab-mirror--load))))

(defun emacs-collab-mirror--remember (service project-key dir)
  (let ((k (emacs-collab-mirror--key service project-key)))
    (emacs-collab-mirror--load)
    (setf (alist-get k emacs-collab-mirror--table nil nil #'equal) dir)
    (emacs-collab-mirror--save)))

;;;###autoload
(defun emacs-collab-forget-mirror (service project-key)
  "Drop the remembered mirror directory of (SERVICE, PROJECT-KEY).
Interactively, pick one of the remembered projects.  The directory itself
is left alone."
  (interactive
   (let* ((tbl (emacs-collab-mirror--load))
          (cands (mapcar (lambda (e) (cons (format "%s  %s  ->  %s" (caar e) (cdar e) (cdr e))
                                           (car e)))
                         tbl)))
     (unless cands (user-error "No remembered mirrors"))
     (let ((k (cdr (assoc (completing-read "Forget mirror: " cands nil t) cands))))
       (list (car k) (cdr k)))))
  (let ((k (emacs-collab-mirror--key service project-key)))
    (emacs-collab-mirror--load)
    (if (assoc k emacs-collab-mirror--table)
        (progn (setq emacs-collab-mirror--table
                     (cl-remove k emacs-collab-mirror--table :key #'car :test #'equal))
               (emacs-collab-mirror--save)
               (message "Forgot the mirror of %s %s" service project-key)
               t)
      (message "No remembered mirror for %s %s" service project-key)
      nil)))

(defun emacs-collab-mirror--slug (s)
  (string-trim (replace-regexp-in-string "[^[:alnum:]._-]+" "-" (format "%s" s)) "-+" "-+"))

(defun emacs-collab-mirror--read-marker (dir)
  "The (SERVICE . PROJECT-KEY) in DIR's marker, or nil."
  (let ((f (expand-file-name emacs-collab-mirror-marker dir)))
    (when (file-readable-p f)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents f)
            (let ((d (read (current-buffer))))
              (cons (plist-get d :service) (plist-get d :project))))
        (error nil)))))

(defun emacs-collab-mirror--write-marker (dir service project-key)
  (with-temp-file (expand-file-name emacs-collab-mirror-marker dir)
    (prin1 (list :service (format "%s" service) :project (format "%s" project-key))
           (current-buffer))
    (insert "\n")))

(defun emacs-collab-mirror--check (dir service project-key)
  "Signal a `user-error' if DIR is marked as another project; warn if foreign."
  (let ((marker (emacs-collab-mirror--read-marker dir))
        (mine (emacs-collab-mirror--key service project-key)))
    (cond
     (marker
      (unless (equal marker mine)
        (user-error "%s is already the mirror of %s %s" (abbreviate-file-name dir)
                    (car marker) (cdr marker))))
     ((directory-files dir nil directory-files-no-dot-files-regexp t 1)
      (display-warning 'emacs-collab
                       (format "%s is not empty and is not a known mirror of %s %s"
                               (abbreviate-file-name dir) service project-key))))))

;;;###autoload
(defun emacs-collab-read-mirror-dir (service project-key &optional suggestion force)
  "Return the directory (with trailing slash) mirroring PROJECT-KEY of SERVICE.
A directory remembered for (SERVICE, PROJECT-KEY) is used without asking
unless FORCE.  Otherwise prompt, starting from the remembered directory,
else SUGGESTION, else `emacs-collab-mirror-root'/SERVICE/PROJECT, else
`default-directory'.  The directory is created, marked with
`emacs-collab-mirror-marker' and remembered.  A directory marked as a
different project is refused with a `user-error'; a non-empty unmarked one
only draws a warning."
  (let* ((remembered (emacs-collab-mirror-remembered service project-key))
         (dir (if (and remembered (not force))
                  remembered
                (read-directory-name
                 (format "Local copy of %s in: " project-key)
                 (file-name-as-directory
                  (expand-file-name
                   (or remembered suggestion
                       (and emacs-collab-mirror-root
                            (expand-file-name
                             (concat (emacs-collab-mirror--slug service) "/"
                                     (emacs-collab-mirror--slug project-key))
                             emacs-collab-mirror-root))
                       default-directory)))))))
    (setq dir (file-name-as-directory (expand-file-name dir)))
    (unless (file-directory-p dir) (make-directory dir t))
    (emacs-collab-mirror--check dir service project-key)
    (emacs-collab-mirror--write-marker dir service project-key)
    (unless (equal remembered dir)
      (emacs-collab-mirror--remember service project-key dir))
    dir))

(provide 'emacs-collab-mirror)
;;; emacs-collab-mirror.el ends here
