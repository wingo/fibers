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
  (%make-scheduler epfd prompt-tag runnables sources sleepers)
  nio?
  (epfd scheduler-epfd)
  (prompt-tag scheduler-prompt-tag)
  ;; (fiber ...)
  (runnables scheduler-runnables set-scheduler-runnables!)
  ;; fd -> ((total-events . min-expiry) #(events expiry fiber) ...)
  (sources scheduler-sources)
  ;; ((fiber . expiry) ...)
  (sleepers scheduler-sleepers set-scheduler-sleepers!))

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

(define (make-scheduler)
  (%make-scheduler (epoll-create) (make-prompt-tag "fibers")
                  '() (make-hash-table) '()))

(define current-scheduler (make-parameter #f))
(define (make-source events expiry fiber) (vector events expiry fiber))
(define (source-events s) (vector-ref s 0))
(define (source-expiry s) (vector-ref s 1))
(define (source-fiber s) (vector-ref s 2))

(define current-fiber (make-parameter #f))

(define (schedule-fiber! sched fiber thunk)
  (when (eq? (fiber-state fiber) 'suspended)
    (set-fiber-state! fiber 'runnable)
    (set-fiber-data! fiber thunk)
    (let ((runnables (scheduler-runnables sched)))
      (set-scheduler-runnables! sched (cons fiber runnables)))))

(define internal-time-units-per-millisecond
  (/ internal-time-units-per-second 1000))

(define (schedule-fibers-for-fd fd revents sched)
  (let ((sources (hashv-ref (scheduler-sources sched) fd)))
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
      (set-cdr! (car sources) #f)))))

(define (poll-for-events sched)
  ;; Called when the runnables list is empty.  Poll for some active
  ;; FD's and schedule their corresponding fibers.  Also schedule any
  ;; sleepers that have timed out.
  (let ((sleepers (scheduler-sleepers sched)))
    (epoll (scheduler-epfd sched)
           32                           ; maxevents
           (match sleepers
             ;; The sleepers list is sorted so the first element
             ;; should be the one whose wake time is soonest.
             (((fiber . expiry) . sleepers)
              (let ((now (get-internal-real-time)))
                (if (< expiry now)
                    0
                    (round/ (- expiry now)
                            internal-time-units-per-millisecond))))
             (_ -1))
           #:folder (lambda (fd revents seed)
                      (schedule-fibers-for-fd fd revents sched)
                      seed))
    (let ((now (get-internal-real-time)))
      ;; Resume fibers whose sleep has timed out.  Do it in such a way
      ;; that the one with the earliest expiry is resumed last, so
      ;; that it will will end up first on the runnable list.  If one
      ;; of these fibers has already been resumed (perhaps because the
      ;; fd is readable or writable), this resume will have no effect.
      (let wake-sleepers ((sleepers sleepers) (wakers '()))
        (if (and (pair? sleepers) (>= now (cdar sleepers)))
            (wake-sleepers (cdr sleepers) (cons (caar sleepers) wakers))
            (begin
              (set-scheduler-sleepers! sched sleepers)
              (for-each (lambda (fiber)
                          (resume-fiber fiber (lambda () 0)))
                        wakers)))))))

(define* (run-fiber sched fiber)
  (when (eq? (fiber-state fiber) 'runnable)
    (parameterize ((current-fiber fiber))
      (call-with-prompt
       (scheduler-prompt-tag sched)
       (lambda ()
         (let ((thunk (fiber-data fiber)))
           (set-fiber-state! fiber 'running)
           (set-fiber-data! fiber #f)
           (thunk)))
       (lambda (k after-suspend)
         (set-fiber-state! fiber 'suspended)
         (set-fiber-data! fiber k)
         (after-suspend fiber))))))

(define (run-scheduler sched)
  (let lp ()
    (let ((runnables (scheduler-runnables sched)))
      (cond
       ((pair? runnables)
        (let ((fiber (car runnables)))
          (set-scheduler-runnables! sched (cdr runnables))
          (run-fiber sched fiber)
          (lp)))
       ((poll-for-events sched)
        (lp))
       (else
        ;; Nothing runnable; quit.
        (values))))))

(define (destroy-scheduler sched)
  #;
  (for-each kill-fiber (list-copy (scheduler-fibers sched)))
  (epoll-destroy (scheduler-epfd sched)))

(define (create-fiber sched thunk)
  (let ((fiber (make-fiber 'suspended sched #f)))
    (schedule-fiber! sched
                      fiber
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

;; FIXME: `resume' should get scheduler from fiber, and if it's not
;; the current scheduler it should add to the remote scheduler's
;; landing pad, an atomic queue that is processed by the remote
;; scheduler at its leisure.

(define* (resume-fiber fiber thunk)
  (let* ((cont (fiber-data fiber))
         (thunk (lambda () (cont thunk))))
    (schedule-fiber! (fiber-scheduler fiber) fiber thunk)))

(define (finalize-fd ctx fd)
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
  (hashv-remove! (scheduler-sources ctx) fd))

(define (add-fd-events! sched fd events fiber)
  (let ((sources (hashv-ref (scheduler-sources sched) fd)))
    (cond
     (sources
      (set-cdr! sources (cons (make-source events #f fiber) (cdr sources)))
      (let ((active-events (caar sources)))
        (unless (and active-events
                     (= (logand events active-events) events))
          (set-car! (car sources) (logior events (or active-events 0)))
          (epoll-modify! (scheduler-epfd sched) fd
                         (logior (caar sources) EPOLLONESHOT)))))
     (else
      (hashv-set! (scheduler-sources sched)
                  fd (acons events #f
                            (list (make-source events #f fiber))))
      (add-fdes-finalizer! fd (lambda (fd) (finalize-fd sched fd)))
      (epoll-add! (scheduler-epfd sched) fd (logior events EPOLLONESHOT))))))

(define (add-sleeper! sched fiber seconds)
  (let ((waketime (+ (get-internal-real-time)
                     (inexact->exact
                      (round (* seconds internal-time-units-per-second))))))
    (let lp ((head '()) (tail (scheduler-sleepers sched)))
      (if (and (pair? tail) (> waketime (cdar tail)))
          (lp (cons (car tail) head) (cdr tail))
          (set-scheduler-sleepers!
           sched
           (append-reverse! head (acons fiber waketime tail)))))))
