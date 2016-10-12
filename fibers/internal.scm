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
  #:use-module (fibers deque)
  #:use-module (fibers epoll)
  #:use-module (fibers psq)
  #:use-module (fibers nameset)
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 match)
  #:use-module (ice-9 fdes-finalizers)
  #:export (;; Low-level interface: schedulers and threads.
            make-scheduler
            with-scheduler
            scheduler-name
            (current-scheduler/public . current-scheduler)
            (scheduler-kernel-thread/public . scheduler-kernel-thread)
            run-scheduler
            destroy-scheduler
            add-fd-events!
            add-timer!

            create-fiber
            current-fiber
            kill-fiber
            fiber-scheduler
            fiber-data

            fold-all-schedulers
            scheduler-by-name
            fold-all-fibers
            fiber-by-name

            suspend-current-fiber
            resume-fiber))

(define-once fibers-nameset (make-nameset))
(define-once schedulers-nameset (make-nameset))

(define (fold-all-schedulers f seed)
  (nameset-fold f schedulers-nameset seed))
(define (scheduler-by-name name)
  (nameset-ref schedulers-nameset name))

(define (fold-all-fibers f seed)
  (nameset-fold f fibers-nameset seed))
(define (fiber-by-name name)
  (nameset-ref fibers-nameset name))

