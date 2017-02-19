;; Fibers: cooperative, event-driven user-space threads.

;;;; Copyright (C) 2016 Free Software Foundation, Inc.
;;;;
;;;; This library is free software; you can redistribute it and/or
;;;; modify it under the terms of the GNU Lesser General Public
;;;; License as published by the Free Software Foundation; either
;;;; version 3 of the License, or (at your option) any later version.
;;;;
;;;; This library is distributed in the hope that it will be useful,
;;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;;; Lesser General Public License for more details.
;;;;
;;;; You should have received a copy of the GNU Lesser General Public
;;;; License along with this library; if not, write to the Free Software
;;;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
;;;;

(define-module (tests basic)
  #:use-module (fibers))

(define failed? #f)

(define-syntax-rule (assert-equal expected actual)
  (let ((x expected))
    (format #t "assert ~s equal to ~s: " 'actual x)
    (force-output)
    (let ((y actual))
      (cond
       ((equal? x y) (format #t "ok\n"))
       (else
        (format #t "no (got ~s)\n" y)
        (set! failed? #t))))))

(define-syntax-rule (assert-terminates exp)
  (begin
    (format #t "assert ~s terminates: " 'exp)
    (force-output)
    exp
    (format #t "ok\n")))

(define-syntax-rule (assert-run-fibers-terminates exp kw ...)
  (begin
    (format #t "assert terminates: ~s: " '(run-fibers (lambda () exp) kw ...))
    (force-output)
    (let ((start (get-internal-real-time)))
      (call-with-values (lambda () (run-fibers (lambda () exp) kw ...))
        (lambda vals
          (format #t "ok (~a s)\n" (/ (- (get-internal-real-time) start)
                                      1.0 internal-time-units-per-second))
          (apply values vals))))))

(define-syntax-rule (assert-run-fibers-returns (expected ...) exp)
  (begin
    (call-with-values (lambda ()
                        (assert-run-fibers-terminates exp #:drain? #t))
      (lambda run-fiber-return-vals
        (assert-equal '(expected ...) run-fiber-return-vals)))))

(define-syntax-rule (do-times n exp)
  (let lp ((count n))
    (let ((count (1- count)))
      exp
      (unless (zero? count) (lp count)))))

(assert-equal #f #f)
(assert-terminates #t)
(assert-equal #f (false-if-exception (begin (run-fibers) #t)))
(assert-run-fibers-terminates (sleep 1) #:drain? #t)
(assert-run-fibers-terminates (do-times 1 (spawn-fiber (lambda () #t))) #:drain? #t)
(assert-run-fibers-terminates (do-times 10 (spawn-fiber (lambda () #t))) #:drain? #t)
(assert-run-fibers-terminates (do-times 100 (spawn-fiber (lambda () #t))) #:drain? #t)
(assert-run-fibers-terminates (do-times 1000 (spawn-fiber (lambda () #t))) #:drain? #t)
(assert-run-fibers-terminates (do-times 10000 (spawn-fiber (lambda () #t))) #:drain? #t)
(assert-run-fibers-terminates (do-times 100000 (spawn-fiber (lambda () #t))) #:drain? #t)
(assert-run-fibers-terminates (do-times 100000
                                        (spawn-fiber (lambda () #t) #:parallel? #t)) #:drain? #t)
(define (loop-to-1e4) (let lp ((i 0)) (when (< i #e1e4) (lp (1+ i)))))
(assert-run-fibers-terminates (do-times 100000 (spawn-fiber loop-to-1e4)) #:drain? #t)
(assert-run-fibers-terminates (do-times 100000 (spawn-fiber loop-to-1e4 #:parallel? #t)) #:drain? #t)
(assert-run-fibers-terminates (do-times 1 (spawn-fiber (lambda () (sleep 1)))) #:drain? #t)
(assert-run-fibers-terminates (do-times 10 (spawn-fiber (lambda () (sleep 1)))) #:drain? #t)
(assert-run-fibers-terminates (do-times 100 (spawn-fiber (lambda () (sleep 1)))) #:drain? #t)
(assert-run-fibers-terminates (do-times 1000 (spawn-fiber (lambda () (sleep 1)))) #:drain? #t)
(assert-run-fibers-terminates (do-times 10000 (spawn-fiber (lambda () (sleep 1)))) #:drain? #t)
(assert-run-fibers-terminates (do-times 20000 (spawn-fiber (lambda () (sleep 1)))) #:drain? #t)
(assert-run-fibers-terminates (do-times 40000 (spawn-fiber (lambda () (sleep 1)))) #:drain? #t)

(define (spawn-fiber-tree n leaf)
  (do-times n (spawn-fiber
               (lambda ()
                 (if (= n 1)
                     (leaf)
                     (spawn-fiber-tree (1- n) leaf))))))
(assert-run-fibers-terminates (spawn-fiber-tree 5 (lambda () (sleep 1))) #:drain? #t)

(define (spawn-fiber-chain n)
  (spawn-fiber
   (lambda ()
     (unless (zero? (1- n))
       (spawn-fiber-chain (1- n))))))
(assert-run-fibers-terminates (spawn-fiber-chain 5) #:drain? #t)
(assert-run-fibers-terminates (spawn-fiber-chain 50) #:drain? #t)
(assert-run-fibers-terminates (spawn-fiber-chain 500) #:drain? #t)
(assert-run-fibers-terminates (spawn-fiber-chain 5000) #:drain? #t)
(assert-run-fibers-terminates (spawn-fiber-chain 50000) #:drain? #t)
(assert-run-fibers-terminates (spawn-fiber-chain 500000) #:drain? #t)
(assert-run-fibers-terminates (spawn-fiber-chain 5000000) #:drain? #t)

(let ((run-order 0))
  (define (test-run-order count)
    (for-each (lambda (n)
                (spawn-fiber
                 (lambda ()
                   (unless (eqv? run-order n)
                     (error "bad run order" run-order n))
                   (set! run-order (1+ n)))))
              (iota count)))
  (assert-run-fibers-terminates (test-run-order 10) #:parallelism 1 #:drain? #t))

(let ((run-order 0))
  (define (test-wakeup-order count)
    (for-each (lambda (n)
                (spawn-fiber
                 (lambda ()
                   (unless (eqv? run-order n)
                     (error "bad run order" run-order n))
                   (set! run-order (1+ n)))))
              (iota count)))
  (assert-run-fibers-terminates (test-wakeup-order 10) #:parallelism 1 #:drain? #t))

(assert-run-fibers-returns (1) 1)

(define (check-sleep timeout)
  (spawn-fiber (lambda ()
                 (let ((start (get-internal-real-time)))
                   (sleep timeout)
                   (let ((elapsed (/ (- (get-internal-real-time) start)
                                     1.0 internal-time-units-per-second)))
                     (format #t "assert sleep ~as < actual ~as: ~a (diff: ~a%)\n"
                             timeout elapsed (<= timeout elapsed)
                             (* 100 (/ (- elapsed timeout) timeout)))
                     (set! failed? (< elapsed timeout)))))))

(assert-run-fibers-terminates
 (do-times 20 (check-sleep (random 1.0))) #:drain? #t)

;; exceptions

;; closing port causes pollerr

;; live threads list

(exit (if failed? 1 0))
