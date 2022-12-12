;;; Simple memcached server implementation

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
;; You should have received a copy of the GNU Lesser General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

(use-modules (rnrs bytevectors)
             (fibers)
             (ice-9 binary-ports)
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

(define (client-error port msg . args)
  (close-port port)
  (apply error msg args))

(define (parse-int port val)
  (let ((num (string->number val)))
    (unless (and num (integer? num) (exact? num) (>= num 0))
      (client-error port "Expected a non-negative integer: ~s" val))
    num))

(define (make-item flags bv)
  (vector flags bv))
(define (item-flags item)
  (vector-ref item 0))
(define (item-bv item)
  (vector-ref item 1))

(define *commands* (make-hash-table))

(define-syntax-rule (define-command (name port store . pat)
                      body body* ...)
  (begin
    (define (name port store args)
      (match args
        (pat body body* ...)
        (else
         (client-error port "Bad line: ~A ~S" 'name (string-join args " ")))))
    (hashq-set! *commands* 'name name)))

(define-command (get port store key* ...)
  (let lp ((key* key*))
    (match key*
      ((key key* ...)
       (let ((item (hash-ref store key)))
         (when item
           (put-string port "VALUE ")
           (put-string port key)
           (put-char port #\space)
           (put-string port (number->string (item-flags item)))
           (put-char port #\space)
           (put-string port (number->string
                              (bytevector-length (item-bv item))))
           (put-char port #\return)
           (put-char port #\newline)
           (put-bytevector port (item-bv item))
           (put-string port "\r\n"))
         (lp key*)))
      (()
       (put-string port "END\r\n")))))

(define-command (set port store key flags exptime bytes
                     . (and noreply (or ("noreply") ())))
  (let* ((flags (parse-int port flags))
         (exptime (parse-int port exptime))
         (bytes (parse-int port bytes)))
    (let ((bv (get-bytevector-n port bytes)))
      (unless (= (bytevector-length bv) bytes)
        (client-error port "Tried to read ~A bytes, only read ~A"
                      bytes (bytevector-length bv)))
      (hash-set! store key (make-item flags bv))
      (when (eqv? (peek-char port) #\return)
        (read-char port))
      (when (eqv? (peek-char port) #\newline)
        (read-char port)))
    (put-string port "STORED\r\n")))

(define (client-loop port addr store)
  ;; Disable Nagle's algorithm.  We buffer ourselves.
  (setsockopt port IPPROTO_TCP TCP_NODELAY 1)
  (setvbuf port 'block 1024)
  (let loop ()
    ;; TODO: Restrict read-line to 512 chars.
    (let ((line (read-line port)))
      (cond
       ((eof-object? line)
        (close-port port))
       (else
        (match (string-split (string-trim-right line) #\space)
          ((verb . args)
           (let ((proc (hashq-ref *commands* (string->symbol verb))))
             (unless proc
               (client-error port "Bad command: ~a" verb))
             (proc port store args)
             (force-output port)
             (loop)))
          (else (client-error port "Bad command line" line))))))))

(define (socket-loop socket store)
  (let loop ()
    (match (accept socket SOCK_NONBLOCK)
      ((client . addr)
       (spawn-fiber
        (lambda () (client-loop client addr store))
        #:parallel? #t)
       (loop)))))

(define* (run-memcached #:key
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

;; Have to restrict parallelism as long as we are using a
;; thread-unsafe hash table as the store!
(run-fibers run-memcached #:parallelism 1)
