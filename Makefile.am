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
	fibers/deque.scm \
	fibers/epoll.scm \
	fibers/internal.scm \
	fibers/interrupts.scm \
	fibers/nameset.scm \
	fibers/operations.scm \
	fibers/posix-clocks.scm \
	fibers/psq.scm \
	fibers/stack.scm \
	fibers/repl.scm \
	fibers/timers.scm \
	fibers/web/server.scm \
	web/server/fibers.scm

BUILT_SOURCES = fibers/config.scm

extlibdir = $(libdir)/guile/$(GUILE_EFFECTIVE_VERSION)/extensions
extlib_LTLIBRARIES = epoll.la
AM_CFLAGS = -I$(srcdir) $(WARN_CFLAGS) $(DEBUG_CFLAGS)
epoll_la_SOURCES = epoll.c
epoll_la_CFLAGS = $(AM_CFLAGS) $(GUILE_CFLAGS)
epoll_la_LIBADD = $(GUILE_LIBS)
epoll_la_LDFLAGS = -export-dynamic -module
$(GOBJECTS): epoll.la

fibers/config.scm: Makefile fibers/config.scm.in
	sed -e "s|@extlibdir\@|$(extlibdir)|" \
	    $(srcdir)/fibers/config.scm.in > fibers/config.scm

CLEANFILES += fibers/config.scm

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
	HACKING \
        COPYING.LESSER \
	README.md \
	TODO.md \
	$(bin_SCRIPTS) \
	$(TESTS) \
	examples
