;;; emacs-collab-ot.el --- Text operations for emacs-collab  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; This file is a port of src/text-operation.js from ot.js
;; (https://github.com/Operational-Transformation/ot.js), MIT licensed:
;; Copyright (c) 2012-2013 Tim Baumann.

;;; Commentary:

;; A text operation (PROTOCOL.md section 3) is a sequence of components:
;;   positive integer N  retain N characters
;;   string S            insert S
;;   negative integer -N delete N characters
;; Operations are accepted as lists or vectors (JSON arrays decode to
;; either).  Results are always returned as normalized lists.  Lengths
;; count characters, i.e. Unicode code points, as in an Emacs buffer.

;;; Code:

(require 'cl-lib)

(define-error 'emacs-collab-ot-error "emacs-collab OT error")

(defun emacs-collab-ot--list (op)
  "Return OP as a list."
  (if (listp op) op (append op nil)))

;;; Builder: appends components keeping the operation canonical.

(defun emacs-collab-ot--push (acc c)
  "Return ACC (reversed component list) with component C added canonically."
  (cond
   ((and (integerp c) (= c 0)) acc)
   ((and (stringp c) (string-empty-p c)) acc)
   ((integerp c)
    (if (and acc (integerp (car acc)) (eq (> c 0) (> (car acc) 0)))
        (cons (+ (car acc) c) (cdr acc))
      (cons c acc)))
   (t
    (cond
     ((and acc (stringp (car acc)))
      (cons (concat (car acc) c) (cdr acc)))
     ;; insert after delete: put the insert first (ot.js canonical order)
     ((and acc (integerp (car acc)) (< (car acc) 0))
      (if (and (cdr acc) (stringp (cadr acc)))
          (cons (car acc) (cons (concat (cadr acc) c) (cddr acc)))
        (cons (car acc) (cons c (cdr acc)))))
     (t (cons c acc))))))

(defun emacs-collab-ot-normalize (op)
  "Return OP as a canonical list: merged adjacent kinds, no empty components."
  (let ((acc nil))
    (dolist (c (emacs-collab-ot--list op))
      (setq acc (emacs-collab-ot--push acc c)))
    (nreverse acc)))

(defun emacs-collab-ot-base-length (op)
  "Length of the document OP applies to."
  (let ((n 0))
    (dolist (c (emacs-collab-ot--list op) n)
      (when (integerp c) (setq n (+ n (abs c)))))))

(defun emacs-collab-ot-target-length (op)
  "Length of the document after applying OP."
  (let ((n 0))
    (dolist (c (emacs-collab-ot--list op) n)
      (cond ((stringp c) (setq n (+ n (length c))))
            ((> c 0) (setq n (+ n c)))))))

(defun emacs-collab-ot-noop-p (op)
  "Non-nil if OP does not change any document."
  (let ((l (emacs-collab-ot--list op)))
    (or (null l)
        (and (null (cdr l)) (integerp (car l)) (> (car l) 0)))))

(defun emacs-collab-ot-apply (doc op)
  "Apply OP to the string DOC and return the new string."
  (unless (= (length doc) (emacs-collab-ot-base-length op))
    (signal 'emacs-collab-ot-error
            (list "base length does not match document length"
                  (length doc) (emacs-collab-ot-base-length op))))
  (let ((i 0) (parts nil))
    (dolist (c (emacs-collab-ot--list op))
      (cond ((stringp c) (push c parts))
            ((> c 0) (push (substring doc i (+ i c)) parts) (setq i (+ i c)))
            (t (setq i (- i c)))))
    (apply #'concat (nreverse parts))))

(defun emacs-collab-ot-from-change (doc-len pos del-len ins)
  "Operation for replacing DEL-LEN chars at 0-based POS by INS in a DOC-LEN doc."
  (when (> (+ pos del-len) doc-len)
    (signal 'emacs-collab-ot-error (list "change beyond document end")))
  (emacs-collab-ot-normalize
   (list pos (- del-len) (or ins "") (- doc-len pos del-len))))

(defun emacs-collab-ot-compose (a b)
  "Compose A and B into one operation with the effect of A then B."
  (let ((l1 (emacs-collab-ot--list a))
        (l2 (emacs-collab-ot--list b))
        (acc nil))
    (unless (= (emacs-collab-ot-target-length a) (emacs-collab-ot-base-length b))
      (signal 'emacs-collab-ot-error
              (list "compose: target length of a /= base length of b")))
    (let ((o1 (pop l1)) (o2 (pop l2)))
      (while (or o1 o2)
        (cond
         ((and o1 (integerp o1) (< o1 0))
          (setq acc (emacs-collab-ot--push acc o1) o1 (pop l1)))
         ((and o2 (stringp o2))
          (setq acc (emacs-collab-ot--push acc o2) o2 (pop l2)))
         ((or (null o1) (null o2))
          (signal 'emacs-collab-ot-error (list "compose: operations too short/long")))
         ((and (integerp o1) (> o1 0) (integerp o2) (> o2 0))
          (cond ((> o1 o2)
                 (setq acc (emacs-collab-ot--push acc o2) o1 (- o1 o2) o2 (pop l2)))
                ((= o1 o2)
                 (setq acc (emacs-collab-ot--push acc o1) o1 (pop l1) o2 (pop l2)))
                (t (setq acc (emacs-collab-ot--push acc o1)
                         o2 (- o2 o1) o1 (pop l1)))))
         ((and (stringp o1) (integerp o2) (< o2 0))
          (cond ((> (length o1) (- o2))
                 (setq o1 (substring o1 (- o2)) o2 (pop l2)))
                ((= (length o1) (- o2))
                 (setq o1 (pop l1) o2 (pop l2)))
                (t (setq o2 (+ o2 (length o1)) o1 (pop l1)))))
         ((and (stringp o1) (integerp o2) (> o2 0))
          (cond ((> (length o1) o2)
                 (setq acc (emacs-collab-ot--push acc (substring o1 0 o2))
                       o1 (substring o1 o2) o2 (pop l2)))
                ((= (length o1) o2)
                 (setq acc (emacs-collab-ot--push acc o1) o1 (pop l1) o2 (pop l2)))
                (t (setq acc (emacs-collab-ot--push acc o1)
                         o2 (- o2 (length o1)) o1 (pop l1)))))
         ((and (integerp o1) (> o1 0) (integerp o2) (< o2 0))
          (cond ((> o1 (- o2))
                 (setq acc (emacs-collab-ot--push acc o2) o1 (+ o1 o2) o2 (pop l2)))
                ((= o1 (- o2))
                 (setq acc (emacs-collab-ot--push acc o2) o1 (pop l1) o2 (pop l2)))
                (t (setq acc (emacs-collab-ot--push acc (- o1))
                         o2 (+ o2 o1) o1 (pop l1)))))
         (t (signal 'emacs-collab-ot-error (list "compose: unreachable" o1 o2))))))
    (nreverse acc)))

(defun emacs-collab-ot-transform (a b)
  "Transform concurrent operations A and B (same base length).
Return (A-PRIME . B-PRIME) such that applying A then B-PRIME equals
applying B then A-PRIME.  When both insert at one position, A's insert
comes first."
  (unless (= (emacs-collab-ot-base-length a) (emacs-collab-ot-base-length b))
    (signal 'emacs-collab-ot-error
            (list "transform: both operations must have the same base length")))
  (let ((l1 (emacs-collab-ot--list a))
        (l2 (emacs-collab-ot--list b))
        (ap nil) (bp nil))
    (let ((o1 (pop l1)) (o2 (pop l2)))
      (while (or o1 o2)
        (cond
         ((and o1 (stringp o1))
          (setq ap (emacs-collab-ot--push ap o1)
                bp (emacs-collab-ot--push bp (length o1))
                o1 (pop l1)))
         ((and o2 (stringp o2))
          (setq ap (emacs-collab-ot--push ap (length o2))
                bp (emacs-collab-ot--push bp o2)
                o2 (pop l2)))
         ((or (null o1) (null o2))
          (signal 'emacs-collab-ot-error (list "transform: operations too short/long")))
         (t
          (let* ((n1 (abs o1)) (n2 (abs o2)) (m (min n1 n2))
                 (r1 (> o1 0)) (r2 (> o2 0)))
            (cond ((and r1 r2)
                   (setq ap (emacs-collab-ot--push ap m)
                         bp (emacs-collab-ot--push bp m)))
                  ((and (not r1) (not r2)))
                  ((not r1)             ; a deletes, b retains
                   (setq ap (emacs-collab-ot--push ap (- m))))
                  (t                    ; a retains, b deletes
                   (setq bp (emacs-collab-ot--push bp (- m)))))
            (if (= n1 m) (setq o1 (pop l1)) (setq o1 (if r1 (- n1 m) (- m n1))))
            (if (= n2 m) (setq o2 (pop l2)) (setq o2 (if r2 (- n2 m) (- m n2)))))))))
    (cons (nreverse ap) (nreverse bp))))

(provide 'emacs-collab-ot)
;;; emacs-collab-ot.el ends here
