(use-modules (fibers web server))

(define (handler request body)
  (values '((content-type . (text/plain)))
          "Hello, World!"))

(run-server handler)
