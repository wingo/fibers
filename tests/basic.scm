;; Fibers: cooperative, event-driven user-space threads.

;;;; Copyright (C) 2016 Free Software Foundation, Inc.
;;;; Copyright (C) 2023 Maxime Devos <maximedevos@telenet.be>
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

(define-module (tests basic)
  #:use-module (fibers)
  #:use-module (fibers conditions)
  #:use-module (fibers scheduler))

(define failed? #f)

(define-syntax-rule (assert-equal expected actual)
  (let ((x expected))
    (format #t "assert ~s equal to ~s: " 'actual x)
    (force-output)
    (let ((y actual))
      (cond
       ((equal? x y) (format #t "ok\n"))
       (else
        (format #t "no (got ~s)\n" y)
        (set! failed? #t))))))

(define-syntax-rule (assert-terminates exp)
  (begin
    (format #t "assert ~s terminates: " 'exp)
    (force-output)
    exp
    (format #t "ok\n")))

(define-syntax-rule (assert-run-fibers-terminates exp kw ...)
  (begin
    (format #t "assert terminates: ~s: " '(run-fibers (lambda () exp) kw ...))
    (force-output)
    (let ((start (get-internal-real-time)))
      (call-with-values (lambda () (run-fibers (lambda () exp) kw ...))
        (lambda vals
          (format #t "ok (~a s)\n" (/ (- (get-internal-real-time) start)
                                      1.0 internal-time-units-per-second))
          (apply values vals))))))

(define-syntax-rule (assert-run-fibers-returns (expected ...) exp kw ...)
  (begin
    (call-with-values (lambda ()
                        (assert-run-fibers-terminates exp #:drain? #t kw ...))
      (lambda run-fiber-return-vals
        (assert-equal '(expected ...) run-fiber-return-vals)))))

(define-syntax-rule (do-times n exp)
  (let lp ((count n))
    (let ((count (1- count)))
      exp
      (unless (zero? count) (lp count)))))

(define (no-rewinding)
  (when (rewinding-for-scheduling?)
    (error "rewinding-for-scheduling?=#true should be invisible to users of dynamic-wind*")))

;; Test some functionality of dynamic-wind*
(define (run-dynamic-wind-loop N poke)
  (let loop ((n 0))
    (define in-entered? #false)
    (define in-left? #false)
    (define thunk-entered? #false)
    (define thunk-left? #false)
    (define out-entered? #false)
    (define out-left? #false)
    (define (expect where a b c d e f)
      (define s (list in-entered? in-left? thunk-entered? thunk-left? out-entered? out-left?))
      (define t (list a b c d e f))
      (unless (equal? s t)
	(pk #:for where
	    #:expected t
	    #:got s)
	(error "wrong state")))
    (dynamic-wind*
     (lambda ()
       (no-rewinding)
       (expect 'in-guard #f #f #f #f #f #f)
       (set! in-entered? #true)
       (poke)
       (no-rewinding)
       (expect 'in-guard #t #f #f #f #f #f)
       (poke)
       (no-rewinding)
       (expect 'in-guard #t #f #f #f #f #f)
       (set! in-left? #true))
     (lambda ()
       (no-rewinding)
       (expect 'thunk #t #t #f #f #f #f)
       (set! thunk-entered? #true)
       (poke)
       (no-rewinding)
       (expect 'thunk #t #t #t #f #f #f)
       (poke)
       (no-rewinding)
       (expect 'thunk #t #t #t #f #f #f)
       (set! thunk-left? #true))
     (lambda ()
       (no-rewinding)
       (expect 'out-guard #t #t #t #t #f #f)
       (set! out-entered? #true)
       (poke)
       (no-rewinding)
       (expect 'out-guard #t #t #t #t #t #f)
       (poke)
       (no-rewinding)
       (expect 'out-guard #t #t #t #t #t #f)
       (set! out-left? #true)))
    (expect 'post-loop #t #t #t #t #t #t)
    (when (< n N)
      (loop (+ n 1)))))

(define (test-dynamic-wind-loop N hz poke)
  (format #t "Testing dynamic-wind* ...~%")
  (run-fibers
   (lambda ()
     (run-dynamic-wind-loop N poke))
   #:hz hz)
  (format #t "ok!~%"))

(define (poke-no-op) (values))
(define (poke-reschedule1)
  (suspend-current-task schedule-task))
(define (poke-reschedule2)
  (yield-current-task))

(define (poke-maybe-hook reschedule)
  (define (random-boolean)
    (= (random 2) 0))
  (set! %nesting-test-1? (random-boolean))
  (set! %nesting-test-2? (random-boolean))
  (reschedule))
(define (reset!)
  (set! %nesting-test-1? #false)
  (set! %nesting-test-2? #false))

;; dynamic-wind* in a loop, no preemption
(test-dynamic-wind-loop 7000 0 poke-no-op)
(reset!)

;; dynamic-wind* in a loop, preemption
(test-dynamic-wind-loop 70000 10000 poke-reschedule1)
(reset!)
(test-dynamic-wind-loop 70000 10000 poke-reschedule2)
(reset!)

;; dynamic-wind* in a loop, preemption, multiple threads.
(define (concurrency-test poke)
  (format #t "Testing dynamic-wind* in a loop with concurrency and preemption ...~%")
  (run-fibers
   (lambda ()
     (define start (make-condition))
     (define (spawn)
       (define c (make-condition))
       (spawn-fiber
	(lambda ()
	  (wait start)
	  (run-dynamic-wind-loop 30000 poke)
	  (signal-condition! c))
	#:parallel? #true) ; maximal concurrency
       c)
     (let loop ((i 5) ; 5 fibers
		(conditions-to-wait-for '()))
       (if (> i 0)
	   (loop (- i 1)
		 (cons (spawn) conditions-to-wait-for))
	   (begin
	     ;; Start all fibers the same time,
	     ;; for maximal concurrency.
	     (signal-condition! start)
	     (for-each wait conditions-to-wait-for)))))
   #:hz 100000
   #:parallelism 6)) ; 'main' fiber and fibers make with 'spawn'.

;; The 'poke' procedures modify the global variables
;; %nesting-test-1? and %nesting-test-2? without any mutexes
;; or atomics or such, but it's just for tests, so should
;; be fine.
(concurrency-test poke-reschedule1)
(reset!)
(concurrency-test poke-reschedule2)
(reset!)


;; dynamic-wind* in a loop, with high likelihood of
;; (simulated) nesting, only simulated preemption
;;
;; There is no similar test for poke-reschedule1, because
;; the real preemption code uses poke-reschedule2 instead
;; of poke-reschedule1.
(test-dynamic-wind-loop 70000 0 (lambda () (poke-maybe-hook poke-reschedule2)))
(reset!)

;; The code for simulated nesting wasn't written with
;; real preemption in mind.
;; (test-dynamic-wind-loop 10000 10000 (lambda () (poke-maybe-hook ...)))

(assert-equal #f #f)
(assert-terminates #t)
(assert-equal #f (false-if-exception (begin (run-fibers) #t)))
(assert-run-fibers-terminates (sleep 1) #:drain? #t)
(assert-run-fibers-terminates (do-times 1 (spawn-fiber (lambda () #t))) #:drain? #t)
(assert-run-fibers-terminates (do-times 10 (spawn-fiber (lambda () #t))) #:drain? #t)
(assert-run-fibers-terminates (do-times 100 (spawn-fiber (lambda () #t))) #:drain? #t)
(assert-run-fibers-terminates (do-times 1000 (spawn-fiber (lambda () #t))) #:drain? #t)
(assert-run-fibers-terminates (do-times 10000 (spawn-fiber (lambda () #t))) #:drain? #t)
(assert-run-fibers-terminates (do-times 100000 (spawn-fiber (lambda () #t))) #:drain? #t)
(assert-run-fibers-terminates (do-times 100000
                                        (spawn-fiber (lambda () #t) #:parallel? #t)) #:drain? #t)
(define (loop-to-1e4) (let lp ((i 0)) (when (< i #e1e4) (lp (1+ i)))))
(assert-run-fibers-terminates (do-times 100000 (spawn-fiber loop-to-1e4)) #:drain? #t)
(assert-run-fibers-terminates (do-times 100000 (spawn-fiber loop-to-1e4 #:parallel? #t)) #:drain? #t)
(assert-run-fibers-terminates (do-times 1 (spawn-fiber (lambda () (sleep 1)))) #:drain? #t)
(assert-run-fibers-terminates (do-times 10 (spawn-fiber (lambda () (sleep 1)))) #:drain? #t)
(assert-run-fibers-terminates (do-times 100 (spawn-fiber (lambda () (sleep 1)))) #:drain? #t)
(assert-run-fibers-terminates (do-times 1000 (spawn-fiber (lambda () (sleep 1)))) #:drain? #t)
(assert-run-fibers-terminates (do-times 10000 (spawn-fiber (lambda () (sleep 1)))) #:drain? #t)
(assert-run-fibers-terminates (do-times 20000 (spawn-fiber (lambda () (sleep 1)))) #:drain? #t)
(assert-run-fibers-terminates (do-times 40000 (spawn-fiber (lambda () (sleep 1)))) #:drain? #t)

(define (spawn-fiber-tree n leaf)
  (do-times n (spawn-fiber
               (lambda ()
                 (if (= n 1)
                     (leaf)
                     (spawn-fiber-tree (1- n) leaf))))))
(assert-run-fibers-terminates (spawn-fiber-tree 5 (lambda () (sleep 1))) #:drain? #t)

(define (spawn-fiber-chain n)
  (spawn-fiber
   (lambda ()
     (unless (zero? (1- n))
       (spawn-fiber-chain (1- n))))))
(assert-run-fibers-terminates (spawn-fiber-chain 5) #:drain? #t)
(assert-run-fibers-terminates (spawn-fiber-chain 50) #:drain? #t)
(assert-run-fibers-terminates (spawn-fiber-chain 500) #:drain? #t)
(assert-run-fibers-terminates (spawn-fiber-chain 5000) #:drain? #t)
(assert-run-fibers-terminates (spawn-fiber-chain 50000) #:drain? #t)
(assert-run-fibers-terminates (spawn-fiber-chain 500000) #:drain? #t)
(assert-run-fibers-terminates (spawn-fiber-chain 5000000) #:drain? #t)

(let ((run-order 0))
  (define (test-run-order count)
    (for-each (lambda (n)
                (spawn-fiber
                 (lambda ()
                   (unless (eqv? run-order n)
                     (error "bad run order" run-order n))
                   (set! run-order (1+ n)))))
              (iota count)))
  (assert-run-fibers-terminates (test-run-order 10) #:parallelism 1 #:drain? #t))

(let ((run-order 0))
  (define (test-wakeup-order count)
    (for-each (lambda (n)
                (spawn-fiber
                 (lambda ()
                   (unless (eqv? run-order n)
                     (error "bad run order" run-order n))
                   (set! run-order (1+ n)))))
              (iota count)))
  (assert-run-fibers-terminates (test-wakeup-order 10) #:parallelism 1 #:drain? #t))

(assert-run-fibers-returns (1) 1)

(define (check-sleep timeout)
  (spawn-fiber (lambda ()
                 (let ((start (get-internal-real-time)))
                   (sleep timeout)
                   (let ((elapsed (/ (- (get-internal-real-time) start)
                                     1.0 internal-time-units-per-second)))
                     (format #t "assert sleep ~as < actual ~as: ~a (diff: ~a%)\n"
                             timeout elapsed (<= timeout elapsed)
                             (* 100 (/ (- elapsed timeout) timeout)))
                     (set! failed? (< elapsed timeout)))))))

(assert-run-fibers-terminates
 (do-times 20 (check-sleep (random 1.0))) #:drain? #t)

;; exceptions

;; closing port causes pollerr

;; live threads list

(exit (if failed? 1 0))
