;;; emacs-collab-mirror-test.el --- Mirror directory selection tests  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'emacs-collab-mirror)

(defmacro ecm-test--with-env (&rest body)
  "Run BODY with an isolated state file and `read-directory-name' stubbed.
`ecm-test-answers' is a list of answers; `ecm-test-prompts' collects
\(PROMPT . INITIAL) of each call; `base' is a temp directory."
  `(let* ((base (file-name-as-directory (file-truename (make-temp-file "ecm" t))))
          (emacs-collab-mirror-state-file (expand-file-name "st/mirrors.eld" base))
          (emacs-collab-mirror--table 'unloaded)
          (emacs-collab-mirror-root nil)
          (default-directory base)
          (ecm-test-answers nil) (ecm-test-prompts nil))
     (unwind-protect
         (cl-letf (((symbol-function 'read-directory-name)
                    (lambda (prompt &optional dir _default _mustmatch initial)
                      (push (cons prompt (or initial dir)) ecm-test-prompts)
                      (or (pop ecm-test-answers) (error "unexpected prompt")))))
           ,@body)
       (delete-directory base t))))

(ert-deftest ecm-test-prompt-creates-marks-remembers ()
  (ecm-test--with-env
   (let ((d (expand-file-name "a/b/" base)))
     (push d ecm-test-answers)
     (should (equal (emacs-collab-read-mirror-dir "svc" "p1") d))
     (should (file-directory-p d))
     (should (file-exists-p (expand-file-name ".emacs-collab" d)))
     (should (string-prefix-p "Local copy of p1 in" (caar ecm-test-prompts)))
     ;; remembered: no further prompt (stub would error)
     (should (equal (emacs-collab-read-mirror-dir "svc" "p1" "/ignored/") d))
     (should (= 1 (length ecm-test-prompts)))
     ;; another project prompts again
     (push (expand-file-name "c/" base) ecm-test-answers)
     (emacs-collab-read-mirror-dir "svc" "p2")
     (should (= 2 (length ecm-test-prompts))))))

(ert-deftest ecm-test-remembered-dir-recreated ()
  (ecm-test--with-env
   (let ((d (expand-file-name "a/" base)))
     (push d ecm-test-answers)
     (emacs-collab-read-mirror-dir "svc" "p")
     (delete-directory d t)
     (should (equal (emacs-collab-read-mirror-dir "svc" "p") d))
     (should (file-directory-p d)))))

(ert-deftest ecm-test-force-reprompts-from-remembered ()
  (ecm-test--with-env
   (let ((d1 (expand-file-name "one/" base)) (d2 (expand-file-name "two/" base)))
     (push d1 ecm-test-answers)
     (emacs-collab-read-mirror-dir "svc" "p")
     (push d2 ecm-test-answers)
     (should (equal (emacs-collab-read-mirror-dir "svc" "p" "/sugg/" t) d2))
     (should (equal (cdar ecm-test-prompts) d1)) ; initial is the remembered one
     (should (equal (emacs-collab-read-mirror-dir "svc" "p") d2)))))

(ert-deftest ecm-test-initial-precedence ()
  (ecm-test--with-env
   ;; default-directory
   (push (expand-file-name "x1/" base) ecm-test-answers)
   (emacs-collab-read-mirror-dir "svc" "p1")
   (should (equal (cdar ecm-test-prompts) base))
   ;; root/service/slug
   (let ((emacs-collab-mirror-root (expand-file-name "root" base)))
     (push (expand-file-name "x2/" base) ecm-test-answers)
     (emacs-collab-read-mirror-dir "my svc" "p 2")
     (should (equal (cdar ecm-test-prompts)
                    (expand-file-name "my-svc/p-2/" (expand-file-name "root" base))))
     ;; suggestion beats root
     (push (expand-file-name "x3/" base) ecm-test-answers)
     (emacs-collab-read-mirror-dir "svc" "p3" (expand-file-name "sugg" base))
     (should (equal (cdar ecm-test-prompts) (expand-file-name "sugg/" base))))))

(ert-deftest ecm-test-marker-mismatch-refused ()
  (ecm-test--with-env
   (let ((d (expand-file-name "m/" base)))
     (push d ecm-test-answers)
     (emacs-collab-read-mirror-dir "svc" "p1")
     (push d ecm-test-answers)
     (should-error (emacs-collab-read-mirror-dir "svc" "p2") :type 'user-error)
     (should-error (progn (push d ecm-test-answers)
                          (emacs-collab-read-mirror-dir "other" "p1"))
                   :type 'user-error)
     ;; refusal is not remembered
     (should-not (emacs-collab-mirror-remembered "svc" "p2")))))

(ert-deftest ecm-test-nonempty-unmarked-warns-not-refuses ()
  (ecm-test--with-env
   (let ((d (expand-file-name "n/" base)) warned)
     (make-directory d t)
     (write-region "x" nil (expand-file-name "f.txt" d))
     (push d ecm-test-answers)
     (cl-letf (((symbol-function 'display-warning) (lambda (&rest _) (setq warned t))))
       (should (equal (emacs-collab-read-mirror-dir "svc" "p") d)))
     (should warned)
     (should (file-exists-p (expand-file-name ".emacs-collab" d))))))

(ert-deftest ecm-test-persistence-round-trip-and-forget ()
  (ecm-test--with-env
   (let ((d (expand-file-name "r/" base)))
     (push d ecm-test-answers)
     (emacs-collab-read-mirror-dir "svc" "http://h/p 1")
     (should (file-exists-p emacs-collab-mirror-state-file))
     (should-not (file-exists-p (concat emacs-collab-mirror-state-file ".tmp")))
     (setq emacs-collab-mirror--table 'unloaded) ; as a fresh Emacs
     (should (equal (emacs-collab-mirror-remembered "svc" "http://h/p 1") d))
     (should (emacs-collab-forget-mirror "svc" "http://h/p 1"))
     (setq emacs-collab-mirror--table 'unloaded)
     (should-not (emacs-collab-mirror-remembered "svc" "http://h/p 1"))
     (should-not (emacs-collab-forget-mirror "svc" "http://h/p 1"))
     (should (file-directory-p d)))))

(provide 'emacs-collab-mirror-test)
;;; emacs-collab-mirror-test.el ends here
