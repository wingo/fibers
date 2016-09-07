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
  #:use-module (fibers epoll)
  #:use-module (fibers internal)
  #:use-module ((ice-9 ports internal)
                #:select (port-read-wait-fd port-write-wait-fd))
  #:use-module (ice-9 suspendable-ports)
  #:export ((get-current-fiber . current-fiber)
            run-fibers
            spawn-fiber
            kill-fiber)
  #:replace (sleep))

;; A thunk and not a parameter to prevent users from using it as a
;; parameter.
(define (get-current-fiber)
  "Return the current fiber, or @code{#f} if no fiber is current."
  (current-fiber))

(define (wait-for-events port fd events)
  (let ((revents (suspend-current-fiber
                  (lambda (fiber)
                    (add-fd-events! (fiber-scheduler fiber) fd events fiber)))))
    (unless (zero? (logand revents EPOLLERR))
      (error "error reading from port" port))))

(define (wait-for-readable port)
  (wait-for-events port (port-read-wait-fd port) (logior EPOLLIN EPOLLRDHUP)))
(define (wait-for-writable port)
  (wait-for-events port (port-write-wait-fd port) EPOLLOUT))

(define* (run-fibers #:optional (init #f)
                     #:key (scheduler (make-scheduler))
                     (install-suspendable-ports? #t)
                     (keep-scheduler? (eq? scheduler (current-scheduler))))
  (when install-suspendable-ports? (install-suspendable-ports!))
  (parameterize ((current-scheduler scheduler)
                 (current-read-waiter wait-for-readable)
                 (current-write-waiter wait-for-writable))
    (when init (spawn-fiber init scheduler))
    (run-scheduler scheduler))
  (unless keep-scheduler? (destroy-scheduler scheduler)))

(define (require-current-scheduler)
  (or (current-scheduler)
      (error "No scheduler current; call within run-fibers instead")))

(define* (spawn-fiber thunk #:optional (sched (require-current-scheduler)))
  (create-fiber sched thunk))

(define (kill-fiber fiber)
  (pk 'unimplemented-kill-fiber fiber))

(define (sleep seconds)
  (suspend-current-fiber
   (lambda (fiber)
     (add-sleeper! (fiber-scheduler fiber) fiber seconds))))
