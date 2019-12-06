;; Channels

;;;; Copyright (C) 2016 Andy Wingo <wingo@pobox.com>
;;;; Copyright (C) 2017 Christopher Allan Webber <cwebber@dustycloud.org>
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

;;; Channel implementation following the 2009 ICFP paper "Parallel
;;; Concurrent ML" by John Reppy, Claudio V. Russo, and Yingqui Xiao.
;;;
;;; Besides the general ways in which this implementation differs from
;;; the paper, this channel implementation avoids locks entirely.
;;; Still, we should disable interrupts while any operation is in a
;;; "claimed" state to avoid excess latency due to pre-emption.  It
;;; would be great if we could verify our protocol though; the
;;; parallel channel operations are still gnarly.

(define-module (fibers channels)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 match)
  #:use-module (fibers counter)
  #:use-module (fibers deque)
  #:use-module (fibers operations)
  #:export (make-channel
            channel?
            put-operation
            get-operation
            put-message
            get-message))

(define-record-type <channel>
  (%make-channel getq getq-gc-counter putq putq-gc-counter)
  channel?
  ;; atomic box of deque
  (getq channel-getq)
  (getq-gc-counter channel-getq-gc-counter)
  ;; atomic box of deque
  (putq channel-putq)
  (putq-gc-counter channel-putq-gc-counter))

(define (make-channel)
  "Make a fresh channel."
  (%make-channel (make-atomic-box (make-empty-deque))
                 (make-counter)
                 (make-atomic-box (make-empty-deque))
                 (make-counter)))

