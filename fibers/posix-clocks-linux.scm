;; POSIX clocks (Linux)

;;;; Copyright (C) 2020 Abdulrahman Semrie <hsamireh@gmail.com>
;;;; Copyright (C) 2020 Aleix Conchillo Flaqué <aconchillo@gmail.com>
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

;;; Fibers uses POSIX clocks to be able to preempt schedulers running
;;; in other threads after regular timeouts in terms of thread CPU time.

(define-module (fibers posix-clocks)
  #:use-module (system foreign)
  #:use-module (ice-9 match)
  #:use-module (rnrs bytevectors)
  #:export (init-posix-clocks
            clock-nanosleep
            clock-getcpuclockid
            pthread-getcpuclockid
            pthread-self))

(define exe (dynamic-link))

(define clockid-t int32)
(define time-t long)
(define pid-t int)
(define pthread-t unsigned-long)
(define struct-timespec (list time-t long))

(define TIMER_ABSTIME 1)

(define CLOCK_REALTIME 0)
(define CLOCK_MONOTONIC 1)
(define CLOCK_PROCESS_CPUTIME_ID 2)
(define CLOCK_THREAD_CPUTIME_ID 3)
(define CLOCK_MONOTONIC_RAW 4)
(define CLOCK_REALTIME_COARSE 5)
(define CLOCK_MONOTONIC_COARSE 6)

(define init-posix-clocks
  (lambda () *unspecified*))

(define pthread-self
  (let* ((ptr (dynamic-pointer "pthread_self" exe))
         (proc (pointer->procedure pthread-t ptr '())))
    (lambda ()
      (proc))))

(define clock-getcpuclockid
  (let* ((ptr (dynamic-pointer "clock_getcpuclockid" exe))
         (proc (pointer->procedure int ptr (list pid-t '*)
                                   #:return-errno? #t)))
    (lambda* (pid #:optional (buf (make-bytevector (sizeof clockid-t))))
      (call-with-values (lambda () (proc pid (bytevector->pointer buf)))
        (lambda (ret errno)
          (unless (zero? ret) (error (strerror errno)))
          (bytevector-s32-native-ref buf 0))))))

(define pthread-getcpuclockid
  (let* ((ptr (dynamic-pointer "pthread_getcpuclockid" exe))
         (proc (pointer->procedure int ptr (list pthread-t '*)
                                   #:return-errno? #t)))
    (lambda* (pthread #:optional (buf (make-bytevector (sizeof clockid-t))))
      (call-with-values (lambda () (proc pthread (bytevector->pointer buf)))
        (lambda (ret errno)
          (unless (zero? ret) (error (strerror errno)))
          (bytevector-s32-native-ref buf 0))))))

(define (nsec->timespec nsec)
  (make-c-struct struct-timespec
                 (list (quotient nsec #e1e9) (modulo nsec #e1e9))))

(define (timespec->nsec ts)
  (match (parse-c-struct ts struct-timespec)
    ((sec nsec)
     (+ (* sec #e1e9) nsec))))

(define clock-nanosleep
  (let* ((ptr (dynamic-pointer "clock_nanosleep" exe))
         (proc (pointer->procedure int ptr (list clockid-t int '* '*))))
    (lambda* (clockid nsec #:key absolute? (buf (nsec->timespec nsec)))
      (let* ((flags (if absolute? TIMER_ABSTIME 0))
             (ret (proc clockid flags buf buf)))
        (cond
         ((zero? ret) (values #t 0))
         ((eqv? ret EINTR) (values #f (timespec->nsec buf)))
         (else (error (strerror ret))))))))

(define clock-gettime
  (let* ((ptr (dynamic-pointer "clock_gettime" exe))
         (proc (pointer->procedure int ptr (list clockid-t '*)
                                   #:return-errno? #t)))
    (lambda* (clockid #:optional (buf (nsec->timespec 0)))
      (call-with-values (lambda () (proc clockid buf))
        (lambda (ret errno)
          (unless (zero? ret) (error (strerror errno)))
          (timespec->nsec buf))))))

;; Quick little test to determine the resolution of clock-nanosleep on
;; different clock types, and how much CPU that takes.  Results on
;; this 2-core, 2-thread-per-core skylake laptop:
;;
;; Clock type     | Applied Hz | Actual Hz | CPU time overhead (%)
;; ---------------------------------------------------------------
;; MONOTONIC        100          98           0.4
;; MONOTONIC        1000         873          4.4
;; MONOTONIC        10000        6242         6.4
;; MONOTONIC        100000       14479       13.6
;; REALTIME         100          98           0.5
;; REALTIME         1000         872          4.5
;; REALTIME         10000        6238         6.5
;; REALTIME         100000       14590       12.2
;; PROCESS_CPUTIME  100          84           1.0
;; PROCESS_CPUTIME  10000        250          1.0
;; PROCESS_CPUTIME  100000       250          1.0
;; pthread cputime  100          84           0.9
;; pthread cputime  10000        250          0.6
;;
;; The cputime benchmarks were run with a background thread in a busy
;; loop to allow that clock to advance at the same rate as a wall
;; clock.
;;
;; Conclusions: The monotonic and realtime clocks are relatively
;; high-precision, allowing for sub-millisecond scheduling quanta, but
;; they have to be actively managed (explicitly deactivated while
;; waiting on FD events).  The cputime clocks don't have to be
;; actively managed, but they aren't as high-precision either.
(define (test clock period)
  (let ((start (clock-gettime CLOCK_PROCESS_CPUTIME_ID))
        (until (+ (clock-gettime clock) #e1e9)))
    (let lp ((n 0))
      (if (< (clock-gettime clock) until)
          (begin
            (clock-nanosleep clock period)
            (lp (1+ n)))
          (values n (/ (- (clock-gettime CLOCK_PROCESS_CPUTIME_ID) start)
                       1e9))))))
