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
  #:use-module ((ice-9 threads)
                #:select (current-thread current-processor-count))
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

(define (%run-fibers scheduler hz finished?)
  (with-scheduler
   scheduler
   (parameterize ((current-read-waiter wait-for-readable)
                  (current-write-waiter wait-for-writable))
     (with-interrupts
      hz yield-current-fiber
      (lambda ()
        (run-scheduler scheduler finished?))))))

(define (start-auxiliary-threads scheduler hz finished?)
  (let ((scheds (scheduler-remote-peers scheduler)))
    (let lp ((i 0))
      (when (< i (vector-length scheds))
        (let ((remote (vector-ref scheds i)))
          (call-with-new-thread
           (lambda ()
             (%run-fibers remote hz finished?)))
          (lp (1+ i)))))))

(define (stop-auxiliary-threads scheduler)
  (let ((scheds (scheduler-remote-peers scheduler)))
    (let lp ((i 0))
      (when (< i (vector-length scheds))
        (let* ((remote (vector-ref scheds i))
               (thread (scheduler-kernel-thread remote)))
          (when thread
            (cancel-thread thread)
            (join-thread thread))
          (lp (1+ i)))))))

(define* (run-fibers #:optional (init #f)
                     #:key (hz 0) (scheduler #f)
                     (parallelism (current-processor-count))
                     (install-suspendable-ports? #t))
  (when install-suspendable-ports? (install-suspendable-ports!))
  (cond
   (scheduler
    (let ((finished? (lambda () #f)))
      (when init (spawn-fiber init scheduler))
      (%run-fibers scheduler hz finished?)))
   (else
    (let* ((scheduler (make-scheduler #:parallelism parallelism))
           (ret (make-atomic-box #f))
           (finished? (lambda () (atomic-box-ref ret))))
      (unless init
        (error "run-fibers requires initial fiber thunk when creating sched"))
      (spawn-fiber (lambda ()
                     (call-with-values init
                       (lambda vals (atomic-box-set! ret vals))))
                   scheduler)
      (dynamic-wind
        (lambda () (start-auxiliary-threads scheduler hz finished?))
        (lambda () (%run-fibers scheduler hz finished?))
        (lambda () (stop-auxiliary-threads scheduler)))
      (destroy-scheduler scheduler)
      (apply values (atomic-box-ref ret))))))

(define* (spawn-fiber thunk #:optional sched #:key parallel?)
  (define (choose-sched sched)
    (let* ((remote (scheduler-remote-peers sched))
           (count (vector-length remote))
           (idx (random (1+ count))))
      (if (= count idx)
          sched
          (vector-ref remote idx))))
  (define (spawn sched thunk)
    (create-fiber (if parallel? (choose-sched sched) sched)
                  thunk
                  (current-dynamic-state)))
  (cond
   (sched
    ;; When a scheduler is passed explicitly, it could be there is no
    ;; current fiber; in that case the dynamic state probably doesn't
    ;; have the right right current-read-waiter /
    ;; current-write-waiter, so wrap the thunk.
    (spawn sched
           (lambda ()
             (current-read-waiter wait-for-readable)
             (current-write-waiter wait-for-writable)
             (thunk))))
   ((current-fiber)
    => (lambda (fiber)
         (spawn (fiber-scheduler fiber) thunk)))
   (else
    (error "No scheduler current; call within run-fibers instead"))))
