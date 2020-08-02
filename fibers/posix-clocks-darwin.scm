;; POSIX clocks (Darwin)

;;;; Copyright (C) 2020 Abdulrahman Semrie <hsamireh@gmail.com>
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
  #:use-module (fibers config)
  #:use-module (ice-9 match)
  #:use-module (system foreign)
  #:export (init-posix-clocks
            clock-nanosleep
            clock-getcpuclockid
            pthread-getcpuclockid
            pthread-self
            getaffinity setaffinity))

(define exe (dynamic-link))
(define exe-clocks (dynamic-link (extension-library "fibers-darwin-clocks")))

(define clockid-t int32)
(define time-t long)
(define pthread-t unsigned-long)
(define struct-timespec (list time-t long))

(define TIMER_ABSTIME 1)

(define CLOCK_REALTIME 0)
(define CLOCK_MONOTONIC 6)
(define CLOCK_PROCESS_CPUTIME_ID 12)
(define CLOCK_THREAD_CPUTIME_ID 16)

(define init-posix-clocks
  (lambda ()
    (eval-when (eval load compile)
      (dynamic-call "init_affinity"
                    (dynamic-link (extension-library "fibers-affinity"))))))

(define clock-getcpuclockid
  (lambda* (pid) CLOCK_PROCESS_CPUTIME_ID))

(define pthread-getcpuclockid
  (lambda* (pid) CLOCK_THREAD_CPUTIME_ID))

(define pthread-self
  (let* ((ptr (dynamic-pointer "pthread_self" exe))
         (proc (pointer->procedure pthread-t ptr '())))
    (lambda ()
      (proc))))

(define (nsec->timespec nsec)
  (make-c-struct struct-timespec
                 (list (quotient nsec #e1e9) (modulo nsec #e1e9))))

(define (timespec->nsec ts)
  (match (parse-c-struct ts struct-timespec)
    ((sec nsec)
     (+ (* sec #e1e9) nsec))))

(define clock-nanosleep
  (let* ((ptr (dynamic-pointer "clock_nanosleep" exe-clocks))
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
