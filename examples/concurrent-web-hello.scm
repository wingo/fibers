(use-modules (http request)
             (fibers web server))

(define (handler request)
  (let ((body (read-request-body request)))
    (values '((content-type . (text/plain)))
            "Hello, World!")))

(run-server handler)
