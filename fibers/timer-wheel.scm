;; Fibers: cooperative, event-driven user-space threads.

;;;; Copyright (C) 2023 Free Software Foundation, Inc.
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

;;;; Hierarchical timer wheel inspired by Juho Snellman's "Ratas".  For a
;;;; detailed discussion, see:
;;;;
;;;;   https://www.snellman.net/blog/archive/2016-07-27-ratas-hierarchical-timer-wheel/
;;;;
;;;; Ported from
;;;; https://github.com/snabbco/snabb/blob/master/src/lib/fibers/timer.lua,
;;;; by Andy Wingo.

(define-module (fibers timer-wheel)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:export (make-timer-wheel
            timer-wheel-add!
            timer-wheel-next-entry-time
            timer-wheel-advance!
            timer-wheel-dump))

(define *slots* 256)
(define *slots-bits* 8)
(define *slots-mask* 255)

(define-record-type <timer-entry>
  (make-timer-entry prev next time obj)
  timer-entry?
  (prev timer-entry-prev set-timer-entry-prev!)
  (next timer-entry-next set-timer-entry-next!)
  (time timer-entry-time)
  (obj timer-entry-obj))

(define-record-type <timer-wheel>
  (%make-timer-wheel time-base shift cur slots outer)
  timer-wheel?
  (time-base timer-wheel-time-base set-timer-wheel-time-base!)
  (shift timer-wheel-shift)
  (cur timer-wheel-cur set-timer-wheel-cur!)
  (slots timer-wheel-slots)
  (outer timer-wheel-outer set-timer-wheel-outer!))

(define (push-timer-entry! entry head)
  (match head
    (($ <timer-entry> prev)
     (set-timer-entry-prev! entry prev)
     (set-timer-entry-next! entry head)
     (set-timer-entry-prev! head entry)
     (set-timer-entry-next! prev entry))))

