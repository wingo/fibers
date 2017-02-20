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

(define-module (tests cml)
  #:use-module (fibers)
  #:use-module (fibers channels))

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

(define-syntax-rule (assert-run-fibers-terminates exp)
  (begin
    (format #t "assert run-fibers on ~s terminates: " 'exp)
    (force-output)
    (let ((start (get-internal-real-time)))
      (call-with-values (lambda () (run-fibers (lambda () exp)))
        (lambda vals
          (format #t "ok (~a s)\n" (/ (- (get-internal-real-time) start)
                                      1.0 internal-time-units-per-second))
          (apply values vals))))))

(define-syntax-rule (assert-run-fibers-returns (expected ...) exp)
  (begin
    (call-with-values (lambda () (assert-run-fibers-terminates exp))
      (lambda run-fiber-return-vals
        (assert-equal '(expected ...) run-fiber-return-vals)))))

(define-syntax-rule (do-times n exp)
  (let lp ((count n))
    (let ((count (1- count)))
      exp
      (unless (zero? count) (lp count)))))

(define-syntax-rule (rpc exp)
  (let ((ch (make-channel)))
    (spawn-fiber (lambda () (put-message ch exp)))
    (get-message ch)))

(assert-run-fibers-returns (1) (rpc 1))

(define (rpc-fib n)
  (rpc (if (< n 2)
           1
           (+ (rpc-fib (- n 1)) (rpc-fib (- n 2))))))

(assert-run-fibers-returns (75025) (rpc-fib 24))

(define (pingpong M N)
  (let ((request (make-channel)))
    (for-each (lambda (m)
                (spawn-fiber (lambda ()
                               (let lp ((n 0))
                                 (when (< n N)
                                   (let ((reply (make-channel)))
                                     (put-message request reply)
                                     (get-message reply)
                                     (lp (1+ n))))))
                             #:parallel? #t))
              (iota M))
    (let lp ((m 0))
      (when (< m M)
        (let lp ((n 0))
          (when (< n N)
            (put-message (get-message request) 'foo)
            (lp (1+ n))))
        (lp (1+ m))))))

(assert-run-fibers-terminates (pingpong (current-processor-count) 1000))

;; timed channel wait

;; multi-channel wait

;; cross-thread calls

(exit (if failed? 1 0))
