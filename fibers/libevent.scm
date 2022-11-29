;; libevent

;;;; Copyright (C) 2016 Andy Wingo <wingo@pobox.com>
;;;; Copyright (C) 2020 Abdulrahman Semrie <hsamireh@gmail.com>
;;;; Copyright (C) 2020-2022 Aleix Conchillo Flaqué <aconchillo@gmail.com>
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

(define-module (fibers events-impl)
    #:use-module ((ice-9 binary-ports) #:select (get-u8 put-u8))
    #:use-module (ice-9 atomic)
    #:use-module (ice-9 control)
    #:use-module (ice-9 match)
    #:use-module (srfi srfi-9)
    #:use-module (srfi srfi-9 gnu)
    #:use-module (rnrs bytevectors)
    #:use-module (fibers config)
    #:export (events-impl-create
              events-impl-destroy
              events-impl?
              events-impl-add!
              events-impl-wake!
              events-impl-fd-finalizer
              events-impl-run

              EVENTS_IMPL_READ EVENTS_IMPL_WRITE EVENTS_IMPL_CLOSED_OR_ERROR))

(eval-when (eval load compile)
  ;; When cross-compiling, the cross-compiled 'fibers-libevent.so' cannot be
  ;; loaded by the 'guild compile' process; skip it.
  (unless (getenv "FIBERS_CROSS_COMPILING")
    (dynamic-call "init_fibers_libevt"
                  (dynamic-link (extension-library "fibers-libevent")))))


