;; Conditions

;;;; Copyright (C) 2017 Andy Wingo <wingo@pobox.com>
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

;;; Condition variable (cvar) implementation following the 2009 ICFP
;;; paper "Parallel Concurrent ML" by John Reppy, Claudio V. Russo,
;;; and Yingqui Xiao.  See channels.scm for additional commentary.
;;;
;;; Besides the general ways in which this implementation differs from
;;; the paper, this channel implementation avoids locks entirely.
;;; Still, we should disable interrupts while any operation is in a
;;; "claimed" state to avoid excess latency due to pre-emption.  It
;;; would be great if we could verify our protocol though; the
;;; parallel channel operations are still gnarly.

(define-module (fibers conditions)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 match)
  #:use-module (fibers stack)
  #:use-module (fibers counter)
  #:use-module (fibers operations)
  #:export (make-condition
            condition?
            signal-condition!
            wait-operation
            wait
            (condition-signalled?/public . condition-signalled?)))

(define-record-type <condition>
  (%make-condition signalled? waiters gc-step)
  condition?
  ;; atomic box of bool
  (signalled? condition-signalled?)
  ;; stack of flag+resume pairs
  (waiters channel-waiters)
  ;; count until garbage collection
  (gc-step channel-gc-step))

(define (make-condition)
  "Make a fresh condition variable."
  (%make-condition (make-atomic-box #f) (make-empty-stack) (make-counter)))

(define (resume-waiters! waiters)
  (define (resume-one flag resume)
    (match (atomic-box-compare-and-swap! flag 'W 'S)
      ('W (resume values))
      ('C (resume-one flag resume))
      ('S #f)))
  ;; Non-tail-recursion to resume waiters in the order they were added
  ;; to the waiters stack.
  (let lp ((waiters (stack-pop-all! waiters)))
    (match waiters
      (() #f)
      (((flag . resume) . waiters)
       (lp waiters)
       (resume-one flag resume)))))

(define (signal-condition! cvar)
  "Mark @var{cvar} as having been signalled.  Resume any fiber or
thread waiting for @var{cvar}.  If @var{cvar} is already signalled,
calling @code{signal-condition!} does nothing and returns @code{#f};
returns @code{#t} otherwise."
  (match cvar
    (($ <condition> signalled? waiters)
     (match (atomic-box-compare-and-swap! signalled? #f #t)
       (#f ;; We signalled the cvar.
        (resume-waiters! waiters)
        #t)
       (#t ;; Cvar already signalled.
        #f)))))

(define (wait-operation cvar)
  "Make an operation that will complete when @var{cvar} is signalled."
  (match cvar
    (($ <condition> signalled? waiters gc-step)
     (define (try-fn) (and (atomic-box-ref signalled?) values))
     (define (block-fn flag sched resume)
       ;; Decrement the garbage collection counter.
       ;; If we've surpassed the number of steps until garbage collection,
       ;; prune out waiters that have already succeeded.
       ;;
       ;; Note that it's possible that this number will go negative,
       ;; but stack-filter! should handle this without errors (though
       ;; possibly extra spin), and testing against zero rather than
       ;; less than zero will prevent multiple threads from repeating
       ;; this work.
       (when (= (counter-decrement! gc-step) 0)
         (stack-filter! waiters
                        (match-lambda
                          ((flag . resume)
                           (not (eq? (atomic-box-ref flag) 'S)))))
         (counter-reset! gc-step))
       ;; We have suspended the current fiber or thread; arrange for
       ;; signal-condition! to call resume-get by adding the flag and
       ;; resume callback to the cvar's waiters stack.
       (stack-push! waiters (cons flag resume))
       ;; It could be that the cvar was actually signalled in between
       ;; the calls to try-fn and block-fn.  In that case it could be
       ;; that resume-waiters! was called before our push above.  In
       ;; that case, call resume-waiters! to resolve the race.
       (when (atomic-box-ref signalled?)
         (resume-waiters! waiters))
       (values))
     (make-base-operation #f try-fn block-fn))))

(define (wait cvar)
  "Wait until @var{cvar} has been signalled."
  (perform-operation (wait-operation cvar)))

(define (condition-signalled?/public cvar)
  "Return @code{#t} if @var{cvar} has already been signalled.

In general you will want to use @code{wait} or @code{wait-operation} to
wait on a condition.  However, sometimes it is useful to see whether or
not a condition has already been signalled without blocking if not."
  (atomic-box-ref (condition-signalled? cvar)))
