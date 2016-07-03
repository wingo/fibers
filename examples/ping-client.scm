;;; Simple ping client implementation

;; Copyright (C)  2012 Free Software Foundation, Inc.

;; This library is free software; you can redistribute it and/or
;; modify it under the terms of the GNU Lesser General Public
;; License as published by the Free Software Foundation; either
;; version 3 of the License, or (at your option) any later version.
;;
;; This library is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; Lesser General Public License for more details.
;;
;; You should have received a copy of the GNU Lesser General Public
;; License along with this library; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
;; 02110-1301 USA

(use-modules (rnrs bytevectors)
             (fibers)
             (ice-9 binary-ports)
             (ice-9 textual-ports)
             (ice-9 rdelim)
             (ice-9 match))

(define (set-nonblocking! port)
  (fcntl port F_SETFL (logior O_NONBLOCK (fcntl port F_GETFL)))
  (setvbuf port 'block 1024))

(define (server-error port msg . args)
  (apply format (current-error-port) msg args)
  (newline (current-error-port))
  (close-port port)
  (suspend))

(define (connect-to-server addrinfo)
  (let ((port (socket (addrinfo:fam addrinfo)
                      (addrinfo:socktype addrinfo)
                      (addrinfo:protocol addrinfo))))
    ;; Disable Nagle's algorithm.  We buffer ourselves.
    (setsockopt port IPPROTO_TCP TCP_NODELAY 0)
    (set-nonblocking! port)
    (connect port (addrinfo:addr addrinfo))
    port))

(define *active-clients* 0)

(define (client-loop addrinfo n num-connections)
  (set! *active-clients* (1+ *active-clients*))
  (let ((port (connect-to-server addrinfo))
        (test (string-append "test-" (number->string n))))
    (let lp ((m 0))
      (when (< m num-connections)
        (put-string port test)
        (put-char port #\newline)
        (force-output port)
        (let ((response (read-line port)))
          (unless (equal? test response)
            (server-error port "Bad response: ~A (expected ~A)" response test))
          (lp (1+ m)))))
    (close-port port))
  (set! *active-clients* (1- *active-clients*))
  (when (zero? *active-clients*)
    (exit 0)))

(define (run-ping-test num-clients num-connections)
  ;; The getaddrinfo call blocks, unfortunately.  Call it once before
  ;; spawning clients.
  (let ((addrinfo (car (getaddrinfo "localhost" (number->string 11211)))))
    (let lp ((n 0))
      (when (< n num-clients)
        (spawn
         (lambda ()
           (client-loop addrinfo n num-connections)))
        (lp (1+ n)))))
  (run))

(apply run-ping-test (map string->number (cdr (program-arguments))))
