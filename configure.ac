define(FIBERS_CONFIGURE_COPYRIGHT,[[

Copyright (C) 2016 Andy Wingo <wingo@pobox.com>
Copyright (C) 2020 Abdulrahman Semrie <hsamireh@gmail.com>
Copyright (C) 2020-2023 Aleix Conchillo Flaqué <aconchillo@gmail.com>

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

AC_PREREQ([2.69])
AC_INIT([fibers],[1.3.1])
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

AC_ARG_ENABLE([epoll], AS_HELP_STRING([--disable-epoll],[Disable epoll support]),
    [disable_epoll=yes], [disable_epoll=no])

AC_CHECK_FUNCS(epoll_wait)
AM_CONDITIONAL([HAVE_EPOLL_WAIT], [test "x$ac_cv_func_epoll_wait" = "xyes"])

AC_CHECK_FUNCS(clock_nanosleep)
AM_CONDITIONAL([HAVE_CLOCK_NANOSLEEP], [test "x$ac_cv_func_clock_nanosleep" = "xyes"])

# We should update `native_support` variable to yes if any native system
# (e.g. epoll, kqueue) was found and not disabled.
AS_IF([test "x$ac_cv_func_epoll_wait" = "xyes"],
    [AS_IF([test "x$disable_epoll" = "xyes"], [native_support=no],[native_support=yes])],[native_support=no])

# If there's no native support or it was disabled, try libevent.
AS_IF([test "x$native_support" = "xno"],
    [PKG_CHECK_MODULES([LIBEVENT], [libevent >= 2.1.0],[have_libevent=yes],
        [AC_MSG_ERROR([Not found or disabled native support, and libevent was not found either])])])

AM_CONDITIONAL([HAVE_LIBEVENT], [test "x$have_libevent" = "xyes"])

# Detect the target system
case "$host_os" in
    *darwin*)
        PLATFORM=darwin
        ;;
    *)
        PLATFORM=generic
        ;;
esac
AC_SUBST(PLATFORM)

#
# Check for Guile
#
GUILE_PKG([3.0 2.2])
GUILE_FLAGS
GUILE_PROGS

AC_CONFIG_FILES([env],[chmod +x env])
AC_CONFIG_FILES(Makefile)
AC_OUTPUT
