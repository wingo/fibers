;; Parallel Concurrent ML for Guile

;;;; Copyright (C) 2016 Andy Wingo <wingo@pobox.com>
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

;;; An implementation of Parallel Concurrent ML following the 2009
;;; ICFP paper "Parallel Concurrent ML" by John Reppy, Claudio
;;; V. Russo, and Yingqui Xiao.
;;;
;;; This implementation differs from the paper in a few ways:
;;;
;;; * Superficially, We use the term "operation" instead of "event".
;;;   We say "wrap-operation" instead of "wrap", "choice-operation"
;;;   instead of "choose", and "perform-operation" instead of "sync".
;;;
;;; * For the moment, this is an implementation of "primitive CML"
;;;   only.  This may change in the future.
;;;
;;; * The continuation handling is a little different; in Manticore
;;;   (or at least in the paper), it appears that suspended threads
;;;   are represented in a quite raw way, whereas in Guile there are
;;;   wrapper <fiber> objects.  Likewise unlike in CML, the
;;;   continuations in Fibers are delimited and composable, so things
;;;   are a little different.  Suspended computations expect to be
;;;   passed a thunk as the resume value, and that thunk gets invoked
;;;   in the context of the fiber.  For this reason we represent
;;;   wrappers explicitly in events, using them to wrap the resume
;;;   thunks.  As in the C# implementation, we delay continuation
;;;   creation / fiber suspension until after a failed "doFn" phase.
;;;
;;; * In Fibers we do away with the "poll" phase, instead merging it
;;;   with the "try" phase.  (Our "try" phase is more like what CML
;;;   calls "do".  In Fibers, there is no do; there is only try.)
;;;

(define-module (fibers operations)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 match)
  #:use-module ((ice-9 threads)
                #:select (current-thread
                          make-mutex make-condition-variable
                          lock-mutex unlock-mutex
                          wait-condition-variable signal-condition-variable))
  #:use-module (fibers scheduler)
  #:export (wrap-operation
            choice-operation
            perform-operation

            make-base-operation))

