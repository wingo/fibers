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

(define-module (fibers interrupts)
  #:use-module (ice-9 threads)
  #:use-module (fibers posix-clocks)
  #:export (with-interrupts))

;; Cause periodic interrupts via `setitimer' and SIGPROF.  This
;; implementation has the disadvantage that it prevents `setitimer'
;; from being used for other purposes like profiling.
(define (with-interrupts/sigprof hz interrupt thunk)
  (let ((prev #f))
    (define (sigprof-handler _) (interrupt))

    (define (start-preemption!)
      (let ((period-usecs (inexact->exact (round (/ 1e6 hz)))))
        (set! prev (car (sigaction SIGPROF sigprof-handler)))
        (setitimer ITIMER_PROF 0 period-usecs 0 period-usecs)))

    (define (stop-preemption!)
      (setitimer ITIMER_PROF 0 0 0 0)
      (sigaction SIGPROF prev))

    (dynamic-wind start-preemption! thunk stop-preemption!)))

;; Cause periodic interrupts via a separate thread sleeping on a clock
;; driven by the current thread's CPU time.
(define (with-interrupts/thread-cputime hz interrupt thunk)
  (let ((interrupt-thread #f)
        (target-thread (current-thread))
        (clockid (pthread-getcpuclockid (pthread-self))))
    (define (start-preemption!)
      (let ((period-nsecs (inexact->exact (round (/ 1e9 hz)))))
        (set! interrupt-thread
          (call-with-new-thread
           (lambda ()
             (let lp ()
               (clock-nanosleep clockid period-nsecs)
               (system-async-mark interrupt target-thread)
               (lp)))))))

    (define (stop-preemption!)
      (cancel-thread interrupt-thread))

    (dynamic-wind start-preemption! thunk stop-preemption!)))

(define (with-interrupts hz interrupt thunk)
  "Run @var{sched} until there are no more fibers ready to run, no
file descriptors being waited on, and no more timers pending to run.
Return zero values."
  (cond
   ((zero? hz) (thunk))
   ((provided? 'threads)
    (with-interrupts/thread-cputime hz interrupt thunk))
   (else
    (with-interrupts/sigprof hz interrupt thunk))))
