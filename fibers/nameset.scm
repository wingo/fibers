;; Fibers: cooperative, event-driven user-space threads.

;;;; Copyright (C) 2016 Free Software Foundation, Inc.
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

(define-module (fibers nameset)
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-26)
  #:export ((make-nameset/public . make-nameset)
            nameset-add!
            nameset-ref
            nameset-fold))

(define-syntax struct
  (lambda (stx)
    (define (id-append ctx . ids)
      (datum->syntax ctx (apply symbol-append (map syntax->datum ids))))
    (syntax-case stx ()
      ((struct tag (field ...))
       (with-syntax ((make-tag (id-append #'tag #'make- #'tag))
                     (tag? (id-append #'tag #'tag #'?))
                     ((tag-field ...) (map (cut id-append #'tag #'tag #'- <>)
                                           #'(field ...))))
         #'(define-record-type tag
             (make-tag field ...)
             tag?
             (field tag-field)
             ...))))))

(struct nameset (names counter))

(define (make-nameset/public)
  "Create a fresh nameset, a weak collection of objects named by
incrementing integers."
  (make-nameset (make-weak-value-hash-table) (make-atomic-box 0)))

(define (atomic-box-fetch-and-inc! box)
  (let lp ((cur (atomic-box-ref box)))
    (let* ((next (1+ cur))
           (cur* (atomic-box-compare-and-swap! box cur next)))
      (if (eqv? cur cur*)
          cur
          (lp cur*)))))

(define (nameset-add! ns obj)
  "Add @var{obj} to the nameset @var{ns}, and return the fresh
name that was created."
  (let ((name (atomic-box-fetch-and-inc! (nameset-counter ns))))
    (hashv-set! (nameset-names ns) name obj)
    name))

(define (nameset-ref ns name)
  "Return the object named @var{name} in nameset @var{ns}, or
@code{#f} if no such object has that name (perhaps because the object
was reclaimed by the garbage collector)."
  (hashv-ref (nameset-names ns) name))

(define* (nameset-fold f ns seed)
  "Fold @var{f} over the objects contained in the nameset @var{ns}.
This will call @var{f} as @code{(@var{f} @var{name} @var{obj}
@var{seed})}, for each @var{name} and @var{obj} in the nameset,
passing the result as @var{seed} to the next call and ultimately
returning the final @var{seed} value."
  (hash-fold f seed (nameset-names ns)))
