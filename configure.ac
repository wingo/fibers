define(FIBERS_CONFIGURE_COPYRIGHT,[[

Copyright (C) 2016 Andy Wingo <wingo@pobox.com>
Copyright (C) 2020 Abdulrahman Semrie <hsamireh@gmail.com>
Copyright (C) 2020-2022 Aleix Conchillo Flaqué <aconchillo@gmail.com>

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

AC_PREREQ([2.71])
AC_INIT([fibers],[1.1.1])
AC_CONFIG_SRCDIR([env.in])
AC_CONFIG_AUX_DIR([build-aux])
AC_CONFIG_MACRO_DIRS([m4])
AM_INIT_AUTOMAKE([subdir-objects serial-tests -Werror foreign])
AC_COPYRIGHT(FIBERS_CONFIGURE_COPYRIGHT)
AC_CONFIG_HEADERS([config.h])

AC_PROG_CC

LT_INIT([disable-static])

AM_CONDITIONAL([CROSS_COMPILING], [test "x$cross_compiling" = "xyes"])

if test "x$cross_compiling" = "xno"; then
   GUILE_TARGET=""
else
   GUILE_TARGET="--target=$host_alias"
fi
AC_SUBST([GUILE_TARGET])

WARN_CFLAGS=-Wall
AC_ARG_ENABLE([Werror], AS_HELP_STRING([--disable-Werror],[Don't stop the build on errors]),
    [], WARN_CFLAGS="-Wall -Werror")
AC_SUBST(WARN_CFLAGS)

AC_CHECK_FUNCS(epoll_wait)
AM_CONDITIONAL([HAVE_EPOLL_WAIT], [test "x$ac_cv_func_epoll_wait" = "xyes"])

GUILE_CHECK([GUILE_HAVE_AFFINITY], (exit (or (defined? 'setaffinity) 2)))
AM_CONDITIONAL([GUILE_HAVE_AFFINITY], [test "x$GUILE_HAVE_AFFINITY" = "x0"])

AC_CHECK_FUNCS(clock_nanosleep)
AM_CONDITIONAL([HAVE_CLOCK_NANOSLEEP], [test "x$ac_cv_func_clock_nanosleep" = "xyes"])

AC_ARG_WITH([libevent],
    [AS_HELP_STRING([--with-libevent],
        [use libevent for events backend  @<:@default=no@:>@])],
        [],
        [with_libevent=no])

AS_IF([test "x$with_libevent" != "xno"],
    [PKG_CHECK_MODULES([LIBEVENT], [libevent >= 2.1.0],,
        [AC_MSG_ERROR([unable to find libevent])])])
AM_CONDITIONAL([WITH_LIBEVENT], [test "x$with_libevent" = "xyes"])

# Detect the target system
case "$host_os" in
    *darwin*)
        PLATFORM=darwin
        ;;
    *linux*)
        PLATFORM=generic
        ;;
esac
AC_SUBST(PLATFORM)

# Check if we have what we need for the detected platform.
AS_IF([test "x$with_libevent" = "xno"],
    [AS_IF([test x"$ac_cv_func_epoll_wait" = "xno"],
        [AC_MSG_ERROR([Native support not available, try --with-libevent=yes instead])])])

#
# Check for Guile
#
GUILE_PKG([3.0 2.2])
GUILE_FLAGS
GUILE_PROGS

AC_CONFIG_FILES([env],[chmod +x env])
AC_CONFIG_FILES(Makefile)
AC_OUTPUT