(define (make-wake-pipe)
  (define (set-nonblocking! port)
    (fcntl port F_SETFL (logior O_NONBLOCK (fcntl port F_GETFL))))
  (let ((pair (pipe)))
    (match pair
      ((read-pipe . write-pipe)
       (setvbuf write-pipe 'none)
       (set-nonblocking! read-pipe)
       (set-nonblocking! write-pipe)
       (values read-pipe write-pipe)))))

(define-record-type <libevt>
  (make-libevt ls added eventsv maxevents state wake-read-pipe wake-write-pipe)
  libevt?
  (ls libevt-ls set-libevt-ls!)
  (added libevt-added set-libevt-added!)
  (eventsv libevt-eventsv set-libevt-eventsv!)
  (maxevents libevt-maxevents set-libevt-maxevents!)
  ;; atomic box of either 'waiting, 'not-waiting or 'dead
  (state libevt-state)
  (wake-read-pipe libevt-wake-read-pipe)
  (wake-write-pipe libevt-wake-write-pipe))

(define-syntax fd-offset
  (lambda (x)
    (syntax-case x ()
      ((_ n)
       #`(* n #,%sizeof-struct-event)))))

(define-syntax event-offset
  (lambda (x)
    (syntax-case x ()
      ((_ n)
       #`(+ (* n #,%sizeof-struct-event)
            #,%offsetof-struct-event-ev)))))

(define libevt-guardian (make-guardian))
(define (pump-libevt-guardian)
  (let ((libevt (libevt-guardian)))
    (when libevt
      (libevt-destroy libevt)
      (pump-libevt-guardian))))
(add-hook! after-gc-hook pump-libevt-guardian)

(define* (libevt-create #:key (maxevents 8))
  (call-with-values (lambda () (make-wake-pipe))
    (lambda (read-pipe write-pipe)
      (let* ((state (make-atomic-box 'not-waiting))
             (eventsv (make-bytevector (fd-offset (or maxevents 8))))
             (libevt (make-libevt (primitive-create-event-base eventsv)
                                  (make-hash-table)
                                  eventsv maxevents state read-pipe write-pipe)))
        (libevt-guardian libevt)
        (libevt-add! libevt (fileno read-pipe) (logior EVREAD EVPERSIST))
        libevt))))

(define (libevt-destroy libevt)
  (atomic-box-set! (libevt-state libevt) 'dead)
  (when (libevt-ls libevt)
    (close-port (libevt-wake-read-pipe libevt))
    ;; FIXME: ignore errors flushing output
    (close-port (libevt-wake-write-pipe libevt))
    (set-libevt-ls! libevt '())
    (set-libevt-added! libevt (make-hash-table))))

(define (libevt-add! libevt fd events)
  (let ((len (hash-count (const #t) (libevt-added libevt)))
        (maxevents (libevt-maxevents libevt)))
    ;; If we reach the limit we need to resize out events vector, so we double
    ;; the size.
    (when (>= maxevents len)
      (set-libevt-eventsv! libevt (make-bytevector (fd-offset (* maxevents 2))))
      (primitive-resize (libevt-ls libevt) (libevt-eventsv libevt)))
    ;; Time to add the event.
    (let ((event (primitive-add-event (libevt-ls libevt) fd events)))
      (hashv-set! (libevt-added libevt) fd event))))

(define (libevt-remove! libevt fd)
  (let ((event (hashv-ref (libevt-added libevt) fd)))
    (when event
      (primitive-remove-event (libevt-ls libevt) event)
      (hashv-remove! (libevt-added libevt) fd))))

(define (libevt-wake! libevt)
  (match (atomic-box-ref (libevt-state libevt))
    ;; It is always correct to wake an epoll via the pipe.  However we
    ;; can avoid it if the epoll is guaranteed to see that the
    ;; runqueue is not empty before it goes to poll next time.
    ('waiting
     (primitive-event-wake (fileno (libevt-wake-write-pipe libevt))))
    ('not-waiting #t)
    ;; This can happen if a fiber was waiting on a condition and
    ;; run-fibers completes before the fiber completes and afterwards
    ;; the condition is signalled.  In that case, we don't have to
    ;; resurrect the fiber or something, we can just do nothing.
    ;; (Bug report: https://github.com/wingo/fibers/issues/61)
    ('dead #t)))

(define (libevt-default-folder fd events seed)
  (acons fd events seed))

(define* (libevt libevt #:key (expiry #f)
                 (update-expiry (lambda (expiry) expiry))
                 (folder libevt-default-folder)
                 (seed '()))
  (define (expiry->timeout expiry)
    (cond
     ((not expiry) -1)
     (else
      (let ((now (get-internal-real-time)))
        (cond
         ((< expiry now) 0)
         (else (- expiry now)))))))
  (let* ((maxevents (libevt-maxevents libevt))
         (eventsv (libevt-eventsv libevt))
         (write-pipe-fd (fileno (libevt-wake-write-pipe libevt)))
         (read-pipe-fd (fileno (libevt-wake-read-pipe libevt))))
    (atomic-box-set! (libevt-state libevt) 'waiting)
    (let* ((timeout (expiry->timeout (update-expiry expiry)))
           (n (primitive-event-loop (libevt-ls libevt)
                                    write-pipe-fd read-pipe-fd timeout)))
      (atomic-box-set! (libevt-state libevt) 'not-waiting)
      (let lp ((seed seed) (i 0))
        (if (< i n)
            (let ((fd (bytevector-s32-native-ref eventsv (fd-offset i)))
                  (events (bytevector-s32-native-ref eventsv (event-offset i))))
              (lp (folder fd events seed) (1+ i)))
            seed)))))

;; Corresponding events, compared to epoll, found at
;; https://github.com/libevent/libevent/blob/master/epoll.c
(define EVENTS_IMPL_READ (logior EVREAD EVCLOSED))
(define EVENTS_IMPL_WRITE EVWRITE)
(define EVENTS_IMPL_CLOSED_OR_ERROR (logior EVREAD EVWRITE))

(define events-impl-create libevt-create)

(define events-impl-destroy libevt-destroy)

(define (events-impl? impl)
  (libevt? impl))

(define events-impl-add! libevt-add!)

(define events-impl-wake! libevt-wake!)

(define (events-impl-fd-finalizer impl fd-waiters)
  (lambda (fd)
    ;; When a file port is closed, clear out the list of
    ;; waiting tasks so that when/if this FD is re-used, we
    ;; don't resume stale tasks.
    ;;
    ;; FIXME: Is there a way to wake all tasks in a thread-safe
    ;; way?  Note that this function may be invoked from a
    ;; finalizer thread.
    (libevt-remove! impl fd)
    (set-cdr! fd-waiters '())
    (set-car! fd-waiters #f)))

(define events-impl-run libevt)
