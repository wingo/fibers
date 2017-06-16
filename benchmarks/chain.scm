#!/usr/bin/env guile
# -*- scheme -*-
!#

(use-modules (ice-9 match)
             (fibers)
             (fibers channels))

(define (make-chain link-count make-head make-link make-tail)
  (let lp ((link-count link-count) (ch (make-head)))
    (if (zero? link-count)
        (make-tail ch)
        (lp (1- link-count) (make-link ch)))))

(define (test link-count message-count)
  (get-message
   (make-chain
    link-count
    (lambda ()
      (let ((out (make-channel)))
        (spawn-fiber (lambda ()
                       (let lp ((n 0))
                         (put-message out n)
                         (lp (1+ n))))
                     #:parallel? #t)
        out))
    (lambda (in)
      (let ((out (make-channel)))
        (spawn-fiber (lambda ()
                       (let lp ()
                         (put-message out (get-message in))
                         (lp)))
                     #:parallel? #t)
        out))
    (lambda (in)
      (let ((out (make-channel)))
        (spawn-fiber (lambda ()
                       (let lp ()
                         (if (< (get-message in) message-count)
                             (lp)
                             (put-message out 'done))))
                     #:parallel? #t)
        out)))))

(define (main args)
  (match args
    ((_ link-count message-count)
     (let ((link-count (string->number link-count))
           (message-count (string->number message-count)))
       (run-fibers (lambda () (test link-count message-count)))))))

(when (batch-mode?) (main (program-arguments)))
