;; Fibers: cooperative, event-driven user-space threads.

;;;; Copyright (C) 2016,2021 Free Software Foundation, Inc.
;;;; Copyright (C) 2021,2023 Maxime Devos
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

(define-module (fibers io-wakeup)
  #:use-module (fibers scheduler)
  #:use-module (fibers operations)
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 control)
  #:use-module (ice-9 match)
  #:use-module (ice-9 suspendable-ports)
  #:use-module (ice-9 threads)
  #:use-module (ice-9 ports internal)
  #:export (make-read-operation
	    make-write-operation
	    wait-until-port-readable-operation
	    wait-until-port-writable-operation
	    accept-operation
	    with-read-waiting-is-failure
	    with-write-waiting-is-failure))

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

(define (try-ready ready? port)
  (lambda ()
    (and (ready? port) values)))

(define (make-wait-operation try-fn schedule-when-ready port port-ready-fd)
  (letrec ((this-operation
	    (make-base-operation
	     #f
	     try-fn
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
		      (perform-operation this-operation)
		      (commit))))))))
    this-operation))

(define (make-read-operation try-fn port)
  "Make an operation that tries TRY-FN, and when TRY-FN fails, blocks until
the input port PORT is readable.  TRY-FN is a thunk that either returns #false,
indicating failure, or a thunk, whose return values are the result of the
operation."
  (unless (input-port? port)
    (error "refusing to wait forever for input on non-input port"))
  (make-wait-operation try-fn schedule-task-when-fd-readable port
		       port-read-wait-fd))

(define (make-write-operation try-fn port)
  "Make an operation that tries TRY-FN, and when TRY-FN fails, blocks until
the output PORT is writable.  TRY-FN is a thunk that either returns #false,
indicating failure, or a thunk, whose return values are the result
of the operation."
  (unless (output-port? port)
    (error "refusing to wait forever for output on non-output port"))
  (make-wait-operation try-fn schedule-task-when-fd-writable port
		       port-write-wait-fd))

(define (wait-until-port-readable-operation port)
  "Make an operation that will succeed when PORT is readable."
  (make-read-operation (try-ready readable? port) port))

(define (wait-until-port-writable-operation port)
  "Make an operation that will succeed when PORT is writable."
  (make-write-operation (try-ready readable? port) port))

(define (with-x-waiting-is-failure port current-x-waiter try-fn)
  "Return a thunk like TRY-FN, except that it also fails when
TRY-FN invokes the procedure from the parameter CURRENT-X-WAITER on PORT.
CURRENT-X-WAITER is a parameter like current-read-waiter or
current-write-waiter.

Due to technical limitations of current-read-waiter/current-write-waiter,
TRY-FN may not modify CURRENT-X-WAITER in ways that this procedure might
notice."
  (lambda ()
    (let/ec escape
      (let* ((old-waiter (current-x-waiter))
	     (new-waiter
	      (lambda (port*)
		(if (eq? port port*)
		    (escape #false)
		    ;; Maybe TRY-FN is doing some logging?  Whatever is
		    ;; happening, (fibers io-wakeup) shouldn't interfere.
		    (old-waiter port*)))))
	(parameterize ((current-x-waiter new-waiter))
	  (try-fn))))))

(define (with-read-waiting-is-failure port try-fn)
  "Return a thunk like TRY-FN, except that it also fails when TRY-FN
invokes the procedure from the parameter current-read-waiter on PORT.

The read waiter at the current depth (relative to the invocation of
the returned thunk) may not be changed while the thunk is being invoked."
  (with-x-waiting-is-failure port current-read-waiter try-fn))

(define (with-write-waiting-is-failure port try-fn)
  "Return a thunk like TRY-FN, except that it also fails when TRY-FN
invokes the procedure from the parameter current-write-waiter on PORT.

The write waiter at the current depth (relative to the invocation of
the returned thunk) may not be changed while the thunk is being invoked."
  (with-x-waiting-is-failure port current-write-waiter try-fn))

(define O_CLOEXEC*
  (if (defined? 'O_CLOEXEC)
      O_CLOEXEC ; doesn't exist on guile-2.2
      0))

(define* (accept-operation port #:key (flags (logior O_CLOEXEC* O_NONBLOCK)))
  "Like '(accept port flags)', but as an operation.  Unlike
'accept', 'O_NONBLOCK' is included in the default flags,
which makes the accepted port non-blocking and hence suitable for
use with Fibers.

The flag 'O_CLOEXEC' is also included (if available).  Without
this flag, ports would be leaked to subprocesses by default, which
usually is at best inefficient and at worst a security problem.  But
rarely, ports are intended to be leaked to subprocesses, in which
case you could remove this flag.

Fibers doesn't emulate 'O_CLOEXEC' when unavailable, because it
would not be entirely equivalent in case of parallelism."
  (define (try)
    (let ((new (accept port flags)))
      (and new (lambda () (values new)))))
  (make-read-operation
   (with-read-waiting-is-failure port try)
   port))
