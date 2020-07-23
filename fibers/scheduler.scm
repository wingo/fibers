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

(define-module (fibers scheduler)
  #:use-module (srfi srfi-9)
  #:use-module (fibers stack)
  #:use-module (fibers libevent)
  #:use-module (fibers psq)
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 control)
  #:use-module (ice-9 match)
  #:use-module (ice-9 fdes-finalizers)
  #:use-module ((ice-9 threads) #:select (current-thread))
  #:export (;; Low-level interface: schedulers and tasks.
            make-scheduler
            (current-scheduler/public . current-scheduler)
            scheduler-runcount
            (scheduler-kernel-thread/public . scheduler-kernel-thread)
            scheduler-remote-peers
            scheduler-work-pending?
            choose-parallel-scheduler
            run-scheduler
            cleanup-scheduler

            schedule-task
            schedule-task-when-fd-readable
            schedule-task-when-fd-writable
            schedule-task-at-time

            suspend-current-task
            yield-current-task))

(define-record-type <scheduler>
  (%make-scheduler libevt runcount-box prompt-tag
                   next-runqueue current-runqueue
                   fd-waiters timers kernel-thread
                   remote-peers choose-parallel-scheduler)
  scheduler?
  (libevt scheduler-libevt)
  ;; atomic variable of uint32
  (runcount-box scheduler-runcount-box)
  (prompt-tag scheduler-prompt-tag)
  ;; atomic stack of tasks to run next turn (reverse order)
  (next-runqueue scheduler-next-runqueue)
  ;; atomic stack of tasks to run this turn
  (current-runqueue scheduler-current-runqueue)
  ;; fd -> (total-events (events . task) ...)
  (fd-waiters scheduler-fd-waiters)
  ;; PSQ of expiry -> task
  (timers scheduler-timers set-scheduler-timers!)
  ;; atomic parameter of thread
  (kernel-thread scheduler-kernel-thread)
  ;; list of sched
  (remote-peers scheduler-remote-peers set-scheduler-remote-peers!)
  ;; () -> sched
  (choose-parallel-scheduler scheduler-choose-parallel-scheduler
                             set-scheduler-choose-parallel-scheduler!))

(define (make-atomic-parameter init)
  (let ((box (make-atomic-box init)))
    (case-lambda
      (() (atomic-box-ref box))
      ((new)
       (if (eq? new init)
           (atomic-box-set! box new)
           (let ((prev (atomic-box-compare-and-swap! box init new)))
             (unless (eq? prev init)
               (error "owned by other thread" prev))))))))

(define (shuffle l)
  (map cdr (sort (map (lambda (x) (cons (random 1.0) x)) l)
                 (lambda (a b) (< (car a) (car b))))))

