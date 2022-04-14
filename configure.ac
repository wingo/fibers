define(FIBERS_CONFIGURE_COPYRIGHT,[[

Copyright (C) 2016-2022 Andy Wingo <wingo@pobox.com>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Lesser General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this program.  If not, see
<http://www.gnu.org/licenses/>.

]])

AC_PREREQ(2.52)
AC_INIT([fibers], [1.1.0])
AC_CONFIG_SRCDIR([env.in])
AC_CONFIG_AUX_DIR([build-aux])
AC_CONFIG_MACRO_DIRS([m4])
AM_INIT_AUTOMAKE([serial-tests])
AC_COPYRIGHT(FIBERS_CONFIGURE_COPYRIGHT)
AM_CONFIG_HEADER(config.h)

AC_DISABLE_STATIC

AC_ISC_POSIX
AC_PROG_CC
AC_STDC_HEADERS
AC_PROG_LIBTOOL

AC_CHECK_HEADERS([sys/epoll.h])
AC_CHECK_FUNCS([epoll_create epoll_create1])

AM_CONDITIONAL([CROSS_COMPILING], [test "x$cross_compiling" = "xyes"])

if test "$cross_compiling" = "no"; then
   GUILE_TARGET=""
else
   GUILE_TARGET="--target=$host_alias"
fi
AC_SUBST([GUILE_TARGET])

WARN_CFLAGS=-Wall
AC_ARG_ENABLE([Werror], AC_HELP_STRING([--disable-Werror],[Don't stop the build on errors]),
        [], WARN_CFLAGS="-Wall -Werror")
AC_SUBST(WARN_CFLAGS)

#
# Check for Guile
#
GUILE_PKG([3.0 2.2])
GUILE_FLAGS
GUILE_PROGS

AC_CONFIG_FILES([env],[chmod +x env])
AC_CONFIG_FILES(Makefile)
AC_OUTPUT
