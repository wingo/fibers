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
;;;; You should have received a copy of the GNU Lesser General Public
;;;; License along with this library; if not, write to the Free Software
;;;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

;;; Guile defines setaffinity and getaffinity in some systems (e.g. Linux). For
;;; those systems where those procedures are not available there should be a
;;; Fibers' specific implementation available through the fibers-affinity
;;; library.

(define-module (fibers affinity)
  #:use-module (system foreign)
  #:use-module (fibers config)
  #:export (getaffinity* setaffinity*))

(eval-when (eval load compile)
  (unless (defined? 'getaffinity)
    ;; When cross-compiling, the cross-compiled 'fibers-affinity.so' cannot be
    ;; loaded by the 'guild compile' process; skip it.
    (unless (getenv "FIBERS_CROSS_COMPILING")
      (catch #t
        (lambda ()
          (dynamic-call "init_fibers_affinity" (dynamic-link (extension-library "fibers-affinity"))))
        (lambda _ (error "Ooops, getaffinity/setaffinity are not available in this platform and we were \
unable to load fibers-affinity extension."))))))

;; getaffinity/setaffinity should be loaded at this point.
(define getaffinity* (if (defined? 'getaffinity) getaffinity))
(define setaffinity* (if (defined? 'setaffinity) setaffinity))
