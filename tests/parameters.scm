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
;;;; You should have received a copy of the GNU Lesser General Public License
;;;; along with this program.  If not, see <http://www.gnu.org/licenses/>.
;;;;

(define-module (tests parameters)
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

(define-syntax-rule (rpc exp)
  (let ((ch (make-channel)))
    (spawn-fiber (lambda () (put-message ch exp)))
    (get-message ch)))

(define my-param (make-parameter #f))

(assert-run-fibers-returns (#f) (my-param))
(assert-run-fibers-returns (#f) (rpc (my-param)))
(assert-run-fibers-returns (42) (rpc (begin (my-param 42) (my-param))))
(assert-run-fibers-returns (#f) (my-param))
(assert-run-fibers-returns (100) (begin (my-param 100) (rpc (my-param))))
(assert-run-fibers-returns (#f) (my-param))
(assert-equal #f (my-param))
(assert-equal 'foo (begin (my-param 'foo) (my-param)))
(assert-run-fibers-returns (foo) (my-param))
(assert-run-fibers-returns (foo) (rpc (my-param)))

(exit (if failed? 1 0))
