# fibers
# Copyright (C) 2016  Andy Wingo <wingo@pobox.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this program.  If not, see
# <http://www.gnu.org/licenses/>.

ACLOCAL_AMFLAGS = -I m4

include build-aux/guile.am

moddir=$(prefix)/share/guile/site/$(GUILE_EFFECTIVE_VERSION)
godir=$(libdir)/guile/$(GUILE_EFFECTIVE_VERSION)/ccache

info_TEXINFOS=fibers.texi

SOURCES = \
	fibers.scm \
	fibers/channels.scm \
	fibers/conditions.scm \
	fibers/config.scm \
	fibers/counter.scm \
	fibers/deque.scm \
	fibers/epoll.scm \
	fibers/interrupts.scm \
	fibers/nameset.scm \
	fibers/operations.scm \
	fibers/posix-clocks.scm \
	fibers/psq.scm \
	fibers/scheduler.scm \
	fibers/stack.scm \
	fibers/system.scm \
	fibers/repl.scm \
	fibers/timers.scm \
	fibers/web/server.scm \
	web/server/fibers.scm

BUILT_SOURCES = fibers/config.scm fibers/system.scm

AM_CFLAGS = -I$(srcdir) $(WARN_CFLAGS) $(DEBUG_CFLAGS)
extlibdir = $(libdir)/guile/$(GUILE_EFFECTIVE_VERSION)/extensions

if HAVE_KQUEUE
extlib_LTLIBRARIES = kqueue.la
kqueue_la_SOURCES = kqueue.c
kqueue_la_CFLAGS = $(AM_CFLAGS) $(GUILE_CFLAGS)
kqueue_la_LIBADD = $(GUILE_LIBS)
kqueue_la_LDFLAGS = -export-dynamic -module
extfilename = kqueue
operating_system = freebsd
$(GOBJECTS): kqueue.la
else
extlib_LTLIBRARIES = epoll.la
epoll_la_SOURCES = epoll.c
epoll_la_CFLAGS = $(AM_CFLAGS) $(GUILE_CFLAGS)
epoll_la_LIBADD = $(GUILE_LIBS)
epoll_la_LDFLAGS = -export-dynamic -module
extfilename = epoll
operating_system = linux
$(GOBJECTS): epoll.la
endif # HAVE_KQUEUE

fibers/config.scm: Makefile fibers/config.scm.in
	mkdir -p fibers
	sed -e "s|@extlibdir@|$(extlibdir)|" \
	    -e "s|@extfilename@|$(extfilename)|" \
	    -e "s|@operating-system@|$(operating_system)|" \
	    $(srcdir)/fibers/config.scm.in > fibers/config.scm

fibers/system.scm: Makefile fibers/system-$(operating_system).scm.in
	cat $(srcdir)/fibers/system-$(operating_system).scm.in >> fibers/system.scm

CLEANFILES += fibers/config.scm fibers/system.scm

TESTS = \
	tests/basic.scm \
	tests/conditions.scm \
	tests/channels.scm \
	tests/foreign.scm \
	tests/parameters.scm \
	tests/preemption.scm \
	tests/speedup.scm
TESTS_ENVIRONMENT=top_srcdir="$(abs_top_srcdir)" ./env $(GUILE) -s

EXTRA_DIST += \
	env.in \
	fibers/config.scm.in \
	fibers/system-freebsd.scm.in \
	fibers/system-linux.scm.in \
	HACKING \
        COPYING.LESSER \
	README.md \
	TODO.md \
	$(bin_SCRIPTS) \
	$(TESTS) \
	examples
