;; Atomic stack

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

(define-module (fibers stack)
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 match)
  #:export (make-empty-stack
            stack-empty?
            stack-push!
            stack-push-list!
            stack-pop!
            stack-pop-all!
            stack-filter!))

(define (make-empty-stack)
  (make-atomic-box '()))

(define (stack-empty? stack)
  (match (atomic-box-ref stack)
    (() #t)
    (_ #f)))

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

(define (stack-push! sbox elt)
  (update! sbox (lambda (stack) (values (cons elt stack) #f))))

(define (stack-push-list! sbox elts)
  (update! sbox (lambda (stack) (values (append elts stack) #f))))

(define* (stack-pop! sbox #:optional default)
  (update! sbox (lambda (stack)
                  (match stack
                    ((elt . stack) (values stack elt))
                    (_ (values stack default))))))

(define (stack-pop-all! sbox)
  (atomic-box-swap! sbox '()))

(define (stack-filter! sbox pred)
  (update! sbox (lambda (stack)
                  (values (filter pred stack) #f))))
