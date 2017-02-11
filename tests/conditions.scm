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

(define-module (tests conditions)
  #:use-module (fibers)
  #:use-module (fibers conditions)
  #:use-module (fibers operations)
  #:use-module (fibers timers))

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

(define* (with-timeout op #:key (seconds 0.05) (wrap values))
  (choice-operation op
                    (wrap-operation (sleep-operation seconds) wrap)))

(define (wait/timeout cv)
  (perform-operation
   (with-timeout
    (wrap-operation (wait-operation cv)
                    (lambda () #t))
    #:wrap (lambda () #f))))

(define cv (make-condition))
(assert-equal #t (condition? cv))
(assert-run-fibers-returns (#f) (wait/timeout cv))
(assert-run-fibers-returns (#f) (wait/timeout cv))
(assert-equal #t (signal-condition! cv))
(assert-equal #f (signal-condition! cv))
(assert-run-fibers-returns (#t) (wait/timeout cv))
(assert-run-fibers-returns (#t) (wait/timeout cv))
(assert-run-fibers-returns (#t)
                           (let ((cv (make-condition)))
                             (spawn-fiber (lambda () (signal-condition! cv)))
                             (wait cv)
                             #t))

(exit (if failed? 1 0))