;; Three possible values: W (waiting), C (claimed), or S (synched).
;; The meanings are as in the Parallel CML paper.
;; R00: 'W is difficult to read.
(define-inlinable (make-op-state) (make-atomic-box 'W))

;; R01: It would be better to wrap base-op and choice-op inside a
;; record <operation> see further down.
(define-record-type <base-op>
  (make-base-operation wrap-fn try-fn block-fn)
  base-op?
  ;; ((arg ...) -> (result ...)) | #f
  (wrap-fn base-op-wrap-fn)
  ;; () -> (thunk | #f)
  (try-fn base-op-try-fn)
  ;; (op-state sched resume-k) -> ()
  (block-fn base-op-block-fn))

(define-record-type <choice-op>
  (make-choice-operation base-ops)
  choice-op?
  (base-ops choice-op-base-ops))

(define (wrap-operation op f)
  "Given the operation @var{op}, return a new operation that, if and
when it succeeds, will apply @var{f} to the values yielded by
performing @var{op}, and yield the result as the values of the wrapped
operation."
  ;; R02: It is possible to avoid the following match by making
  ;; wrap-operation a field inside a record <operation>, see R01.
  (match op
    (($ <base-op> wrap-fn try-fn block-fn)
     (make-base-operation (match wrap-fn  ;; R03: it is possible to
                                          ;; avoid match
                            (#f f)        ;; by making the default
                                          ;; wrap-fn the procedure: values
                            (_ (lambda args
                                 (call-with-values (lambda ()
                                                     (apply wrap-fn args))
                                   f))))
                          try-fn
                          block-fn))
    (($ <choice-op> base-ops)
     (let* ((count (vector-length base-ops))
            (base-ops* (make-vector count)))
       ;; R04: lp can be replaced with vector-map
       (let lp ((i 0))
         (when (< i count)
           (vector-set! base-ops* i (wrap-operation (vector-ref base-ops i) f))
           (lp (1+ i))))
       (make-choice-operation base-ops*)))))

(define (choice-operation . ops)
  "Given the operations @var{ops}, return a new operation that if it
succeeds, will succeed with one and only one of the sub-operations
@var{ops}."
  ;; DOC: Choice operation may appear like a nested tree structure,
  ;; even if in fact it is a list.
  (define (flatten ops)
    (match ops
      (() '())
      ((op . ops)
       ;; R05: append could be replaced with cons in the first match
       ;; clause, and in the second clause it would be faster to
       ;; replace append with (adjoin vector list) because the order
       ;; of the ops does not matter.
       (append (match op
                 (($ <base-op>) (list op))
                 (($ <choice-op> base-ops) (vector->list base-ops)))
               (flatten ops)))))
  (match (flatten ops)
    ((base-op) base-op)
    ;; R06: Does a choice operation with an empty list makes sense?
    (base-ops (make-choice-operation (list->vector base-ops)))))

(define (perform-operation op)
  "Perform the operation @var{op} and return the resulting values.  If
the operation cannot complete directly, block until it can complete."
  ;; R07: See R01, perform-operation could be a "function pointer".
  (define (wrap-resume resume wrap-fn)
    ;; see R03.
    (if wrap-fn
        (lambda (thunk)
          (resume (lambda ()
                    (call-with-values thunk wrap-fn))))
        resume))

  (define (block sched resume)
    ;; DOC: Flag is shared among all the operations of the choice,
    ;; making the whole choice operation perform-once (single shot)

    ;; R10: s/flag/state/?
    (let ((flag (make-op-state)))
      (match op
        (($ <base-op> wrap-fn try-fn block-fn)
         (block-fn flag sched (wrap-resume resume wrap-fn)))
        (($ <choice-op> base-ops)
         ;; R08: lp is vector-for-each
         (let lp ((i 0))
           (when (< i (vector-length base-ops))
             (match (vector-ref base-ops i)
               (($ <base-op> wrap-fn try-fn block-fn)
                ;; R09: I do not see the point of match since only
                ;; wrap-fn is extracted.
                (block-fn flag sched (wrap-resume resume wrap-fn))))
             (lp (1+ i))))))))

  (define (suspend)
    ;; Two cases.  If there is a current fiber, then we suspend the
    ;; current fiber and arrange to restart it when the operation
    ;; succeeds.  Otherwise we block the current thread until the
    ;; operation succeeds, to allow for communication between fibers
    ;; and foreign threads.

    ;; R11: That expression may be factored while avoiding the if.
    ;; See https://git.io/JYRWI
    (if (current-scheduler)
        ((suspend-current-task
          (lambda (sched k)
            (define (resume thunk)
              (schedule-task sched (lambda () (k thunk))))
            (block sched resume))))
        (let ((k #f)
              (thread (current-thread))
              ;; R12: In my implementation, mutex and condvar are
              ;; allocated once per POSIX thread. See
              ;; https://git.io/JYRWI
              (mutex (make-mutex))
              (condvar (make-condition-variable)))
          (define (resume thunk)
            (cond
             ((eq? (current-thread) thread)
              (set! k thunk))
             (else
              (call-with-blocked-asyncs
               (lambda ()
                 (lock-mutex mutex)
                 (set! k thunk)
                 (signal-condition-variable condvar)
                 (unlock-mutex mutex))))))
          ;; R13: IIUC the following expression, describe that condvar
          ;; may be signaled while k is still #f. How can that happen?
          (lock-mutex mutex)
          (block #f resume)
          (let lp ()
            (cond
             (k
              (unlock-mutex mutex)
              (k))
             (else
              (wait-condition-variable condvar mutex)
              (lp)))))))

  ;; First, try to sync on an op.  If no op syncs, block.
  (match op
    (($ <base-op> wrap-fn try-fn)
     (match (try-fn)
       (#f (suspend))
       (thunk
        (if wrap-fn ;; See R03
            (call-with-values thunk wrap-fn)
            (thunk)))))
    (($ <choice-op> base-ops)
     ;; R14: That may be factored for readability inside a
     ;; vector-random-for-each. I am wondering how much randomization
     ;; helps?
     (let* ((count (vector-length base-ops))
            (offset (random count)))
       (let lp ((i 0))
         (if (< i count)
             (match (vector-ref base-ops (modulo (+ i offset) count))
               (($ <base-op> wrap-fn try-fn)
                (match (try-fn)
                  (#f (lp (1+ i)))
                  (thunk
                   ;; See R03
                   (if wrap-fn
                       (call-with-values thunk wrap-fn)
                       (thunk))))))
             (suspend)))))))
