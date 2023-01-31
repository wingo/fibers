# fibers
# Copyright (C) 2016 Andy Wingo <wingo@pobox.com>
# Copyright (C) 2020 Abdulrahman Semrie <hsamireh@gmail.com>
# Copyright (C) 2020-2022 Aleix Conchillo Flaqué <aconchillo@gmail.com>
# Copyright (C) 2023 Maxime Devos <maximedevos@telenet.be>
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

# Don't include fibers/events-impl.scm in here even though it's a source file,
# otherwise "make install" will install fibers/events-impl.scm even though
# shouldn't.  Likewise for fibers/posix-clocks.scm.

SOURCES = \
	fibers.scm \
	fibers/affinity.scm \
	fibers/channels.scm \
	fibers/conditions.scm \
	fibers/config.scm \
	fibers/counter.scm \
	fibers/deque.scm \
	fibers/interrupts.scm \
	fibers/io-wakeup.scm \
	fibers/nameset.scm \
	fibers/operations.scm \
	fibers/psq.scm \
	fibers/repl.scm \
	fibers/scheduler.scm \
	fibers/stack.scm \
	fibers/timers.scm \
	fibers/web/server.scm \
	web/server/fibers.scm

BUILT_SOURCES = \
	fibers/config.scm \
	override/fibers/events-impl.scm \
	override/fibers/posix-clocks.scm

extlibdir = $(libdir)/guile/$(GUILE_EFFECTIVE_VERSION)/extensions
AM_CFLAGS = -I$(srcdir) $(WARN_CFLAGS) $(DEBUG_CFLAGS)

extlib_LTLIBRARIES =

if HAVE_LIBEVENT
extlib_LTLIBRARIES += fibers-libevent.la
fibers_libevent_la_SOURCES = extensions/libevent.c
fibers_libevent_la_CFLAGS = $(AM_CFLAGS) $(GUILE_CFLAGS) $(LIBEVENT_CFLAGS) -I$(top_srcdir)/extensions
fibers_libevent_la_LDFLAGS = -module -no-undefined $(LIBEVENT_LIBS) $(GUILE_LDFLAGS)
$(GOBJECTS): fibers-libevent.la

override/fibers/events-impl.scm: Makefile fibers/libevent.scm
	mkdir -p $(abs_top_builddir)/override/fibers
	cp -f $(abs_top_srcdir)/fibers/libevent.scm $(abs_top_builddir)/override/fibers/events-impl.scm
else
if HAVE_EPOLL_WAIT
extlib_LTLIBRARIES += fibers-epoll.la
fibers_epoll_la_SOURCES = extensions/epoll.c
fibers_epoll_la_CFLAGS = $(AM_CFLAGS) $(GUILE_CFLAGS) -I$(top_srcdir)/extensions
fibers_epoll_la_LIBADD = $(GUILE_LIBS)
fibers_epoll_la_LDFLAGS = -export-dynamic -module
$(GOBJECTS): fibers-epoll.la

override/fibers/events-impl.scm: Makefile fibers/epoll.scm
	mkdir -p $(abs_top_builddir)/override/fibers
	cp -f $(abs_top_srcdir)/fibers/epoll.scm $(abs_top_builddir)/override/fibers/events-impl.scm
endif
endif

if ! HAVE_CLOCK_NANOSLEEP
extlib_LTLIBRARIES += fibers-clocks.la
fibers_clocks_la_SOURCES = extensions/$(PLATFORM)/clock-nanosleep.c
fibers_clocks_la_CFLAGS = $(AM_CFLAGS) $(GUILE_CFLAGS) -I$(top_srcdir)/extensions
fibers_clocks_la_LDFLAGS = -module -no-undefined $(GUILE_LDFLAGS)
endif

fibers/config.scm: Makefile fibers/config.scm.in
	mkdir -p fibers
	sed -e "s|@extlibdir\@|$(extlibdir)|" \
	    $(srcdir)/fibers/config.scm.in > fibers/config.scm

override/fibers/posix-clocks.scm: Makefile fibers/posix-clocks-$(PLATFORM).scm
	mkdir -p $(abs_top_builddir)/override/fibers
	cp -f $(abs_top_srcdir)/fibers/posix-clocks-$(PLATFORM).scm $(abs_top_builddir)/override/fibers/posix-clocks.scm

CLEANFILES += \
	fibers/config.scm \
	override/fibers/events-impl.go \
	override/fibers/posix-clocks.go \
	override/fibers/events-impl.scm \
	override/fibers/posix-clocks.scm

TESTS = \
	tests/basic.scm \
	tests/conditions.scm \
	tests/channels.scm \
	tests/foreign.scm \
	tests/io-wakeup.scm \
	tests/parameters.scm \
	tests/preemption.scm \
	tests/speedup.scm

# The following tests require SOCK_NONBLOCK and SOCK_CLOEXEC. For now we just
# run them on a platform that supports epoll (probably Linux).
if HAVE_EPOLL_WAIT
TESTS += \
        tests/ports.scm \
	tests/concurrent-web-server.scm
endif

TESTS_ENVIRONMENT=top_srcdir="$(abs_top_srcdir)" ./env $(GUILE) -s

EXTRA_DIST += \
	$(bin_SCRIPTS) \
	$(TESTS) \
	env.in \
	HACKING \
        COPYING.LESSER \
	README.md \
	TODO.md \
	fibers/config.scm.in \
	fibers/events-impl.scm \
	fibers/epoll.scm \
	fibers/libevent.scm \
	fibers/posix-clocks.scm \
	fibers/posix-clocks-darwin.scm \
	fibers/posix-clocks-generic.scm \
	examples

# List all extension files here.
EXTRA_DIST += \
	extensions/epoll.c \
	extensions/libevent.c \
	extensions/clock-nanosleep.h \
	extensions/darwin/clock-nanosleep.c \
	extensions/generic/clock-nanosleep.c