(define (make-slots)
  (let ((slots (make-vector *slots* #f)))
    (let lp ((i 0))
      (when (< i *slots*)
        (let ((entry (make-timer-entry #f #f #f #f)))
          (set-timer-entry-prev! entry entry)
          (set-timer-entry-next! entry entry)
          (vector-set! slots i entry))
        (lp (1+ i))))
    slots))

(define (time->slot-index internal-time shift)
  (logand (ash internal-time (- shift)) *slots-mask*))

(define (compute-time-base shift internal-time)
  (logand internal-time (lognot (1- (ash 1 shift)))))

(define* (make-timer-wheel #:key (now (get-internal-real-time))
                           ;; Default to at-least-millisecond precision.
                           (precision 1000)
                           (shift (let lp ((shift 0))
                                    (if (< (ash internal-time-units-per-second
                                                (- (1+ shift)))
                                           precision)
                                        shift
                                        (lp (1+ shift))))))
  (%make-timer-wheel (compute-time-base (+ shift *slots-bits*) now)
                     shift
                     (time->slot-index now shift)
                     (make-slots)
                     #f))

(define (add-outer-wheel! inner)
  (match inner
    (($ <timer-wheel> time-base shift cur slots #f)
     (let* ((next-outer-tick (+ time-base (ash *slots* shift)))
            (outer (make-timer-wheel #:now next-outer-tick
                                     #:shift (+ shift *slots-bits*))))
       (set-timer-wheel-outer! inner outer)
       outer))))

(define (next-tick-time time-base cur shift)
  (+ time-base (ash cur shift)))

(define (timer-wheel-next-tick-time wheel)
  (match wheel
    (($ <timer-wheel> time-base shift cur slots outer)
     (next-tick-time time-base cur shift))))

(define (timer-wheel-add! wheel t obj)
  (match wheel
    (($ <timer-wheel> time-base shift cur slots outer)
     (let ((offset (ash (- t (next-tick-time time-base cur shift))
                        (- shift))))
       (cond
        ((< offset *slots*)
         (let ((idx (logand (+ cur (max offset 0)) *slots-mask*))
               (entry (make-timer-entry #f #f t obj)))
           (push-timer-entry! entry (vector-ref slots idx))
           entry))
        (else
         (timer-wheel-add! (or outer (add-outer-wheel! wheel)) t obj)))))))

(define (timer-wheel-next-entry-time wheel)
  (define (slot-min-time head)
    (let lp ((entry (timer-entry-next head)) (min #f))
      (if (eq? entry head)
          min
          (match entry
            (($ <timer-entry> prev next t obj)
             (lp next (if (and min (< min t)) min t)))))))
  (match wheel
    (($ <timer-wheel> time-base shift cur slots outer)
     (let lp ((i 0))
       (cond
        ((< i *slots*)
         (match (slot-min-time
                 (vector-ref slots (logand (+ cur i) *slots-mask*)))
           (#f (lp (1+ i))) ;; Empty slot.
           (t
            ;; Unless we just migrated entries from outer to inner wheel
            ;; on the last tick, outer wheel overlaps with inner.
            (let ((outer-t (match outer
                             (#f #f)
                             (($ <timer-wheel> time-base shift cur slots outer)
                              (slot-min-time (vector-ref slots cur))))))
              (if outer-t
                  (min t outer-t)
                  t)))))
        (outer (timer-wheel-next-entry-time outer))
        (else #f))))))

(define* (timer-wheel-dump wheel #:key (port (current-output-port))
                           (level 0)
                           (process-time
                            (lambda (t)
                              (/ t 1.0 internal-time-units-per-second))))
  (match wheel
    (($ <timer-wheel> time-base shift cur slots outer)
     (let ((start (next-tick-time time-base cur shift)))
       (let lp ((i 0))
         (when (< i *slots*)
           (let* ((head (vector-ref slots (logand *slots-mask* (+ cur i))))
                  (entry (timer-entry-next head)))
             (unless (eq? entry head)
               (format port "level ~a, tick +~a (~a-~a):\n" level i
                       (process-time (+ start (ash i shift)))
                       (process-time (+ start (ash (1+ i) shift))))
               (let lp ((entry entry))
                 (match entry
                   (($ <timer-entry> _ next t obj)
                    (format port "  ~a: ~a\n" (process-time t) obj)
                    (unless (eq? next head)
                      (lp next)))))))
           (lp (1+ i)))))
     (when outer
       (timer-wheel-dump outer #:port port #:level (1+ level)
                         #:process-time process-time)))))

(define (timer-wheel-advance! wheel t schedule!)
  (define (tick!)
    ;; Define as syntax to make sure it gets inlined; otherwise the
    ;; compiler currently ends up making a closure.
    (define-syntax-rule (advance-wheel! wheel visit-timer-entry!)
      (match wheel
        (($ <timer-wheel> time-base shift cur slots outer)
         (let ((head (vector-ref slots cur)))
           (let lp ()
             (match head
               (($ <timer-entry> _ entry)
                (cond
                 ((eq? entry head) #f)
                 (else
                  (match entry
                    (($ <timer-entry> _ next t obj)
                     (set-timer-entry-next! head next)
                     (set-timer-entry-prev! next head)
                     (visit-timer-entry! entry t obj)
                     (lp)))))))))
         (let ((cur (logand (1+ cur) *slots-mask*)))
           (set-timer-wheel-cur! wheel cur)
           (when (zero? cur)
             (let ((time-base (+ time-base (ash *slots* shift))))
               (set-timer-wheel-time-base! wheel time-base)
               (when outer (tick-outer! wheel outer))))))))

    (define (tick-outer! inner outer)
      (define (add-to-inner! entry t obj)
        (match inner
          (($ <timer-wheel> time-base shift cur slots outer)
           (let ((new-head (vector-ref slots (time->slot-index t shift))))
             (push-timer-entry! entry new-head)))))
      (advance-wheel! outer add-to-inner!))

    (advance-wheel! wheel (lambda (entry t obj) (schedule! obj))))

  (match wheel
    (($ <timer-wheel> time-base shift cur slots outer)
     (let ((inc (ash 1 shift)))
       (let lp ((next-tick (next-tick-time time-base cur shift)))
         (when (<= next-tick t)
           (tick!)
           (lp (+ next-tick inc))))))))

(define (self-test)
  (define start (get-internal-real-time))
  (define wheel (make-timer-wheel #:now start))
  
  (define one-hour (* 60 60 internal-time-units-per-second))
  ;; At millisecond precision, advancing the wheel by an hour shouldn't
  ;; take perceptible time.
  (timer-wheel-advance! wheel one-hour error)

  ;; (timer-wheel-dump wheel)

  (define event-count 10000)
  (define end
    (let lp ((t (+ start one-hour)) (i 0))
      (if (< i event-count)
          (let ((t (+ t (random internal-time-units-per-second))))
            (timer-wheel-add! wheel t t)
            (lp t (1+ i)))
          t)))

  ;; (timer-wheel-dump wheel)

  (define last 0)
  (define count 0)
  (define (check! t)
    ;; The timer wheel only guarantees ordering between ticks, not
    ;; ordering within a tick.  It doesn't even guarantee insertion
    ;; order within a tick.  However for this test we know that
    ;; insertion order is preserved.
    (unless (<= last t) (error "unexpected tick" last t))
    (set! last t)
    (set! count (1+ count))
    ;; Check that timers fire within the tick that they should.
    (define tick-start (timer-wheel-next-tick-time wheel))
    (define tick-end (+ tick-start (ash 1 (timer-wheel-shift wheel))))
    (when (< t tick-start)
      (error "tick late" tick-start t tick-end))
    (when (<= tick-end t)
      (error "tick early" tick-start t tick-end)))

  (timer-wheel-advance! wheel end check!)
  (unless (= count event-count) (error "what4"))
  #t)
