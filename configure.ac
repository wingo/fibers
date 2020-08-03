define(FIBERS_CONFIGURE_COPYRIGHT,[[
Copyright (C) 2016 Andy Wingo <wingo@pobox.com>
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
AC_INIT([fibers], [1.0.0])
AC_CONFIG_SRCDIR([env.in])
AC_CONFIG_AUX_DIR([build-aux])
AC_CONFIG_MACRO_DIRS([m4])
AM_INIT_AUTOMAKE([serial-tests -Werror foreign])
AC_COPYRIGHT(FIBERS_CONFIGURE_COPYRIGHT)
#AM_CONFIG_HEADER(config.h)

AM_PROG_AR
AC_PROG_CC

LT_INIT([disable-static])

WARN_CFLAGS=-Wall
AC_ARG_ENABLE([Werror], AC_HELP_STRING([--disable-Werror],[Don't stop the build on errors]),
        [], WARN_CFLAGS="-Wall -Werror")
AC_SUBST(WARN_CFLAGS)

build_darwin=no

# Detect the target system
case "$host_os" in
     linux*)
        build_linux=yes
        PLATFORM=linux
        ;;
     darwin*)
        build_darwin=yes
        PLATFORM=darwin
        ;;
esac

AM_CONDITIONAL([DARWIN], [test "$build_darwin" = "yes"])
AM_CONDITIONAL([LINUX], [test "$build_linux" = "yes"])
AC_SUBST(PLATFORM)

#
# Dependencies
#
PKG_CHECK_MODULES([LIBEVENT], [libevent >= 2.1.0])

#
# Check for Guile
#
GUILE_PKG([3.0 2.2])
GUILE_FLAGS
GUILE_PROGS

AC_CONFIG_FILES([env],[chmod +x env])
AC_CONFIG_FILES(Makefile)
AC_OUTPUT
