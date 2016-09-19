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
;;;; You should have received a copy of the GNU Lesser General Public
;;;; License along with this library; if not, write to the Free Software
;;;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
;;;;

(define-module (fibers repl)
  #:use-module (system repl command)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (fibers internal))

(define-meta-command ((fibers fibers) repl #:optional sched)
  "fibers [SCHED]
Show a list of fibers.

If SCHED is given, limit to fibers bound to the given fold."
  (match (sort (fold-all-fibers acons '())
               (match-lambda*
                 (((id1 . _) (id2 . _)) (< id1 id2))))
    (() (format #t "No fibers.\n"))
    (fibers
     (format #t "~a ~8t~a\n" "fiber" "state")
     (format #t "~a ~8t~a\n" "-----" "-----")
     (for-each
      (match-lambda
        ((id . fiber)
         ;; How to show fiber data?  Would be nice to say "suspended
         ;; at foo.scm:32:4".
         (format #t "~a ~8t~a\n" id (fiber-state fiber))))
      fibers))))
