;;; Simple memcached client implementation

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

(define (parse-int port val)
  (let ((num (string->number val)))
    (unless (and num (integer? num) (exact? num) (>= num 0))
      (server-error port "Expected a non-negative integer: ~s" val))
    num))

(define (make-item flags bv)
  (vector flags bv))
(define (item-flags item)
  (vector-ref item 0))
(define (item-bv item)
  (vector-ref item 1))

(define (get port . keys)
  (put-string port "get ")
  (put-string port (string-join keys " "))
  (put-string port "\r\n")
  (force-output port)
  (let lp ((vals '()))
    (let ((line (read-line port)))
      (when (eof-object? line)
        (server-error port "Expected a response to 'get', got EOF"))
      (match (string-split (string-trim-right line) #\space)
        (("VALUE" key flags length)
         (let* ((flags (parse-int port flags))
                (length (parse-int port length)))
           (unless (member key keys)
             (server-error port "Unknown key: ~a" key))
           (when (assoc key vals)
             (server-error port "Already have response for key: ~a" key))
           (let ((bv (get-bytevector-n port length)))
             (unless (= (bytevector-length bv) length)
               (server-error port "Expected ~A bytes, got ~A" length bv))
             (when (eqv? (peek-char port) #\return)
               (read-char port))
             (unless (eqv? (read-char port) #\newline)
               (server-error port "Expected \\n"))
             (lp (acons key (make-item flags bv) vals)))))
        (("END")
         (reverse vals))
        (_
         (server-error port "Bad line: ~A" line))))))

(define* (set port key flags exptime bytes #:key noreply?)
  (put-string port "set ")
  (put-string port key)
  (put-char port #\space)
  (put-string port (number->string flags))
  (put-char port #\space)
  (put-string port (number->string exptime))
  (put-char port #\space)
  (put-string port (number->string (bytevector-length bytes)))
  (when noreply?
    (put-string port " noreply"))
  (put-string port "\r\n")
  (put-bytevector port bytes)
  (put-string port "\r\n")
  (force-output port)
  (let ((line (read-line port)))
    (match line
      ((? eof-object?)
       (server-error port "EOF while expecting response from server"))
      ("STORED\r" #t)
      ("NOT_STORED\r" #t)
      (_
       (server-error port "Unexpected response from server: ~A" line)))))

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
        (key (string-append "test-" (number->string n))))
    (let lp ((m 0))
      (when (< m num-connections)
        (let ((v (string->utf8 (number->string m))))
          (set port key 0 0 v)
          (let* ((response (get port key))
                 (item (assoc-ref response key)))
            (unless item
              (server-error port "Not found: ~A" key))
            (unless (equal? (item-bv item) v)
              (server-error port "Bad response: ~A (expected ~A)" (item-bv item) v))
            (lp (1+ m))))))
    (close-port port))
  (set! *active-clients* (1- *active-clients*))
  (when (zero? *active-clients*)
    (exit 0)))

(define (run-memcached-test num-clients num-connections)
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

(apply run-memcached-test (map string->number (cdr (program-arguments))))
