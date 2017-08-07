;; Fibers: cooperative, event-driven user-space threads.

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

(use-modules (ice-9 popen)
             (ice-9 match)
             (ice-9 rdelim)
             (srfi srfi-1)
             (srfi srfi-26)
             (guix build-system gnu)
             (guix gexp)
             (guix git-download)
             (guix licenses)
             (guix packages)
             (gnu packages)
             (gnu packages autotools)
             (gnu packages gettext)
             (gnu packages guile)
             (gnu packages pkg-config)
             (gnu packages texinfo))

(define %source-dir (dirname (current-filename)))

(define guile-fibers
  (package
    (name "guile-fibers")
    (version "git")
    (source (local-file %source-dir
                        #:recursive? #t
                        #:select? (git-predicate %source-dir)))
    (build-system gnu-build-system)
    (native-inputs `(("autoconf" ,autoconf)
                     ("automake" ,automake)
                     ("libtool" ,libtool)
                     ("pkg-config" ,pkg-config)
                     ("texinfo" ,texinfo)
                     ("gettext" ,gettext-minimal)))
    (inputs
     `(("guile" ,guile-2.2)))
    (arguments
     `(#:phases (modify-phases %standard-phases
                  (add-before 'configure 'bootstrap
                    (lambda _
                      (zero? (system* "./autogen.sh"))))
                  (add-before 'configure 'setenv
                    (lambda _
                      (setenv "GUILE_AUTO_COMPILE" "0"))))))
    (synopsis "Lightweight concurrency facility for Guile")
    (description
     "Fibers is a Guile library that implements a a lightweight concurrency
facility, inspired by systems like Concurrent ML, Go, and Erlang.  A fiber is
like a \"goroutine\" from the Go language: a lightweight thread-like
abstraction.  Systems built with Fibers can scale up to millions of concurrent
fibers, tens of thousands of concurrent socket connections, and many parallel
cores.  The Fibers library also provides Concurrent ML-like channels for
communication between fibers.

Note that Fibers makes use of some Guile 2.1/2.2-specific features and
is not available for Guile 2.0.")
    (home-page "https://github.com/wingo/fibers")
    (license lgpl3+)))

guile-fibers
