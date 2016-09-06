;; channels

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

(define-module (fibers channels)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 match)
  #:use-module (fibers) ;; fixme, eliminate cycle
  #:export (channel?
            make-channel
            put-message
            get-message))



(define-record-type <read-wait-queue>
  (make-read-wait-queue waiters)
  read-wait-queue?
  ;; list of fiber, lifo order
  (waiters read-wait-queue-waiters))

;; A message queue is a list of messages in FIFO order.  A message is
;; any value.  The list is in FIFO order to make adding to the list
;; more expensive (O(n)) than removing from it (O(1)).  It's a list to
;; avoid record overhead.

(define-record-type <write-wait-queue>
  (make-write-wait-queue messages waiters)
  write-wait-queue?
  (messages write-wait-queue-messages)
  (waiters write-wait-queue-waiters))

(define-record-type <channel>
  (%make-channel queue-size state)
  channel?
  (queue-size channel-queue-size)
  ;; Atomic reference to channel state.  Channel state is either a
  ;; <read-wait-queue>, if the queue is empty and readers are blocked,
  ;; or a message queue (described above) if the queue is not blocked,
  ;; or a <write-wait-queue> if the queue is full and there are
  ;; blocked writers.
  (state channel-message-state))

(define* (make-channel #:key (queue-size 1))
  (%make-channel queue-size (make-atomic-box '())))

(define (put-message channel message)
  (match channel
    (($ <channel> queue-size state)
     (let retry ((old-state (atomic-box-ref state)))
       (define (commit new-state kt)
         (let ((x (atomic-box-compare-and-swap! state old-state new-state)))
           (if (eq? x old-state) (kt) (retry x))))
       (match old-state
         ((or () (_ . _))
          (if (< (length old-state) queue-size)
              (commit (append old-state (list message)) values)
              (commit (make-write-wait-queue old-state (list (current-fiber)))
                      (lambda ()
                        (suspend)
                        (retry (atomic-box-ref state))))))
         (($ <read-wait-queue> waiters)
          (commit (list message)
                  (lambda ()
                    (for-each (lambda (fiber) (resume fiber values)) waiters)
                    (values))))
         (($ <write-wait-queue> messages waiters)
          (commit (make-write-wait-queue messages (cons (current-fiber) waiters))
                  (lambda ()
                    (suspend)
                    (retry (atomic-box-ref state))))))))))

(define (get-message channel)
  (match channel
    (($ <channel> queue-size state)
     (let retry ((old-state (atomic-box-ref state)))
       (define (commit new-state kt)
         (let ((x (atomic-box-compare-and-swap! state old-state new-state)))
           (if (eq? x old-state) (kt) (retry x))))
       (match old-state
         (()
          (commit (make-read-wait-queue (list (current-fiber)))
                  (lambda ()
                    (suspend)
                    (retry (atomic-box-ref state)))))
         ((message . messages)
          (commit messages (lambda () message)))
         (($ <read-wait-queue> waiters)
          (commit (make-read-wait-queue (cons (current-fiber) waiters))
                  (lambda ()
                    (suspend)
                    (retry (atomic-box-ref state)))))
         (($ <write-wait-queue> (message . messages) waiters)
          (commit messages
                  (lambda ()
                    (for-each (lambda (fiber) (resume fiber values)) waiters)
                    message))))))))
