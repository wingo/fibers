;; Fibers: cooperative, event-driven user-space threads.

;;;; Copyright (C) 2016 Free Software Foundation, Inc.
;;;; Copyright (C) 2021 Maxime Devos
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
;;;;

(define-module (tests io-wakeup)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 control)
  #:use-module (ice-9 suspendable-ports)
  #:use-module (ice-9 binary-ports)
  #:use-module (fibers)
  #:use-module (fibers io-wakeup)
  #:use-module (fibers operations)
  #:use-module (fibers timers))

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

(define-syntax-rule (assert-run-fibers-terminates exp)
  (begin
    (format #t "assert run-fibers on ~s terminates: " 'exp)
    (force-output)
    (let ((start (get-internal-real-time)))
      (call-with-values (lambda () (run-fibers (lambda () exp)))
        (lambda vals
          (format #t "ok (~a s)\n" (/ (- (get-internal-real-time) start)
                                      1.0 internal-time-units-per-second))
          (apply values vals))))))

(define-syntax-rule (assert-run-fibers-returns (expected ...) exp)
  (begin
    (call-with-values (lambda () (assert-run-fibers-terminates exp))
      (lambda run-fiber-return-vals
        (assert-equal '(expected ...) run-fiber-return-vals)))))


;; Note that theoretically, on very slow systems, SECONDS might need
;; to be increased.  However, readable/timeout? and writable/timeout?
;; call this 5 times in a loop anyways, so the effective timeout is
;; a fourth of a second, which should be plenty in practice.
(define* (with-timeout op #:key (seconds 0.05) (wrap values))
  (choice-operation op
                    (wrap-operation (sleep-operation seconds) wrap)))

(define* (readable/timeout? port #:key (allowed-spurious 5))
  "Does waiting for readability time-out?
Allow @var{allowed-spurious} spurious wakeups."
  (or (perform-operation
	(with-timeout
	 (wrap-operation (wait-until-port-readable-operation port)
			 (lambda () #f))
	 #:wrap (lambda () #t)))
      (and (> allowed-spurious 0)
	   (readable/timeout? port #:allowed-spurious
			      (- allowed-spurious 1)))))

(define* (writable/timeout? port #:key (allowed-spurious 5))
  "Does waiting for writability time-out?
Allow @var{allowed-spurious} spurious wakeups."
  (or (perform-operation
       (with-timeout
	(wrap-operation (wait-until-port-writable-operation port)
			(lambda () #f))
	#:wrap (lambda () #t)))
      (and (> allowed-spurious 0)
	   (writable/timeout? port #:allowed-spurious
			      (- allowed-spurious 1)))))

;; Tests:
;;  * wait-until-port-readable-operaton / wait-until-port-writable-operation
;;    blocks if the port isn't ready for input / output.
;;
;;    This is tested with a pipe (read & write)
;;    and a listening socket (read, or accept in this case).
;;
;;    Due to the possibility of spurious wakeups,
;;    a limited few spurious wakeups are tolerated.
;;
;;  * these operations succeed if the port is ready for input / output.
;;
;;    These are again tested with a pipe and a listening socket
;;
;; Blocking is detected with a small time-out.

(define (make-listening-socket)
  (let ((server (socket PF_INET SOCK_DGRAM 0)))
    (bind server AF_INET INADDR_LOOPBACK 0)
    server))

(let ((s (make-listening-socket)))
  (assert-run-fibers-returns (#t)
			     (readable/timeout? s))
  (assert-equal #t (readable/timeout? s))
  (close s))

(define (set-nonblocking! sock)
  (let ((flags (fcntl sock F_GETFL)))
    (fcntl sock F_SETFL (logior O_NONBLOCK flags))))

(define-syntax-rule (with-pipes (A B) exp exp* ...)
  (let* ((pipes (pipe))
	 (A (car pipes))
	 (B (cdr pipes)))
    exp exp* ...
    (close A)
    (close B)))

(with-pipes (A B)
  (setvbuf A 'none)
  (setvbuf B 'none)
  (assert-run-fibers-returns (#t)
			     (readable/timeout? A))
  (assert-equal #t (readable/timeout? A))

  ;; The buffer is empty, so writability is expected.
  (assert-run-fibers-returns (#f)
			     (writable/timeout? B))
  (assert-equal #f (writable/timeout? B))

  ;; Fill the buffer
  (set-nonblocking! B)
  (let ((bv (make-bytevector 1024)))
    (let/ec k
      (parameterize ((current-write-waiter k))
	(let loop ()
	  (put-bytevector B bv)
	  (loop)))))

  ;; As the buffer is full, writable/timeout? should return
  ;; #t.
  (assert-run-fibers-returns (#t)
			     (writable/timeout? B))
  ;; There's plenty to read now, so readable/timeout? should
  ;; return #f.
  (assert-run-fibers-returns (#f)
			     (readable/timeout? A)))

(exit (if failed? 1 0))

;; Local Variables:
;; eval: (put 'with-pipes 'scheme-indent-function 1)
;; End:
