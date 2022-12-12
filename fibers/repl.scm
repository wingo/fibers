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

(define-module (fibers repl)
  #:use-module (system repl common)
  #:use-module (system repl command)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module ((ice-9 threads)
                #:select (call-with-new-thread cancel-thread join-thread))
  #:use-module (fibers)
  #:use-module (fibers nameset)
  #:use-module (fibers scheduler))

(define-once schedulers-nameset (make-nameset))

(define (fold-all-schedulers f seed)
  "Fold @var{f} over the set of known schedulers.  @var{f} will be
invoked as @code{(@var{f} @var{name} @var{scheduler} @var{seed})}."
  (nameset-fold f schedulers-nameset seed))
(define (scheduler-by-name name)
  "Return the scheduler named @var{name}, or @code{#f} if no scheduler
of that name is known."
  (nameset-ref schedulers-nameset name))

(define repl-current-scheds (make-doubly-weak-hash-table))
(define (repl-current-sched repl)
  (hashq-ref repl-current-scheds repl))
(define (repl-set-current-sched! repl name sched verbose?)
  (when verbose?
    (format #t "Scheduler ~a on thread ~a is now current\n."
            name (scheduler-kernel-thread sched)))
  (hashq-set! repl-current-scheds repl sched))
(define* (repl-ensure-current-sched repl #:optional (verbose? #t))
  (define (sched-alive? sched)
    ;; FIXME: ensure scheduler has not been destroyed.
    (and (scheduler-kernel-thread sched)))
  (or (repl-current-sched repl)
      (let lp ((scheds (fold-all-schedulers acons '())))
        (match scheds
          (()
           (let* ((sched (make-scheduler))
                  (name (nameset-add! schedulers-nameset sched))
                  (thread (call-with-new-thread
                           (lambda ()
                             (run-fibers #:scheduler sched)))))
             (when verbose?
               (format #t "No active schedulers; spawned a new one (#~a).\n"
                       name))
             (repl-set-current-sched! repl name sched verbose?)
             sched))
          (((id . (and sched (? sched-alive?))) . scheds)
           (when verbose?
             (format #t "No current scheduler; choosing scheduler #~a randomly.\n"
                     id))
           (repl-set-current-sched! repl id sched verbose?)
           sched)))))

(define-meta-command ((scheds fibers) repl)
  "scheds
Show a list of schedulers."
  (match (sort (fold-all-schedulers acons '())
               (match-lambda*
                 (((id1 . _) (id2 . _)) (< id1 id2))))
    (() (format #t "No schedulers.\n"))
    (schedulers
     (format #t "~a ~8t~a\n" "sched" "kernel thread")
     (format #t "~a ~8t~a\n" "-----" "-------------")
     (for-each
      (match-lambda
        ((id . sched)
         (format #t "~a ~8t~a\n" id (scheduler-kernel-thread sched))))
      schedulers))))

(define-meta-command ((spawn-sched fibers) repl)
  "spawn-sched
Create a new scheduler for fibers, and run it on a new kernel thread."
  (let* ((sched (make-scheduler))
         (name (nameset-add! schedulers-nameset sched)))
    (call-with-new-thread (lambda ()
                            (call-with-new-thread
                             (lambda ()
                               (run-fibers #:scheduler sched)))))
    (format #t "Spawned scheduler #~a.\n" name)))

(define-meta-command ((kill-sched fibers) repl name)
  "kill-sched NAME
Shut down a scheduler."
  (let ((sched (or (scheduler-by-name name)
                   (error "no scheduler with name" name))))
    (cond
     ((scheduler-kernel-thread sched)
      => (lambda (thread)
           (format #t "Killing thread running scheduler #~a...\n" name)
           (cancel-thread thread)
           (join-thread thread)
           (format #t "Thread running scheduler #~a stopped.\n" name)))
     (else
      (format #t "Scheduler #~a not running.\n" name)))))

(define-meta-command ((spawn-fiber fibers) repl (form) #:optional sched)
  "spawn-fiber EXP [SCHED]
Spawn a new fiber that runs EXP.

If SCHED is given, the fiber will be spawned on the given scheduler."
  (let ((thunk (repl-prepare-eval-thunk repl (repl-parse repl form)))
        (sched (repl-ensure-current-sched repl)))
    (spawn-fiber thunk sched)))
