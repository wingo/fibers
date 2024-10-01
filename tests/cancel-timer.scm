;; Fibers: cooperative, event-driven user-space threads.

;;;; Copyright (C) 2024 Ludovic Courtès <ludo@gnu.org>
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
;;;;

(define-module (tests cancel-timer)
  #:use-module (fibers)
  #:use-module (fibers channels)
  #:use-module (fibers operations)
  #:use-module (fibers timers)
  #:use-module (ice-9 format))

(define (heap-size)
  (assoc-ref (gc-stats) 'heap-size))

(define iterations 200000)

;;; Check the heap growth caused by repeated choice operations where one of
;;; the base operations is a timer that always "loses" the choice.
;;;
;;; This situation used to cause timer continuations to accumulate, thereby
;;; leading to unbounded heap growth.  The cancel function of
;;; 'timer-operation' fixes that by immediately canceling timers that lost in
;;; a choice operation.  See <https://github.com/wingo/fibers/issues/109>.

(run-fibers
 (lambda ()
   (define channel
     (make-channel))

   (spawn-fiber
    (lambda ()
      (let loop ((i 0))
        (when (< i iterations)
          (put-message channel 'hello)
          (loop (+ i 1))))))

   (let ((initial-heap-size (heap-size)))
     (let loop ((i 0))
       (when (< i iterations)
         (perform-operation
          (choice-operation (sleep-operation 500)
                            (get-operation channel)))
         (loop (+ 1 i))))

     (let ((final-heap-size (heap-size))
           (MiB (lambda (size)
                  (/ size (expt 2 20.)))))
       (if (<= final-heap-size (* 2 initial-heap-size))
           (format #t "final heap size: ~,2f MiB; initial heap size: ~,2f MiB~%"
                   (MiB final-heap-size) (MiB initial-heap-size))
           (begin
             (format #t "heap grew too much: ~,2f MiB vs. ~,2f MiB~%"
                     (MiB final-heap-size) (MiB initial-heap-size))
             (primitive-exit 1)))))))
