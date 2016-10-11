;; Double-ended queue

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

(define-module (fibers deque)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 match)
  #:export (make-deque
            make-empty-deque
            enqueue
            dequeue
            dequeue-match
            undequeue
            enqueue!))

;; A functional double-ended queue ("deque") has a head and a tail,
;; which are both lists.  The head is in FIFO order and the tail is in
;; LIFO order.
(define-inlinable (make-deque head tail)
  (cons head tail))

(define (make-empty-deque)
  (make-deque '() '()))

(define (enqueue dq item)
  (match dq
    ((head . tail)
     (make-deque head (cons item tail)))))

;; -> new deque, val | #f, #f
(define (dequeue dq)
  (match dq
    ((() . ()) (values #f #f))
    ((() . tail)
     (dequeue (make-deque (reverse tail) '())))
    (((item . head) . tail)
     (values (make-deque head tail) item))))

(define (dequeue-match dq pred)
  (match dq
    ((() . ()) (values #f #f))
    ((() . tail)
     (dequeue (make-deque (reverse tail) '())))
    (((item . head) . tail)
     (if (pred item)
         (values (make-deque head tail) item)
         (call-with-values (dequeue-match (make-deque head tail) pred)
           (lambda (dq item*)
             (values (undequeue dq item) item*)))))))

(define (undequeue dq item)
  (match dq
    ((head . tail)
     (make-deque (cons item head) tail))))

(define (enqueue! qbox item)
  (let spin ((q (atomic-box-ref qbox)))
    (let* ((q* (enqueue q item))
           (q** (atomic-box-compare-and-swap! qbox q q*)))
      (unless (eq? q q**)
        (spin q**)))))
