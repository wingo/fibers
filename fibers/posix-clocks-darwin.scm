;; POSIX clocks (Darwin)

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
  #:export (clock-nanosleep
            clock-getcpuclockid
            pthread-getcpuclockid
            pthread-self
            getaffinity setaffinity))

(eval-when (eval load compile)
  (dynamic-call "init_affinity"
                (dynamic-link (extension-library "affinity"))))

(define exe (dynamic-link))

(define time-t long)
(define pthread-t unsigned-long)
(define struct-timespec (list time-t long))

(define TIMER_ABSTIME 1)

(define CLOCK_PROCESS_CPUTIME_ID 12)
(define CLOCK_THREAD_CPUTIME_ID 16)

(define (nsec->timespec nsec)
  (make-c-struct struct-timespec
                 (list (quotient nsec #e1e9) (modulo nsec #e1e9))))
(define (timespec->nsec ts)
  (match (parse-c-struct ts struct-timespec)
    ((sec nsec)
     (+ (* sec #e1e9) nsec))))

(define clock-getcpuclockid
  (lambda* (pid) CLOCK_PROCESS_CPUTIME_ID))

(define pthread-getcpuclockid
  (lambda* (pid) CLOCK_THREAD_CPUTIME_ID))

(define pthread-self
  (let* ((ptr (dynamic-pointer "pthread_self" exe))
         (proc (pointer->procedure pthread-t ptr '())))
    (lambda ()
      (proc))))

(define clock-nanosleep
  (let* ((ptr (dynamic-pointer "nanosleep" exe))
         (proc (pointer->procedure int ptr (list '* '*))))
    (lambda* (clockid nsec #:key absolute? (buf (nsec->timespec nsec)))
      (let* ((flags (if absolute? TIMER_ABSTIME 0))
             (ret (proc buf buf)))
        (cond
         ((zero? ret) (values #t 0))
         ((eqv? ret EINTR) (values #f (timespec->nsec buf)))
         (else (error (strerror ret))))))))