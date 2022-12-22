;; Fibers: cooperative, event-driven user-space threads.

;;;; Copyright (C) 2022 Ludovic Courtès <ludo@gnu.org>
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
;;;; You should have received a copy of the GNU Lesser General Public License
;;;; along with this program.  If not, see <http://www.gnu.org/licenses/>.
;;;;

(define-module (tests ports)
  #:use-module (fibers)
  #:use-module (fibers channels)
  #:use-module (fibers scheduler)
  #:use-module (ice-9 match)
  #:use-module (ice-9 rdelim)
  #:use-module ((ice-9 ports internal)
                #:select (port-read-wait-fd)))

(define* (bind* sock address)
  ;; Like 'bind', but retry upon EADDRINUSE.
  (let loop ((n 5))
    (define result
      (catch 'system-error
        (lambda ()
          (bind sock address))
        (lambda args
          (if (and (= EADDRINUSE (system-error-errno args))
                   (> n 0))
              'in-use
              (apply throw args)))))

    (when (eq? result 'in-use)
      (sleep 1)
      (loop (- n 1)))))


(run-fibers
 (lambda ()
   (let* ((address (make-socket-address AF_INET INADDR_LOOPBACK 5556))
          (notification (make-channel)))
     (spawn-fiber
      (lambda ()
        ;; The server.
        (let loop ((n 5))
          ;; Create a socket; the underlying file descriptor has the same
          ;; value for each iteration.  What we're checking here is that the
          ;; waiter list and epoll set are properly updated when a file
          ;; descriptor with the same value is reused, allowing the eventual
          ;; 'accept' call to succeed.
          (let ((sock (socket AF_INET (logior SOCK_NONBLOCK SOCK_STREAM)
                              0)))
            (pk 'listening-socket sock)
            (setsockopt sock SOL_SOCKET SO_REUSEADDR 1)
            (bind* sock address)
            (listen sock 1)

            (if (zero? n)
                (begin
                  ;; Let's go.
                  (put-message notification 'ready!)
                  (match (pk 'accepted-connection (accept sock SOCK_NONBLOCK))
                    ((connection . _)
                     (display (pk 'received (read-line connection)) connection)
                     (newline connection)
                     (close-port connection))))
                (begin
                  ;; Spawn a fiber and have it wait on SOCK.  Then
                  ;; immediately close SOCK.  The next loop iteration creates
                  ;; a new file descriptor with the same value.
                  (spawn-fiber
                   (lambda ()
                     (suspend-current-task
                      (lambda (sched k)
                        (schedule-task-when-fd-readable sched
                                                        (port-read-wait-fd sock)
                                                        k)
                        (close-port sock)))))
                  (loop (- n 1))))))))

     (spawn-fiber
      (lambda ()
        ;; Watchdog: bail out after some time has passed.
        (sleep 30)
        (display "timeout!\n" (current-error-port))
        (primitive-_exit 1)))

     ;; Wait for the server to be ready.
     (match (get-message notification)
       ('ready!
        ;; Connect, send a message, and receive its echo.
        (let ((sock (socket AF_INET (logior SOCK_NONBLOCK SOCK_STREAM)
                            0)))
          (connect sock address)
          (pk 'connected address)
          (display "hello!\n" sock)
          (match (pk 'echo (read-line sock))
            ("hello!"
             (close-port sock)
             (display "success\n" (current-error-port)))))))))

 #:hz 0                                           ;cooperative scheduling
 #:parallelism 1)                                 ;single-threaded
