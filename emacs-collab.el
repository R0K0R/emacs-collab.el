;;; emacs-collab.el --- Real-time collaborative editing via bridges  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Package-Requires: ((emacs "30.1"))
;; Keywords: collaboration, comm
;; Version: 0.1

;;; Commentary:

;; Emacs client for the emacs-collab protocol (see PROTOCOL.md).  A
;; "bridge" subprocess speaks the protocol on stdin/stdout and the
;; collaboration service's own protocol on the network.  This file
;; starts the bridge, mirrors edits of attached buffers to it, applies
;; remote edits, and shows peers' cursors.
;;
;; Usage:
;;   (emacs-collab-connect '("python3" "bridge-ref/loopback.py")
;;                         '((dir . "/path/to/project")))
;;
;; After the bridge reports `ready', every file buffer under the
;; project root (existing and future) gets `emacs-collab-mode'.
;;
;; Undo: remote edits are applied as ordinary buffer changes and are
;; recorded in `buffer-undo-list' (with undo boundaries around them).
;; The undo list therefore stays a faithful history of the buffer, so
;; `undo' can never corrupt the text or our sync state: undoing walks
;; back through remote edits too, and each undo is just another local
;; edit that is sent to the bridge.  Binding `buffer-undo-list' to t
;; around remote edits (the alternative) would leave earlier undo
;; entries with stale positions, which makes `undo' delete the wrong text.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-collab-ot)

(defgroup emacs-collab nil
  "Real-time collaborative editing through emacs-collab bridges."
  :group 'applications
  :prefix "emacs-collab-")

(defcustom emacs-collab-cursor-idle-delay 0.3
  "Seconds of idle time before our cursor position is sent."
  :type 'number)

(defcustom emacs-collab-client-name "emacs-collab.el"
  "Client name sent in `hello'."
  :type 'string)

(defcustom emacs-collab-ack-idle-delay 0.5
  "Seconds of idle time before remote edits are acknowledged to the bridge."
  :type 'number)

(defcustom emacs-collab-replace-timeout 1.0
  "Max seconds `replace-buffer-contents' may spend on a `doc' update."
  :type 'number)

(defvar emacs-collab-ready-functions nil
  "Abnormal hook run with the connection after the bridge sent `ready'.")

(defvar emacs-collab-message-functions nil
  "Abnormal hook run with (CONNECTION MESSAGE) for every bridge message.
MESSAGE is an alist with symbol keys.  Runs before normal handling.")

(defvar emacs-collab-need-auth-function nil
  "Function called as (CONN FIELDS REASON) on `need_auth'.
It should return a credentials alist, which is sent in a new `open',
or nil to give up.")

(defvar emacs-collab-peer-functions nil
  "Abnormal hook run with (CONNECTION PEER) after a peer changed.")

;;; Data

(cl-defstruct (emacs-collab-conn (:constructor emacs-collab--make-conn)
                                 (:copier nil))
  process stderr-buffer (partial "") root root-true self bridge capabilities
  project preview (status "connecting") status-detail command params credentials
  (docs (make-hash-table :test 'equal))
  (peers (make-hash-table :test 'equal))
  cursor-timer ready)

(cl-defstruct (emacs-collab-doc (:constructor emacs-collab--make-doc)
                                (:copier nil))
  path buffer (sent 0) (seen 0) pending synced dirty (acked 0) ack-timer)

(cl-defstruct (emacs-collab-peer (:constructor emacs-collab--make-peer)
                                 (:copier nil))
  id name color path pos mark overlays)

(defvar emacs-collab--connections nil
  "Live connections, most recent first.")

(defvar emacs-collab-mode)
(defvar-local emacs-collab--conn nil "Connection of this buffer.")
(defvar-local emacs-collab--path nil "Project-relative path of this buffer.")
(defvar-local emacs-collab--applying nil
  "Non-nil while we apply a remote or `doc' change to this buffer.")
(defvar-local emacs-collab--before nil
  "State captured by `before-change-functions': (SIZE BEG END OLDTEXT).")
(defvar-local emacs-collab--known-size nil
  "Buffer size after the last change we tracked.")
(defvar-local emacs-collab--last-cursor nil "Last (POS . MARK) sent.")
(defvar-local emacs-collab--locked nil
  "Non-nil while we hold the buffer read-only, awaiting the bridge's `doc'.
Then the value is (OLD) where OLD is the previous `buffer-read-only'.")

(dolist (v '(emacs-collab-mode emacs-collab--conn emacs-collab--path
             emacs-collab--known-size emacs-collab--last-cursor
             emacs-collab--locked))
  (put v 'permanent-local t))

;;; Logging

(defun emacs-collab--log (fmt &rest args)
  "Append a line to the internal log buffer."
  (with-current-buffer (get-buffer-create " *emacs-collab-log*")
    (goto-char (point-max))
    (insert (format-time-string "%H:%M:%S ") (apply #'format fmt args) "\n")))

;;; Sending

(defun emacs-collab--send (conn msg)
  "Send the plist MSG to the bridge of CONN as one JSON line."
  (let ((proc (emacs-collab-conn-process conn)))
    (when (process-live-p proc)
      (process-send-string proc (concat (json-serialize msg) "\n")))))

;;; Connection

;;;###autoload
(defun emacs-collab-connect (command params &optional credentials)
  "Start the bridge COMMAND (an argv list) and open a project with PARAMS.
PARAMS is an alist (symbol keys) sent as `open.params'; CREDENTIALS, if
non-nil, as `open.credentials'.  Return the connection."
  (interactive
   (list (split-string-and-unquote (read-string "Bridge command: "))
         (read (read-string "Params (alist): " "nil"))))
  (let* ((stderr (generate-new-buffer " *emacs-collab-stderr*"))
         (conn (emacs-collab--make-conn :stderr-buffer stderr :command command
                                        :params params :credentials credentials))
         (proc (make-process :name "emacs-collab"
                             :command command
                             :connection-type 'pipe
                             :coding 'utf-8-unix
                             :noquery t
                             :stderr stderr
                             :filter #'emacs-collab--filter
                             :sentinel #'emacs-collab--sentinel)))
    (when-let* ((sp (get-buffer-process stderr)))
      (set-process-query-on-exit-flag sp nil))
    (setf (emacs-collab-conn-process conn) proc)
    (process-put proc 'emacs-collab-conn conn)
    (push conn emacs-collab--connections)
    (add-hook 'find-file-hook #'emacs-collab--find-file-hook)
    (emacs-collab--send conn (list :t "hello" :client emacs-collab-client-name
                                   :version 0))
    (emacs-collab--send-open conn)
    conn))

(defun emacs-collab--send-open (conn &optional credentials)
  (let ((creds (or credentials (emacs-collab-conn-credentials conn))))
    (emacs-collab--send
     conn (append (list :t "open" :params (or (emacs-collab-conn-params conn) '()))
                  (and creds (list :credentials creds))))))

(defun emacs-collab-disconnect (&optional conn)
  "Close CONN (default: the most recent connection) and kill its bridge."
  (interactive)
  (when-let* ((conn (or conn (car emacs-collab--connections))))
    (setf (emacs-collab-conn-ready conn) nil
          (emacs-collab-conn-status conn) "disconnecting")
    (dolist (buf (emacs-collab--attached-buffers conn))
      (with-current-buffer buf (emacs-collab-mode -1)))
    (let ((proc (emacs-collab-conn-process conn)))
      (when (process-live-p proc)
        (emacs-collab--send conn (list :t "close"))
        (ignore-errors (process-send-eof proc))
        (let ((deadline (+ (float-time) 2)))
          (while (and (process-live-p proc) (< (float-time) deadline))
            (accept-process-output proc 0.05)))
        (when (process-live-p proc) (delete-process proc))))
    (emacs-collab--drop-conn conn)))

(defun emacs-collab--drop-conn (conn)
  (when (timerp (emacs-collab-conn-cursor-timer conn))
    (cancel-timer (emacs-collab-conn-cursor-timer conn)))
  (maphash (lambda (_ p) (emacs-collab--clear-peer-overlays p))
           (emacs-collab-conn-peers conn))
  (setq emacs-collab--connections (delq conn emacs-collab--connections))
  (unless emacs-collab--connections
    (remove-hook 'find-file-hook #'emacs-collab--find-file-hook))
  (setf (emacs-collab-conn-status conn) "disconnected")
  (force-mode-line-update t))

(defun emacs-collab--sentinel (proc _event)
  (let ((conn (process-get proc 'emacs-collab-conn)))
    (when (and conn (not (process-live-p proc)))
      (emacs-collab--log "bridge process exited")
      (when (memq conn emacs-collab--connections)
        (unless (equal (emacs-collab-conn-status conn) "disconnecting")
          (message "emacs-collab: bridge exited; buffers keep their text, save them yourself"))
        (dolist (buf (emacs-collab--attached-buffers conn))
          (with-current-buffer buf (emacs-collab-mode -1)))
        (emacs-collab--drop-conn conn)))))

(defun emacs-collab--attached-buffers (conn)
  (let (bufs)
    (maphash (lambda (_ d)
               (when (buffer-live-p (emacs-collab-doc-buffer d))
                 (push (emacs-collab-doc-buffer d) bufs)))
             (emacs-collab-conn-docs conn))
    bufs))

;;; Reading

(defun emacs-collab--filter (proc string)
  (when-let* ((conn (process-get proc 'emacs-collab-conn)))
    (let ((data (concat (emacs-collab-conn-partial conn) string))
          (start 0) nl)
      (while (setq nl (string-search "\n" data start))
        (let ((line (substring data start nl)))
          (setq start (1+ nl))
          (unless (string-empty-p (string-trim line))
            (emacs-collab--handle-line conn line))))
      (setf (emacs-collab-conn-partial conn) (substring data start)))))

(defun emacs-collab--handle-line (conn line)
  (let ((msg (condition-case err
                 (json-parse-string line :object-type 'alist :array-type 'list)
               (error (emacs-collab--log "bad JSON from bridge: %S (%s)" err line)
                      nil))))
    (when (consp msg)
      (condition-case err
          (progn
            (run-hook-with-args 'emacs-collab-message-functions conn msg)
            (emacs-collab--dispatch conn msg))
        (error (emacs-collab--log "error handling %S: %S" (alist-get 't msg) err)
               (message "emacs-collab: internal error on %s: %S"
                        (alist-get 't msg) err))))))

(defun emacs-collab--dispatch (conn msg)
  (pcase (alist-get 't msg)
    ("hello" (setf (emacs-collab-conn-bridge conn) (alist-get 'bridge msg)
                   (emacs-collab-conn-capabilities conn) (alist-get 'capabilities msg)))
    ("ready" (emacs-collab--handle-ready conn msg))
    ("doc" (emacs-collab--handle-doc conn msg))
    ("remote" (emacs-collab--handle-remote conn msg))
    ("ack" (emacs-collab--handle-ack conn msg))
    ("peer" (emacs-collab--handle-peer conn msg))
    ("peer_left" (emacs-collab--handle-peer-left conn msg))
    ("file_event" (emacs-collab--handle-file-event conn msg))
    ("chat" (message "[collab] %s: %s" (alist-get 'from msg) (alist-get 'text msg)))
    ("status" (setf (emacs-collab-conn-status conn) (alist-get 'state msg)
                    (emacs-collab-conn-status-detail conn) (alist-get 'detail msg))
     (force-mode-line-update t))
    ("preview" (setf (emacs-collab-conn-preview conn) (alist-get 'url msg)))
    ("need_auth" (emacs-collab--handle-need-auth conn msg))
    ("error" (emacs-collab--handle-error conn msg))
    (_ nil)))

(defun emacs-collab--handle-ready (conn msg)
  (let* ((project (alist-get 'project msg))
         (root (file-name-as-directory (alist-get 'root project))))
    (setf (emacs-collab-conn-project conn) project
          (emacs-collab-conn-self conn) (alist-get 'self msg)
          (emacs-collab-conn-root conn) root
          (emacs-collab-conn-root-true conn) (file-name-as-directory (file-truename root))
          (emacs-collab-conn-ready conn) t)
    (dolist (buf (buffer-list))
      (with-current-buffer buf (emacs-collab--maybe-attach conn)))
    (run-hook-with-args 'emacs-collab-ready-functions conn)))

(defun emacs-collab--handle-need-auth (conn msg)
  (let ((creds (and emacs-collab-need-auth-function
                    (funcall emacs-collab-need-auth-function conn
                             (alist-get 'fields msg) (alist-get 'reason msg)))))
    (if creds
        (emacs-collab--send-open conn creds)
      (message "emacs-collab: credentials needed (%S): %s"
               (alist-get 'fields msg) (or (alist-get 'reason msg) "")))))

(defun emacs-collab--handle-error (conn msg)
  (let ((code (alist-get 'code msg)) (path (alist-get 'path msg)))
    (message "emacs-collab: %s%s: %s%s" code (if path (format " [%s]" path) "")
             (alist-get 'message msg)
             (if (eq (alist-get 'fatal msg) t) " (fatal)" ""))
    (emacs-collab--log "error %s %s %s" code path (alist-get 'message msg))
    (when (and path (member code '("desync" "resync")))
      (when-let* ((d (gethash path (emacs-collab-conn-docs conn))))
        (if (equal code "desync")
            (emacs-collab--reattach conn d)
          ;; The bridge sends a fresh `doc' itself after `resync'.
          (setf (emacs-collab-doc-synced d) nil))))))

;;; Attaching buffers

(defun emacs-collab--path-for (conn file)
  "Project-relative path of FILE under CONN's root, or nil."
  (when (and file (emacs-collab-conn-root-true conn) (not (file-remote-p file)))
    (let ((true (file-truename file)))
      (when (file-in-directory-p true (emacs-collab-conn-root-true conn))
        (file-relative-name true (emacs-collab-conn-root-true conn))))))

(defun emacs-collab--maybe-attach (conn)
  "Enable `emacs-collab-mode' in the current buffer if it is under CONN's root."
  (when (and buffer-file-name (not emacs-collab-mode)
             (emacs-collab-conn-ready conn)
             (emacs-collab--path-for conn buffer-file-name))
    (setq emacs-collab--conn conn)
    (emacs-collab-mode 1)))

(defun emacs-collab--find-file-hook ()
  (dolist (conn emacs-collab--connections)
    (emacs-collab--maybe-attach conn)))

(defun emacs-collab--lighter ()
  (let ((conn emacs-collab--conn))
    (format " Collab[%s]" (if conn (emacs-collab-conn-status conn) "none"))))

(define-minor-mode emacs-collab-mode
  "Collaboratively edit this buffer through an emacs-collab bridge."
  :lighter (:eval (emacs-collab--lighter))
  (if emacs-collab-mode
      (emacs-collab--enable)
    (emacs-collab--disable)))

(defun emacs-collab--enable ()
  (let* ((conn (or emacs-collab--conn
                   (cl-find-if (lambda (c) (emacs-collab--path-for c buffer-file-name))
                               emacs-collab--connections)))
         (path (and conn (emacs-collab--path-for conn buffer-file-name))))
    (unless path
      (setq emacs-collab-mode nil)
      (user-error "emacs-collab: this buffer is not a file under a connected project"))
    (setq emacs-collab--conn conn
          emacs-collab--path path
          emacs-collab--known-size (buffer-size)
          emacs-collab--before nil
          emacs-collab--last-cursor nil)
    (let ((d (emacs-collab--make-doc :path path :buffer (current-buffer))))
      (puthash path d (emacs-collab-conn-docs conn))
      (add-hook 'before-change-functions #'emacs-collab--before-change nil t)
      (add-hook 'after-change-functions #'emacs-collab--after-change nil t)
      (add-hook 'kill-buffer-hook #'emacs-collab--kill-hook nil t)
      (add-hook 'post-command-hook #'emacs-collab--post-command nil t)
      (emacs-collab--lock)
      (emacs-collab--send conn (list :t "attach" :path path)))))

(defun emacs-collab--lock ()
  "Make the current buffer read-only until the bridge's `doc' arrives.
No edit can then be made that the `doc' reset would have to discard."
  (unless emacs-collab--locked
    (setq emacs-collab--locked (list buffer-read-only)
          buffer-read-only t)))

(defun emacs-collab--unlock ()
  "Restore the `buffer-read-only' value from before `emacs-collab--lock'."
  (when emacs-collab--locked
    (setq buffer-read-only (car emacs-collab--locked)
          emacs-collab--locked nil)))

(dolist (f '(emacs-collab--before-change emacs-collab--after-change
             emacs-collab--kill-hook emacs-collab--post-command))
  (put f 'permanent-local-hook t))

(defun emacs-collab--disable ()
  (remove-hook 'before-change-functions #'emacs-collab--before-change t)
  (remove-hook 'after-change-functions #'emacs-collab--after-change t)
  (remove-hook 'kill-buffer-hook #'emacs-collab--kill-hook t)
  (remove-hook 'post-command-hook #'emacs-collab--post-command t)
  (emacs-collab--unlock)
  (when (and emacs-collab--conn emacs-collab--path)
    (when-let* ((d (gethash emacs-collab--path (emacs-collab-conn-docs emacs-collab--conn))))
      (emacs-collab--cancel-ack d))
    (when (gethash emacs-collab--path (emacs-collab-conn-docs emacs-collab--conn))
      (remhash emacs-collab--path (emacs-collab-conn-docs emacs-collab--conn))
      (emacs-collab--send emacs-collab--conn
                          (list :t "detach" :path emacs-collab--path))))
  (remove-overlays nil nil 'emacs-collab-peer t)
  (setq emacs-collab--before nil))

(defun emacs-collab--kill-hook ()
  (when emacs-collab-mode (emacs-collab-mode -1)))

(defun emacs-collab--doc ()
  "Document state of the current buffer."
  (and emacs-collab--conn emacs-collab--path
       (gethash emacs-collab--path (emacs-collab-conn-docs emacs-collab--conn))))

(defun emacs-collab--reattach (conn d)
  "Ask the bridge for D's full text again; local edits are held back until then."
  (setf (emacs-collab-doc-synced d) nil
        (emacs-collab-doc-sent d) 0
        (emacs-collab-doc-seen d) 0
        (emacs-collab-doc-pending d) nil
        (emacs-collab-doc-acked d) 0)
  (emacs-collab--cancel-ack d)
  (when (buffer-live-p (emacs-collab-doc-buffer d))
    (with-current-buffer (emacs-collab-doc-buffer d) (emacs-collab--lock)))
  (emacs-collab--send conn (list :t "attach" :path (emacs-collab-doc-path d))))

(defun emacs-collab--resync (conn d why)
  "We detected a protocol problem on D: tell the bridge, then re-attach."
  (message "emacs-collab: %s desynchronised (%s); resynchronising" (emacs-collab-doc-path d) why)
  (emacs-collab--log "desync %s: %s" (emacs-collab-doc-path d) why)
  (emacs-collab--send conn (list :t "error" :code "desync" :message why
                                 :path (emacs-collab-doc-path d)))
  (emacs-collab--reattach conn d))

;;; `doc'

(defun emacs-collab--buffer-string ()
  (save-restriction (widen) (buffer-substring-no-properties (point-min) (point-max))))

(defun emacs-collab--replace-text (text)
  "Make the buffer hold TEXT, preserving point and markers where possible."
  (unless (string= text (emacs-collab--buffer-string))
    (let ((emacs-collab--applying t)
          (inhibit-read-only t)
          (src (generate-new-buffer " *emacs-collab-src*")))
      (unwind-protect
          (progn
            (with-current-buffer src (insert text))
            (undo-boundary)
            (save-restriction
              (widen)
              (replace-region-contents (point-min) (point-max) (lambda () src)
                                       emacs-collab-replace-timeout))
            (undo-boundary))
        (kill-buffer src)))))

(defun emacs-collab--handle-doc (conn msg)
  (let* ((path (alist-get 'path msg))
         (d (gethash path (emacs-collab-conn-docs conn)))
         (buf (and d (emacs-collab-doc-buffer d))))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (when (emacs-collab-doc-dirty d)
          (message "emacs-collab: %s: edits made before it synced were replaced by the shared text"
                   path))
        (emacs-collab--replace-text (or (alist-get 'text msg) ""))
        (setf (emacs-collab-doc-sent d) 0
              (emacs-collab-doc-seen d) 0
              (emacs-collab-doc-pending d) nil
              (emacs-collab-doc-acked d) 0
              (emacs-collab-doc-dirty d) nil
              (emacs-collab-doc-synced d) t)
        (emacs-collab--cancel-ack d)
        (emacs-collab--unlock)
        (setq emacs-collab--known-size (buffer-size)
              emacs-collab--before nil
              emacs-collab--last-cursor nil)
        (maphash (lambda (_ p) (when (equal (emacs-collab-peer-path p) path)
                                 (emacs-collab--render-peer conn p)))
                 (emacs-collab-conn-peers conn))
        (emacs-collab--send-cursor conn)))))

;;; Local edits

(defun emacs-collab--before-change (beg end)
  (when (and emacs-collab-mode (not emacs-collab--applying))
    (setq emacs-collab--before
          (list (buffer-size) beg end
                (and (<= (- end beg) 20000)
                     (buffer-substring-no-properties beg end))))))

(defun emacs-collab--after-change (beg end oldlen)
  (when (and emacs-collab-mode (not emacs-collab--applying))
    (let ((b emacs-collab--before)
          (d (emacs-collab--doc))
          (conn emacs-collab--conn))
      (setq emacs-collab--before nil)
      (when d
        (cond
         ;; Not yet synced: nothing to send; remember we have edits to report.
         ((not (emacs-collab-doc-synced d))
          (setf (emacs-collab-doc-dirty d) t)
          (setq emacs-collab--known-size (buffer-size)))
         ;; A change happened that we did not see in full (hooks inhibited).
         ((or (null b) (/= (car b) emacs-collab--known-size)
              (/= (- (nth 2 b) (nth 1 b)) oldlen))
          (emacs-collab--resync conn d "untracked buffer change"))
         (t
          (let ((ins (buffer-substring-no-properties beg end)))
            (unless (and (= oldlen (- end beg)) (equal ins (nth 3 b)))
              (let ((op (emacs-collab-ot-from-change (car b) (1- beg) oldlen ins)))
                (setq emacs-collab--known-size (buffer-size))
                (unless (emacs-collab-ot-noop-p op)
                  (emacs-collab--send-edit conn d op)))))))))))

(defun emacs-collab--send-edit (conn d op)
  ;; The edit's `seen' acknowledges everything applied so far.
  (emacs-collab--cancel-ack d)
  (setf (emacs-collab-doc-acked d) (emacs-collab-doc-seen d))
  (let ((seq (cl-incf (emacs-collab-doc-sent d))))
    (setf (emacs-collab-doc-pending d)
          (nconc (emacs-collab-doc-pending d) (list (cons seq op))))
    (emacs-collab--send conn (list :t "edit" :path (emacs-collab-doc-path d)
                                   :seq seq :seen (emacs-collab-doc-seen d)
                                   :op (vconcat op)))))

;;; Remote edits

(defun emacs-collab--apply-op (op)
  "Apply OP to the current buffer without triggering our change tracking."
  (let ((emacs-collab--applying t)
        (inhibit-read-only t))
    (undo-boundary)
    (save-excursion
      (save-restriction
        (widen)
        (let ((pos (point-min)))
          (dolist (c op)
            (cond ((stringp c)
                   (goto-char pos)
                   (insert c)
                   (setq pos (+ pos (length c))))
                  ((> c 0) (setq pos (+ pos c)))
                  (t (delete-region pos (- pos c))))))))
    (undo-boundary)
    (setq emacs-collab--known-size (buffer-size))))

(defun emacs-collab--handle-remote (conn msg)
  (let* ((path (alist-get 'path msg))
         (d (gethash path (emacs-collab-conn-docs conn)))
         (buf (and d (emacs-collab-doc-buffer d))))
    (when (and buf (buffer-live-p buf) (emacs-collab-doc-synced d))
      (let ((seq (alist-get 'seq msg))
            (s (alist-get 'seen msg))
            (op (alist-get 'op msg)))
        (condition-case err
            (with-current-buffer buf
              (unless (and (integerp seq) (integerp s) (listp op))
                (error "malformed remote message"))
              (unless (= seq (1+ (emacs-collab-doc-seen d)))
                (error "sequence gap: expected %d, got %s"
                       (1+ (emacs-collab-doc-seen d)) seq))
              (let ((pending (cl-remove-if (lambda (p) (<= (car p) s))
                                           (emacs-collab-doc-pending d)))
                    (op (emacs-collab-ot-normalize op))
                    (new nil))
                (dolist (p pending)
                  (let ((r (emacs-collab-ot-transform op (cdr p))))
                    (setq op (car r))
                    (push (cons (car p) (cdr r)) new)))
                (setq new (nreverse new))
                (unless (= (emacs-collab-ot-base-length op) (buffer-size))
                  (error "base length %d does not match buffer size %d"
                         (emacs-collab-ot-base-length op) (buffer-size)))
                (setf (emacs-collab-doc-pending d) new)
                (emacs-collab--apply-op op)
                (setf (emacs-collab-doc-seen d) seq)
                (emacs-collab--schedule-ack conn d)))
          (error (emacs-collab--resync conn d (error-message-string err))))))))

;;; Acknowledgements

(defun emacs-collab--cancel-ack (d)
  (when (timerp (emacs-collab-doc-ack-timer d))
    (cancel-timer (emacs-collab-doc-ack-timer d)))
  (setf (emacs-collab-doc-ack-timer d) nil))

(defun emacs-collab--schedule-ack (conn d)
  "Acknowledge the bridge's edits once idle, unless we send an edit first."
  (unless (emacs-collab-doc-ack-timer d)
    (setf (emacs-collab-doc-ack-timer d)
          (run-with-idle-timer emacs-collab-ack-idle-delay nil
                               #'emacs-collab--ack-timer conn d))))

(defun emacs-collab--ack-timer (conn d)
  (setf (emacs-collab-doc-ack-timer d) nil)
  (when (and (emacs-collab-doc-synced d)
             (eq d (gethash (emacs-collab-doc-path d) (emacs-collab-conn-docs conn)))
             (> (emacs-collab-doc-seen d) (emacs-collab-doc-acked d)))
    (setf (emacs-collab-doc-acked d) (emacs-collab-doc-seen d))
    (emacs-collab--send conn (list :t "ack" :path (emacs-collab-doc-path d)
                                   :seen (emacs-collab-doc-seen d)))))

(defun emacs-collab--handle-ack (conn msg)
  "The bridge has applied our edits up to `seen': forget them."
  (let* ((path (alist-get 'path msg))
         (d (gethash path (emacs-collab-conn-docs conn)))
         (s (alist-get 'seen msg)))
    (when (and d (emacs-collab-doc-synced d))
      (if (and (integerp s) (<= 0 s (emacs-collab-doc-sent d)))
          (setf (emacs-collab-doc-pending d)
                (cl-remove-if (lambda (p) (<= (car p) s))
                              (emacs-collab-doc-pending d)))
        (emacs-collab--resync conn d (format "ack.seen %s out of range" s))))))

;;; Cursors and peers

(defun emacs-collab--post-command ()
  (when-let* ((conn emacs-collab--conn))
    (unless (emacs-collab-conn-cursor-timer conn)
      (setf (emacs-collab-conn-cursor-timer conn)
            (run-with-idle-timer emacs-collab-cursor-idle-delay nil
                                 #'emacs-collab--cursor-timer conn)))))

(defun emacs-collab--cursor-timer (conn)
  (setf (emacs-collab-conn-cursor-timer conn) nil)
  (emacs-collab--send-cursor conn))

(defun emacs-collab--send-cursor (conn &optional buffer)
  "Send point and mark of BUFFER (default: current) if it changed."
  (with-current-buffer (or buffer (current-buffer))
    (when (and emacs-collab-mode (eq emacs-collab--conn conn)
               (let ((d (emacs-collab--doc))) (and d (emacs-collab-doc-synced d))))
      (let* ((pos (1- (point)))
             (mark (and (region-active-p) (mark t) (1- (mark t))))
             (cur (cons pos mark)))
        (unless (equal cur emacs-collab--last-cursor)
          (setq emacs-collab--last-cursor cur)
          (emacs-collab--send
           conn (append (list :t "cursor" :path emacs-collab--path :pos pos)
                        (and mark (list :mark mark)))))))))

(defun emacs-collab--clear-peer-overlays (peer)
  (mapc #'delete-overlay (emacs-collab-peer-overlays peer))
  (setf (emacs-collab-peer-overlays peer) nil))

(defun emacs-collab--peer-color (peer)
  (let ((c (emacs-collab-peer-color peer)))
    (if (and (stringp c) (color-defined-p c)) c "orange")))

(defun emacs-collab--render-peer (conn peer)
  "Redraw PEER's cursor overlays in the buffer of its document."
  (emacs-collab--clear-peer-overlays peer)
  (let* ((d (and (emacs-collab-peer-path peer)
                 (gethash (emacs-collab-peer-path peer) (emacs-collab-conn-docs conn))))
         (buf (and d (emacs-collab-doc-buffer d)))
         (pos (emacs-collab-peer-pos peer)))
    (when (and buf (buffer-live-p buf) (integerp pos))
      (with-current-buffer buf
        (save-restriction
          (widen)
          (let* ((color (emacs-collab--peer-color peer))
                 (name (or (emacs-collab-peer-name peer) "peer"))
                 (p (max (point-min) (min (point-max) (1+ pos))))
                 (mk (emacs-collab-peer-mark peer))
                 ov)
            (if (or (>= p (point-max)) (eq (char-after p) ?\n))
                (setq ov (make-overlay p p buf))
              (setq ov (make-overlay p (1+ p) buf))
              (overlay-put ov 'face `(:background ,color :foreground "black")))
            (when (or (>= p (point-max)) (eq (char-after p) ?\n))
              (overlay-put ov 'before-string
                           (propertize " " 'face `(:background ,color)
                                       'cursor t)))
            (overlay-put ov 'help-echo name)
            (overlay-put ov 'emacs-collab-peer t)
            (overlay-put ov 'priority 100)
            (push ov (emacs-collab-peer-overlays peer))
            (when (integerp mk)
              (let* ((m (max (point-min) (min (point-max) (1+ mk))))
                     (mo (make-overlay (min p m) (max p m) buf)))
                (overlay-put mo 'face `(:underline (:color ,color :style line)))
                (overlay-put mo 'help-echo name)
                (overlay-put mo 'emacs-collab-peer t)
                (push mo (emacs-collab-peer-overlays peer))))))))))

(defun emacs-collab--handle-peer (conn msg)
  (let* ((id (alist-get 'id msg))
         (peers (emacs-collab-conn-peers conn))
         (peer (or (gethash id peers)
                   (puthash id (emacs-collab--make-peer :id id) peers))))
    (when (assq 'name msg) (setf (emacs-collab-peer-name peer) (alist-get 'name msg)))
    (when (assq 'color msg) (setf (emacs-collab-peer-color peer) (alist-get 'color msg)))
    (when (assq 'path msg)
      (setf (emacs-collab-peer-path peer) (alist-get 'path msg)
            (emacs-collab-peer-pos peer) (alist-get 'pos msg)
            (emacs-collab-peer-mark peer) (alist-get 'mark msg)))
    (emacs-collab--render-peer conn peer)
    (run-hook-with-args 'emacs-collab-peer-functions conn peer)))

(defun emacs-collab--handle-peer-left (conn msg)
  (let* ((id (alist-get 'id msg))
         (peer (gethash id (emacs-collab-conn-peers conn))))
    (when peer
      (emacs-collab--clear-peer-overlays peer)
      (remhash id (emacs-collab-conn-peers conn)))))

;;; Files

(defun emacs-collab--handle-file-event (conn msg)
  (let* ((op (alist-get 'op msg))
         (path (alist-get 'path msg))
         (file (and (stringp path) (emacs-collab-conn-root conn)
                    (expand-file-name path (emacs-collab-conn-root conn))))
         (buf (and file (find-buffer-visiting file))))
    (when (and buf (member op '("create" "change"))
               (not (buffer-local-value 'emacs-collab-mode buf))
               (not (buffer-modified-p buf)))
      (with-current-buffer buf (revert-buffer t t t)))
    (when (and buf (equal op "rename"))
      (message "emacs-collab: %s was renamed to %s on the service" path (alist-get 'to msg)))))

;;; Commands

(defun emacs-collab-status ()
  "Show the state of the current collaboration connection."
  (interactive)
  (if-let* ((conn (or emacs-collab--conn (car emacs-collab--connections))))
      (message "emacs-collab: %s%s; root %s; %d document(s), %d peer(s)"
               (emacs-collab-conn-status conn)
               (if-let* ((x (emacs-collab-conn-status-detail conn))) (format " (%s)" x) "")
               (or (emacs-collab-conn-root conn) "-")
               (hash-table-count (emacs-collab-conn-docs conn))
               (hash-table-count (emacs-collab-conn-peers conn)))
    (message "emacs-collab: not connected")))

(defun emacs-collab-show-log (&optional internal)
  "Show the bridge's stderr log.  With prefix INTERNAL, show our own log."
  (interactive "P")
  (let ((conn (or emacs-collab--conn (car emacs-collab--connections))))
    (pop-to-buffer
     (if (or internal (not conn) (not (buffer-live-p (emacs-collab-conn-stderr-buffer conn))))
         (get-buffer-create " *emacs-collab-log*")
       (emacs-collab-conn-stderr-buffer conn)))))

(defun emacs-collab-send-chat (text)
  "Send the chat message TEXT."
  (interactive "sChat: ")
  (when-let* ((conn (or emacs-collab--conn (car emacs-collab--connections))))
    (emacs-collab--send conn (list :t "chat" :text text))))

(provide 'emacs-collab)
;;; emacs-collab.el ends here
