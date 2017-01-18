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

(define-module (fibers internal)
  #:use-module (srfi srfi-9)
  #:use-module (fibers stack)
  #:use-module (fibers epoll)
  #:use-module (fibers psq)
  #:use-module (fibers nameset)
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 control)
  #:use-module (ice-9 match)
  #:use-module (ice-9 fdes-finalizers)
  #:use-module ((ice-9 threads) #:select (current-thread))
  #:export (;; Low-level interface: schedulers and threads.
            make-scheduler
            with-scheduler
            scheduler-name
            (scheduler-kernel-thread/public . scheduler-kernel-thread)
            scheduler-remote-peers
            choose-parallel-scheduler
            run-scheduler
            destroy-scheduler

            resume-on-readable-fd
            resume-on-writable-fd
            add-timer

            create-fiber
            (current-fiber/public . current-fiber)
            kill-fiber
            fiber-scheduler
            fiber-continuation

            fold-all-schedulers
            scheduler-by-name
            fold-all-fibers
            fiber-by-name

            suspend-current-fiber
            resume-fiber
            yield-current-fiber))

(define-once fibers-nameset (make-nameset))
(define-once schedulers-nameset (make-nameset))

(define (fold-all-schedulers f seed)
  "Fold @var{f} over the set of known schedulers.  @var{f} will be
invoked as @code{(@var{f} @var{name} @var{scheduler} @var{seed})}."
  (nameset-fold f schedulers-nameset seed))
(define (scheduler-by-name name)
  "Return the scheduler named @var{name}, or @code{#f} if no scheduler
of that name is known."
  (nameset-ref schedulers-nameset name))

(define (fold-all-fibers f seed)
  "Fold @var{f} over the set of known fibers.  @var{f} will be
invoked as @code{(@var{f} @var{name} @var{fiber} @var{seed})}."
  (nameset-fold f fibers-nameset seed))
(define (fiber-by-name name)
  "Return the fiber named @var{name}, or @code{#f} if no fiber of that
name is known."
  (nameset-ref fibers-nameset name))

