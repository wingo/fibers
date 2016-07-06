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
  #:use-module ((srfi srfi-1) #:select (append-reverse!))
  #:use-module (srfi srfi-9)
  #:use-module (fibers epoll)
  #:use-module (ice-9 match)
  #:use-module (ice-9 ports internal)
  #:use-module (ice-9 suspendable-ports)
  #:replace (sleep)
  #:export (;; Low-level interface: contexts and threads.
            make-scheduler
            current-scheduler
            ensure-current-scheduler
            destroy-scheduler

            create-fiber
            current-fiber
            kill-fiber
            fiber-state

            ;; High-level interface.
            run
            spawn
            suspend
            resume
            ;; sleep is #:replace'd; see above
            ))

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
  (make-fiber state data)
  fiber?
  ;; One of: runnable, running, suspended, finished.
  (state fiber-state set-fiber-state!)
  ;; State-specific data.  For runnable, a thunk; for running, nothing;
  ;; for suspended, a continuation; for finished, a list of values.
  (data fiber-data set-fiber-data!))

(define (make-scheduler)
  (%make-scheduler (epoll-create) (make-prompt-tag "fibers")
                  '() (make-hash-table) '()))

(define current-scheduler (make-parameter #f))
(define (ensure-current-scheduler)
  (let ((ctx (current-scheduler)))
    (or ctx
        (begin
          (current-scheduler (make-scheduler))
          (ensure-current-scheduler)))))

(define (make-source events expiry fiber) (vector events expiry fiber))
(define (source-events s) (vector-ref s 0))
(define (source-expiry s) (vector-ref s 1))
(define (source-fiber s) (vector-ref s 2))

(define current-fiber (make-parameter #f))

(define (schedule-fiber! ctx fiber thunk)
  (when (eq? (fiber-state fiber) 'suspended)
    (set-fiber-state! fiber 'runnable)
    (set-fiber-data! fiber thunk)
    (let ((runnables (scheduler-runnables ctx)))
      (set-scheduler-runnables! ctx (cons fiber runnables)))))

(define internal-time-units-per-millisecond
  (/ internal-time-units-per-second 1000))

(define (schedule-fibers-for-fd fd revents ctx)
  (let ((sources (hashv-ref (scheduler-sources ctx) fd)))
    (for-each (lambda (source)
                ;; FIXME: If we were waiting with a timeout, this
                ;; fiber might still be in "sleepers", and we should
                ;; probably remove it.  Currently we don't do timed
                ;; waits though, only sleeps.
                (unless (zero? (logand revents
                                       (logior (source-events source) EPOLLERR)))
                  (resume (source-fiber source) (lambda () revents) ctx)))
              (cdr sources))
    (cond
     ((zero? (logand revents EPOLLERR))
      (hashv-remove! (scheduler-sources ctx) fd)
      (epoll-remove! (scheduler-epfd ctx) fd))
     (else
      (set-cdr! sources '())
      ;; Reset active events and expiration time, respectively.
      (set-car! (car sources) #f)
      (set-cdr! (car sources) #f)))))

(define (poll-for-events ctx)
  ;; Called when the runnables list is empty.  Poll for some active
  ;; FD's and schedule their corresponding fibers.  Also schedule any
  ;; sleepers that have timed out.
  (let ((sleepers (scheduler-sleepers ctx)))
    (epoll (scheduler-epfd ctx)
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
                      (schedule-fibers-for-fd fd revents ctx)
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
              (set-scheduler-sleepers! ctx sleepers)
              (for-each (lambda (fiber)
                          (resume fiber (lambda () 0) ctx))
                        wakers)))))))

(define (next-fiber ctx)
  (let lp ()
    (let ((runnables (scheduler-runnables ctx)))
      (cond
       ((pair? runnables)
        (let ((fiber (car runnables)))
          (set-scheduler-runnables! ctx (cdr runnables))
          fiber))
       (else
        (poll-for-events ctx)
        (lp))))))

(define (run-fiber ctx fiber)
  (when (eq? (fiber-state fiber) 'runnable)
    (parameterize ((current-fiber fiber))
      (call-with-prompt
       (scheduler-prompt-tag ctx)
       (lambda ()
         (let ((thunk (fiber-data fiber)))
           (set-fiber-state! fiber 'running)
           (set-fiber-data! fiber #f)
           (thunk)))
       (lambda (k after-suspend)
         (set-fiber-state! fiber 'suspended)
         (set-fiber-data! fiber k)
         (after-suspend ctx fiber))))))

(define (destroy-scheduler ctx)
  #;
  (for-each kill-fiber (list-copy (scheduler-fibers ctx)))
  (epoll-destroy (scheduler-epfd ctx)))

(define (create-fiber ctx thunk)
  (let ((fiber (make-fiber 'suspended #f)))
    (schedule-fiber! ctx
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
(define* (suspend #:optional (after-suspend (lambda (ctx fiber) #f)))
  ((abort-to-prompt (scheduler-prompt-tag (current-scheduler))
                    after-suspend)))

(define* (resume fiber thunk #:optional (ctx (ensure-current-scheduler)))
  (let* ((cont (fiber-data fiber))
         (thunk (lambda () (cont thunk))))
    (schedule-fiber! ctx fiber thunk)))

(define* (run #:optional (ctx (ensure-current-scheduler))
              #:key (install-suspendable-ports? #t))
  (when install-suspendable-ports? (install-suspendable-ports!))
  (parameterize ((current-scheduler ctx)
                 (current-read-waiter wait-for-readable)
                 (current-write-waiter wait-for-writable))
    (let lp ()
      (run-fiber ctx (next-fiber ctx))
      (lp))))

(define* (spawn thunk #:optional (ctx (ensure-current-scheduler)))
  (create-fiber ctx thunk))

(define (wait-for-readable port)
  (wait-for-events port (port-read-wait-fd port) (logior EPOLLIN EPOLLRDHUP)))

(define (wait-for-writable port)
  (wait-for-events port (port-write-wait-fd port) EPOLLOUT))

(define (handle-events port events revents)
  (unless (zero? (logand revents EPOLLERR))
    (error "error reading from port" port)))

(define (wait-for-events port fd events)
  (handle-events
   port
   events
   (suspend
    (lambda (ctx fiber)
      (let ((sources (hashv-ref (scheduler-sources ctx) fd)))
        (cond
         (sources
          (set-cdr! sources (cons (make-source events #f fiber) (cdr sources)))
          (let ((active-events (caar sources)))
            (unless (and active-events
                         (= (logand events active-events) events))
              (set-car! (car sources) (logior events (or active-events 0)))
              (epoll-modify! (scheduler-epfd ctx) fd
                             (logior (caar sources) EPOLLONESHOT)))))
         (else
          (hashv-set! (scheduler-sources ctx)
                      fd (acons events #f
                                (list (make-source events #f fiber))))
          (epoll-add! (scheduler-epfd ctx) fd (logior events EPOLLONESHOT)))))))))

(define (add-sleeper! ctx fiber seconds)
  (let ((waketime (+ (get-internal-real-time)
                     (inexact->exact
                      (round (* seconds internal-time-units-per-second))))))
    (let lp ((head '()) (tail (scheduler-sleepers ctx)))
      (if (and (pair? tail) (> waketime (cdar tail)))
          (lp (cons (car tail) head) (cdr tail))
          (set-scheduler-sleepers!
           ctx
           (append-reverse! head (acons fiber waketime tail)))))))

(define (sleep seconds)
  (suspend
   (lambda (ctx fiber)
     (add-sleeper! ctx fiber seconds))))
