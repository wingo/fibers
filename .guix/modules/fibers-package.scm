;; Fibers: cooperative, event-driven user-space threads.

;;;; Copyright (C) 2017 Christine Lemmer-Webber <cwebber@dustycloud.org>
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

(define-module (fibers-package)
  #:use-module (guix)
  #:use-module (guix build-system gnu)
  #:use-module (guix gexp)
  #:use-module (guix git-download)
  #:use-module (guix licenses)
  #:use-module (guix packages)
  #:use-module (gnu packages)
  #:use-module (gnu packages autotools)
  #:use-module (gnu packages gettext)
  #:use-module (gnu packages guile)
  #:use-module (gnu packages libevent)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages texinfo))

(define %source-dir (in-vicinity (current-source-directory) "../.."))

(define-public guile-fibers
  (package
    (name "guile-fibers")
    (version "git")
    (source (local-file %source-dir "guile-fibers-checkout"
                        #:recursive? #t
                        #:select? (git-predicate %source-dir)))
    (build-system gnu-build-system)
    (native-inputs
     (list autoconf automake libtool texinfo gettext-minimal pkg-config
           (this-package-input "guile")))         ;for cross-compilation
    (inputs
     (list guile-3.0))
    (synopsis "Lightweight concurrency facility for Guile")
    (description
     "Fibers is a Guile library that implements a a lightweight concurrency
facility, inspired by systems like Concurrent ML, Go, and Erlang.  A fiber is
like a \"goroutine\" from the Go language: a lightweight thread-like
abstraction.  Systems built with Fibers can scale up to millions of concurrent
fibers, tens of thousands of concurrent socket connections, and many parallel
cores.  The Fibers library also provides Concurrent ML-like channels for
communication between fibers.")
    (home-page "https://github.com/wingo/fibers")
    (license lgpl3+)))

(define-public guile2.2-fibers
  (package/inherit guile-fibers
    (name "guile2.2-fibers")
    (inputs (modify-inputs (package-inputs guile-fibers)
              (replace "guile" guile-2.2)))))

(define-public guile-fibers/libevent
  (package/inherit guile-fibers
    (name "guile-fibers-on-libevent")
    (arguments
     (list #:configure-flags #~(list "--disable-epoll")))
    (inputs (modify-inputs (package-inputs guile-fibers)
              (append libevent)))))

guile-fibers
