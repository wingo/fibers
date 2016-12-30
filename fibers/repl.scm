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

(define-module (fibers repl)
  #:use-module (system repl common)
  #:use-module (system repl command)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module ((ice-9 threads) #:select (call-with-new-thread))
  #:use-module (fibers)
  #:use-module (fibers internal))

(define (sleep-forever)
  (let lp () (sleep 3600) (lp)))

(define repl-current-scheds (make-doubly-weak-hash-table))
(define (repl-current-sched repl)
  (hashq-ref repl-current-scheds repl))
(define (repl-set-current-sched! repl sched verbose?)
  (when verbose?
    (format #t "Scheduler ~a on thread ~a is now current\n."
            (scheduler-name sched) (scheduler-kernel-thread sched)))
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
                  (thread (call-with-new-thread
                           (lambda ()
                             (run-fibers sleep-forever
                                         #:scheduler sched)))))
             (when verbose?
               (format #t "No active schedulers; spawned a new one.\n"))
             (repl-set-current-sched! repl sched verbose?)
             sched))
          (((id . (and sched (? sched-alive?))) . scheds)
           (when verbose?
             (format #t "No current scheduler; choosing one randomly.\n"))
           (repl-set-current-sched! repl sched verbose?)
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
  (call-with-new-thread (lambda ()
                          (run-fibers sleep-forever))))

(define-meta-command ((kill-sched fibers) repl sched)
  "kill-sched SCHED
Shut down a scheduler."
  (display "Don't know how to do that yet!\n"))

(define-meta-command ((fibers fibers) repl #:optional sched)
  "fibers [SCHED]
Show a list of fibers.

If SCHED is given, limit to fibers bound to the given scheduler."
  (let ((sched (and sched
                    (or (scheduler-by-name sched)
                        (error "no scheduler with name" sched)))))
    (match (sort (fold-all-fibers acons '())
                 (match-lambda*
                   (((id1 . _) (id2 . _)) (< id1 id2))))
      (() (format #t "No fibers.\n"))
      (fibers
       (format #t "~a ~8t~a\n" "fiber" "state")
       (format #t "~a ~8t~a\n" "-----" "-----")
       (for-each
        (match-lambda
          ((id . fiber)
           ;; How to show fiber data?  Would be nice to say "suspended
           ;; at foo.scm:32:4".
           (when (or (not sched) (eq? (fiber-scheduler fiber) sched))
             (format #t "~a ~8t~a\n" id
                     (if (fiber-continuation fiber) "(suspended)" "")))))
        fibers)))))

(define-meta-command ((spawn-fiber fibers) repl (form) #:optional sched)
  "spawn-fiber EXP [SCHED]
Spawn a new fiber that runs EXP.

If SCHED is given, the fiber will be spawned on the given scheduler."
  (let ((thunk (repl-prepare-eval-thunk repl (repl-parse repl form)))
        (sched (repl-ensure-current-sched repl)))
    (spawn-fiber thunk sched)))

(define-meta-command ((kill-fiber fibers) repl fiber)
  "kill-fiber FIBER
Shut down a fiber."
  (display "Don't know how to do that yet!\n"))
