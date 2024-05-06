;; Double-ended queue

;;;; Copyright (C) 2016 Andy Wingo <wingo@pobox.com>
;;;; Copyright (C) 2017 Christine Lemmer-Webber <cwebber@dustycloud.org>
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
;;;; You should have received a copy of the GNU Lesser General Public License
;;;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

(define-module (fibers deque)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 match)
  #:export (make-deque
            make-empty-deque
            empty-deque?
            enqueue
            dequeue
            dequeue-all
            dequeue-match
            dequeue-filter
            undequeue
            dequeue!
            dequeue-all!
            enqueue!
            dequeue-filter!))

;; A functional double-ended queue ("deque") has a head and a tail,
;; which are both lists.  The head is in FIFO order and the tail is in
;; LIFO order.
(define-inlinable (make-deque head tail)
  (cons head tail))

(define (make-empty-deque)
  (make-deque '() '()))

(define (empty-deque? dq)
  (match dq
    ((() . ()) #t)
    (_ #f)))

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

(define (dequeue-all dq)
  (match dq
    ((head . ()) head)
    ((head . tail) (append head (reverse tail)))))

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

(define (dequeue-filter dq pred)
  (match dq
    ((head . tail)
     (cons (filter pred head)
           (filter pred tail)))))

(define-inlinable (update! box f)
  (let spin ((x (atomic-box-ref box)))
    (call-with-values (lambda () (f x))
      (lambda (x* ret)
        (if (eq? x x*)
            ret
            (let ((x** (atomic-box-compare-and-swap! box x x*)))
              (if (eq? x x**)
                  ret
                  (spin x**))))))))

(define* (dequeue! dqbox #:optional default)
  (update! dqbox (lambda (dq)
                   (call-with-values (lambda () (dequeue dq))
                     (lambda (dq* fiber)
                       (if dq*
                           (values dq* fiber)
                           (values dq default)))))))

(define (dequeue-all! dqbox)
  (update! dqbox (lambda (dq)
                   (values (make-empty-deque)
                           (dequeue-all dq)))))

(define (enqueue! dqbox item)
  (update! dqbox (lambda (dq)
                   (values (enqueue dq item)
                           #f))))

(define (dequeue-filter! dqbox pred)
  (update! dqbox (lambda (dq)
                   (values (dequeue-filter dq pred)
                           #f))))
