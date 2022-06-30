;; Fibers: cooperative, event-driven user-space threads.

;;;; Copyright (C) 2016 Free Software Foundation, Inc.
;;;; Copyright (C) 2022 Christopher Baines <mail@cbaines.net>
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

(define-module (tests concurrent-web-server)
  #:use-module (ice-9 match)
  #:use-module (ice-9 threads)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 binary-ports)
  #:use-module (rnrs bytevectors)
  #:use-module (web uri)
  #:use-module (web http)
  #:use-module (web client)
  #:use-module (web request)
  #:use-module (web response)
  #:use-module (fibers web server))

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

(define port 8080)

(define (handler request body)
  (match (uri-path (request-uri request))
    ("/"
     (values '((content-type . (text/plain)))
             "Hello, World!"))
    ("/proc"
     (let ((bv
            (uint-list->bytevector (iota 10000)
                                   (endianness little)
                                   4)))
       (values `((content-type   . (application/octet-stream))
                 (content-length . ,(bytevector-length bv)))
               (lambda (port)
                 (put-bytevector port bv)))))
    ("/proc-chunked"
     (values `((content-type   . (application/octet-stream)))
             (lambda (port)
               (put-bytevector
                port
                (uint-list->bytevector (iota 10000)
                                       (endianness little)
                                       4)))))))

(call-with-new-thread
 (lambda ()
   (run-server handler #:port 8080)))

(call-with-values
    (lambda ()
      (http-get (string->uri "http://127.0.0.1:8080/proc")
                #:decode-body? #f))
  (lambda (response body)
    (let ((data
           (bytevector->uint-list body
                                  (endianness little)
                                  4)))
      (assert-equal 10000
                    (length data)))))

(call-with-values
    (lambda ()
      (http-get (string->uri "http://127.0.0.1:8080/proc-chunked")
                #:decode-body? #f
                #:streaming? #t))
  (lambda (response body)
    (let ((data
           (bytevector->uint-list
            (get-bytevector-all body)
            (endianness little)
            4)))
      (assert-equal 10000
                    (length data)))))

(exit (if failed? 1 0))
