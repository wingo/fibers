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

(define-module (tests speedup)
  #:use-module (ice-9 threads)
  #:use-module (fibers))

(define failed? #f)

(define-syntax-rule (do-times n exp)
  (let lp ((count n))
    (let ((count (1- count)))
      exp
      (unless (zero? count) (lp count)))))

(define (time thunk)
  (let ((start (get-internal-real-time)))
    (thunk)
    (/ (- (get-internal-real-time) start)
       1.0 internal-time-units-per-second)))

(define-syntax-rule (measure-speedup exp)
  (begin
    (format #t "speedup for ~s: " 'exp)
    (force-output)
    (let ((thunk (lambda () exp)))
      (let ((t1 (time (lambda ()
                        (run-fibers thunk #:parallelism 1 #:drain? #t)))))
        (format #t "~a s" t1)
        (let ((t2 (time (lambda () (run-fibers thunk #:drain? #t)))))
          (format #t " / ~a s = ~ax (~a cpus)\n" t2 (/ t1 t2)
                  (current-processor-count)))))))

(define (loop-to n) (let lp ((i 0)) (when (< i n) (lp (1+ i)))))
(define (alloc-to words n)
  (let lp ((i 0) (x #f))
    (if (< i n)
        (lp (1+ i) (make-vector (- words 2) #f))
        x)))

(unless (getenv "FIBERS_EXPENSIVE_TESTS")
  (newline (current-error-port))
  (format (current-error-port) "Skipping expensive test/benchmark.~%")
  (format (current-error-port) "\
Set the 'FIBERS_EXPENSIVE_TESTS' environment variable to run it.~%")
  (newline (current-error-port))
  (exit 77))

(measure-speedup
 (do-times 100000 (spawn-fiber (lambda () #t) #:parallel? #t)))
(measure-speedup
 (do-times 40000 (spawn-fiber (lambda () (sleep 1)) #:parallel? #t)))
(measure-speedup
 (do-times 100000 (spawn-fiber (lambda () (loop-to #e1e4)) #:parallel? #t)))
(measure-speedup
 (do-times 10000 (spawn-fiber (lambda () (loop-to #e1e5)) #:parallel? #t)))
(measure-speedup
 (do-times 1000 (spawn-fiber (lambda () (loop-to #e1e6)) #:parallel? #t)))

(measure-speedup
 (do-times 100000 (spawn-fiber (lambda () (alloc-to 4 #e1e3)) #:parallel? #t)))
(measure-speedup
 (do-times 10000 (spawn-fiber (lambda () (alloc-to 4 #e1e4)) #:parallel? #t)))
(measure-speedup
 (do-times 1000 (spawn-fiber (lambda () (alloc-to 4 #e1e5)) #:parallel? #t)))
