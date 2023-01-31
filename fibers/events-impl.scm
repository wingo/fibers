;;;; Copyright (C) 2023 Maxime Devos <maximedevos@telenet.be>
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

(define-module (fibers events-impl)
  #:export (events-impl-create
	    events-impl-destroy
	    events-impl?
	    events-impl-add!
	    events-impl-wake!
	    events-impl-fd-finalizer
	    events-impl-run

	    EVENTS_IMPL_READ EVENTS_IMPL_WRITE EVENTS_IMPL_CLOSED_OR_ERROR))

;; When cross-compiling, the cross-compiled 'fibers-libevent.so' cannot be loaded
;; by the 'guild compile' process, so during the compilation of Guile-Fibers
;; this 'fake' fibers/events-impl.scm / fibers/events-impl.go module is loaded,
;; which doesn't link to the library.
;; Likewise for other libraries (e.g. fibers-epoll.so).
;;
;; When Guile-Fibers is actually installed, the real fibers/epoll.scm or
;; fibers/libevents.scm and their corresponding .go is installed instead.
;; Likewise, when tests are run, the real modules are used instead.
;;
;; In the past, a FIBERS_CROSS_COMPILING environment variable was consulted
;; at runtime.  However, this is problematic in some situations.  For example,
;; when using './env', the user might want to start a program that
;; (as an implementation detail) happens to use Guile-Fibers and hence needs
;; to load the relevant ".so" of the copy of Guile-Fibers of that program,
;; which FIBERS_CROSS_COMPILING would prevent.
