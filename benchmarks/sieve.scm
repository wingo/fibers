#!/usr/bin/env guile
# -*- scheme -*-
!#

(use-modules (ice-9 match)
             (fibers)
             (fibers channels))

(define (sieve p in)
  (let ((out (make-channel)))
    (spawn-fiber (lambda ()
                   (let lp ()
                     (let ((n (get-message in)))
                       (unless (zero? (modulo n p))
                         (put-message out n)))
                     (lp)))
                 #:parallel? #t)
    out))

(define (integers-from n)
  (let ((out (make-channel)))
    (spawn-fiber (lambda ()
                   (let lp ((n n))
                     (put-message out n)
                     (lp (1+ n))))
                 #:parallel? #t)
    out))

(define (take ch n)
  (let lp ((n n))
    (unless (zero? n)
      (get-message ch)
      (lp (1- n)))))

(define (primes)
  (let ((out (make-channel)))
    (spawn-fiber (lambda ()
                   (let lp ((ch (integers-from 2)))
                     (let ((p (pk (get-message ch))))
                       (put-message out p)
                       (lp (sieve p ch)))))
                 #:parallel? #t)
    out))

(define (main args)
  (match args
    ((_ count)
     (let ((count (string->number count)))
       (run-fibers (lambda () (take (primes) count)))))))

(when (batch-mode?) (main (program-arguments)))
