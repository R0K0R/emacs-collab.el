;;; emacs-collab-test.el --- Integration tests against bridge-ref/loopback.py  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'emacs-collab)
(require 'emacs-collab-ot)

(defconst emacs-collab-test--dir
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))

(defvar emacs-collab-test--texts (make-hash-table :test 'equal)
  "path -> last `x-test-text' reply.")

(defvar emacs-collab-test--pending (make-hash-table :test 'equal)
  "path -> last `x-test-pending' count.")

(defun emacs-collab-test--collect (_conn msg)
  (when (equal (alist-get 't msg) "x-test-text")
    (puthash (alist-get 'path msg) (alist-get 'text msg) emacs-collab-test--texts))
  (when (equal (alist-get 't msg) "x-test-pending")
    (puthash (alist-get 'path msg) (alist-get 'count msg) emacs-collab-test--pending)))

(defun emacs-collab-test--wait (pred &optional timeout)
  "Run process output until PRED is non-nil; fail after TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 10))) r)
    (while (and (not (setq r (funcall pred))) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (or r (ert-fail (list "timeout waiting for" pred)))))

(defun emacs-collab-test--tmpdir ()
  (let ((base (or (getenv "EMACS_COLLAB_TEST_TMPDIR") temporary-file-directory)))
    (make-temp-file (expand-file-name "emacs-collab-" base) t)))

(defun emacs-collab-test--bridge-text (conn path)
  "Ask the bridge for PATH's text and wait for the answer."
  (remhash path emacs-collab-test--texts)
  (emacs-collab--send conn (list :t "x-test-text" :path path))
  (emacs-collab-test--wait (lambda () (gethash path emacs-collab-test--texts)) 10)
  (gethash path emacs-collab-test--texts))

(defun emacs-collab-test--buf-text ()
  (buffer-substring-no-properties (point-min) (point-max)))

(defun emacs-collab-test--synced-p (buf)
  (with-current-buffer buf
    (and emacs-collab-mode (emacs-collab-doc-synced (emacs-collab--doc)))))

(defmacro emacs-collab-test--with-session (spec &rest body)
  "SPEC is (CONN DIR [PRE-FORM]).  Run BODY with a connected loopback bridge.
PRE-FORM runs before connecting (e.g. to visit files)."
  (declare (indent 1))
  `(let* ((,(nth 1 spec) (emacs-collab-test--tmpdir))
          (src (expand-file-name "conformance/fixture/" emacs-collab-test--dir))
          (emacs-collab--connections nil)
          (,(car spec) nil))
     (copy-directory src ,(nth 1 spec) nil t t)
     (add-hook 'emacs-collab-message-functions #'emacs-collab-test--collect)
     (unwind-protect
         (progn
           ,(nth 2 spec)
           (setq ,(car spec)
                 (emacs-collab-connect
                  (list "python3" (expand-file-name "bridge-ref/loopback.py"
                                                    emacs-collab-test--dir)
                        "--test")
                  (list (cons 'dir ,(nth 1 spec)))))
           (emacs-collab-test--wait (lambda () (emacs-collab-conn-ready ,(car spec))))
           ,@body)
       (remove-hook 'emacs-collab-message-functions #'emacs-collab-test--collect)
       (when ,(car spec) (ignore-errors (emacs-collab-disconnect ,(car spec))))
       (dolist (b (buffer-list))
         (when-let* ((f (buffer-file-name b)))
           (when (string-prefix-p ,(nth 1 spec) (file-truename f))
             (with-current-buffer b (set-buffer-modified-p nil))
             (kill-buffer b))))
       (delete-directory ,(nth 1 spec) t))))

(defun emacs-collab-test--visit (conn dir rel)
  "Visit DIR/REL, wait until attached and synced; return the buffer."
  (let ((buf (find-file-noselect (expand-file-name rel dir))))
    (emacs-collab-test--wait (lambda () (emacs-collab-test--synced-p buf)))
    (ignore conn)
    buf))

(defun emacs-collab-test--bridge-pending (conn path)
  "Ask the bridge how many of its edits for PATH are unacknowledged."
  (remhash path emacs-collab-test--pending)
  (emacs-collab--send conn (list :t "x-test-pending" :path path))
  (emacs-collab-test--wait
   (lambda () (numberp (gethash path emacs-collab-test--pending))))
  (gethash path emacs-collab-test--pending))

(defun emacs-collab-test--settle (conn path buf)
  "Wait for quiescence; assert buffer == bridge text; return it."
  (let ((bt (emacs-collab-test--bridge-text conn path)))
    (with-current-buffer buf
      (should (equal (emacs-collab-test--buf-text) bt)))
    bt))

;;; Tests

(ert-deftest emacs-collab-test-attach ()
  (emacs-collab-test--with-session (conn dir)
    (let* ((buf (emacs-collab-test--visit conn dir "a.txt")))
      (with-current-buffer buf
        (should emacs-collab-mode)
        (should (equal emacs-collab--path "a.txt"))
        (should (string-match-p "Collab\\[connected\\]" (emacs-collab--lighter)))
        (should (equal (emacs-collab-test--buf-text)
                       (emacs-collab-test--bridge-text conn "a.txt")))))))

(ert-deftest emacs-collab-test-existing-buffer-attached-on-ready ()
  (let (buf)
    (emacs-collab-test--with-session
        (conn dir (setq buf (find-file-noselect (expand-file-name "main.tex" dir))))
      (emacs-collab-test--wait (lambda () (emacs-collab-test--synced-p buf)))
      (should (buffer-local-value 'emacs-collab-mode buf))
      (emacs-collab-test--settle conn "main.tex" buf))))

(ert-deftest emacs-collab-test-ready-hook ()
  (let (called)
    (add-hook 'emacs-collab-ready-functions (lambda (c) (setq called c)))
    (unwind-protect
        (emacs-collab-test--with-session (conn dir)
          (should (eq called conn)))
      (setq emacs-collab-ready-functions nil))))

(ert-deftest emacs-collab-test-local-edit-reaches-bridge ()
  (emacs-collab-test--with-session (conn dir)
    (let ((buf (emacs-collab-test--visit conn dir "a.txt")))
      (with-current-buffer buf
        (goto-char (point-min))
        (insert "héllo 😀 ")
        (goto-char (point-max))
        (insert "tail\n")
        (delete-region 3 5)
        (should (equal (emacs-collab-test--settle conn "a.txt" buf)
                       (emacs-collab-test--buf-text)))
        (should (string-match-p "😀" (emacs-collab-test--buf-text)))))))

(ert-deftest emacs-collab-test-remote-edit-appears ()
  (emacs-collab-test--with-session (conn dir)
    (let* ((buf (emacs-collab-test--visit conn dir "a.txt"))
           (len (buffer-size buf)))
      (emacs-collab--send conn (list :t "x-test-remote" :path "a.txt"
                                     :op (vector "REMOTE😀" len)))
      (emacs-collab-test--wait
       (lambda () (string-prefix-p "REMOTE😀" (with-current-buffer buf (emacs-collab-test--buf-text)))))
      (emacs-collab-test--settle conn "a.txt" buf)
      ;; delete in the middle
      (emacs-collab--send conn (list :t "x-test-remote" :path "a.txt"
                                     :op (vector 3 -2 (- (buffer-size buf) 5))))
      (emacs-collab-test--wait
       (lambda () (= (buffer-size buf) (- len -7 2))))
      (emacs-collab-test--settle conn "a.txt" buf))))

(ert-deftest emacs-collab-test-bridge-acks-local-edits ()
  (emacs-collab-test--with-session (conn dir)
    (let* ((buf (emacs-collab-test--visit conn dir "a.txt"))
           (d (with-current-buffer buf (emacs-collab--doc))))
      (with-current-buffer buf
        (dotimes (i 12)
          (goto-char (point-min))
          (insert (format "x%d " i))))
      (should (= (length (emacs-collab-doc-pending d)) 12))
      ;; Idle: the bridge acks, and the pending list empties.
      (emacs-collab-test--wait (lambda () (null (emacs-collab-doc-pending d))) 5)
      (emacs-collab-test--settle conn "a.txt" buf))))

(ert-deftest emacs-collab-test-emacs-acks-remote-edits ()
  (emacs-collab-test--with-session (conn dir)
    (let* ((buf (emacs-collab-test--visit conn dir "a.txt"))
           (len (buffer-size buf))
           (d (with-current-buffer buf (emacs-collab--doc))))
      (dotimes (i 6)
        (emacs-collab--send conn (list :t "x-test-remote" :path "a.txt"
                                       :op (vector "r" (+ len i)))))
      (emacs-collab-test--wait (lambda () (= (emacs-collab-doc-seen d) 6)))
      (should (= 6 (emacs-collab-test--bridge-pending conn "a.txt")))
      ;; Idle timers never run in batch mode: fire ours by hand.
      (should (timerp (emacs-collab-doc-ack-timer d)))
      (timer-event-handler (emacs-collab-doc-ack-timer d))
      (should-not (emacs-collab-doc-ack-timer d))
      ;; Only our ack empties the bridge's pending list.
      (emacs-collab-test--wait
       (lambda () (= 0 (emacs-collab-test--bridge-pending conn "a.txt"))) 5)
      (should (= (emacs-collab-doc-acked d) 6))
      (emacs-collab-test--settle conn "a.txt" buf))))

(ert-deftest emacs-collab-test-read-only-until-doc ()
  (let (buf ro-at-ready)
    (add-hook 'emacs-collab-ready-functions
              (lambda (_c) (setq ro-at-ready (buffer-local-value 'buffer-read-only buf))))
    (unwind-protect
        (emacs-collab-test--with-session
            (conn dir (setq buf (find-file-noselect (expand-file-name "a.txt" dir))))
          (emacs-collab-test--wait (lambda () (emacs-collab-test--synced-p buf)))
          ;; attached but no `doc' yet when `ready' hooks ran: read-only then
          (should ro-at-ready)
          (with-current-buffer buf
            (should-not buffer-read-only)
            (should-not emacs-collab--locked)
            ;; A re-attach locks again until the new doc arrives.
            (let ((d (emacs-collab--doc)))
              (emacs-collab--reattach conn d)
              (should buffer-read-only)
              (should-error (insert "x") :type 'buffer-read-only)
              (emacs-collab-test--wait (lambda () (emacs-collab-doc-synced d)))
              (should-not buffer-read-only)
              (insert "x")
              (emacs-collab-test--settle conn "a.txt" buf))))
      (setq emacs-collab-ready-functions nil))))

(ert-deftest emacs-collab-test-read-only-preserved ()
  (let (buf)
    (emacs-collab-test--with-session
        (conn dir (setq buf (find-file-noselect (expand-file-name "a.txt" dir))))
      (emacs-collab-test--wait (lambda () (emacs-collab-test--synced-p buf)))
      (with-current-buffer buf
        (setq buffer-read-only t)
        (emacs-collab--reattach conn (emacs-collab--doc))
        (should buffer-read-only)
        (emacs-collab-test--wait (lambda () (emacs-collab-doc-synced (emacs-collab--doc))))
        ;; The user's own read-only state survives the lock/unlock.
        (should buffer-read-only)))))

(ert-deftest emacs-collab-test-point-and-markers ()
  (emacs-collab-test--with-session (conn dir)
    (let* ((buf (emacs-collab-test--visit conn dir "a.txt")))
      (with-current-buffer buf
        (erase-buffer)
        (insert "0123456789")
        (emacs-collab-test--settle conn "a.txt" buf)
        (goto-char 6)
        (let ((m (copy-marker 8)))
          ;; remote insert before point/marker shifts them
          (emacs-collab--send conn (list :t "x-test-remote" :path "a.txt"
                                         :op (vector 2 "ab" 8)))
          (emacs-collab-test--wait (lambda () (= (buffer-size) 12)))
          (should (= (point) 8))
          (should (= (marker-position m) 10))
          ;; remote insert after both leaves them
          (emacs-collab--send conn (list :t "x-test-remote" :path "a.txt"
                                         :op (vector 11 "Z" 1)))
          (emacs-collab-test--wait (lambda () (= (buffer-size) 13)))
          (should (= (point) 8))
          (should (= (marker-position m) 10))
          ;; remote delete covering point collapses it
          (emacs-collab--send conn (list :t "x-test-remote" :path "a.txt"
                                         :op (vector 5 -6 2)))
          (emacs-collab-test--wait (lambda () (= (buffer-size) 7)))
          (should (= (point) 6))
          (emacs-collab-test--settle conn "a.txt" buf))))))

(ert-deftest emacs-collab-test-peer-overlay ()
  (emacs-collab-test--with-session (conn dir)
    (let ((buf (emacs-collab-test--visit conn dir "a.txt")))
      (emacs-collab--send conn (list :t "x-test-peer" :id "p1" :name "Alice"
                                     :color "#ff0000" :path "a.txt" :pos 1))
      (emacs-collab-test--wait (lambda () (gethash "p1" (emacs-collab-conn-peers conn))))
      (with-current-buffer buf
        (let ((ovs (cl-remove-if-not (lambda (o) (overlay-get o 'emacs-collab-peer))
                                     (overlays-in (point-min) (point-max)))))
          (should ovs)
          (should (equal (overlay-get (car ovs) 'help-echo) "Alice"))))
      ;; moving removes the old overlay
      (emacs-collab--send conn (list :t "x-test-peer" :id "p1" :name "Alice"
                                     :color "#ff0000" :path "a.txt" :pos 0))
      (emacs-collab-test--wait
       (lambda () (let ((ov (car (emacs-collab-peer-overlays
                                  (gethash "p1" (emacs-collab-conn-peers conn))))))
                    (and ov (= 1 (overlay-start ov))))))
      (emacs-collab--handle-peer-left conn '((id . "p1")))
      (with-current-buffer buf
        (should-not (overlays-in (point-min) (point-max)))))))

(ert-deftest emacs-collab-test-cursor-message ()
  (emacs-collab-test--with-session (conn dir)
    (let ((buf (emacs-collab-test--visit conn dir "a.txt")) sent)
      (advice-add 'emacs-collab--send :before
                  (lambda (_c msg) (when (equal (plist-get msg :t) "cursor") (push msg sent)))
                  '((name . cursor-spy)))
      (unwind-protect
          (with-current-buffer buf
            (goto-char 3)
            (emacs-collab--send-cursor conn)
            (should (equal (plist-get (car sent) :pos) 2))
            (should-not (plist-member (car sent) :mark)))
        (advice-remove 'emacs-collab--send 'cursor-spy)))))

(ert-deftest emacs-collab-test-kill-buffer-detaches ()
  (emacs-collab-test--with-session (conn dir)
    (let* ((buf (emacs-collab-test--visit conn dir "a.txt"))
           (file (expand-file-name "a.txt" dir))
           final)
      (with-current-buffer buf
        (goto-char (point-max))
        (insert "KILLME😀\n")
        (setq final (emacs-collab-test--settle conn "a.txt" buf))
        (set-buffer-modified-p nil))
      (kill-buffer buf)
      (should-not (gethash "a.txt" (emacs-collab-conn-docs conn)))
      (emacs-collab-test--wait
       (lambda () (equal (with-temp-buffer
                           (let ((coding-system-for-read 'utf-8-unix))
                             (insert-file-contents file))
                           (buffer-string))
                         final))))))

(ert-deftest emacs-collab-test-file-event-reverts-unattached ()
  (emacs-collab-test--with-session (conn dir)
    (let ((buf (emacs-collab-test--visit conn dir "a.txt")))
      (with-current-buffer buf (emacs-collab-mode -1))
      (should-not (buffer-local-value 'emacs-collab-mode buf))
      (let ((len (buffer-size buf)))
        (emacs-collab--send conn (list :t "x-test-remote" :path "a.txt"
                                       :op (vector "NEW" len)))
        (emacs-collab-test--wait
         (lambda () (string-prefix-p "NEW" (with-current-buffer buf (emacs-collab-test--buf-text)))))))))

(ert-deftest emacs-collab-test-disconnect ()
  (emacs-collab-test--with-session (conn dir)
    (let ((buf (emacs-collab-test--visit conn dir "a.txt")))
      (emacs-collab-disconnect conn)
      (should-not (process-live-p (emacs-collab-conn-process conn)))
      (should-not (buffer-local-value 'emacs-collab-mode buf)))))

;;; Concurrent stress with a model of the bridge

(defvar emacs-collab-test--alphabet (vconcat "abcdefgh \n" (list #x1F600 #x1F9D1 #xE9 #x4E2D)))

(defun emacs-collab-test--rand-string (n)
  (apply #'string (cl-loop repeat n collect
                           (aref emacs-collab-test--alphabet
                                 (random (length emacs-collab-test--alphabet))))))

(defun emacs-collab-test--rand-op (len)
  (let ((acc nil) (i 0))
    (while (< i len)
      (let ((n (min (1+ (random 4)) (- len i))))
        (pcase (random 3)
          (0 (push n acc) (setq i (+ i n)))
          (1 (push (- n) acc) (setq i (+ i n)))
          (2 (push (emacs-collab-test--rand-string (1+ (random 3))) acc)))))
    (when (zerop (random 2)) (push (emacs-collab-test--rand-string (1+ (random 3))) acc))
    (emacs-collab-ot-normalize (nreverse acc))))

(cl-defstruct emacs-collab-test--sim text (sent 0) (seen 0) pending)

(defun emacs-collab-test--sim-handle (sim msg)
  "Mirror the bridge's handling of MSG (as sent by Emacs)."
  (pcase (plist-get msg :t)
    ("attach" (setf (emacs-collab-test--sim-sent sim) 0 (emacs-collab-test--sim-seen sim) 0
                    (emacs-collab-test--sim-pending sim) nil))
    ("edit"
     (let ((op (emacs-collab-ot-normalize (plist-get msg :op)))
           (s (plist-get msg :seen)) (pending nil))
       (dolist (p (emacs-collab-test--sim-pending sim))
         (when (> (car p) s) (push p pending)))
       (setq pending (nreverse pending))
       (setq pending
             (mapcar (lambda (p)
                       (let ((r (emacs-collab-ot-transform (cdr p) op)))
                         (setq op (cdr r))
                         (cons (car p) (car r))))
                     pending))
       (setf (emacs-collab-test--sim-pending sim) pending
             (emacs-collab-test--sim-text sim)
             (emacs-collab-ot-apply (emacs-collab-test--sim-text sim) op)
             (emacs-collab-test--sim-seen sim) (plist-get msg :seq))))
    ("x-test-remote"
     (let ((op (emacs-collab-ot-normalize (plist-get msg :op))))
       (setf (emacs-collab-test--sim-text sim)
             (emacs-collab-ot-apply (emacs-collab-test--sim-text sim) op))
       (cl-incf (emacs-collab-test--sim-sent sim))
       (setf (emacs-collab-test--sim-pending sim)
             (append (emacs-collab-test--sim-pending sim)
                     (list (cons (emacs-collab-test--sim-sent sim) op))))))))

(defun emacs-collab-test--stress (seed rounds)
  (random seed)
  (emacs-collab-test--with-session (conn dir)
    (let* ((buf (emacs-collab-test--visit conn dir "main.tex"))
           (sim (make-emacs-collab-test--sim
                 :text (emacs-collab-test--bridge-text conn "main.tex")))
           (advice (lambda (_c msg) (emacs-collab-test--sim-handle sim msg))))
      (advice-add 'emacs-collab--send :before advice)
      (unwind-protect
          (with-current-buffer buf
            (dotimes (_ rounds)
              (pcase (random 5)
                ((or 0 1)               ; local edit
                 (let* ((n (buffer-size)) (pos (1+ (random (1+ n))))
                        (del (random (1+ (min 4 (- (1+ n) pos))))))
                   (goto-char pos)
                   (when (> del 0) (delete-region pos (+ pos del)))
                   (when (> (random 3) 0)
                     (insert (emacs-collab-test--rand-string (random 4))))))
                ((or 2 3)               ; remote edit, no waiting
                 (let ((op (emacs-collab-test--rand-op
                            (length (emacs-collab-test--sim-text sim)))))
                   (unless (emacs-collab-ot-noop-p op)
                     (emacs-collab--send conn (list :t "x-test-remote" :path "main.tex"
                                                    :op (vconcat op))))))
                (_ (accept-process-output nil (if (zerop (random 2)) 0 0.002)))))
            (let ((bt (emacs-collab-test--bridge-text conn "main.tex")))
              (should (equal (emacs-collab-test--buf-text) bt))
              (should (equal bt (emacs-collab-test--sim-text sim)))))
        (advice-remove 'emacs-collab--send advice)))))

(ert-deftest emacs-collab-test-concurrent-stress ()
  (dolist (seed '("s1" "s2" "s3" "s4" "s5" "s6"))
    (emacs-collab-test--stress seed 150)))

(provide 'emacs-collab-test)
;;; emacs-collab-test.el ends here
