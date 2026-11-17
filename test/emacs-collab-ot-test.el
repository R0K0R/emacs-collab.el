;;; emacs-collab-ot-test.el --- OT tests  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'emacs-collab-ot)

(ert-deftest emacs-collab-ot-apply-basic ()
  (should (equal (emacs-collab-ot-apply "hello" '(1 "a" -2 2)) "halo"))
  (should (equal (emacs-collab-ot-apply "hello" [5 " world"]) "hello world"))
  (should (equal (emacs-collab-ot-apply "" '("x")) "x"))
  (should-error (emacs-collab-ot-apply "abc" '(2)) :type 'emacs-collab-ot-error))

(ert-deftest emacs-collab-ot-lengths ()
  (let ((op '(2 "xyz" -1 4)))
    (should (= (emacs-collab-ot-base-length op) 7))
    (should (= (emacs-collab-ot-target-length op) 9))
    (should (= (emacs-collab-ot-base-length [2 "xyz" -1 4]) 7))))

(ert-deftest emacs-collab-ot-normalize ()
  (should (equal (emacs-collab-ot-normalize '(1 2 "a" "" "b" 0 -1 -2 "c"))
                 '(3 "abc" -3)))
  (should (equal (emacs-collab-ot-normalize [0 ""]) nil)))

(ert-deftest emacs-collab-ot-noop ()
  (should (emacs-collab-ot-noop-p '(5)))
  (should (emacs-collab-ot-noop-p nil))
  (should-not (emacs-collab-ot-noop-p '(5 "a")))
  (should-not (emacs-collab-ot-noop-p '(-1))))

(ert-deftest emacs-collab-ot-from-change ()
  (should (equal (emacs-collab-ot-from-change 5 2 0 "X") '(2 "X" 3)))
  (should (equal (emacs-collab-ot-from-change 5 0 5 "") '(-5)))
  (should (equal (emacs-collab-ot-from-change 5 1 2 "ab") '(1 "ab" -2 2)))
  (should (emacs-collab-ot-noop-p (emacs-collab-ot-from-change 5 2 0 "")))
  (should (equal (emacs-collab-ot-from-change 0 0 0 "hi") '("hi"))))

(ert-deftest emacs-collab-ot-transform-tie ()
  (let* ((a '("A" 3)) (b '("B" 3))
         (r (emacs-collab-ot-transform a b)))
    (should (equal (emacs-collab-ot-apply (emacs-collab-ot-apply "xyz" a) (cdr r))
                   "ABxyz"))
    (should (equal (emacs-collab-ot-apply (emacs-collab-ot-apply "xyz" b) (car r))
                   "ABxyz"))))

(ert-deftest emacs-collab-ot-transform-delete-overlap ()
  (let* ((a '(1 -3 1)) (b '(2 -3))
         (r (emacs-collab-ot-transform a b)))
    (should (equal (emacs-collab-ot-apply (emacs-collab-ot-apply "abcde" a) (cdr r))
                   (emacs-collab-ot-apply (emacs-collab-ot-apply "abcde" b) (car r))))
    (should (equal (emacs-collab-ot-apply (emacs-collab-ot-apply "abcde" a) (cdr r))
                   "a"))))

;;; Randomized

(defconst emacs-collab-ot-test--alphabet
  (vconcat "abcdefgh \n" (list #x1F600 #x1F9D1 #x10FFFF #xE9 #x4E2D)))

(defun emacs-collab-ot-test--rand-string (n)
  (apply #'string (cl-loop repeat n collect
                           (aref emacs-collab-ot-test--alphabet
                                 (random (length emacs-collab-ot-test--alphabet))))))

(defun emacs-collab-ot-test--rand-op (doc)
  "Random operation on DOC (a string)."
  (let ((acc nil) (len (length doc)) (i 0))
    (while (< i len)
      (let ((n (min (1+ (random 5)) (- len i))))
        (pcase (random 3)
          (0 (push n acc) (setq i (+ i n)))
          (1 (push (- n) acc) (setq i (+ i n)))
          (2 (push (emacs-collab-ot-test--rand-string (1+ (random 4))) acc)))))
    (when (zerop (random 2))
      (push (emacs-collab-ot-test--rand-string (1+ (random 4))) acc))
    (emacs-collab-ot-normalize (nreverse acc))))

(ert-deftest emacs-collab-ot-random-transform ()
  (random "emacs-collab-seed-1")
  (dotimes (_ 3000)
    (let* ((doc (emacs-collab-ot-test--rand-string (random 25)))
           (a (emacs-collab-ot-test--rand-op doc))
           (b (emacs-collab-ot-test--rand-op doc))
           (r (emacs-collab-ot-transform a b))
           (d1 (emacs-collab-ot-apply (emacs-collab-ot-apply doc a) (cdr r)))
           (d2 (emacs-collab-ot-apply (emacs-collab-ot-apply doc b) (car r))))
      (should (equal d1 d2))
      ;; vector inputs behave the same
      (should (equal r (emacs-collab-ot-transform (vconcat a) (vconcat b))))
      ;; results are canonical
      (should (equal (car r) (emacs-collab-ot-normalize (car r))))
      (should (equal (cdr r) (emacs-collab-ot-normalize (cdr r)))))))

(ert-deftest emacs-collab-ot-random-compose ()
  (random "emacs-collab-seed-2")
  (dotimes (_ 3000)
    (let* ((doc (emacs-collab-ot-test--rand-string (random 25)))
           (a (emacs-collab-ot-test--rand-op doc))
           (d1 (emacs-collab-ot-apply doc a))
           (b (emacs-collab-ot-test--rand-op d1))
           (c (emacs-collab-ot-compose a b)))
      (should (equal (emacs-collab-ot-apply doc c)
                     (emacs-collab-ot-apply d1 b)))
      (should (= (emacs-collab-ot-base-length c) (length doc))))))

(ert-deftest emacs-collab-ot-random-compose-transform ()
  "transform(a, b) and compose agree: a;b' = b;a' as operations."
  (random "emacs-collab-seed-3")
  (dotimes (_ 1500)
    (let* ((doc (emacs-collab-ot-test--rand-string (random 25)))
           (a (emacs-collab-ot-test--rand-op doc))
           (b (emacs-collab-ot-test--rand-op doc))
           (r (emacs-collab-ot-transform a b))
           (ab (emacs-collab-ot-compose a (cdr r)))
           (ba (emacs-collab-ot-compose b (car r))))
      (should (equal (emacs-collab-ot-apply doc ab)
                     (emacs-collab-ot-apply doc ba))))))

(ert-deftest emacs-collab-ot-random-from-change ()
  (random "emacs-collab-seed-4")
  (dotimes (_ 1000)
    (let* ((doc (emacs-collab-ot-test--rand-string (random 25)))
           (pos (random (1+ (length doc))))
           (del (random (1+ (- (length doc) pos))))
           (ins (emacs-collab-ot-test--rand-string (random 4)))
           (op (emacs-collab-ot-from-change (length doc) pos del ins)))
      (should (equal (emacs-collab-ot-apply doc op)
                     (concat (substring doc 0 pos) ins (substring doc (+ pos del))))))))

(provide 'emacs-collab-ot-test)
;;; emacs-collab-ot-test.el ends here
