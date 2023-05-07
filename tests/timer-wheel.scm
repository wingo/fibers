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

(define-module (tests timer-wheel)
  #:use-module (fibers timer-wheel))

(define (self-test)
  (define start (get-internal-real-time))
  (define wheel (make-timer-wheel #:now start))
  
  (define one-hour (* 60 60 internal-time-units-per-second))
  ;; At millisecond precision, advancing the wheel by an hour shouldn't
  ;; take perceptible time.
  (define start+one-hour
    (let ((t (+ start one-hour)))
      (timer-wheel-advance! wheel t error)
      t))

  ;; (timer-wheel-dump wheel)

  (define event-count 10000)
  (define end
    (let lp ((t start+one-hour) (i 0))
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
    (let ((tick-start (timer-wheel-next-tick-start wheel))
          (tick-end (timer-wheel-next-tick-end wheel)))
      (when (< t tick-start)
        (error "tick late" tick-start t tick-end))
      (when (<= tick-end t)
        (error "tick early" tick-start t tick-end))))

  (timer-wheel-advance! wheel end check!)
  ;; The precision of the timer is at least milliseconds, and it won't
  ;; advance until all time in the current tick has passed, so to ensure
  ;; the last event has been processed all events we need to go one more
  ;; tick.
  (timer-wheel-advance! wheel (timer-wheel-next-tick-end wheel) check!)
  (unless (= count event-count) (error "what4" count event-count)))

(self-test)
