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

(define-module (fibers)
  #:use-module (ice-9 match)
  #:use-module (ice-9 atomic)
  #:use-module (fibers internal)
  #:use-module (fibers repl)
  #:use-module (fibers timers)
  #:use-module (fibers interrupts)
  #:use-module ((ice-9 threads) #:select (current-thread))
  #:use-module ((ice-9 ports internal)
                #:select (port-read-wait-fd port-write-wait-fd))
  #:use-module (ice-9 suspendable-ports)
  #:export (run-fibers spawn-fiber)
  #:re-export (current-fiber sleep))

(define (wait-for-readable port)
  (suspend-current-fiber
   (lambda (fiber)
     (resume-on-readable-fd (port-read-wait-fd port) fiber))))
(define (wait-for-writable port)
  (suspend-current-fiber
   (lambda (fiber)
     (resume-on-writable-fd (port-read-wait-fd port) fiber))))

(define* (run-fibers #:optional (init #f)
                     #:key (hz 0) (scheduler (make-scheduler))
                     (install-suspendable-ports? #t)
                     (keep-scheduler?
                      (->bool (scheduler-kernel-thread scheduler))))
  (when install-suspendable-ports? (install-suspendable-ports!))
  (with-scheduler
   scheduler
   (parameterize ((current-read-waiter wait-for-readable)
                  (current-write-waiter wait-for-writable))
     (with-interrupts
      hz yield-current-fiber
      (lambda ()
        (let ((ret (make-atomic-box #f)))
          (spawn-fiber (lambda ()
                         (call-with-values (or init values)
                           (lambda vals (atomic-box-set! ret vals))))
                       scheduler)
          (run-scheduler scheduler (lambda () (atomic-box-ref ret)))
          (unless keep-scheduler? (destroy-scheduler scheduler))
          (apply values (atomic-box-ref ret))))))))

(define (current-fiber-scheduler)
  (match (current-fiber)
    (#f (error "No scheduler current; call within run-fibers instead"))
    (fiber (fiber-scheduler fiber))))

(define* (spawn-fiber thunk #:optional (sched (current-fiber-scheduler))
                      #:key (dynamic-state (current-dynamic-state)))
  (create-fiber sched thunk dynamic-state))