(define (put-operation channel message)
  "Make an operation that if and when it completes will rendezvous
with a receiver fiber to send @var{message} over @var{channel}."
  (match channel
    (($ <channel> getq-box getq-gc-counter putq-box putq-gc-counter)
     (define (try-fn)
       ;; Try to find and perform a pending get operation.  If that
       ;; works, return a result thunk, or otherwise #f.
       (let try ((getq (atomic-box-ref getq-box)))
         (call-with-values (lambda () (dequeue getq))
           (lambda (getq* item)
             (define (maybe-commit)
               ;; Try to update getq.  Return the new getq value in
               ;; any case.
               (let ((q (atomic-box-compare-and-swap! getq-box getq getq*)))
                 (if (eq? q getq) getq* q)))
             ;; Return #f if the getq was empty.
             (and getq*
                  (match item
                    (#(get-flag resume-get)
                     (let spin ()
                       (match (atomic-box-compare-and-swap! get-flag 'W 'S)
                         ('W
                          ;; Success.  Commit the dequeue operation,
                          ;; unless the getq changed in the
                          ;; meantime.  If we don't manage to commit
                          ;; the dequeue, some other put operation will
                          ;; commit it before it successfully
                          ;; performs any other operation on this
                          ;; channel.
                          (maybe-commit)
                          (resume-get (lambda () message))
                          ;; Continue directly.
                          (lambda () (values)))
                         ;; Get operation temporarily busy; try again.
                         ('C (spin))
                         ;; Get operation already performed; pop it
                         ;; off the getq (if we can) and try again.
                         ;; If we fail to commit, no big deal, we will
                         ;; try again next time if no other fiber
                         ;; handled it already.
                         ('S (try (maybe-commit))))))))))))
     (define (block-fn put-flag put-sched resume-put)
       ;; We have suspended the current fiber; arrange for the fiber
       ;; to be resumed by a get operation by adding it to the channel's
       ;; putq.
       (define (not-me? item)
         (match item
           (#(get-flag resume-get)
            (not (eq? put-flag get-flag)))))
       ;; First, publish this put operation.
       (enqueue! putq-box (vector put-flag resume-put message))
       ;; Next, possibly clear off any garbage from queue.
       (when (= (counter-decrement! putq-gc-counter) 0)
         (dequeue-filter! putq-box
                          (match-lambda
                            (#(flag resume)
                             (not (eq? (atomic-box-ref flag) 'S)))))
         (counter-reset! putq-gc-counter))
       ;; In the try phase, we scanned the getq for a get operation,
       ;; but we were unable to perform any of them.  Since then,
       ;; there might be a new get operation on the queue.  However
       ;; only get operations published *after* we publish our put
       ;; operation to the putq are responsible for trying to complete
       ;; this put operation; we are responsible for get operations
       ;; published before we published our put.  Therefore, here we
       ;; visit the getq again.  This is like the "try" phase, but
       ;; with the difference that we've published our op state flag
       ;; to the queue, so other fibers might be racing to synchronize
       ;; on our own op.
       (let service-get-ops ((getq (atomic-box-ref getq-box)))
         (call-with-values (lambda () (dequeue-match getq not-me?))
           (lambda (getq* item)
             (define (maybe-commit)
               ;; Try to update getq.  Return the new getq value in
               ;; any case.
               (let ((q (atomic-box-compare-and-swap! getq-box getq getq*)))
                 (if (eq? q getq) getq* q)))
             ;; We only have to service the getq if it is non-empty.
             (when getq*
               (match item
                 (#(get-flag resume-get)
                  (match (atomic-box-ref get-flag)
                    ('S
                     ;; This get operation has already synchronized;
                     ;; try to commit and  operation and in any
                     ;; case try again.
                     (service-get-ops (maybe-commit)))
                    (_
                     (let spin ()
                       (match (atomic-box-compare-and-swap! put-flag 'W 'C)
                         ('W
                          ;; We were able to claim our op.  Now try to
                          ;; synchronize on a get operation as well.
                          (match (atomic-box-compare-and-swap! get-flag 'W 'S)
                            ('W
                             ;; It worked!  Mark our own op as
                             ;; synchronized, try to commit the result
                             ;; getq, and resume both fibers.
                             (atomic-box-set! put-flag 'S)
                             (maybe-commit)
                             (resume-get (lambda () message))
                             (resume-put values)
                             (values))
                            ('C
                             ;; Other fiber trying to do the same
                             ;; thing we are; reset our state and try
                             ;; again.
                             (atomic-box-set! put-flag 'W)
                             (spin))
                            ('S
                             ;; Other op already synchronized.  Reset
                             ;; our flag, try to remove this dead
                             ;; entry from the getq, and give it
                             ;; another go.
                             (atomic-box-set! put-flag 'W)
                             (service-get-ops (maybe-commit)))))
                         (_
                          ;; Claiming our own op failed; this can only
                          ;; mean that some other fiber completed our
                          ;; op for us.
                          (values)))))))))))))
     (make-base-operation #f try-fn block-fn))))

(define (get-operation channel)
  "Make an operation that if and when it completes will rendezvous
with a sender fiber to receive one value from @var{channel}."
  (match channel
    (($ <channel> getq-box getq-gc-counter putq-box putq-gc-counter)
     (define (try-fn)
       ;; Try to find and perform a pending put operation.  If that
       ;; works, return a result thunk, or otherwise #f.
       (let try ((putq (atomic-box-ref putq-box)))
         (call-with-values (lambda () (dequeue putq))
           (lambda (putq* item)
             (define (maybe-commit)
               ;; Try to update putq.  Return the new putq value in
               ;; any case.
               (let ((q (atomic-box-compare-and-swap! putq-box putq putq*)))
                 (if (eq? q putq) putq* q)))
             ;; Return #f if the putq was empty.
             (and putq*
                  (match item
                    (#(put-flag resume-put message)
                     (let spin ()
                       (match (atomic-box-compare-and-swap! put-flag 'W 'S)
                         ('W
                          ;; Success.  Commit the fresh putq if we
                          ;; can.  If we don't manage to commit right
                          ;; now, some other get operation will commit
                          ;; it before synchronizing any other
                          ;; operation on this channel.
                          (maybe-commit)
                          (resume-put values)
                          ;; Continue directly.
                          (lambda () message))
                         ;; Put operation temporarily busy; try again.
                         ('C (spin))
                         ;; Put operation already synchronized; pop it
                         ;; off the putq (if we can) and try again.
                         ;; If we fail to commit, no big deal, we will
                         ;; try again next time if no other fiber
                         ;; handled it already.
                         ('S (try (maybe-commit))))))))))))
     (define (block-fn get-flag get-sched resume-get)
       ;; We have suspended the current fiber; arrange for the fiber
       ;; to be resumed by a put operation by adding it to the
       ;; channel's getq.
       (define (not-me? item)
         (match item
           (#(put-flag resume-put message)
            (not (eq? get-flag put-flag)))))
       ;; First, publish this get operation.
       (enqueue! getq-box (vector get-flag resume-get))
       ;; Next, possibly clear off any garbage from queue.
       (when (= (counter-decrement! getq-gc-counter) 0)
         (dequeue-filter! getq-box
                          (match-lambda
                            (#(flag resume)
                             (not (eq? (atomic-box-ref flag) 'S)))))
         (counter-reset! getq-gc-counter))
       ;; In the try phase, we scanned the putq for a live put
       ;; operation, but we were unable to synchronize.  Since then,
       ;; there might be a new operation on the putq.  However only
       ;; put operations published *after* we publish our get
       ;; operation to the getq are responsible for trying to complete
       ;; this get operation; we are responsible for put operations
       ;; published before we published our get.  Therefore, here we
       ;; visit the putq again.  This is like the "try" phase, but
       ;; with the difference that we've published our op state flag
       ;; to the getq, so other fibers might be racing to synchronize
       ;; on our own op.
       (let service-put-ops ((putq (atomic-box-ref putq-box)))
         (call-with-values (lambda () (dequeue-match putq not-me?))
           (lambda (putq* item)
             (define (maybe-commit)
               ;; Try to update putq.  Return the new putq value in
               ;; any case.
               (let ((q (atomic-box-compare-and-swap! putq-box putq putq*)))
                 (if (eq? q putq) putq* q)))
             ;; We only have to service the putq if it is non-empty.
             (when putq*
               (match item
                 (#(put-flag resume-put message)
                  (match (atomic-box-ref put-flag)
                    ('S
                     ;; This put operation has already synchronized;
                     ;; try to commit the dequeue operation and in any
                     ;; case try again.
                     (service-put-ops (maybe-commit)))
                    (_
                     (let spin ()
                       (match (atomic-box-compare-and-swap! get-flag 'W 'C)
                         ('W
                          ;; We were able to claim our op.  Now try
                          ;; to synchronize on a put operation as well.
                          (match (atomic-box-compare-and-swap! put-flag 'W 'S)
                            ('W
                             ;; It worked!  Mark our own op as
                             ;; synchronized, try to commit the put
                             ;; dequeue operation, and mark both
                             ;; fibers for resumption.
                             (atomic-box-set! get-flag 'S)
                             (maybe-commit)
                             (resume-get (lambda () message))
                             (resume-put values)
                             (values))
                            ('C
                             ;; Other fiber trying to do the same
                             ;; thing we are; reset our state and try
                             ;; again.
                             (atomic-box-set! get-flag 'W)
                             (spin))
                            ('S
                             ;; Put op already synchronized.  Reset
                             ;; get flag, try to remove this dead
                             ;; entry from the putq, and give it
                             ;; another go.
                             (atomic-box-set! get-flag 'W)
                             (service-put-ops (maybe-commit)))))
                         (_
                          ;; Claiming our own op failed; this can
                          ;; only mean that some other fiber
                          ;; completed our op for us.
                          (values)))))))))))))
     (make-base-operation #f try-fn block-fn))))

(define (put-message channel message)
  "Send @var{message} on @var{channel}, and return zero values.  If
there is already another fiber waiting to receive a message on this
channel, give it our message and continue.  Otherwise, block until a
receiver becomes available."
  (perform-operation (put-operation channel message)))

(define (get-message channel)
  "Receive a message from @var{channel} and return it.  If there is
already another fiber waiting to send a message on this channel, take
its message directly.  Otherwise, block until a sender becomes
available."
  (perform-operation (get-operation channel)))
