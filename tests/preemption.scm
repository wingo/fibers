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
  #:use-module (ice-9 atomic)
  #:use-module (fibers)
  #:use-module (fibers scheduler))

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
      (call-with-values (lambda () (run-fibers (lambda () exp) #:hz 1000))
        (lambda vals
          (format #t "ok (~a s)\n" (/ (- (get-internal-real-time) start)
                                      1.0 internal-time-units-per-second))
          (apply values vals))))))

(define-syntax-rule (assert-run-fibers-returns (expected ...) exp)
  (begin
    (call-with-values (lambda () (assert-run-fibers-terminates exp))
      (lambda run-fiber-return-vals
        (assert-equal '(expected ...) run-fiber-return-vals)))))

(assert-run-fibers-terminates
 (let lp ((n 0))
   (when (< n #e1e8) (lp (1+ n)))))

(define (race-until n)
  (let ((box (make-atomic-box 0)))
    (spawn-fiber (lambda ()
                   (let lp ()
                     (let ((x (atomic-box-ref box)))
                       (unless (= x n)
                         (when (even? x)
                           (atomic-box-set! box (1+ x)))
                         (lp))))))
    (spawn-fiber (lambda ()
                   (let lp ()
                     (let ((x (atomic-box-ref box)))
                       (unless (= x n)
                         (when (odd? x)
                           (atomic-box-set! box (1+ x)))
                         (lp))))))
    (let lp ()
      (if (equal? (atomic-box-ref box) n)
          n
          (lp)))))
(assert-run-fibers-returns (100) (race-until 100))

(exit (if failed? 1 0))
