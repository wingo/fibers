;; epoll

;;;; Copyright (C) 2016 Andy Wingo <wingo@pobox.com>
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

(define-module (fibers epoll)
  #:use-module ((ice-9 binary-ports) #:select (get-u8 put-u8))
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 control)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:use-module (rnrs bytevectors)
  #:use-module (fibers config)
  #:export (epoll-create
            epoll-destroy
            epoll?
            epoll-add!
            epoll-modify!
            epoll-remove!
            epoll-wake!
            epoll

            EPOLLIN EPOLLOUT EPOLLPRO EPOLLERR EPOLLHUP EPOLLET))

(eval-when (eval load compile)
  (dynamic-call "init_fibers_epoll"
                (dynamic-link (extension-library "epoll"))))

(when (defined? 'EPOLLRDHUP)
  (export EPOLLRDHUP))
(when (defined? 'EPOLLONESHOT)
  (export EPOLLONESHOT))

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

(define-record-type <epoll>
  (make-epoll fd eventsv maxevents state wake-read-pipe wake-write-pipe)
  epoll?
  (fd epoll-fd set-epoll-fd!)
  (eventsv epoll-eventsv set-epoll-eventsv!)
  (maxevents epoll-maxevents set-epoll-maxevents!)
  ;; atomic box of either 'waiting, 'not-waiting or 'dead
  (state epoll-state)
  (wake-read-pipe epoll-wake-read-pipe)
  (wake-write-pipe epoll-wake-write-pipe))

(define-syntax events-offset
  (lambda (x)
    (syntax-case x ()
      ((_ n)
       #`(* n #,%sizeof-struct-epoll-event)))))

(define-syntax fd-offset
  (lambda (x)
    (syntax-case x ()
      ((_ n)
       #`(+ (* n #,%sizeof-struct-epoll-event)
            #,%offsetof-struct-epoll-event-fd)))))

(define epoll-guardian (make-guardian))
(define (pump-epoll-guardian)
  (let ((epoll (epoll-guardian)))
    (when epoll
      (epoll-destroy epoll)
      (pump-epoll-guardian))))
(add-hook! after-gc-hook pump-epoll-guardian)

(define* (epoll-create #:key (close-on-exec? #t) (maxevents 8))
  (call-with-values (lambda () (make-wake-pipe))
    (lambda (read-pipe write-pipe)
      (let* ((state (make-atomic-box 'not-waiting))
             (epoll (make-epoll (primitive-epoll-create close-on-exec?)
                                #f maxevents state read-pipe write-pipe)))
        (epoll-guardian epoll)
        (epoll-add! epoll (fileno read-pipe) EPOLLIN)
        epoll))))

(define (epoll-destroy epoll)
  (atomic-box-set! (epoll-state epoll) 'dead)
  (when (epoll-fd epoll)
    (close-port (epoll-wake-read-pipe epoll))
    ;; FIXME: ignore errors flushing output
    (close-port (epoll-wake-write-pipe epoll))
    (close-fdes (epoll-fd epoll))
    (set-epoll-fd! epoll #f)))

(define (epoll-add! epoll fd events)
  (primitive-epoll-ctl (epoll-fd epoll) EPOLL_CTL_ADD fd events))

(define* (epoll-modify! epoll fd events)
  (primitive-epoll-ctl (epoll-fd epoll) EPOLL_CTL_MOD fd events))

(define (epoll-remove! epoll fd)
  (primitive-epoll-ctl (epoll-fd epoll) EPOLL_CTL_DEL fd))

(define (epoll-wake! epoll)
  "Run after modifying the shared state used by a thread that might be
waiting on this epoll descriptor, to break that thread out of the
epoll wait (if appropriate)."
  (match (atomic-box-ref (epoll-state epoll))
    ;; It is always correct to wake an epoll via the pipe.  However we
    ;; can avoid it if the epoll is guaranteed to see that the
    ;; runqueue is not empty before it goes to poll next time.
    ('waiting
     (primitive-epoll-wake (fileno (epoll-wake-write-pipe epoll))))
    ('not-waiting #t)
    ('dead (error "epoll instance is dead"))))

(define (epoll-default-folder fd events seed)
  (acons fd events seed))

(define (ensure-epoll-eventsv epoll maxevents)
  (let ((prev (epoll-eventsv epoll)))
    (if (and prev
             (or (not maxevents)
                 (= (events-offset maxevents) (bytevector-length prev))))
        prev
        (let ((v (make-bytevector (events-offset (or maxevents 8)))))
          (set-epoll-eventsv! epoll v)
          v))))

(define* (epoll epoll #:key (get-timeout (lambda () -1))
                (folder epoll-default-folder) (seed '()))
  (atomic-box-set! (epoll-state epoll) 'waiting)
  (let* ((maxevents (epoll-maxevents epoll))
         (eventsv (ensure-epoll-eventsv epoll maxevents))
         (write-pipe-fd (fileno (epoll-wake-write-pipe epoll)))
         (read-pipe-fd (fileno (epoll-wake-read-pipe epoll)))
         (n (primitive-epoll-wait (epoll-fd epoll) write-pipe-fd read-pipe-fd
                                  eventsv (get-timeout))))
    ;; If we received `maxevents' events, it means that probably there
    ;; are more active fd's in the queue that we were unable to
    ;; receive.  Expand our event buffer in that case.
    (when (= n maxevents)
      (set-epoll-maxevents! epoll (* maxevents 2)))
    (atomic-box-set! (epoll-state epoll) 'not-waiting)
    (let lp ((seed seed) (i 0))
      (if (< i n)
          (let ((fd (bytevector-s32-native-ref eventsv (fd-offset i)))
                (events (bytevector-u32-native-ref eventsv (events-offset i))))
            (lp (folder fd events seed) (1+ i)))
          seed))))
