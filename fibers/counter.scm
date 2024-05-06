;; Counters

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

;;; General atomic counters; currently used for garbage collection.

(define-module (fibers counter)
  #:use-module (ice-9 atomic)
  #:export (make-counter
            counter-decrement!
            counter-reset!))

;;; Counter utilities
;;;
;;; Counters here are an atomic box containing an integer which are
;;; either decremented or reset.

;; How many times we run the block-fn until we gc
(define %countdown-steps 42)  ; haven't tried testing for the most efficient number

(define* (make-counter)
  (make-atomic-box %countdown-steps))

(define (counter-decrement! counter)
  "Decrement integer in atomic box COUNTER."
  (let spin ((x (atomic-box-ref counter)))
    (let* ((x-new (1- x))
           (x* (atomic-box-compare-and-swap! counter x x-new)))
      (if (= x* x)  ; successful decrement
          x-new
          (spin x*)))))

(define (counter-reset! counter)
  "Reset a counter's contents."
  (atomic-box-set! counter %countdown-steps))
