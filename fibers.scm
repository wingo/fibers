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
  #:use-module (fibers internal)
  #:use-module (fibers repl)
  #:use-module (fibers timers)
  #:use-module ((ice-9 ports internal)
                #:select (port-read-wait-fd port-write-wait-fd))
  #:use-module (ice-9 suspendable-ports)
  #:export (run-fibers
            spawn-fiber)
  #:re-export (current-fiber
               sleep))

(define (wait-for-readable port)
  (suspend-current-fiber
   (lambda (fiber)
     (resume-on-readable-fd (port-read-wait-fd port) fiber))))
(define (wait-for-writable port)
  (suspend-current-fiber
   (lambda (fiber)
     (resume-on-writable-fd (port-read-wait-fd port) fiber))))

(define* (run-fibers #:optional (init #f)
                     #:key (scheduler (make-scheduler))
                     (install-suspendable-ports? #t)
                     (keep-scheduler? (eq? scheduler (current-scheduler))))
  (when install-suspendable-ports? (install-suspendable-ports!))
  (with-scheduler
   scheduler
   (parameterize ((current-read-waiter wait-for-readable)
                  (current-write-waiter wait-for-writable))
     (let ((ret #f))
       (spawn-fiber (lambda ()
                      (call-with-values (or init values)
                        (lambda vals (set! ret vals))))
                    scheduler)
       (let lp ()
         (run-scheduler scheduler)
         (unless ret (lp)))
       (unless keep-scheduler? (destroy-scheduler scheduler))
       (apply values ret)))))

(define (require-current-scheduler)
  (or (current-scheduler)
      (error "No scheduler current; call within run-fibers instead")))

(define* (spawn-fiber thunk #:optional (sched (require-current-scheduler)))
  (create-fiber sched thunk))
