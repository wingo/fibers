;;; Fibers web server

;; Copyright (C)  2010-2013,2015,2017 Free Software Foundation, Inc.

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

;;; Commentary:
;;;
;;; (web server) is a web server implementation using Fibers.  Unlike
;;; the standard Guile web server implementation which threads all
;;; handler calls through a single thread, this implementation
;;; allows multiple concurrent handler threads.
;;;
;;; Code:

(define-module (fibers web server)
  #:use-module (fibers)
  #:use-module (fibers conditions)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 iconv)
  #:use-module (ice-9 match)
  #:use-module ((srfi srfi-9 gnu) #:select (set-field))
  #:use-module (system repl error-handling)
  #:use-module (web http)
  #:use-module (web request)
  #:use-module (web response)
  #:export (run-server))

(define (set-nonblocking! port)
  (fcntl port F_SETFL (logior O_NONBLOCK (fcntl port F_GETFL)))
  (setvbuf port 'block 1024))

(define (make-default-socket family addr port)
  (let ((sock (socket PF_INET SOCK_STREAM 0)))
    (setsockopt sock SOL_SOCKET SO_REUSEADDR 1)
    (fcntl sock F_SETFD FD_CLOEXEC)
    (bind sock family addr port)
    (set-nonblocking! sock)
    sock))

(define (extend-response r k v . additional)
  (define (extend-alist alist k v)
    (let ((pair (assq k alist)))
      (acons k v (if pair (delq pair alist) alist))))
  (let ((r (set-field r (response-headers)
                      (extend-alist (response-headers r) k v))))
    (if (null? additional)
        r
        (apply extend-response r additional))))

;; -> response body
(define (sanitize-response request response body)
  "\"Sanitize\" the given response and body, making them appropriate for
the given request.

As a convenience to web handler authors, RESPONSE may be given as
an alist of headers, in which case it is used to construct a default
response.  Ensures that the response version corresponds to the request
version.  If BODY is a string, encodes the string to a bytevector,
in an encoding appropriate for RESPONSE.  Adds a
‘content-length’ and ‘content-type’ header, as necessary.

If BODY is a procedure, it is called with a port as an argument,
and the output collected as a bytevector.  In the future we might try to
instead use a compressing, chunk-encoded port, and call this procedure
later, in the write-client procedure.  Authors are advised not to rely
on the procedure being called at any particular time."
  (cond
   ((list? response)
    (sanitize-response request
                       (build-response #:version (request-version request)
                                       #:headers response)
                       body))
   ((not (equal? (request-version request) (response-version response)))
    (sanitize-response request
                       (adapt-response-version response
                                               (request-version request))
                       body))
   ((not body)
    (values response #vu8()))
   ((string? body)
    (let* ((type (response-content-type response
                                        '(text/plain)))
           (declared-charset (assq-ref (cdr type) 'charset))
           (charset (or declared-charset "utf-8")))
      (sanitize-response
       request
       (if declared-charset
           response
           (extend-response response 'content-type
                            `(,@type (charset . ,charset))))
       (string->bytevector body charset))))
   ((not (or (bytevector? body)
             (procedure? body)))
    (error "unexpected body type"))
   ((and (response-must-not-include-body? response)
         body
         ;; FIXME make this stricter: even an empty body should be prohibited.
         (not (zero? (bytevector-length body))))
    (error "response with this status code must not include body" response))
   (else
    ;; check length; assert type; add other required fields?
    (values (if (procedure? body)
                (if (response-content-length response)
                    response
                    (extend-response response
                                     'transfer-encoding
                                     '((chunked))))
                (let ((rlen (response-content-length response))
                      (blen (bytevector-length body)))
                  (cond
                   (rlen (if (= rlen blen)
                             response
                             (error "bad content-length" rlen blen)))
                   (else (extend-response response 'content-length blen)))))
            (if (eq? (request-method request) 'HEAD)
                ;; Responses to HEAD requests must not include bodies.
                ;; We could raise an error here, but it seems more
                ;; appropriate to just do something sensible.
                #f
                body)))))

(define (with-stack-and-prompt thunk)
  (call-with-prompt (default-prompt-tag)
                    (lambda () (start-stack #t (thunk)))
                    (lambda (k proc)
                      (with-stack-and-prompt (lambda () (proc k))))))

;; -> response body
(define (handle-request handler request body)
  (cond
   ((not request)
    ;; Bad request.
    (values (build-response #:version '(1 . 0) #:code 400
                            #:headers '((content-length . 0)))
            #vu8()))
   (else
    (call-with-error-handling
      (lambda ()
        (call-with-values (lambda ()
                            (with-stack-and-prompt
                             (lambda ()
                               (handler request body))))
          (lambda (response body)
            (sanitize-response request response body))))
      #:on-error 'backtrace
      #:post-error (lambda _
                     (values (build-response #:code 500) #f))))))

(define (keep-alive? response)
  (let ((v (response-version response)))
    (and (or (< (response-code response) 400)
             (= (response-code response) 404))
         (case (car v)
           ((1)
            (case (cdr v)
              ((1) (not (memq 'close (response-connection response))))
              ((0) (memq 'keep-alive (response-connection response)))))
           (else #f)))))

(define (client-loop client handler)
  ;; Always disable Nagle's algorithm, as we handle buffering
  ;; ourselves; when we force-output, we really want the data to go
  ;; out.
  (setvbuf client 'block 1024)
  (setsockopt client IPPROTO_TCP TCP_NODELAY 1)
  (with-throw-handler #t
    (lambda ()
      (let loop ()
        (cond
         ((catch #t
            (lambda () (eof-object? (lookahead-u8 client)))
            (lambda _ #t))
          (close-port client))
         (else
          (call-with-values
              (lambda ()
                (catch #t
                  (lambda ()
                    (let* ((request (read-request client))
                           (body (read-request-body request)))
                      (values request body)))
                  (lambda (key . args)
                    (display "While reading request:\n" (current-error-port))
                    (print-exception (current-error-port) #f key args)
                    (values #f #f))))
            (lambda (request body)
              (call-with-values (lambda ()
                                  (handle-request handler request body))
                (lambda (response body)
                  (write-response response client)
                  (when body
                    (if (procedure? body)
                        (if (response-content-length response)
                            (body client)
                            (let ((chunked-port
                                   (make-chunked-output-port client
                                                             #:keep-alive? #t)))
                              (body chunked-port)
                              (close-port chunked-port)))
                        (put-bytevector client body)))
                  (force-output client)
                  (if (keep-alive? response)
                      (loop)
                      (close-port client))))))))))
    (lambda (k . args)
      (close-port client))))

(define (socket-loop socket handler)
  (let loop ()
    (match (accept socket (logior SOCK_NONBLOCK SOCK_CLOEXEC))
      ((client . sockaddr)
       (spawn-fiber (lambda ()
                      (client-loop client handler))
                    #:parallel? #t)
       (loop)))))

(define (call-with-sigint thunk cvar)
  (let ((handler #f))
    (dynamic-wind
      (lambda ()
        (set! handler
          (sigaction SIGINT (lambda (sig) (signal-condition! cvar)))))
      thunk
      (lambda ()
        (if handler
            ;; restore Scheme handler, SIG_IGN or SIG_DFL.
            (sigaction SIGINT (car handler) (cdr handler))
            ;; restore original C handler.
            (sigaction SIGINT #f))))))

(define* (run-server handler #:key
                     (host #f)
                     (family AF_INET)
                     (addr (if host
                               (inet-pton family host)
                               INADDR_LOOPBACK))
                     (port 8080)
                     (socket (make-default-socket family addr port)))
  "Run the fibers web server.

HANDLER should be a procedure that takes two arguments, the HTTP request
and request body, and returns two values, the response and response
body.

For example, here is a simple \"Hello, World!\" server:

@example
 (define (handler request body)
   (values '((content-type . (text/plain)))
           \"Hello, World!\"))
 (run-server handler)
@end example

The response and body will be run through ‘sanitize-response’
before sending back to the client."
  ;; We use a large backlog by default.  If the server is suddenly hit
  ;; with a number of connections on a small backlog, clients won't
  ;; receive confirmation for their SYN, leading them to retry --
  ;; probably successfully, but with a large latency.
  (listen socket 1024)
  (set-nonblocking! socket)
  (sigaction SIGPIPE SIG_IGN)
  (let ((finished? (make-condition)))
    (call-with-sigint
     (lambda ()
       (run-fibers
        (lambda ()
          (spawn-fiber (lambda () (socket-loop socket handler)))
          (wait finished?))))
     finished?)))
