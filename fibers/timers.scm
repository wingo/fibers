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

(define-module (fibers timers)
  #:use-module (fibers internal)
  #:use-module (fibers operations)
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 match)
  #:export (wait-operation
            timer-operation)
  #:replace (sleep))

(define (timer-operation expiry)
  "Make an operation that will succeed when the current time is
greater than or equal to @var{expiry}, expressed in internal time
units.  The operation will succeed with no values."
  (make-base-operation #f
                       (lambda ()
                         (and (< expiry (get-internal-real-time))
                              values))
                       (lambda (flag sched resume)
                         (define (timer)
                           (match (atomic-box-compare-and-swap! flag 'W 'S)
                             ('W (resume values))
                             ('C (timer))
                             ('S #f)))
                         (add-timer sched expiry timer))))

(define (wait-operation seconds)
  "Make an operation that will succeed with no values when
@var{seconds} have elapsed."
  (timer-operation
   (+ (get-internal-real-time)
      (inexact->exact
       (round (* seconds internal-time-units-per-second))))))

(define (sleep seconds)
  "Block the calling fiber until @var{seconds} have elapsed."
  (perform-operation (wait-operation seconds)))
