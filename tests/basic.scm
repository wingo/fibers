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
  #:use-module (fibers)
  #:use-module (srfi srfi-1))

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

(define-syntax-rule (assert-run-fibers-terminates exp)
  (begin
    (format #t "assert run-fibers on ~s terminates: " 'exp)
    (force-output)
    (let ((start (get-internal-real-time)))
      (run-fibers (lambda () exp))
      (format #t "ok (~a s)\n" (/ (- (get-internal-real-time) start)
                                  1.0 internal-time-units-per-second)))))

(define-syntax-rule (do-times n exp)
  (let lp ((count n))
    (let ((count (1- count)))
      exp
      (unless (zero? count) (lp count)))))

(assert-equal #f #f)
(assert-terminates #t)
(assert-terminates (run-fibers))
(assert-run-fibers-terminates (sleep 1))
(assert-run-fibers-terminates (do-times 1 (spawn-fiber (lambda () #t))))
(assert-run-fibers-terminates (do-times 10 (spawn-fiber (lambda () #t))))
(assert-run-fibers-terminates (do-times 100 (spawn-fiber (lambda () #t))))
(assert-run-fibers-terminates (do-times 1000 (spawn-fiber (lambda () #t))))
(assert-run-fibers-terminates (do-times 10000 (spawn-fiber (lambda () #t))))
(assert-run-fibers-terminates (do-times 100000 (spawn-fiber (lambda () #t))))
(assert-run-fibers-terminates (do-times 1 (spawn-fiber (lambda () (sleep 1)))))
(assert-run-fibers-terminates (do-times 10 (spawn-fiber (lambda () (sleep 1)))))
(assert-run-fibers-terminates (do-times 100 (spawn-fiber (lambda () (sleep 1)))))
(assert-run-fibers-terminates (do-times 1000 (spawn-fiber (lambda () (sleep 1)))))
(assert-run-fibers-terminates (do-times 10000 (spawn-fiber (lambda () (sleep 1)))))
(assert-run-fibers-terminates (do-times 20000 (spawn-fiber (lambda () (sleep 1)))))
(assert-run-fibers-terminates (do-times 40000 (spawn-fiber (lambda () (sleep 1)))))

(define (spawn-fiber-tree n leaf)
  (do-times n (spawn-fiber
               (lambda ()
                 (if (= n 1)
                     (leaf)
                     (spawn-fiber-tree (1- n) leaf))))))
(assert-run-fibers-terminates (spawn-fiber-tree 5 (lambda () (sleep 1))))

(define (spawn-fiber-chain n)
  (spawn-fiber
   (lambda ()
     (unless (zero? (1- n))
       (spawn-fiber-chain (1- n))))))
(assert-run-fibers-terminates (spawn-fiber-chain 5))
(assert-run-fibers-terminates (spawn-fiber-chain 50))
(assert-run-fibers-terminates (spawn-fiber-chain 500))
(assert-run-fibers-terminates (spawn-fiber-chain 5000))
(assert-run-fibers-terminates (spawn-fiber-chain 50000))
(assert-run-fibers-terminates (spawn-fiber-chain 500000))
(assert-run-fibers-terminates (spawn-fiber-chain 5000000))

;; sleep wakeup order

(define sleep-list-mtx (make-mutex))

(define sleep-list '())

(define (add-order n)
  (lock-mutex sleep-list-mtx)
  (set! sleep-list (cons n sleep-list))
  (unlock-mutex sleep-list-mtx))

(define *randstate* (random-state-from-platform))

;; TODO(codemac): Curerntly this does not pass, as the "spawn time"
;; for each sleep isn't actually taken into account here. Ideally we
;; can make these sleeps small enough that the test goes quickly
;; without actually drifting across when each spawn-fiber is called.
(assert-run-fibers-terminates
 (do-times
  1000
  (let* ((nr (random 100 *randstate*))
	 (n  (exact->inexact (/ nr 1000))))
    (spawn-fiber (lambda () (sleep n) (add-order n))))))

(assert-equal (sort sleep-list <) (reverse sleep-list))

;; fib using channels

;; sleep durations

;; timed channel wait

;; multi-channel wait

;; exceptions

;; cross-thread calls

;; closing port causes pollerr

;; live threads list

(exit (if failed? 1 0))
