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
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:use-module (rnrs bytevectors)
  #:export (epoll-create
            epoll-destroy
            epoll?
            epoll-add!
            epoll-modify!
            epoll-remove!
            epoll

            EPOLLIN EPOLLOUT EPOLLPRO EPOLLERR EPOLLHUP EPOLLET))

(eval-when (eval load compile)
  (load-extension "epoll" "init_fibers_epoll"))

(when (defined? 'EPOLLRDHUP)
  (export EPOLLRDHUP))
(when (defined? 'EPOLLONESHOT)
  (export EPOLLONESHOT))

(define-record-type <epoll>
  (make-epoll fd eventsv)
  epoll?
  (fd epoll-fd set-epoll-fd!)
  (eventsv epoll-eventsv set-epoll-eventsv!))

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

(define* (epoll-create #:key (close-on-exec? #t))
  (let ((epoll (make-epoll (primitive-epoll-create close-on-exec?) #f)))
    (epoll-guardian epoll)
    epoll))

(define (epoll-destroy epoll)
  (when (epoll-fd epoll)
    (close-fdes (epoll-fd epoll))
    (set-epoll-fd! epoll #f)))

(define (epoll-add! epoll fd events)
  (primitive-epoll-ctl (epoll-fd epoll) EPOLL_CTL_ADD fd events))

(define* (epoll-modify! epoll fd events)
  (primitive-epoll-ctl (epoll-fd epoll) EPOLL_CTL_MOD fd events))

(define (epoll-remove! epoll fd)
  (primitive-epoll-ctl (epoll-fd epoll) EPOLL_CTL_DEL fd))

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

(define* (epoll epoll #:optional maxevents (timeout -1)
                #:key (folder epoll-default-folder) (seed '()))
  (let* ((eventsv (ensure-epoll-eventsv epoll maxevents))
         (n (primitive-epoll-wait (epoll-fd epoll) eventsv timeout)))
    (let lp ((seed seed) (i 0))
      (if (< i n)
          (lp (folder (bytevector-s32-native-ref eventsv (fd-offset i))
                      (bytevector-u32-native-ref eventsv (events-offset i))
                      seed)
              (1+ i))
          seed))))
