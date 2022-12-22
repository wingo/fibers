;;; Simple ping server implementation

;; Copyright (C)  2016 Free Software Foundation, Inc.

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
;; You should have received a copy of the GNU Lesser General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

(use-modules (rnrs bytevectors)
             (fibers)
             (ice-9 textual-ports)
             (ice-9 rdelim)
             (ice-9 match))

(define (make-default-socket family addr port)
  (let ((sock (socket PF_INET SOCK_STREAM 0)))
    (setsockopt sock SOL_SOCKET SO_REUSEADDR 1)
    (fcntl sock F_SETFD FD_CLOEXEC)
    (bind sock family addr port)
    (fcntl sock F_SETFL (logior O_NONBLOCK (fcntl sock F_GETFL)))
    sock))

(define (client-loop port addr store)
  (setvbuf port 'block 1024)
  ;; Disable Nagle's algorithm.  We buffer ourselves.
  (setsockopt port IPPROTO_TCP TCP_NODELAY 1)
  (let loop ()
    ;; TODO: Restrict read-line to 512 chars.
    (let ((line (read-line port)))
      (cond
       ((eof-object? line)
        (close-port port))
       (else
        (put-string port line)
        (put-char port #\newline)
        (force-output port)
        (loop))))))

(define (socket-loop socket store)
  (let loop ()
    (match (accept socket SOCK_NONBLOCK)
      ((client . addr)
       (spawn-fiber (lambda () (client-loop client addr store))
                    #:parallel? #t)
       (loop)))))

(define* (run-ping-server #:key
                          (host #f)
                          (family AF_INET)
                          (addr (if host
                                    (inet-pton family host)
                                    INADDR_LOOPBACK))
                          (port 11211)
                          (socket (make-default-socket family addr port)))
  (listen socket 1024)
  (sigaction SIGPIPE SIG_IGN)
  (socket-loop socket (make-hash-table)))

(run-fibers run-ping-server)