(define (make-selector items)
  (let ((items (list->vector (shuffle items))))
    (match (vector-length items)
      (0 (lambda () #f))
      (1 (let ((item (vector-ref items 0))) (lambda () item)))
      (n (let ((idx 0))
           (lambda ()
             (let ((item (vector-ref items idx)))
               (set! idx (let ((idx (1+ idx)))
                           (if (= idx (vector-length items)) 0 idx)))
               item)))))))

(define* (make-scheduler #:key parallelism
                         (prompt-tag (make-prompt-tag "fibers")))
  "Make a new scheduler in which to run fibers."
  (let ((evt (libevt-create))
        (runcount-box (make-atomic-box 0))
        (next-runqueue (make-empty-stack))
        (current-runqueue (make-empty-stack))
        (fd-waiters (make-hash-table))
        (timers (make-psq (match-lambda*
                            (((t1 . c1) (t2 . c2)) (< t1 t2)))
                          <))
        (kernel-thread (make-atomic-parameter #f)))
    (let* ((sched (%make-scheduler evt runcount-box prompt-tag
                                   next-runqueue current-runqueue
                                   fd-waiters timers kernel-thread
                                   #f #f))
           (all-scheds
            (cons sched
                  (if parallelism
                      (map (lambda (_)
                             (make-scheduler #:prompt-tag prompt-tag))
                           (iota (1- parallelism)))
                      '()))))
      (for-each
       (lambda (sched)
         (let ((choose! (make-selector all-scheds)))
           (set-scheduler-remote-peers! sched (delq sched all-scheds))
           (set-scheduler-choose-parallel-scheduler! sched choose!)))
       all-scheds)
      sched)))

(define current-scheduler (fluid->parameter (make-thread-local-fluid #f)))
(define (current-scheduler/public)
  "Return the current scheduler, or @code{#f} if no scheduler is current."
  (current-scheduler))

(define-syntax-rule (with-scheduler scheduler body ...)
  "Evaluate @code{(begin @var{body} ...)} in an environment in which
@var{scheduler} is bound to the current kernel thread and
@code{current-scheduler} is bound to @var{scheduler}.  Signal an error
if @var{scheduler} is already running in some other kernel thread."
  (let ((sched scheduler))
    (dynamic-wind (lambda ()
                    ((scheduler-kernel-thread sched) (current-thread)))
                  (lambda ()
                    (parameterize ((current-scheduler sched))
                      body ...))
                  (lambda ()
                    ((scheduler-kernel-thread sched) #f)))))

(define (scheduler-runcount sched)
  "Return the number of tasks that have been run on @var{sched} since
it was started, modulo 2@sup{32}."
  (atomic-box-ref (scheduler-runcount-box sched)))

(define (scheduler-kernel-thread/public sched)
  "Return the kernel thread on which @var{sched} is running, or
@code{#f} if @var{sched} is not running."
  ((scheduler-kernel-thread sched)))

(define (choose-parallel-scheduler sched)
  ((scheduler-choose-parallel-scheduler sched)))

(define-inlinable (schedule-task/no-wakeup sched task)
  (stack-push! (scheduler-next-runqueue sched) task))

(define (schedule-task sched task)
  "Add the task @var{task} to the run queue of the scheduler
@var{sched}.  On the next turn, @var{sched} will invoke @var{task}
with no arguments.

This function is thread-safe even if @var{sched} is running on a
remote kernel thread."
  (schedule-task/no-wakeup sched task)
  ; (unless (eq? ((scheduler-kernel-thread sched)) (current-thread))
  ;   (libevt-wake! (scheduler-libevt sched)))
  (values))

(define (schedule-tasks-for-active-fd fd revents sched)
  (match (hashv-ref (scheduler-fd-waiters sched) fd)
    (#f (warn "scheduler for unknown fd" fd))
    ((and events+waiters (active-events . waiters))
     ;; First, clear the active status, as the EPOLLONESHOT has
     ;; deactivated our entry in the epoll set.
     (set-car! events+waiters #f)
     (set-cdr! events+waiters '())
     (unless (zero? (logand revents EVERR))
       (hashv-remove! (scheduler-fd-waiters sched) fd))
     ;; Now resume or re-schedule waiters, as appropriate.
     (let lp ((waiters waiters))
       (match waiters
         (() #f)
         (((events . task) . waiters)
          (if (zero? (logand revents (logior events EVERR)))
              ;; Re-schedule.
              (schedule-task-when-fd-active sched fd events task)
              ;; Resume.
              (schedule-task/no-wakeup sched task))
          (lp waiters)))))))

(define (schedule-tasks-for-expired-timers sched)
  ;; Schedule expired timer tasks in the order that they expired.
  (let ((now (get-internal-real-time)))
    (let expire-timers ((timers (scheduler-timers sched)))
      (cond
       ((or (psq-empty? timers)
            (< now (car (psq-min timers))))
        (set-scheduler-timers! sched timers))
       (else
        (call-with-values (lambda () (psq-pop timers))
          (match-lambda*
            (((_ . task) timers)
             (schedule-task/no-wakeup sched task)
             (expire-timers timers)))))))))

(define (schedule-tasks-for-next-turn sched)
  ;; Called when all tasks from the current turn have been run.
  ;; Note that there may be tasks already scheduled for the next
  ;; turn; one way this can happen is if a fiber suspended itself
  ;; because it was blocked on a channel, but then another fiber woke
  ;; it up, or if a remote thread scheduled a fiber on this scheduler.
  ;; In any case, check the kernel to see if any of the fd's that we
  ;; are interested in are active, and in that case schedule their
  ;; corresponding tasks.  Also run any timers that have timed out.
  (define (timers-expiry timers)
    (and (not (psq-empty? timers))
         (match (psq-min timers)
           ((expiry . task)
            expiry))))
  (define (update-expiry expiry)
    ;; If there are pending tasks, cause epoll to return
    ;; immediately.
    (if (stack-empty? (scheduler-next-runqueue sched))
        expiry
        0))
  (libevt (scheduler-libevt sched)
        #:expiry (timers-expiry (scheduler-timers sched))
        #:update-expiry update-expiry
        #:folder (lambda (fd revents sched)
                    (schedule-tasks-for-active-fd fd revents sched)
                    sched)
         #:seed sched)
  (schedule-tasks-for-expired-timers sched))

(define (work-stealer sched)
  "Steal some work from a random scheduler in the vector
@var{schedulers}.  Return a task, or @code{#f} if no work could be
stolen."
  (let ((selector (make-selector (scheduler-remote-peers sched))))
    (lambda ()
      (let ((peer (selector)))
        (and peer
             (stack-pop! (scheduler-current-runqueue peer) #f))))))

(define (scheduler-work-pending? sched)
  "Return @code{#t} if @var{sched} has any work pending: any tasks or
any pending timeouts."
  (not (and (psq-empty? (scheduler-timers sched))
            (stack-empty? (scheduler-current-runqueue sched))
            (stack-empty? (scheduler-next-runqueue sched)))))

(define* (run-scheduler sched finished?)
  "Run @var{sched} until calling @code{finished?} returns a true
value.  Return zero values."
  (let ((tag (scheduler-prompt-tag sched))
        (runcount-box (scheduler-runcount-box sched))
        (next (scheduler-next-runqueue sched))
        (cur (scheduler-current-runqueue sched))
        (steal-work! (work-stealer sched)))
    (define (run-task task)
      (atomic-box-set! runcount-box
                       (logand (1+ (atomic-box-ref runcount-box)) #xffffFFFF))
      (call-with-prompt tag
        task
        (lambda (k after-suspend)
          (after-suspend sched k))))
    (define (next-task)
      (match (stack-pop! cur #f)
        (#f
         (when (stack-empty? next)
           ;; Both current and next runqueues are empty; steal a
           ;; little bit of work from a remote scheduler if we
           ;; can.  Run it directly instead of pushing onto a
           ;; queue to avoid double stealing.
           (let ((task (steal-work!)))
             (when task
               (run-task task))))
         (next-turn))
        (task
         (run-task task)
         (next-task))))
    (define (next-turn)
      (unless (finished?)
        (schedule-tasks-for-next-turn sched)
        (stack-push-list! cur (reverse (stack-pop-all! next)))
        (next-task)))
    (define (run-scheduler/error-handling)
      (catch #t
        next-task
        (lambda args  (apply throw args))
        (let ((err (current-error-port)))
          (lambda (key . args)
            (false-if-exception
             (let ((stack (make-stack #t 4 tag)))
               (format err "Uncaught exception in task:\n")
               ;; FIXME: Guile's display-backtrace isn't respecting
               ;; stack narrowing; manually passing stack-length as
               ;; depth is a workaround.
               (display-backtrace stack err 0 (stack-length stack))
               (print-exception err (stack-ref stack 0)
                                key args)))))))
    (with-scheduler sched (run-scheduler/error-handling))))

(define (destroy-scheduler sched)
  "Release any resources associated with @var{sched}."
  (libevt-destroy (scheduler-libevt sched)))

(define (schedule-task-when-fd-active sched fd events task)
  "Arrange for @var{sched} to schedule @var{task} when the file
descriptor @var{fd} becomes active with any of the given @var{events},
expressed as an epoll bitfield."
  (let ((fd-waiters (hashv-ref (scheduler-fd-waiters sched) fd)))
    (match fd-waiters
      ((active-events . waiters)
       (set-cdr! fd-waiters (acons events task waiters))
       (unless (and active-events
                    (= (logand events active-events) events))
         (let ((active-events (logior events (or active-events 0))))
           (set-car! fd-waiters active-events)
           (libevt-add! (scheduler-libevt sched) fd active-events))))
      (#f
       (let ((fd-waiters (list events (cons events task))))
         (define (finalize-fd fd)
           ;; When a file port is closed, clear out the list of
           ;; waiting tasks so that when/if this FD is re-used, we
           ;; don't resume stale tasks.  Note that we don't need to
           ;; remove the FD from the epoll set, as the kernel manages
           ;; that for us.
           ;;
           ;; FIXME: Is there a way to wake all tasks in a thread-safe
           ;; way?  Note that this function may be invoked from a
           ;; finalizer thread.
           (set-cdr! fd-waiters '())
           (set-car! fd-waiters #f))
         (hashv-set! (scheduler-fd-waiters sched) fd fd-waiters)
         (add-fdes-finalizer! fd finalize-fd)
         (libevt-add! (scheduler-libevt sched) fd events))))))

(define (schedule-task-when-fd-readable sched fd task)
  "Arrange to schedule @var{task} on @var{sched} when the file
descriptor @var{fd} becomes readable."
  (schedule-task-when-fd-active sched fd (logior EVREAD EVWRITE) task))

(define (schedule-task-when-fd-writable sched fd task)
  "Arrange to schedule @var{k} on @var{sched} when the file descriptor
@var{fd} becomes writable."
  (schedule-task-when-fd-active sched fd EVWRITE task))

(define (schedule-task-at-time sched expiry task)
  "Arrange to schedule @var{task} when the absolute real time is
greater than or equal to @var{expiry}, expressed in internal time
units."
  (set-scheduler-timers! sched
                         (psq-set (scheduler-timers sched)
                                  (cons expiry task)
                                  expiry)))

;; Shim for Guile 2.1.5.
(unless (defined? 'suspendable-continuation?)
  (define! 'suspendable-continuation? (lambda (tag) #t)))

(define* (suspend-current-task after-suspend)
  "Suspend the current task.  After suspending, call the
@var{after-suspend} callback with two arguments: the current
scheduler, and the continuation of the current task.  The continuation
passed to the @var{after-suspend} handler is the continuation of the
@code{suspend-current-task} call."
  (let ((tag (scheduler-prompt-tag (current-scheduler))))
    (unless (suspendable-continuation? tag)
      (error "Attempt to suspend fiber within continuation barrier"))
    (abort-to-prompt tag after-suspend)))

(define* (yield-current-task)
  "Yield control to the current scheduler.  Like calling
@code{(suspend-current-task schedule-task)} except that it avoids
suspending if the current continuation isn't suspendable.  Returns
@code{#t} if the yield succeeded, or @code{#f} otherwise."
  (match (current-scheduler)
    (#f #f)
    (sched
     (let ((tag (scheduler-prompt-tag sched)))
       (and (suspendable-continuation? tag)
            (begin
              (abort-to-prompt tag schedule-task)
              #t))))))

(define (cleanup-scheduler sched)
  (for-each destroy-scheduler (scheduler-remote-peers sched))
  (destroy-scheduler sched)
)