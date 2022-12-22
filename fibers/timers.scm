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

(define-module (fibers timers)
  #:use-module (fibers scheduler)
  #:use-module (fibers operations)
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 match)
  #:use-module (ice-9 threads)
  #:export (sleep-operation
            timer-operation)
  #:replace (sleep))

(define *timer-sched* (make-atomic-box #f))

(define (timer-sched)
  (or (atomic-box-ref *timer-sched*)
      (let ((sched (make-scheduler)))
        (cond
         ((atomic-box-compare-and-swap! *timer-sched* #f sched))
         (else
          ;; FIXME: Would be nice to clean up this thread at some point.
          (call-with-new-thread
           (lambda ()
             (define (finished?) #f)
             (run-scheduler sched finished?)))
          sched)))))

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
                         (if sched
                             (schedule-task-at-time sched expiry timer)
                             (schedule-task
                              (timer-sched)
                              (lambda ()
                                (perform-operation (timer-operation expiry))
                                (timer)))))))

(define (sleep-operation seconds)
  "Make an operation that will succeed with no values when
@var{seconds} have elapsed."
  (timer-operation
   (+ (get-internal-real-time)
      (inexact->exact
       (round (* seconds internal-time-units-per-second))))))

(define (sleep seconds)
  "Block the calling fiber until @var{seconds} have elapsed."
  (perform-operation (sleep-operation seconds)))
