;; CPU affinity

;;;; Copyright (C) 2022 Aleix Conchillo Flaqué <aconchillo@gmail.com>
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

;;; Guile defines setaffinity and getaffinity in some systems (e.g. Linux). For
;;; those systems where those procedures are not available there should be a
;;; Fibers' specific implementation available through the fibers-affinity
;;; library.

(define-module (fibers affinity)
  #:use-module (ice-9 threads)
  #:export (getaffinity* setaffinity*))

;;
;; Some platforms don't implement (getaffinity) or (setaffinity).
;;
;; For example, it seems it is not possible to link a thread to a specific core
;; on macOS. See: https://developer.apple.com/forums/thread/44002.
;;
;; So for now getaffinity/setaffinity are no-ops on those paltforms.
;;

;; getaffinity/setaffinity should be defined in Guile
(define getaffinity*
  (cond
   ((defined? 'getaffinity) getaffinity)
   (else
    (lambda (pid)
      (make-bitvector (current-processor-count) 1)))))

(define setaffinity*
  (cond
   ((defined? 'setaffinity) setaffinity)
   (else (lambda (pid affinity) *unspecified*))))