(define-record-type <scheduler>
  (%make-scheduler name epfd active-fd-count prompt-tag
                   next-runqueue current-runqueue
                   sources timers kernel-thread
                   remote-peers choose-parallel-scheduler)
  scheduler?
  (name scheduler-name set-scheduler-name!)
  (epfd scheduler-epfd)
  (active-fd-count scheduler-active-fd-count set-scheduler-active-fd-count!)
  (prompt-tag scheduler-prompt-tag)
  ;; atomic stack of fiber to run next turn (reverse order)
  (next-runqueue scheduler-next-runqueue)
  ;; atomic stack of fiber to run this turn
  (current-runqueue scheduler-current-runqueue)
  ;; fd -> ((total-events . min-expiry) #(events expiry fiber) ...)
  (sources scheduler-sources)
  ;; PSQ of thunk -> expiry
  (timers scheduler-timers set-scheduler-timers!)
  ;; atomic parameter of thread
  (kernel-thread scheduler-kernel-thread)
  ;; list of sched
  (remote-peers scheduler-remote-peers set-scheduler-remote-peers!)
  ;; () -> sched
  (choose-parallel-scheduler scheduler-choose-parallel-scheduler
                             set-scheduler-choose-parallel-scheduler!))

(define-record-type <fiber>
  (make-fiber scheduler continuation)
  fiber?
  ;; The scheduler to which a fiber is currently bound.
  (scheduler fiber-scheduler set-fiber-scheduler!)
  ;; What the fiber should do when it resumes, or #f if the fiber is
  ;; currently running.
  (continuation fiber-continuation set-fiber-continuation!))

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
  (let ((epfd (epoll-create))
        (active-fd-count 0)
        (next-runqueue (make-empty-stack))
        (current-runqueue (make-empty-stack))
        (sources (make-hash-table))
        (timers (make-psq (match-lambda*
                            (((t1 . c1) (t2 . c2)) (< t1 t2)))
                          <))
        (kernel-thread (make-atomic-parameter #f)))
    (let ((sched (%make-scheduler #f epfd active-fd-count prompt-tag
                                  next-runqueue current-runqueue
                                  sources timers kernel-thread
                                  #f #f)))
      (set-scheduler-name! sched (nameset-add! schedulers-nameset sched))
      (let ((all-scheds
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
         all-scheds))
      sched)))

(define-syntax-rule (with-scheduler scheduler body ...)
  "Evaluate @code{(begin @var{body} ...)} in an environment in which
@var{scheduler} is bound to the current kernel thread.  Signal an
error if @var{scheduler} is already running in some other kernel
thread."
  (let ((sched scheduler))
    (dynamic-wind (lambda ()
                    ((scheduler-kernel-thread sched) (current-thread)))
                  (lambda ()
                    body ...)
                  (lambda ()
                    ((scheduler-kernel-thread sched) #f)))))

(define (scheduler-kernel-thread/public sched)
  "Return the kernel thread on which @var{sched} is running, or
@code{#f} if @var{sched} is not running."
  ((scheduler-kernel-thread sched)))

(define (choose-parallel-scheduler sched)
  ((scheduler-choose-parallel-scheduler sched)))

(define (make-source events expiry fiber) (vector events expiry fiber))
(define (source-events s) (vector-ref s 0))
(define (source-expiry s) (vector-ref s 1))
(define (source-fiber s) (vector-ref s 2))

(define current-fiber (make-parameter #f))
(define (current-fiber/public)
  "Return the current fiber, or @code{#f} if no fiber is current."
  (current-fiber))

(define (schedule-fiber! fiber thunk)
  ;; The fiber will be resumed at most once, and we are the ones that
  ;; will resume it, so we can set the thunk directly.  Adding the
  ;; fiber to the runqueue is an atomic operation with SEQ_CST
  ;; ordering, so that will make sure this operation is visible even
  ;; for a fiber scheduled on a remote thread.
  (set-fiber-continuation! fiber thunk)
  (let ((sched (fiber-scheduler fiber)))
    (stack-push! (scheduler-next-runqueue sched) fiber)
    (unless (eq? ((scheduler-kernel-thread sched)) (current-thread))
      (epoll-wake! (scheduler-epfd sched)))
    (values)))

(define internal-time-units-per-millisecond
  (/ internal-time-units-per-second 1000))

(define (schedule-fibers-for-fd fd revents sched)
  (match (hashv-ref (scheduler-sources sched) fd)
    (#f (warn "scheduler for unknown fd" fd))
    (sources
     (set-scheduler-active-fd-count! sched
                                     (1- (scheduler-active-fd-count sched)))
     (for-each (lambda (source)
                 ;; FIXME: This fiber might have been woken up by
                 ;; another event.  A moot point while file descriptor
                 ;; operations aren't proper CML operations, though.
                 (unless (zero? (logand revents
                                        (logior (source-events source) EPOLLERR)))
                   ;; Fibers can't be stolen while they are in the
                   ;; sources table; the scheduler of the fiber must
                   ;; be SCHED, and so we are indeed responsible for
                   ;; resuming the fiber.
                   (resume-fiber (source-fiber source) (lambda () revents))))
               (cdr sources))
     (cond
      ((zero? (logand revents EPOLLERR))
       (hashv-remove! (scheduler-sources sched) fd)
       (epoll-remove! (scheduler-epfd sched) fd))
      (else
       (set-cdr! sources '())
       ;; Reset active events and expiration time, respectively.
       (set-car! (car sources) #f)
       (set-cdr! (car sources) #f))))))

(define (scheduler-finished? sched finished?)
  (and (finished?)
       (psq-empty? (scheduler-timers sched))))

(define (scheduler-poll-timeout sched finished?)
  (cond
   ((not (stack-empty? (scheduler-next-runqueue sched)))
    ;; Don't sleep if there are fibers in the runqueue already.
    0)
   ((psq-empty? (scheduler-timers sched))
    ;; Avoid sleeping if the scheduler is actually finished.
    (let ((done? (and (finished?) (zero? (scheduler-active-fd-count sched)))))
      (if done? 0 -1)))
   (else
    (match (psq-min (scheduler-timers sched))
      ((expiry . thunk)
       (let ((now (get-internal-real-time)))
         (if (< expiry now)
             0
             (round/ (- expiry now)
                     internal-time-units-per-millisecond))))))))

(define (run-timers sched)
  ;; Run expired timer thunks in the order that they expired.
  (let ((now (get-internal-real-time)))
    (let run-timers ((timers (scheduler-timers sched)))
      (cond
       ((or (psq-empty? timers)
            (< now (car (psq-min timers))))
        (set-scheduler-timers! sched timers))
       (else
        (call-with-values (lambda () (psq-pop timers))
          (match-lambda*
            (((_ . thunk) timers)
             (thunk)
             (run-timers timers)))))))))

(define (schedule-runnables-for-next-turn sched finished?)
  ;; Called when all runnables from the current turn have been run.
  ;; Note that there may be runnables already scheduled for the next
  ;; turn; one way this can happen is if a fiber suspended itself
  ;; because it was blocked on a channel, but then another fiber woke
  ;; it up, or if a remote thread scheduled a fiber on this scheduler.
  ;; In any case, check the kernel to see if any of the fd's that we
  ;; are interested in are active, and in that case schedule their
  ;; corresponding fibers.  Also run any timers that have timed out.
  (epoll (scheduler-epfd sched)
         #:get-timeout (lambda () (scheduler-poll-timeout sched finished?))
         #:folder (lambda (fd revents seed)
                    (schedule-fibers-for-fd fd revents sched)
                    seed))
  (run-timers sched))

(define (fiber-stealer sched)
  "Steal some work from a random scheduler in the vector
@var{schedulers}.  Return a fiber, or @code{#f} if no work could be
stolen."
  (let ((selector (make-selector (scheduler-remote-peers sched))))
    (lambda ()
      (let ((peer (selector)))
        (and peer
             (stack-pop! (scheduler-current-runqueue peer) #f))))))

(define* (run-scheduler sched finished?)
  "Run @var{sched} until there are no more fibers ready to run, no
file descriptors being waited on, and no more timers pending to run.
Return zero values."
  (let ((tag (scheduler-prompt-tag sched))
        (next (scheduler-next-runqueue sched))
        (cur (scheduler-current-runqueue sched))
        (steal-fiber! (fiber-stealer sched)))
    (define (run-fiber fiber)
      (call-with-prompt tag
        (lambda ()
          (let ((thunk (fiber-continuation fiber)))
            (set-fiber-continuation! fiber #f)
            (thunk)))
        (lambda (k after-suspend)
          (set-fiber-continuation! fiber k)
          (after-suspend fiber))))
    (let next-turn ()
      (schedule-runnables-for-next-turn sched finished?)
      (stack-push-list! cur (reverse (stack-pop-all! next)))
      (let next-fiber ()
        (match (stack-pop! cur #f)
          (#f
           (cond
            ((stack-empty? next)
             ;; Both current and next runqueues are empty; steal a
             ;; little bit of work from a remote scheduler if we
             ;; can.  Run it directly instead of pushing onto a
             ;; queue to avoid double stealing.
             (match (steal-fiber!)
               (#f
                (unless (scheduler-finished? sched finished?)
                  (next-turn)))
               (fiber
                (set-fiber-scheduler! fiber sched)
                (run-fiber fiber)
                (next-turn))))
            (else
             (next-turn))))
          (fiber
           (run-fiber fiber)
           (next-fiber)))))))

(define (destroy-scheduler sched)
  "Release any resources associated with @var{sched}."
  #;
  (for-each kill-fiber (list-copy (scheduler-fibers sched)))
  (epoll-destroy (scheduler-epfd sched)))

(define (create-fiber sched thunk)
  "Spawn a new fiber in @var{sched} with the continuation @var{thunk}.
The fiber will be scheduled on the next turn.  @var{thunk} will run
with a copy of the current dynamic state, isolating fluid and
parameter mutations to the fiber."
  (let* ((fiber (make-fiber sched #f))
         (thunk (let ((dynamic-state (current-dynamic-state)))
                  (lambda ()
                    (with-dynamic-state dynamic-state
                                        (lambda ()
                                          (current-fiber fiber)
                                          (thunk)))))))
    (nameset-add! fibers-nameset fiber)
    (schedule-fiber! fiber thunk)))

(define (kill-fiber fiber)
  "Try to kill @var{fiber}, causing it to raise an exception.  Note
that this is currently unimplemented!"
  (error "kill-fiber is unimplemented"))

;; Shim for Guile 2.1.5.
(unless (defined? 'suspendable-continuation?)
  (define! 'suspendable-continuation? (lambda (tag) #t)))

;; The AFTER-SUSPEND thunk allows the user to suspend the current
;; fiber, saving its state, and then perform some other nonlocal
;; control flow.
;;
(define* (suspend-current-fiber #:optional
                                (after-suspend (lambda (fiber) #f)))
  "Suspend the current fiber.  Call the optional @var{after-suspend}
callback, if present, with the suspended thread as its argument."
  (let ((tag (scheduler-prompt-tag (fiber-scheduler (current-fiber)))))
    (unless (suspendable-continuation? tag)
      (error "Attempt to suspend fiber within continuation barrier"))
    ((abort-to-prompt tag after-suspend))))

(define* (resume-fiber fiber thunk)
  "Resume @var{fiber}, adding it to the run queue of its scheduler.
The fiber will start by applying @var{thunk}.  A fiber @emph{must}
only be resumed when it is suspended.  This function is thread-safe
even if @var{fiber} is running on a remote scheduler."
  (let ((cont (fiber-continuation fiber)))
    (unless cont (error "invalid fiber" fiber))
    (schedule-fiber! fiber (lambda () (cont thunk)))))

(define* (yield-current-fiber)
  "Yield control to the current scheduler.  Like
@code{suspend-current-fiber} followed directly by @code{resume-fiber},
except that it avoids suspending if the current continuation isn't
suspendable.  Returns @code{#t} if the yield succeeded, or @code{#f}
otherwise."
  (match (current-fiber)
    (#f #f)
    (fiber
     (let ((tag (scheduler-prompt-tag (fiber-scheduler fiber))))
       (and (suspendable-continuation? tag)
            (begin
              (abort-to-prompt tag (lambda (fiber) (resume-fiber fiber #f)))
              #t))))))

(define (finalize-fd sched fd)
  "Remove data associated with @var{fd} from the scheduler @var{ctx}.
Called by Guile just before Guile goes to close a file descriptor, in
response either to an explicit call to @code{close-port}, or because
the port became unreachable.  In the latter case, this call may come
from a finalizer thread."
  ;; When a file descriptor is closed, the kernel silently removes it
  ;; from any associated epoll sets, so we don't need to do anything
  ;; there.
  ;;
  ;; FIXME: Take a lock on the sources table?
  ;; FIXME: Wake all sources with EPOLLERR.
  (let ((sources-table (scheduler-sources sched)))
    (when (hashv-ref sources-table fd)
      (set-scheduler-active-fd-count! sched
                                      (1- (scheduler-active-fd-count sched)))
      (hashv-remove! sources-table fd))))

(define (resume-on-fd-events fd events fiber)
  "Arrange to resume @var{fiber} when the file descriptor @var{fd} has
the given @var{events}, expressed as an epoll bitfield."
  (let* ((sched (fiber-scheduler fiber))
         (sources (hashv-ref (scheduler-sources sched) fd)))
    (cond
     (sources
      (set-cdr! sources (cons (make-source events #f fiber) (cdr sources)))
      (let ((active-events (caar sources)))
        (unless active-events
          (set-scheduler-active-fd-count! sched
                                          (1+ (scheduler-active-fd-count sched))))
        (unless (and active-events
                     (= (logand events active-events) events))
          (set-car! (car sources) (logior events (or active-events 0)))
          (epoll-modify! (scheduler-epfd sched) fd
                         (logior (caar sources) EPOLLONESHOT)))))
     (else
      (set-scheduler-active-fd-count! sched
                                      (1+ (scheduler-active-fd-count sched)))
      (hashv-set! (scheduler-sources sched)
                  fd (acons events #f
                            (list (make-source events #f fiber))))
      (add-fdes-finalizer! fd (lambda (fd) (finalize-fd sched fd)))
      (epoll-add! (scheduler-epfd sched) fd (logior events EPOLLONESHOT))))))

(define (resume-on-readable-fd fd fiber)
  "Arrange to resume @var{fiber} when the file descriptor @var{fd}
becomes readable."
  (resume-on-fd-events fd (logior EPOLLIN EPOLLRDHUP) fiber))

(define (resume-on-writable-fd fd fiber)
  "Arrange to resume @var{fiber} when the file descriptor @var{fd}
becomes writable."
  (resume-on-fd-events fd EPOLLOUT fiber))

(define (add-timer sched expiry thunk)
  "Arrange to call @var{thunk} when the absolute real time is greater
than or equal to @var{expiry}, expressed in internal time units."
  (set-scheduler-timers! sched
                         (psq-set (scheduler-timers sched)
                                  (cons expiry thunk)
                                  expiry)))
