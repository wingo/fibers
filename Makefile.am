# fibers
# Copyright (C) 2016 Andy Wingo <wingo@pobox.com>
# Copyright (C) 2020 Abdulrahman Semrie <hsamireh@gmail.com>
# Copyright (C) 2020-2022 Aleix Conchillo Flaqué <aconchillo@gmail.com>
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
godir=$(libdir)/guile/$(GUILE_EFFECTIVE_VERSION)/site-ccache

info_TEXINFOS=fibers.texi

SOURCES = \
	fibers.scm \
	fibers/channels.scm \
	fibers/conditions.scm \
	fibers/config.scm \
	fibers/counter.scm \
	fibers/deque.scm \
	fibers/events-impl.scm \
	fibers/interrupts.scm \
	fibers/io-wakeup.scm \
	fibers/nameset.scm \
	fibers/operations.scm \
	fibers/posix-clocks.scm \
	fibers/psq.scm \
	fibers/scheduler.scm \
	fibers/stack.scm \
	fibers/repl.scm \
	fibers/timers.scm \
	fibers/web/server.scm \
	web/server/fibers.scm

BUILT_SOURCES = fibers/config.scm fibers/posix-clocks.scm fibers/events-impl.scm

extlibdir = $(libdir)/guile/$(GUILE_EFFECTIVE_VERSION)/extensions
AM_CFLAGS = -I$(srcdir) $(WARN_CFLAGS) $(DEBUG_CFLAGS)

extlib_LTLIBRARIES =

if WITH_LIBEVENT
extlib_LTLIBRARIES += fibers-libevent.la
fibers_libevent_la_SOURCES = libevent.c
fibers_libevent_la_CFLAGS = $(AM_CFLAGS) $(GUILE_CFLAGS) $(LIBEVENT_CFLAGS)
fibers_libevent_la_LDFLAGS = -module -no-undefined $(LIBEVENT_LIBS) $(GUILE_LDFLAGS)
$(GOBJECTS): fibers-libevent.la

fibers/events-impl.scm: Makefile fibers/libevent.scm
	ln -sf libevent.scm fibers/events-impl.scm
else
if LINUX
extlib_LTLIBRARIES += fibers-epoll.la
fibers_epoll_la_SOURCES = epoll.c
fibers_epoll_la_CFLAGS = $(AM_CFLAGS) $(GUILE_CFLAGS)
fibers_epoll_la_LIBADD = $(GUILE_LIBS)
fibers_epoll_la_LDFLAGS = -export-dynamic -module
$(GOBJECTS): fibers-epoll.la

fibers/events-impl.scm: Makefile fibers/epoll.scm
	ln -sf epoll.scm fibers/events-impl.scm
endif
endif

if DARWIN
extlib_LTLIBRARIES += fibers-affinity.la
fibers_affinity_la_SOURCES = affinity.c
fibers_affinity_la_CFLAGS = $(AM_CFLAGS) $(GUILE_CFLAGS)
fibers_affinity_la_LDFLAGS = -module -no-undefined $(GUILE_LDFLAGS)

extlib_LTLIBRARIES += fibers-darwin-clocks.la
fibers_darwin_clocks_la_SOURCES = clock_nanosleep.c
fibers_darwin_clocks_la_CFLAGS = $(AM_CFLAGS) $(GUILE_CFLAGS)
fibers_darwin_clocks_la_LDFLAGS = -module -no-undefined $(GUILE_LDFLAGS)
endif

fibers/config.scm: Makefile fibers/config.scm.in
	mkdir -p fibers
	sed -e "s|@extlibdir\@|$(extlibdir)|" \
	    $(srcdir)/fibers/config.scm.in > fibers/config.scm

fibers/posix-clocks.scm: Makefile fibers/posix-clocks-$(PLATFORM).scm
	ln -sf posix-clocks-$(PLATFORM).scm fibers/posix-clocks.scm

CLEANFILES += fibers/config.scm fibers/posix-clocks.scm fibers/events-impl.scm

TESTS = \
	tests/basic.scm \
	tests/conditions.scm \
	tests/channels.scm \
	tests/foreign.scm \
	tests/io-wakeup.scm \
	tests/parameters.scm \
        tests/ports.scm \
	tests/preemption.scm \
	tests/speedup.scm \
	tests/concurrent-web-server.scm

TESTS_ENVIRONMENT=top_srcdir="$(abs_top_srcdir)" ./env $(GUILE) -s

EXTRA_DIST += \
	env.in \
	fibers/config.scm.in \
	fibers/epoll.scm \
	fibers/libevent.scm \
	fibers/posix-clocks-linux.scm \
	fibers/posix-clocks-darwin.scm \
	HACKING \
        COPYING.LESSER \
	README.md \
	TODO.md \
	$(bin_SCRIPTS) \
	$(TESTS) \
	examples
