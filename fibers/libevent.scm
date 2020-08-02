(define-module (fibers libevent)
    #:use-module ((ice-9 binary-ports) #:select (get-u8 put-u8))
    #:use-module (ice-9 atomic)
    #:use-module (ice-9 control)
    #:use-module (ice-9 match)
    #:use-module (srfi srfi-9)
    #:use-module (srfi srfi-9 gnu)
    #:use-module (rnrs bytevectors)
    #:use-module (fibers config)
    #:export (libevt-create
              libevt-destroy
              libevt?
              libevt-add!
              libevt-wake!
              libevt
              EVREAD EVWRITE EVERR))

(eval-when (eval load compile)
  (dynamic-call "init_libevt"
                (dynamic-link (extension-library "fibers-libevent"))))


(when (defined? 'EVREAD)
  (export EVREAD))
(when (defined? 'EVWRITE)
  (export EVWRITE))

(define EVERR (logior EVREAD EVWRITE))

(define (make-wake-pipe)
  (define (set-nonblocking! port)
    (fcntl port F_SETFL (logior O_NONBLOCK (fcntl port F_GETFL))))
  (let ((pair (pipe)))
    (match pair
      ((read-pipe . write-pipe)
       (setvbuf write-pipe 'none)
       (set-nonblocking! read-pipe)
       (set-nonblocking! write-pipe)
       (values read-pipe write-pipe)))))

(define-record-type <libevt>
  (make-libevt ls eventsv maxevents state wake-read-pipe wake-write-pipe)
  libevt?
  (ls libevt-ls set-libevt-ls!)
  (eventsv libevt-eventsv set-libevt-eventsv!)
  (maxevents libevt-maxevents set-libevt-maxevents!)
  ;; atomic box of either 'waiting, 'not-waiting or 'dead
  (state libevt-state)
  (wake-read-pipe libevt-wake-read-pipe)
  (wake-write-pipe libevt-wake-write-pipe))

(define-syntax fd-offset
  (lambda (x)
    (syntax-case x ()
      ((_ n)
       #`(* n #,%sizeof-struct-event)))))

(define-syntax event-offset
  (lambda (x)
    (syntax-case x ()
      ((_ n)
       #`(+ (* n #,%sizeof-struct-event)
            #,%offsetof-struct-event-ev)))))

(define libevt-guardian (make-guardian))
(define (pump-libevt-guardian)
  (let ((libevt (libevt-guardian)))
    (when libevt
      (libevt-destroy libevt)
      (pump-libevt-guardian))))
(add-hook! after-gc-hook pump-libevt-guardian)

(define* (libevt-create #:key (maxevents 8))
  (call-with-values (lambda () (make-wake-pipe))
    (lambda (read-pipe write-pipe)
      (let* ((state (make-atomic-box 'not-waiting))
             (eventsv (make-bytevector (fd-offset (or maxevents 8))))
             (libevt (make-libevt (primitive-create-event-base eventsv)
                                  eventsv maxevents state read-pipe write-pipe)))
        (libevt-guardian libevt)
        (libevt-add! libevt (fileno read-pipe) (logior EVREAD EVPERSIST))
        libevt))))

(define (libevt-destroy libevt)
  (atomic-box-set! (libevt-state libevt) 'dead)
  (when (libevt-ls libevt)
    (close-port (libevt-wake-read-pipe libevt))
    ;; FIXME: ignore errors flushing output
    (close-port (libevt-wake-write-pipe libevt))
    (set-libevt-ls! libevt '())))

(define* (libevt-add! libevt fd events)
  (primitive-add-event (libevt-ls libevt) fd events))

(define (libevt-wake! libevt)
  (match (atomic-box-ref (libevt-state libevt))
    ;; It is always correct to wake an epoll via the pipe.  However we
    ;; can avoid it if the epoll is guaranteed to see that the
    ;; runqueue is not empty before it goes to poll next time.
    ('waiting
     (primitive-event-wake (fileno (libevt-wake-write-pipe libevt))))
    ('not-waiting #t)
    ('dead (error "libevt instance is dead"))))

(define (libevt-default-folder fd events seed)
  (acons fd events seed))

(define* (libevt libevt #:key (expiry #f)
                 (update-expiry (lambda (expiry) expiry))
                 (folder libevt-default-folder)
                 (seed '()))
  (define (expiry->timeout expiry)
    (cond
     ((not expiry) -1)
     (else
      (let ((now (get-internal-real-time)))
        (cond
         ((< expiry now) 0)
         (else (- expiry now)))))))
  (let* ((maxevents (libevt-maxevents libevt))
         (eventsv (libevt-eventsv libevt))
         (write-pipe-fd (fileno (libevt-wake-write-pipe libevt)))
         (read-pipe-fd (fileno (libevt-wake-read-pipe libevt))))
    (atomic-box-set! (libevt-state libevt) 'waiting)
    (let* ((timeout (expiry->timeout (update-expiry expiry)))
           (n (primitive-event-loop (libevt-ls libevt)
                                    write-pipe-fd read-pipe-fd timeout)))
      (let lp ((seed seed) (i 0))
        (if (< i n)
            (let ((fd (bytevector-s32-native-ref eventsv (fd-offset i)))
                  (events (bytevector-s32-native-ref eventsv (event-offset i))))
              (lp (folder fd events seed) (+ 1 i)))
            seed)))))
