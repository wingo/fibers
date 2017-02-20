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
             (fibers channels)
             (ice-9 binary-ports)
             (ice-9 textual-ports)
             (ice-9 rdelim)
             (ice-9 match))

(define (connect-to-server addrinfo)
  (let ((port (socket (addrinfo:fam addrinfo)
                      (addrinfo:socktype addrinfo)
                      (addrinfo:protocol addrinfo))))
    ;; Disable Nagle's algorithm.  We buffer ourselves.
    (setsockopt port IPPROTO_TCP TCP_NODELAY 1)
    (fcntl port F_SETFL (logior O_NONBLOCK (fcntl port F_GETFL)))
    (setvbuf port 'block 1024)
    (connect port (addrinfo:addr addrinfo))
    port))

(define (client-loop addrinfo n num-connections)
  (let ((port (connect-to-server addrinfo))
        (test (string-append "test-" (number->string n))))
    (let lp ((m 0))
      (when (< m num-connections)
        (put-string port test)
        (put-char port #\newline)
        (force-output port)
        (let ((response (read-line port)))
          (unless (equal? test response)
            (close-port port)
            (error "Bad response: ~A (expected ~A)" response test))
          (lp (1+ m)))))
    (close-port port)))

(define (run-ping-test num-clients num-connections)
  ;; The getaddrinfo call blocks, unfortunately.  Call it once before
  ;; spawning clients.
  (let ((addrinfo (car (getaddrinfo "localhost" (number->string 11211)))))
    (map get-message
         (map (lambda (n)
                (let ((ch (make-channel)))
                  (spawn-fiber
                   (lambda ()
                     (client-loop addrinfo n num-connections)
                     (put-message ch 'done))
                   #:parallel? #t)
                  ch))
              (iota num-clients)))))

(run-fibers
 (lambda ()
   (apply run-ping-test (map string->number (cdr (program-arguments))))))
