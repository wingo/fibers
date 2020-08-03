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

(define-module (tests close-port-resumes-waiters)
  #:use-module (fibers)
  #:use-module (fibers conditions)
  #:use-module (fibers operations)
  #:use-module (fibers timers)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 match))

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

(define (set-port-nonblocking! port)
  (fcntl port
         F_SETFL
         (logior O_NONBLOCK
                 (fcntl port F_GETFL))))

(define (timeout seconds)
  (+ (get-internal-real-time)
     (inexact->exact
      (round
       (* seconds
          internal-time-units-per-second)))))

(define client-terminated #f)

(assert-run-fibers-terminates
 (let ((condition (make-condition)))
   (match (pipe)
     ((in . out)
      (set-port-nonblocking! in)
      (set-port-nonblocking! out)
      (spawn-fiber (lambda ()
                     (catch #t
                       (lambda ()
                         (get-bytevector-n! in (make-bytevector 1) 0 1))
                       (lambda err (format #t "Err: ~a~%" err)))
                     (signal-condition! condition))
                   #:parallel? #t)
      ;; Need to wait a bit to ensure fiber is reading from port when
      ;; we close it
      (sleep 1)
      (close-port in)
      (set! client-terminated
        (perform-operation
         (choice-operation
          (wrap-operation (wait-operation condition) (const #t))
          (wrap-operation (timer-operation (timeout 1)) (const #f)))))))))

(assert-equal #t client-terminated)

(exit (if failed? 1 0))
