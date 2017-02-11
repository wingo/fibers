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

(define-module (tests foreign)
  #:use-module (fibers)
  #:use-module (fibers operations)
  #:use-module (fibers channels)
  #:use-module (fibers timers)
  #:use-module (ice-9 threads))

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

(define (receive-from-fiber x)
  (let* ((ch (make-channel))
         (t (call-with-new-thread
             (lambda ()
               (run-fibers (lambda () (put-message ch 42))))))
         (v (get-message ch)))
    (join-thread t)
    v))

(define (send-to-fiber x)
  (let* ((ch (make-channel))
         (t (call-with-new-thread
             (lambda ()
               (run-fibers (lambda () (get-message ch)))))))
    (put-message ch x)
    (join-thread t)))

(assert-equal #f #f)
(assert-terminates #t)
(assert-terminates (sleep 1))
(assert-terminates (perform-operation (sleep-operation 1)))
(assert-equal 42 (receive-from-fiber 42))
(assert-equal 42 (send-to-fiber 42))

(exit (if failed? 1 0))
