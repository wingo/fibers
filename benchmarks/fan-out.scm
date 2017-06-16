#!/usr/bin/env guile
# -*- scheme -*-
!#

(use-modules (ice-9 match)
             (fibers)
             (fibers channels))

(define (make-fan-out degree make-head make-tail)
  (let ((ch (make-head)))
    (let lp ((degree degree))
      (when (positive? degree)
        (make-tail ch)
        (lp (1- degree))))))

(define (test degree message-count)
  (let ((ch (make-channel)))
    (make-fan-out
     degree
     (lambda () ch)
     (lambda (ch)
       (spawn-fiber (lambda ()
                      (let lp () (get-message ch) (lp)))
                    #:parallel? #t)))
    (let lp ((n 0))
      (when (< n message-count)
        (put-message ch n)
        (lp (1+ n))))))

(define (main args)
  (match args
    ((_ degree message-count)
     (let ((degree (string->number degree))
           (message-count (string->number message-count)))
       (run-fibers (lambda () (test degree message-count)))))))

(when (batch-mode?) (main (program-arguments)))
