#!/usr/bin/env guile
# -*- scheme -*-
!#

(use-modules (ice-9 match)
             (fibers)
             (fibers channels))

(define (run-ping-pong message-count)
  (let ((ch (make-channel)))
    (spawn-fiber (lambda ()
                   (let lp ()
                     (put-message ch (get-message ch))
                     (lp)))
                 #:parallel? #t)
    (let lp ((n 0))
      (when (< n message-count)
        (put-message ch n)
        (get-message ch)
        (lp (1+ n))))))

(define (test pair-count message-count)
  (let ((done (make-channel)))
    (for-each (lambda (_)
                (spawn-fiber (lambda ()
                               (run-ping-pong message-count)
                               (put-message done 'done))
                             #:parallel? #t))
              (iota pair-count))
    (for-each (lambda (_) (get-message done))
              (iota pair-count))))

(define (main args)
  (match args
    ((_ pair-count message-count)
     (let ((pair-count (string->number pair-count))
           (message-count (string->number message-count)))
       (run-fibers (lambda () (test pair-count message-count)))))))

(when (batch-mode?) (main (program-arguments)))
