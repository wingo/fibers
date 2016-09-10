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
  #:use-module ((srfi srfi-1) #:select (append-reverse!))
  #:use-module (srfi srfi-9)
  #:use-module (fibers epoll)
  #:use-module (fibers psq)
  #:use-module (ice-9 atomic)
  #:use-module ((ice-9 control) #:select (let/ec))
  #:use-module ((ice-9 binary-ports) #:select (get-u8 put-u8))
  #:use-module (ice-9 fdes-finalizers)
  #:use-module (ice-9 match)
  #:use-module (ice-9 suspendable-ports)
  #:replace (sleep)
  #:export (;; Low-level interface: schedulers and threads.
            make-scheduler
            current-scheduler
            run-scheduler
            destroy-scheduler
            add-fd-events!
            add-sleeper!

            create-fiber
            current-fiber
            kill-fiber
            fiber-scheduler
            fiber-state

            suspend-current-fiber
            resume-fiber))

(define-record-type <scheduler>
  (%make-scheduler epfd active-fd-count prompt-tag runnables
                   sources sleepers inbox inbox-state wake-pipe)
  nio?
  (epfd scheduler-epfd)
  (active-fd-count scheduler-active-fd-count set-scheduler-active-fd-count!)
  (prompt-tag scheduler-prompt-tag)
  ;; (fiber ...)
  (runnables scheduler-runnables set-scheduler-runnables!)
  ;; fd -> ((total-events . min-expiry) #(events expiry fiber) ...)
  (sources scheduler-sources)
  ;; PSQ of fiber -> expiry
  (sleepers scheduler-sleepers set-scheduler-sleepers!)
  ;; atomic box of (fiber ...)
  (inbox scheduler-inbox)
  ;; atomic box of either 'will-check, 'needs-wake or 'dead
  (inbox-state scheduler-inbox-state)
  ;; (read-pipe . write-pipe)
  (wake-pipe scheduler-wake-pipe))

;; fixme: prevent fibers from running multiple times in a turn
(define-record-type <fiber>
  (make-fiber state scheduler data)
  fiber?
  ;; One of: runnable, running, suspended, finished.
  (state fiber-state set-fiber-state!)
  ;; The scheduler that a fiber runs in.  As a scheduler only runs in
  ;; one kernel thread, this binds a fiber to a kernel thread.
  (scheduler fiber-scheduler)
  ;; State-specific data.  For runnable, a thunk; for running, nothing;
  ;; for suspended, a continuation; for finished, a list of values.
  (data fiber-data set-fiber-data!))

(define (make-wake-pipe)
  (define (set-nonblocking! port)
    (fcntl port F_SETFL (logior O_NONBLOCK (fcntl port F_GETFL))))
  (let ((pair (pipe)))
    (match pair
      ((read-pipe . write-pipe)
       (setvbuf write-pipe 'none)
       (set-nonblocking! read-pipe)
       (set-nonblocking! write-pipe)
       pair))))

;; FIXME: Perhaps epoll should handle the wake pipe business itself
(define (make-scheduler)
  (let ((epfd (epoll-create))
        (wake-pipe (make-wake-pipe)))
    (match wake-pipe
      ((read-pipe . _)
       (epoll-add! epfd (fileno read-pipe) EPOLLIN)))
    (%make-scheduler epfd 0 (make-prompt-tag "fibers")
                     '() (make-hash-table)
                     ;; sleepers psq
                     (make-psq (match-lambda*
                                 (((t1 . f1) (t2 . f2)) (< t1 t2)))
                               <)
                     (make-atomic-box '()) (make-atomic-box 'will-check)
                     wake-pipe)))

(define current-scheduler (make-parameter #f))
(define (make-source events expiry fiber) (vector events expiry fiber))
(define (source-events s) (vector-ref s 0))
(define (source-expiry s) (vector-ref s 1))
(define (source-fiber s) (vector-ref s 2))

(define current-fiber (make-parameter #f))

(define (atomic-box-prepend! box x)
  (let lp ((tail (atomic-box-ref box)))
    (let ((tail* (atomic-box-compare-and-swap! box tail (cons x tail))))
      (unless (eq? tail tail*)
        (lp tail*)))))

(define (wake-remote-scheduler! sched)
  (match (scheduler-wake-pipe sched)
    ((_ . write-pipe)
     (let/ec cancel
       (parameterize ((current-write-waiter cancel))
         (put-u8 write-pipe #x00))))))

(define (schedule-fiber! fiber thunk)
  (let ((sched (fiber-scheduler fiber)))
    (define (schedule/local)
      (when (eq? (fiber-state fiber) 'suspended)
        (set-fiber-state! fiber 'runnable)
        (set-fiber-data! fiber thunk)
        (set-scheduler-runnables! sched
                                  (cons fiber (scheduler-runnables sched)))))
    (define (schedule/remote)
      (atomic-box-prepend! (scheduler-inbox sched) (cons fiber thunk))
      (match (atomic-box-ref (scheduler-inbox-state sched))
        ;; It is always correct to wake the scheduler via the pipe.
        ;; However we can avoid it if the scheduler is guaranteed to
        ;; see that the inbox is not empty before it goes to poll next
        ;; time.
        ('will-check #t)
        ('needs-wake (wake-remote-scheduler! sched))
        ('dead (error "Scheduler is dead"))))
    (if (eq? sched (current-scheduler))
        (schedule/local)
        (schedule/remote))
    (values)))

(define internal-time-units-per-millisecond
  (/ internal-time-units-per-second 1000))

(define (schedule-fibers-for-fd fd revents sched)
  (match (hashv-ref (scheduler-sources sched) fd)
    (#f
     (match (scheduler-wake-pipe sched)
       ((read-pipe . _)
        (cond
         ((eqv? fd (fileno read-pipe))
          ;; Slurp off any wake bytes from the fd.
          (let/ec cancel
            (parameterize ((current-write-waiter cancel))
              (let lp () (get-u8 read-pipe) (lp)))))
         (else
          (warn "scheduler for unknown fd" fd))))))
    (sources
     (set-scheduler-active-fd-count! sched
                                     (1- (scheduler-active-fd-count sched)))
     (for-each (lambda (source)
                 ;; FIXME: If we were waiting with a timeout, this
                 ;; fiber might still be in "sleepers", and we should
                 ;; probably remove it.  Currently we don't do timed
                 ;; waits though, only sleeps.
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
   ((not (null? (atomic-box-ref (scheduler-inbox sched))))
    ;; There are pending requests in our inbox, so we don't need to
    ;; sleep at all.
    0)
   ((not (null? (scheduler-runnables sched)))
    ;; Likewise, don't sleep if there are runnables scheduled already.
    0)
   ((psq-empty? (scheduler-sleepers sched))
    -1)
   (else
    (match (psq-min (scheduler-sleepers sched))
      ((expiry . fiber)
       (let ((now (get-internal-real-time)))
         (if (< expiry now)
             0
             (round/ (- expiry now)
                     internal-time-units-per-millisecond))))))))

(define (wake-sleepers sched)
  ;; Resume fibers whose sleep has timed out.  Do it in such a way
  ;; that the one with the earliest expiry is resumed last, so
  ;; that it will will end up first on the runnable list.  If one
  ;; of these fibers has already been resumed (perhaps because the
  ;; fd is readable or writable), this resume will have no effect.
  (let ((now (get-internal-real-time)))
    (let wake-sleepers ((sleepers (scheduler-sleepers sched)))
      (cond
       ((or (psq-empty? sleepers)
            (< now (car (psq-min sleepers))))
        (set-scheduler-sleepers! sched sleepers))
       (else
        (call-with-values (lambda () (psq-pop sleepers))
          (match-lambda*
            (((_ . fiber) sleepers)
             (wake-sleepers sleepers)
             (resume-fiber fiber (lambda () 0))))))))))

(define (handle-inbox sched)
  (for-each (match-lambda
              ((fiber . thunk)
               (resume-fiber fiber thunk)))
            (atomic-box-swap! (scheduler-inbox sched) '())))

(define (schedule-runnables-for-next-turn sched)
  ;; Called when all runnables from the current turn have been run.
  ;; Note that the there may be runnables already scheduled for the
  ;; next turn; one way this can happen is if a fiber suspended itself
  ;; because it was blocked on a channel, but then another fiber woke
  ;; it up.  In any case, check the kernel to see if any of the fd's
  ;; that we are interested in are active, and in that case schedule
  ;; their corresponding fibers.  Also schedule any sleepers that have
  ;; timed out, and process the inbox that receives
  ;; requests-to-schedule from remote threads.
  ;;
  ;; FIXME: use a deque instead
  (set-scheduler-runnables! sched (reverse (scheduler-runnables sched)))
  (unless (zero? (scheduler-active-fd-count sched))
    (atomic-box-set! (scheduler-inbox-state sched) 'needs-wake)
    (epoll (scheduler-epfd sched)
           32                           ; maxevents
           (scheduler-poll-timeout sched)
           #:folder (lambda (fd revents seed)
                      (schedule-fibers-for-fd fd revents sched)
                      seed))
    (atomic-box-set! (scheduler-inbox-state sched) 'will-check))
  (handle-inbox sched)
  (wake-sleepers sched))

(define* (run-fiber fiber)
  (when (eq? (fiber-state fiber) 'runnable)
    (parameterize ((current-fiber fiber))
      (call-with-prompt
       (scheduler-prompt-tag (fiber-scheduler fiber))
       (lambda ()
         (let ((thunk (fiber-data fiber)))
           (set-fiber-state! fiber 'running)
           (set-fiber-data! fiber #f)
           (thunk)))
       (lambda (k after-suspend)
         (set-fiber-state! fiber 'suspended)
         (set-fiber-data! fiber k)
         (after-suspend fiber))))))

(define (scheduler-finished? sched)
  (let/ec return
    (define (only-finished-if bool)
      (if bool #t (return #f)))
    (only-finished-if (zero? (scheduler-active-fd-count sched)))
    (only-finished-if (null? (atomic-box-ref (scheduler-inbox sched))))
    (only-finished-if (psq-empty? (scheduler-sleepers sched)))))

(define* (run-scheduler sched #:key join-fiber)
  (let lp ()
    (schedule-runnables-for-next-turn sched)
    (match (scheduler-runnables sched)
      (()
       ;; Could be the scheduler is stopping, or it could be that we
       ;; got a spurious wakeup.  In any case, this is the place to
       ;; check to see whether the scheduler is really done.
       (cond
        ((not (scheduler-finished? sched)) (lp))
        ((not join-fiber) (values))
        ((not (eq? (fiber-state join-fiber) 'finished)) (lp))
        (else (apply values (fiber-data join-fiber)))))
      (runnables
       (set-scheduler-runnables! sched '())
       (for-each run-fiber runnables)
       (lp)))))

(define (destroy-scheduler sched)
  #;
  (for-each kill-fiber (list-copy (scheduler-fibers sched)))
  (atomic-box-set! (scheduler-inbox-state sched) 'dead)
  (match (scheduler-wake-pipe sched)
    ((read-pipe . write-pipe)
     (close-port read-pipe)
     ;; FIXME: ignore errors flushing output
     (close-port write-pipe)))
  (epoll-destroy (scheduler-epfd sched)))

(define (create-fiber sched thunk)
  (let ((fiber (make-fiber 'suspended sched #f)))
    (schedule-fiber! fiber
                     (lambda ()
                       (call-with-values thunk
                         (lambda results
                           (set-fiber-state! fiber 'finished)
                           (set-fiber-data! fiber results)))))
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
         (thunk (lambda () (cont thunk))))
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

(define (add-sleeper! sched fiber seconds)
  (let ((waketime (+ (get-internal-real-time)
                     (inexact->exact
                      (round (* seconds internal-time-units-per-second))))))
    (set-scheduler-sleepers!
     sched
     (psq-set (scheduler-sleepers sched) (cons waketime fiber) waketime)
     #;
     (let lp ((sleepers (scheduler-sleepers sched)))
       (match sleepers
         (((and sleeper (_ . (? (lambda (expiry) (> waketime expiry)))))
           . tail)
          (set-cdr! sleepers (lp tail))
          sleepers)
         (_ (acons fiber waketime sleepers)))))))
