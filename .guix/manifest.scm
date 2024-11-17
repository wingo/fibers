;; Fibers: cooperative, event-driven user-space threads.

;;;; Copyright (C) 2024 Ludovic Courtès <ludo@gnu.org>
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

(use-modules (guix)
             (guix profiles)
             (fibers-package)
             (srfi srfi-1))

;;; Commentary:
;;;
;;; This file defines a manifest containing a configuration matrix for
;;; different native and cross-compilation targets and different variants.
;;; To build them, run:
;;;
;;;   guix build -L .guix/modules -m manifest.scm
;;;
;;; Code:

(define* (package->manifest-entry* package system
                                   #:key target)
  "Return a manifest entry for PACKAGE on SYSTEM, optionally cross-compiled to
TARGET."
  (manifest-entry
    (inherit (package->manifest-entry package))
    (name (string-append (package-name package) "." system
                         (if target
                             (string-append "." target)
                             "")))
    (item (with-parameters ((%current-system system)
                            (%current-target-system target))
            package))))

(define native-builds
  (manifest
   (append-map (lambda (system)
                 (map (lambda (package)
                        (package->manifest-entry* package system))
                      (list guile-fibers
                            guile2.2-fibers
                            guile-fibers/libevent)))
               '("x86_64-linux"
                 "i686-linux"))))

(define cross-builds
  (manifest
   (map (lambda (target)
          (package->manifest-entry* (if (string-contains target "linux")
                                        guile-fibers
                                        guile-fibers/libevent)
                                    "x86_64-linux"
                                    #:target target))
        '("i586-pc-gnu"
          "aarch64-linux-gnu"))))

(concatenate-manifests (list native-builds cross-builds))
