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
  #:use-module (fibers scheduler)
  #:use-module (fibers repl)
  #:use-module (fibers timers)
  #:use-module (fibers interrupts)
  #:use-module (ice-9 threads)
  #:use-module ((ice-9 ports internal)
                #:select (port-read-wait-fd port-write-wait-fd))
  #:use-module (ice-9 suspendable-ports)
  #:export (run-fibers spawn-fiber)
  #:re-export (sleep))

(define (wait-for-readable port)
  (suspend-current-task
   (lambda (sched k)
     (schedule-task-when-fd-readable sched (port-read-wait-fd port) k))))
(define (wait-for-writable port)
  (suspend-current-task
   (lambda (sched k)
     (schedule-task-when-fd-writable sched (port-write-wait-fd port) k))))

(define-syntax-rule (with-affinity affinity exp ...)
  (let ((saved #f))
    (dynamic-wind
      (lambda ()
        (set! saved (getaffinity 0))
        (setaffinity 0 affinity))
      (lambda () exp ...)
      (lambda ()
        (setaffinity 0 saved)))))

(define (%run-fibers scheduler hz finished? affinity)
  (with-affinity
   affinity
   (with-interrupts
    hz
    (let ((last-runcount 0))
      (lambda ()
        (let* ((runcount (scheduler-runcount scheduler))
               (res (eqv? runcount last-runcount)))
          (set! last-runcount runcount)
          res)))
    yield-current-task
    (lambda ()
      (run-scheduler scheduler finished?)))))

(define (start-auxiliary-threads scheduler hz finished? affinities)
  (for-each (lambda (sched affinity)
              (call-with-new-thread
               (lambda ()
                 (%run-fibers sched hz finished? affinity))))
            (scheduler-remote-peers scheduler) affinities))

(define (stop-auxiliary-threads scheduler)
  (for-each
   (lambda (scheduler)
     (let ((thread (scheduler-kernel-thread scheduler)))
       (when thread
         (cancel-thread thread)
         (join-thread thread))))
   (scheduler-remote-peers scheduler)))

(define (compute-affinities group-affinity parallelism)
  (define (each-thread-has-group-affinity)
    (make-list parallelism group-affinity))
  (define (one-thread-per-cpu)
    (let lp ((cpu 0))
      (match (bit-position #t group-affinity cpu)
        (#f '())
        (cpu (let ((affinity
                    (make-bitvector (bitvector-length group-affinity) #f)))
               (bitvector-set! affinity cpu #t)
               (cons affinity (lp (1+ cpu))))))))
  (let ((cpu-count (bit-count #t group-affinity)))
    (if (eq? parallelism cpu-count)
        (one-thread-per-cpu)
        (each-thread-has-group-affinity))))

(define* (run-fibers #:optional (init #f)
                     #:key (hz 100) (scheduler #f)
                     (parallelism (current-processor-count))
                     (cpus (getaffinity 0))
                     (install-suspendable-ports? #t)
                     (drain? #f))
  (when install-suspendable-ports? (install-suspendable-ports!))
  (cond
   (scheduler
    (let ((finished? (lambda () #f)))
      (when init (spawn-fiber init scheduler))
      (%run-fibers scheduler hz finished? cpus)))
   (else
    (let* ((scheduler (make-scheduler #:parallelism parallelism))
           (ret (make-atomic-box #f))
           (finished? (lambda ()
                        (and (atomic-box-ref ret)
                             (or (not drain?)
                                 (not (scheduler-work-pending? scheduler))))))
           (affinities (compute-affinities cpus parallelism)))
      (unless init
        (error "run-fibers requires initial fiber thunk when creating sched"))
      (spawn-fiber (lambda ()
                     (call-with-values init
                       (lambda vals (atomic-box-set! ret vals)))
                     ;; Could be that this fiber was migrated away.
                     ;; Make sure to wake up the main scheduler.
                     (spawn-fiber (lambda () #t) scheduler))
                   scheduler)
      (match affinities
        ((affinity . affinities)
         (dynamic-wind
           (lambda ()
             (start-auxiliary-threads scheduler hz finished? affinities))
           (lambda ()
             (%run-fibers scheduler hz finished? affinity))
           (lambda ()
             (stop-auxiliary-threads scheduler)))))
      (for-each destroy-scheduler (scheduler-remote-peers scheduler))
      (destroy-scheduler scheduler)
      (apply values (atomic-box-ref ret))))))

(define* (spawn-fiber thunk #:optional sched #:key parallel?)
  "Spawn a new fiber which will start by invoking @var{thunk}.
The fiber will be scheduled on the next turn.  @var{thunk} will run
with a copy of the current dynamic state, isolating fluid and
parameter mutations to the fiber."
  (define (capture-dynamic-state thunk)
    (let ((dynamic-state (current-dynamic-state)))
      (lambda ()
        (with-dynamic-state dynamic-state thunk))))
  (define (create-fiber sched thunk)
    (schedule-task sched
                   (capture-dynamic-state thunk)))
  (cond
   (sched
    ;; When a scheduler is passed explicitly, it could be there is no
    ;; current fiber; in that case the dynamic state probably doesn't
    ;; have the right right current-read-waiter /
    ;; current-write-waiter, so wrap the thunk.
    (create-fiber sched
                  (lambda ()
                    (current-read-waiter wait-for-readable)
                    (current-write-waiter wait-for-writable)
                    (thunk))))
   ((current-scheduler)
    => (lambda (sched)
         (create-fiber (if parallel?
                           (choose-parallel-scheduler sched)
                           sched)
                       thunk)))
   (else
    (error "No scheduler current; call within run-fibers instead"))))