(define-record-type <scheduler>
  (%make-scheduler name epfd active-fd-count prompt-tag runqueue
                   sources timers kernel-thread)
  scheduler?
  (name scheduler-name set-scheduler-name!)
  (epfd scheduler-epfd)
  (active-fd-count scheduler-active-fd-count set-scheduler-active-fd-count!)
  (prompt-tag scheduler-prompt-tag)
  ;; atomic box of deque of fiber
  (runqueue scheduler-runqueue)
  ;; fd -> ((total-events . min-expiry) #(events expiry fiber) ...)
  (sources scheduler-sources)
  ;; PSQ of thunk -> expiry
  (timers scheduler-timers set-scheduler-timers!)
  ;; atomic parameter of thread
  (kernel-thread scheduler-kernel-thread))

(define-record-type <fiber>
  (make-fiber scheduler data)
  fiber?
  ;; The scheduler that a fiber runs in.  As a scheduler only runs in
  ;; one kernel thread, this binds a fiber to a kernel thread.
  (scheduler fiber-scheduler)
  ;; State-specific data.  For runnable, a thunk; for running, nothing;
  ;; for suspended, a continuation; for finished, a list of values.
  (data fiber-data set-fiber-data!))

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

(define (make-scheduler)
  (let ((epfd (epoll-create))
        (active-fd-count 0)
        (prompt-tag (make-prompt-tag "fibers"))
        (runqueue (make-atomic-box (make-empty-deque)))
        (sources (make-hash-table))
        (timers (make-psq (match-lambda*
                              (((t1 . c1) (t2 . c2)) (< t1 t2)))
                            <))
        (kernel-thread (make-atomic-parameter #f)))
    (let ((sched (%make-scheduler #f epfd active-fd-count prompt-tag
                                  runqueue sources timers kernel-thread)))
      (set-scheduler-name! sched (nameset-add! schedulers-nameset sched))
      sched)))

(define-syntax-rule (with-scheduler scheduler body ...)
  (let ((sched scheduler))
    (dynamic-wind (lambda ()
                    ((scheduler-kernel-thread sched) (current-thread)))
                  (lambda ()
                    (parameterize ((current-scheduler sched))
                      body ...))
                  (lambda ()
                    ((scheduler-kernel-thread sched) #f)))))

(define (scheduler-kernel-thread/public sched)
  ((scheduler-kernel-thread sched)))

(define current-scheduler (make-parameter #f))
(define (current-scheduler/public) (current-scheduler))
(define (make-source events expiry fiber) (vector events expiry fiber))
(define (source-events s) (vector-ref s 0))
(define (source-expiry s) (vector-ref s 1))
(define (source-fiber s) (vector-ref s 2))

(define current-fiber (make-parameter #f))

(define (schedule-fiber! fiber thunk)
  ;; The fiber will be resumed at most once, and we are the ones that
  ;; will resume it, so we can set the thunk directly.  Adding the
  ;; fiber to the runqueue is an atomic operation with SEQ_CST
  ;; ordering, so that will make sure this operation is visible even
  ;; for a fiber scheduled on a remote thread.
  (set-fiber-data! fiber thunk)
  (let ((sched (fiber-scheduler fiber)))
    (enqueue! (scheduler-runqueue sched) fiber)
    (unless (eq? sched (current-scheduler))
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

(define (scheduler-poll-timeout sched)
  (cond
   ((not (empty-deque? (atomic-box-ref (scheduler-runqueue sched))))
    ;; Don't sleep if there are fibers in the runqueue already.
    0)
   ((psq-empty? (scheduler-timers sched))
    ;; If there are no timers, only sleep if there are active fd's. (?)
    (cond
     ((zero? (scheduler-active-fd-count sched)) 0)
     (else -1)))
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

(define (schedule-runnables-for-next-turn sched)
  ;; Called when all runnables from the current turn have been run.
  ;; Note that the there may be runnables already scheduled for the
  ;; next turn; one way this can happen is if a fiber suspended itself
  ;; because it was blocked on a channel, but then another fiber woke
  ;; it up, or if a remote thread scheduled a fiber on this scheduler.
  ;; In any case, check the kernel to see if any of the fd's that we
  ;; are interested in are active, and in that case schedule their
  ;; corresponding fibers.  Also run any timers that have timed out.
  (epoll (scheduler-epfd sched)
         32                           ; maxevents
         (lambda () (scheduler-poll-timeout sched))
         #:folder (lambda (fd revents seed)
                    (schedule-fibers-for-fd fd revents sched)
                    seed))
  (run-timers sched))

(define* (run-fiber fiber)
  (parameterize ((current-fiber fiber))
    (call-with-prompt
        (scheduler-prompt-tag (fiber-scheduler fiber))
      (lambda ()
        (let ((thunk (fiber-data fiber)))
          (set-fiber-data! fiber #f)
          (thunk)))
      (lambda (k after-suspend)
        (set-fiber-data! fiber k)
        (after-suspend fiber)))))

(define* (run-scheduler sched)
  (let lp ()
    (schedule-runnables-for-next-turn sched)
    (match (dequeue-all! (scheduler-runqueue sched))
      (()
       ;; Could be the scheduler is stopping, or it could be that we
       ;; got a spurious wakeup.  In any case, this is the place to
       ;; check to see whether the scheduler is really done.
       (cond
        ((not (zero? (scheduler-active-fd-count sched))) (lp))
        ((not (psq-empty? (scheduler-timers sched))) (lp))
        (else (values))))
      (runnables
       (for-each run-fiber runnables)
       (lp)))))

(define (destroy-scheduler sched)
  #;
  (for-each kill-fiber (list-copy (scheduler-fibers sched)))
  (epoll-destroy (scheduler-epfd sched)))

(define (create-fiber sched thunk)
  (let ((fiber (make-fiber sched #f)))
    (nameset-add! fibers-nameset fiber)
    (schedule-fiber! fiber thunk)
    fiber))

(define (kill-fiber fiber)
  (pk 'kill-fiber fiber))

;; The AFTER-SUSPEND thunk allows the user to suspend the current
;; fiber, saving its state, and then perform some other nonlocal
;; control flow.
;;
(define* (suspend-current-fiber #:optional
                                (after-suspend (lambda (fiber) #f)))
  ((abort-to-prompt (scheduler-prompt-tag (current-scheduler))
                    after-suspend)))

(define* (resume-fiber fiber thunk)
  (let* ((cont (fiber-data fiber))
         (thunk (if cont (lambda () (cont thunk)) thunk)))
    (schedule-fiber! fiber thunk)))

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

(define (add-fd-events! sched fd events fiber)
  (let ((sources (hashv-ref (scheduler-sources sched) fd)))
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

(define (add-timer! sched thunk expiry)
  (set-scheduler-timers! sched
                         (psq-set (scheduler-timers sched)
                                  (cons expiry thunk)
                                  expiry)))
