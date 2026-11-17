;;; emacs-collab-layout.el --- Service-agnostic project window layout and quit  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Package-Requires: ((emacs "30.1") (emacs-collab "0.1"))
;; Keywords: convenience, frames
;; Version: 0.1

;; This file is part of emacs-collab.el.
;; It is free software: you can redistribute it and/or modify it under
;; the terms of the GNU General Public License as published by the Free
;; Software Foundation, either version 3 of the License, or (at your
;; option) any later version.  It is distributed WITHOUT ANY WARRANTY.

;;; Commentary:

;; One declarative layout for a project workspace, whatever service it
;; edits against (Noteworthy, Overleaf, ...):
;;
;;   +------+----------------------+---------+---------+
;;   | tree |        editor        |   pdf   | preview |
;;   |      +----------------------+---------+---------+
;;   |      |                terminal                  |
;;   +------+------------------------------------------+
;;
;;   (emacs-collab-layout-build :root "~/proj/" :main-file "main.tex"
;;                              :tree t :terminal t
;;                              :pdf "build/main.pdf"
;;                              :preview '(xwidget "http://localhost:23627")
;;                              :on-quit #'my-cleanup)
;;
;; Every pane but the editor is optional, and so is every package that
;; draws one: treemacs (tree), vterm (terminal; falls back to `shell'),
;; xwidgets (preview), pdf-tools (pdf; falls back to whatever opens the
;; file), lsp-mode (root registration, shutdown).  Nothing here
;; `require's them hard.
;;
;; Windows carry the parameter `emacs-collab-role' (editor, tree,
;; preview, pdf or terminal) and `emacs-collab-layout-root'.  Their
;; sizes are remembered per project in `emacs-collab-layout-state-file'.
;; `emacs-collab-layout-quit' undoes everything the layout started.
;;
;; To build the layout whenever a bridge is ready:
;;
;;   (add-hook \='emacs-collab-ready-functions #\='emacs-collab-layout-for-connection)

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-collab)

(defgroup emacs-collab-layout nil
  "Project window layout for emacs-collab workspaces."
  :group 'emacs-collab)

(defcustom emacs-collab-layout-state-file
  (expand-file-name "emacs-collab-layout.eld"
                    (if (and (boundp 'doom-cache-dir) (stringp (symbol-value 'doom-cache-dir)))
                        (symbol-value 'doom-cache-dir)
                      user-emacs-directory))
  "File remembering each project's window sizes."
  :type 'file)

(defcustom emacs-collab-layout-default-sizes
  '(:tree-width 30 :preview-width 0.35 :pdf-width 0.35 :terminal-height 0.25)
  "Default pane sizes.  A float is a fraction of the frame, an integer cells."
  :type 'plist)

(defcustom emacs-collab-layout-default-args nil
  "Plist of `emacs-collab-layout-build' arguments for connections.
Used by `emacs-collab-layout-for-connection'.  May be a function called
with the connection that returns such a plist."
  :type '(choice plist function))

(defcustom emacs-collab-layout-register-lsp t
  "Whether the layout makes the project root an lsp-mode workspace folder."
  :type 'boolean)

;;; State

(cl-defstruct (emacs-collab-layout-project (:constructor emacs-collab-layout--make)
                                           (:copier nil))
  root main conn on-quit terminal pdf pdf-file preview processes buffers
  preview-spec editor-buffer)

(defvar emacs-collab-layout--projects nil
  "Open layouts: list of `emacs-collab-layout-project', newest first.")

(defvar emacs-collab-layout--sizes nil
  "Alist ROOT -> plist of pane sizes.
Keys: :tree-width :preview-width :pdf-width :terminal-height.")

(defvar emacs-collab-layout--sizes-loaded nil)
(defvar emacs-collab-layout--building nil
  "Non-nil while a layout is built, so transient sizes are not recorded.")

(defvar emacs-collab-layout-last-root nil
  "Root of the layout built last (used when the current buffer says nothing).")

(defvar-local emacs-collab-layout--buffer-root nil
  "Project root a buffer of the layout belongs to.")

(defun emacs-collab-layout--canon (dir)
  (file-name-as-directory (file-truename (expand-file-name dir))))

(defun emacs-collab-layout-project (&optional root)
  "The layout project for ROOT, or for the current buffer when ROOT is nil."
  (let ((root (and root (emacs-collab-layout--canon root))))
    (cl-find-if
     (lambda (p)
       (if root
           (equal (emacs-collab-layout-project-root p) root)
         (emacs-collab-layout--in-root-p (or buffer-file-name default-directory)
                                         (emacs-collab-layout-project-root p))))
     emacs-collab-layout--projects)))

(defun emacs-collab-layout--in-root-p (file root)
  (and file root (file-in-directory-p (file-truename file) root)))

(defun emacs-collab-layout--current-project ()
  (or (and emacs-collab-layout--buffer-root
           (emacs-collab-layout-project emacs-collab-layout--buffer-root))
      (emacs-collab-layout-project)
      (and emacs-collab-layout-last-root
           (emacs-collab-layout-project emacs-collab-layout-last-root))
      (car emacs-collab-layout--projects)))

;;; Persisted sizes

(defun emacs-collab-layout--load-state ()
  (unless emacs-collab-layout--sizes-loaded
    (setq emacs-collab-layout--sizes-loaded t)
    (when (file-readable-p emacs-collab-layout-state-file)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents emacs-collab-layout-state-file)
            (let ((data (read (current-buffer))))
              (when (listp data)
                (dolist (e data)
                  (unless (assoc (car e) emacs-collab-layout--sizes)
                    (push e emacs-collab-layout--sizes))))))
        (error (message "emacs-collab-layout: unreadable %s"
                        emacs-collab-layout-state-file))))))

(defun emacs-collab-layout-save-state ()
  "Write the remembered window sizes to `emacs-collab-layout-state-file'."
  (interactive)
  (emacs-collab-layout--load-state)
  (when emacs-collab-layout--sizes
    (condition-case err
        (progn
          (make-directory (file-name-directory emacs-collab-layout-state-file) t)
          (with-temp-file emacs-collab-layout-state-file
            (insert ";; emacs-collab-layout window sizes\n")
            (let ((print-length nil) (print-level nil))
              (prin1 emacs-collab-layout--sizes (current-buffer)))
            (insert "\n")))
      (error (message "emacs-collab-layout: could not save sizes: %s"
                      (error-message-string err))))))

(defun emacs-collab-layout-sizes (root)
  "Remembered sizes of ROOT merged over the defaults (a plist)."
  (emacs-collab-layout--load-state)
  (let ((saved (cdr (assoc (emacs-collab-layout--canon root)
                           emacs-collab-layout--sizes)))
        (res (copy-sequence emacs-collab-layout-default-sizes)))
    (cl-loop for (k v) on saved by #'cddr do (setq res (plist-put res k v)))
    res))

(defun emacs-collab-layout-record-sizes (&optional frame)
  "Remember the current pane sizes of every layout shown in FRAME."
  (unless emacs-collab-layout--building
    (dolist (w (window-list frame 'no-minibuf))
      (when-let* ((role (window-parameter w 'emacs-collab-role))
                  (root (window-parameter w 'emacs-collab-layout-root))
                  (key (pcase role
                         ('tree :tree-width) ('preview :preview-width)
                         ('pdf :pdf-width) ('terminal :terminal-height))))
        (let* ((cell (or (assoc root emacs-collab-layout--sizes)
                         (car (push (list root) emacs-collab-layout--sizes))))
               (val (if (eq role 'terminal) (window-total-height w) (window-total-width w))))
          (setcdr cell (plist-put (cdr cell) key val)))))))

(defun emacs-collab-layout--on-exit ()
  (emacs-collab-layout-record-sizes)
  (emacs-collab-layout-save-state))

(defun emacs-collab-layout--install-hooks ()
  (add-hook 'window-size-change-functions #'emacs-collab-layout-record-sizes)
  (add-hook 'kill-emacs-hook #'emacs-collab-layout--on-exit))

(defun emacs-collab-layout--remove-hooks ()
  (remove-hook 'window-size-change-functions #'emacs-collab-layout-record-sizes)
  (remove-hook 'kill-emacs-hook #'emacs-collab-layout--on-exit))

;;; Windows by role

(defun emacs-collab-layout-window (role &optional root frame)
  "The live window with ROLE (and project ROOT, if given) in FRAME."
  (let ((root (and root (emacs-collab-layout--canon root))))
    (or (cl-find-if (lambda (w)
                      (and (eq (window-parameter w 'emacs-collab-role) role)
                           (or (null root)
                               (equal (window-parameter w 'emacs-collab-layout-root) root))))
                    (window-list frame 'no-minibuf))
        (and (eq role 'tree) (fboundp 'treemacs-get-local-window)
             (treemacs-get-local-window)))))

(defun emacs-collab-layout--mark (win role root)
  (when (window-live-p win)
    (set-window-parameter win 'emacs-collab-role role)
    (set-window-parameter win 'emacs-collab-layout-root root))
  win)

(defun emacs-collab-layout-select (role)
  "Select the window with ROLE, or signal a `user-error'."
  (if-let* ((w (emacs-collab-layout-window role)))
      (select-window w)
    (user-error "No %s window in this layout" role)))

(dolist (role '(editor tree preview pdf terminal))
  (let ((name (intern (format "emacs-collab-layout-select-%s" role))))
    (defalias name (lambda () (interactive) (emacs-collab-layout-select role))
      (format "Select the %s window of the layout." role))))

(defun emacs-collab-layout--clamp (size total)
  "SIZE (a float fraction of TOTAL, or cells) as cells, leaving room."
  (let ((n (if (floatp size) (round (* size total)) size)))
    (max window-min-width (min n (max window-min-width (- total window-min-width 1))))))

;;; Optional-package helpers

(defun emacs-collab-layout--have (feature)
  (or (featurep feature) (require feature nil t)))

(defun emacs-collab-layout--xwidgets-p ()
  (and (display-graphic-p) (fboundp 'make-xwidget) (fboundp 'xwidget-webkit-browse-url)
       (or (featurep 'xwidget-internal) (boundp 'xwidget-webkit-mode-map))))

(defvar treemacs--find-user-project-functions)
(declare-function treemacs "treemacs")
(declare-function treemacs-add-and-display-current-project-exclusively "treemacs")
(declare-function treemacs-get-local-window "treemacs")
(defvar treemacs-width)

(defun emacs-collab-layout--treemacs-show-root (dir)
  "Make DIR the one project Treemacs shows.
DIR itself, not the repository it lies in, which project.el or
projectile would find by walking up."
  (let ((default-directory dir)
        (treemacs--find-user-project-functions (list (lambda () dir))))
    (treemacs-add-and-display-current-project-exclusively)))

(defun emacs-collab-layout--enforce-treemacs-root (root)
  (when (and (file-directory-p root) (fboundp 'treemacs-get-local-window))
    (when-let* ((w (treemacs-get-local-window)))
      (with-selected-window w
        (condition-case err
            (emacs-collab-layout--treemacs-show-root root)
          (error (message "emacs-collab-layout: treemacs root: %s" err)))))))

(declare-function lsp-session "lsp-mode")
(declare-function lsp-session-folders "lsp-mode")
(declare-function lsp-f-canonical "lsp-mode")
(declare-function lsp-workspace-folders-add "lsp-mode")
(declare-function lsp-workspace-shutdown "lsp-mode")
(declare-function lsp--session-workspaces "lsp-mode")
(declare-function lsp--workspace-root "lsp-mode")

(defun emacs-collab-layout-register-lsp-root (dir)
  "Make DIR a language server root, so lsp-mode does not guess one.
No-op when lsp-mode is not available."
  (when (and emacs-collab-layout-register-lsp (emacs-collab-layout--have 'lsp-mode)
             (fboundp 'lsp-workspace-folders-add))
    (condition-case nil
        (unless (member (lsp-f-canonical dir) (lsp-session-folders (lsp-session)))
          (lsp-workspace-folders-add dir))
      (error nil))))

(defun emacs-collab-layout--lsp-shutdown (root)
  (when (and (featurep 'lsp-mode) (fboundp 'lsp-session))
    (dolist (ws (ignore-errors (lsp--session-workspaces (lsp-session))))
      (when (equal (file-name-as-directory (expand-file-name (lsp--workspace-root ws))) root)
        (ignore-errors (lsp-workspace-shutdown ws))))))

;;; Terminal

(defvar vterm-shell)
(declare-function vterm "vterm")
(defvar explicit-shell-file-name)

(defun emacs-collab-layout--terminal-name (root)
  (format "*emacs-collab-term: %s*"
          (file-name-nondirectory (directory-file-name root))))

(defun emacs-collab-layout--make-terminal (root cmd)
  "Start a terminal in ROOT running CMD (nil/t: the default shell)."
  (let* ((name (emacs-collab-layout--terminal-name root))
         (default-directory root)
         (argv (cond ((stringp cmd) (split-string-and-unquote cmd))
                     ((consp cmd) cmd)))
         (prog (or (car argv) (getenv "SHELL") (executable-find "bash") "sh"))
         (line (mapconcat #'identity (or argv (list prog)) " ")))
    (or (and (get-buffer name) (get-buffer-process (get-buffer name)) (get-buffer name))
        (or (and (emacs-collab-layout--have 'vterm) (fboundp 'vterm)
                 (condition-case nil
                     (let ((vterm-shell line) (display-buffer-alist nil))
                       (vterm name)
                       (current-buffer))
                   (error nil)))
            (let ((explicit-shell-file-name prog)
                  (display-buffer-alist nil))
              (shell name)
              (current-buffer))))))

;;; Panes

(defun emacs-collab-layout--pdf-placeholder (root file)
  (with-current-buffer (get-buffer-create
                        (format "*emacs-collab-pdf: %s*"
                                (file-name-nondirectory (directory-file-name root))))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (format "No PDF yet.\nExpected: %s\n" (or file "(unknown)"))))
    (special-mode)
    (current-buffer)))

(declare-function pdf-tools-install "pdf-tools")
(declare-function pdf-view-fit-width-to-window "pdf-view")
(defvar pdf-view-mode)

(defun emacs-collab-layout--visit-pdf (file)
  "Visit FILE with the best viewer around; return the buffer or nil."
  (when (and (display-graphic-p) (emacs-collab-layout--have 'pdf-tools)
             (fboundp 'pdf-tools-install))
    (ignore-errors (pdf-tools-install t t t)))
  (condition-case nil
      (find-file-noselect file)
    (error nil)))

(defun emacs-collab-layout-show-pdf (&optional file root)
  "Show FILE in ROOT's pdf pane, remembering it as the layout's PDF.
FILE defaults to the one given to the layout.  Does nothing if the file
does not exist yet or there is no pdf pane."
  (interactive)
  (when-let* ((p (if root (emacs-collab-layout-project root)
                   (emacs-collab-layout--current-project)))
              (file (or file (emacs-collab-layout-project-pdf-file p)))
              (win (emacs-collab-layout-window 'pdf (emacs-collab-layout-project-root p))))
    (setf (emacs-collab-layout-project-pdf-file p) file)
    (when (file-regular-p file)
      (when-let* ((buf (emacs-collab-layout--visit-pdf file)))
        (set-window-buffer win buf)
        (setf (emacs-collab-layout-project-pdf p) buf)
        (with-current-buffer buf
          (setq emacs-collab-layout--buffer-root (emacs-collab-layout-project-root p)))
        (when (and (display-graphic-p) (bound-and-true-p pdf-view-mode))
          (run-with-timer 0.1 nil
                          (lambda (w)
                            (when (and (window-live-p w) (fboundp 'pdf-view-fit-width-to-window))
                              (with-selected-window w
                                (ignore-errors (pdf-view-fit-width-to-window)))))
                          win))
        buf))))

(defun emacs-collab-layout-register-process (proc &optional root)
  "Make the quit of ROOT's layout (default: the current one) kill PROC."
  (when-let* ((p (if root (emacs-collab-layout-project root)
                   (emacs-collab-layout--current-project))))
    (cl-pushnew proc (emacs-collab-layout-project-processes p))
    proc))

(defun emacs-collab-layout-register-buffer (buf &optional root)
  "Make the quit of ROOT's layout (default: the current one) kill BUF."
  (when-let* ((p (if root (emacs-collab-layout-project root)
                   (emacs-collab-layout--current-project))))
    (cl-pushnew buf (emacs-collab-layout-project-buffers p))
    buf))

(declare-function xwidget-webkit-browse-url "xwidget")
(declare-function typst-preview-start "typst-preview")
(declare-function typst-preview-stop "typst-preview")

(defun emacs-collab-layout--preview-available-p (spec)
  (pcase spec
    ((or 'nil 'none) nil)
    ((pred functionp) t)
    (`(xwidget . ,_) (emacs-collab-layout--xwidgets-p))
    (`(typst-preview . ,_) (and (emacs-collab-layout--xwidgets-p)
                                (emacs-collab-layout--have 'typst-preview)
                                (fboundp 'typst-preview-start)))
    (`(pdf . ,_) t)
    (_ nil)))

(defun emacs-collab-layout--fill-preview (p win)
  "Show the preview of P in WIN (selected).  Return the buffer or nil."
  (let* ((spec (emacs-collab-layout-project-preview-spec p))
         (root (emacs-collab-layout-project-root p))
         (display-buffer-overriding-action '(display-buffer-same-window))
         (before (buffer-list))
         buf)
    (setq buf
          (pcase spec
            ((pred functionp) (funcall spec root))
            (`(xwidget ,url . ,_)
             (xwidget-webkit-browse-url url t) (current-buffer))
            (`(typst-preview . ,_)
             (when-let* ((eb (emacs-collab-layout-project-editor-buffer p)))
               (with-current-buffer eb
                 (typst-preview-start t)))
             (current-buffer))
            (`(pdf ,file . ,_) (emacs-collab-layout--visit-pdf file))))
    (when (and (bufferp buf) (buffer-live-p buf))
      (set-window-buffer win buf))
    ;; Whatever the preview started: kill it at quit.
    (dolist (b (buffer-list))
      (unless (memq b before)
        (when (eq (buffer-local-value 'major-mode b) 'xwidget-webkit-mode)
          (cl-pushnew b (emacs-collab-layout-project-preview p)))))
    (when (and (bufferp buf) (buffer-live-p buf))
      (cl-pushnew buf (emacs-collab-layout-project-preview p)))
    buf))

;;; Build

(defvar emacs-collab-layout-after-build-hook nil
  "Hook run, in the editor window, after `emacs-collab-layout-build'.")

;;;###autoload
(cl-defun emacs-collab-layout-build (&key root main-file tree terminal preview pdf
                                          on-quit connection)
  "Build the project window layout and return the editor window.
ROOT is the project directory.  MAIN-FILE (absolute, or relative to ROOT)
opens in the editor.  TREE non-nil shows treemacs pinned to ROOT.
TERMINAL non-nil runs a shell below the editor: t for the default one, or
a command (string or argv list).  PREVIEW is nil, a function (called with
ROOT in the preview window, returning a buffer), (xwidget URL),
\(typst-preview) or (pdf FILE).  PDF is a file, or a function returning one,
shown in a pane beside the editor; it may not exist yet (see
`emacs-collab-layout-show-pdf').  ON-QUIT is called with ROOT at the
start of `emacs-collab-layout-quit'.  CONNECTION is the emacs-collab
connection to close at quit (default: the one rooted at ROOT)."
  (unless root (user-error "emacs-collab-layout-build: no :root"))
  (let* ((root (emacs-collab-layout--canon root))
         (old (emacs-collab-layout-project root))
         (emacs-collab-layout--building t)
         (sizes (emacs-collab-layout-sizes root))
         (main (and main-file (expand-file-name main-file root)))
         (pdf-file (if (functionp pdf) (funcall pdf) pdf))
         (p (emacs-collab-layout--make
             :root root :main main :on-quit on-quit :preview-spec preview
             :conn (or connection
                       (cl-find-if (lambda (c) (equal (emacs-collab-conn-root-true c) root))
                                   emacs-collab--connections))
             :pdf-file pdf-file))
         editor)
    (when old (emacs-collab-layout-quit root 'no-close))
    (setq emacs-collab-layout--projects
          (cons p (delq old emacs-collab-layout--projects))
          emacs-collab-layout-last-root root)
    (emacs-collab-layout--install-hooks)
    (delete-other-windows)
    (when emacs-collab-layout-register-lsp
      (emacs-collab-layout-register-lsp-root root))
    ;; The editor.
    (let ((default-directory root))
      (switch-to-buffer
       (if (and main (file-exists-p main))
           (find-file-noselect main)
         (dired-noselect root))))
    (setf (emacs-collab-layout-project-editor-buffer p) (current-buffer))
    (setq editor (emacs-collab-layout--mark (selected-window) 'editor root))
    ;; Tree (left).
    (when (and tree (emacs-collab-layout--have 'treemacs) (fboundp 'treemacs))
      (condition-case err
          (let ((treemacs-width (emacs-collab-layout--clamp
                                 (plist-get sizes :tree-width) (frame-width))))
            ;; Pinning the root displays treemacs itself; calling `treemacs'
            ;; first would prompt for a project when its workspace is empty.
            (emacs-collab-layout--treemacs-show-root root)
            (unless (treemacs-get-local-window) (treemacs))
            (emacs-collab-layout--mark (treemacs-get-local-window) 'tree root))
        (error (message "emacs-collab-layout: no tree: %s" (error-message-string err)))))
    ;; Terminal (below the editor).
    (when terminal
      (select-window editor)
      (let* ((h (window-total-height editor))
             (th (max window-min-height
                      (min (let ((s (plist-get sizes :terminal-height)))
                             (if (floatp s) (round (* s h)) s))
                           (- h window-min-height 1))))
             (tw (ignore-errors (split-window editor (- th) 'below))))
        (when tw
          (select-window tw)
          (when-let* ((buf (emacs-collab-layout--make-terminal
                            root (if (eq terminal t) nil terminal))))
            (set-window-buffer tw buf)
            (setf (emacs-collab-layout-project-terminal p) buf)
            (with-current-buffer buf (setq emacs-collab-layout--buffer-root root)))
          (emacs-collab-layout--mark tw 'terminal root))))
    ;; Preview (rightmost: split first, the pdf pane then goes between).
    (when (emacs-collab-layout--preview-available-p preview)
      (select-window editor)
      (let* ((w (emacs-collab-layout--clamp (plist-get sizes :preview-width)
                                            (window-total-width editor)))
             (vw (ignore-errors (split-window editor (- w) 'right))))
        (when vw
          (emacs-collab-layout--mark vw 'preview root)
          (select-window vw)
          (let ((buf (condition-case err
                         (emacs-collab-layout--fill-preview p vw)
                       (error (message "emacs-collab-layout: preview: %s"
                                       (error-message-string err))
                              nil))))
            (unless buf (ignore-errors (delete-window vw)))))))
    ;; PDF (right of the editor, left of the preview).
    (when pdf-file
      (select-window editor)
      (let* ((w (emacs-collab-layout--clamp (plist-get sizes :pdf-width)
                                            (window-total-width editor)))
             (pw (ignore-errors (split-window editor (- w) 'right))))
        (when pw
          (emacs-collab-layout--mark pw 'pdf root)
          (set-window-buffer pw (emacs-collab-layout--pdf-placeholder root pdf-file))
          (set-window-dedicated-p pw nil)
          (emacs-collab-layout-show-pdf pdf-file root))))
    (when (window-live-p editor) (select-window editor))
    (run-hooks 'emacs-collab-layout-after-build-hook)
    (when tree
      (run-with-timer 1.0 nil #'emacs-collab-layout--enforce-treemacs-root root))
    (message "Workspace ready: %s" (abbreviate-file-name root))
    editor))

;;; Connection hook

(defun emacs-collab-layout--project-main (conn)
  (let* ((project (emacs-collab-conn-project conn))
         (main (alist-get 'main project))
         (files (alist-get 'files project)))
    (or (and (stringp main) main)
        (and (vectorp files) (> (length files) 0) (aref files 0))
        (and (consp files) (car files)))))

;;;###autoload
(defun emacs-collab-layout-for-connection (conn &optional args)
  "Build the layout for the project of CONN.
Fit for `emacs-collab-ready-functions'.  The root and main file come from
the bridge's `ready'; ARGS (default `emacs-collab-layout-default-args') is
a plist of further `emacs-collab-layout-build' arguments, or a function
of CONN returning one."
  (let* ((args (or args (if (functionp emacs-collab-layout-default-args)
                            (funcall emacs-collab-layout-default-args conn)
                          emacs-collab-layout-default-args)))
         (args (cl-loop for (k v) on args by #'cddr
                        unless (memq k '(:root :main-file :connection))
                        append (list k v))))
    (apply #'emacs-collab-layout-build
           :root (emacs-collab-conn-root conn)
           :main-file (emacs-collab-layout--project-main conn)
           :connection conn
           args)))

;;; Quit

(defun emacs-collab-layout--quit-terminal (buf)
  "Kill the terminal BUF, asking only if a command is running in it.
An idle shell is just a prompt; Emacs would ask about it anyway."
  (let ((proc (get-buffer-process buf)))
    (when (and proc (not (process-running-child-p proc)))
      (set-process-query-on-exit-flag proc nil))
    (kill-buffer buf)))

(defun emacs-collab-layout--kill-xwidget-buffer (b)
  (when (and (buffer-live-p b) (fboundp 'get-buffer-xwidgets))
    (dolist (xw (get-buffer-xwidgets b))
      (set-xwidget-query-on-exit-flag xw nil)))
  (when (buffer-live-p b) (kill-buffer b)))

(declare-function get-buffer-xwidgets "xwidget.c" (buffer))
(declare-function set-xwidget-query-on-exit-flag "xwidget.c" (xwidget flag))
(declare-function +doom-dashboard/open "doom-dashboard")

;;;###autoload
(defun emacs-collab-layout-quit (&optional root no-close)
  "Close the workspace of ROOT and everything its layout started.
ROOT defaults to the current buffer's project.  Offers to save the
project's modified files first; a file left unsaved is asked about
again rather than killed.  Then stops the preview processes and kills the
preview xwidgets, shuts down this project's language server, disconnects
the emacs-collab bridge, runs the layout's `:on-quit', kills the
project's buffers, the PDF and the terminal (asking only if a command is
running in it), closes treemacs and returns to the dashboard.
With NO-CLOSE (used internally when rebuilding), keep the windows."
  (interactive)
  (let* ((p (if root (emacs-collab-layout-project root)
              (emacs-collab-layout--current-project)))
         (root (cond (p (emacs-collab-layout-project-root p))
                     (root (emacs-collab-layout--canon root))
                     (t (user-error "No workspace is open")))))
    ;; 1. Save first, so nothing below has to decide about unsaved work.
    (save-some-buffers nil (lambda () (emacs-collab-layout--in-root-p buffer-file-name root)))
    (emacs-collab-layout-record-sizes)
    (emacs-collab-layout-save-state)
    ;; 2. Preview: processes, typst-preview, xwidgets.
    (when p
      (when (and (consp (emacs-collab-layout-project-preview-spec p))
                 (eq (car (emacs-collab-layout-project-preview-spec p)) 'typst-preview)
                 (fboundp 'typst-preview-stop))
        (ignore-errors
          (with-current-buffer (or (emacs-collab-layout-project-editor-buffer p)
                                   (current-buffer))
            (typst-preview-stop))))
      (dolist (proc (emacs-collab-layout-project-processes p))
        (when (processp proc)
          (set-process-query-on-exit-flag proc nil)
          (when (process-live-p proc) (delete-process proc))))
      (dolist (b (append (emacs-collab-layout-project-buffers p)
                         (emacs-collab-layout-project-preview p)))
        (when (buffer-live-p b)
          (when-let* ((proc (get-buffer-process b)))
            (set-process-query-on-exit-flag proc nil))
          (emacs-collab-layout--kill-xwidget-buffer b))))
    ;; 3. This project's language server.
    (emacs-collab-layout--lsp-shutdown root)
    ;; 4. Collaboration, before its buffers go.
    (let ((conn (or (and p (emacs-collab-layout-project-conn p))
                    (cl-find-if (lambda (c) (equal (emacs-collab-conn-root-true c) root))
                                emacs-collab--connections))))
      (when (and conn (memq conn emacs-collab--connections))
        (emacs-collab-disconnect conn)))
    (when (and p (emacs-collab-layout-project-on-quit p))
      (condition-case err (funcall (emacs-collab-layout-project-on-quit p) root)
        (error (message "emacs-collab-layout: on-quit: %s" (error-message-string err)))))
    ;; 5. The project's buffers, the PDF and the terminal.
    (when (and p (buffer-live-p (emacs-collab-layout-project-pdf p)))
      (kill-buffer (emacs-collab-layout-project-pdf p)))
    (when-let* ((term (and p (emacs-collab-layout-project-terminal p))))
      (when (buffer-live-p term) (emacs-collab-layout--quit-terminal term)))
    (dolist (b (buffer-list))
      (when (buffer-live-p b)
        (with-current-buffer b
          (cond ((emacs-collab-layout--in-root-p buffer-file-name root) (kill-buffer b))
                ((equal emacs-collab-layout--buffer-root root) (kill-buffer b))
                ((and default-directory
                      (memq major-mode '(vterm-mode term-mode eshell-mode shell-mode dired-mode))
                      (emacs-collab-layout--in-root-p default-directory root))
                 (if (eq major-mode 'dired-mode) (kill-buffer b)
                   (emacs-collab-layout--quit-terminal b)))))))
    (setq emacs-collab-layout--projects (delq p emacs-collab-layout--projects))
    (unless no-close
      ;; 6. The layout.
      (when-let* ((w (and (fboundp 'treemacs-get-local-window) (treemacs-get-local-window))))
        (ignore-errors (delete-window w)))
      (when (equal emacs-collab-layout-last-root root)
        (setq emacs-collab-layout-last-root nil))
      (unless emacs-collab-layout--projects
        (emacs-collab-layout--remove-hooks))
      (ignore-errors (delete-other-windows))
      (dolist (w (window-list nil 'no-minibuf))
        (when (equal (window-parameter w 'emacs-collab-layout-root) root)
          (set-window-parameter w 'emacs-collab-role nil)
          (set-window-parameter w 'emacs-collab-layout-root nil)))
      (if (fboundp '+doom-dashboard/open)
          (+doom-dashboard/open (selected-frame))
        (switch-to-buffer (get-scratch-buffer-create)))
      (message "Workspace closed: %s" (abbreviate-file-name root)))))

;; The role marks must survive a workspace switch: Doom's workspaces (and
;; `window-state-get'/`window-state-put' generally) keep a window parameter
;; only if it is listed here.  Without it, coming back to the workspace left
;; no window marked as the editor.
(dolist (param '(emacs-collab-role emacs-collab-layout-root))
  (setf (alist-get param window-persistent-parameters) 'writable))

(provide 'emacs-collab-layout)
;;; emacs-collab-layout.el ends here
