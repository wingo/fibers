;; Fibers: cooperative, event-driven user-space threads.

;;;; Copyright (C) 2016,2021 Free Software Foundation, Inc.
;;;; Copyright (C) 2021 Maxime Devos
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

(define-module (fibers io-wakeup)
  #:use-module (fibers scheduler)
  #:use-module (fibers operations)
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 match)
  #:use-module (ice-9 threads)
  #:use-module (ice-9 ports internal)
  #:export (wait-until-port-readable-operation
	    wait-until-port-writable-operation))

(define *poll-sched* (make-atomic-box #f))

(define (poll-sched)
  (or (atomic-box-ref *poll-sched*)
      (let ((sched (make-scheduler)))
        (cond
         ((atomic-box-compare-and-swap! *poll-sched* #f sched))
         (else
          ;; FIXME: Would be nice to clean up this thread at some point.
          (call-with-new-thread
           (lambda ()
             (define (finished?) #f)
             (run-scheduler sched finished?)))
          sched)))))

;; These procedure are subject to spurious wakeups.

(define (readable? port)
  "Test if PORT is writable."
  (match (select (vector port) #() #() 0)
    ((#() #() #()) #f)
    ((#(_) #() #()) #t)))

(define (writable? port)
  "Test if PORT is writable."
  (match (select #() (vector port) #() 0)
    ((#() #() #()) #f)
    ((#() #(_) #()) #t)))

(define (make-wait-operation ready? schedule-when-ready port port-ready-fd this-procedure)
  (make-base-operation #f
                       (lambda _
                         (and (ready? port) values))
                       (lambda (flag sched resume)
                         (define (commit)
                           (match (atomic-box-compare-and-swap! flag 'W 'S)
                             ('W (resume values))
                             ('C (commit))
                             ('S #f)))
                         (if sched
                             (schedule-when-ready
                              sched (port-ready-fd port) commit)
                             (schedule-task
                              (poll-sched)
                              (lambda ()
                                (perform-operation (this-procedure port))
                                (commit)))))))

(define (wait-until-port-readable-operation port)
  "Make an operation that will succeed when PORT is readable."
  (unless (input-port? port)
    (error "refusing to wait forever for input on non-input port"))
  (make-wait-operation readable? schedule-task-when-fd-readable port
                       port-read-wait-fd
                       wait-until-port-readable-operation))

(define (wait-until-port-writable-operation port)
  "Make an operation that will succeed when PORT is writable."
  (unless (output-port? port)
    (error "refusing to wait forever for output on non-output port"))
  (make-wait-operation writable? schedule-task-when-fd-writable port
                       port-write-wait-fd
                       wait-until-port-writable-operation))
