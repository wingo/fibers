
AC_DEFUN([AC_HAVE_KQUEUE], [dnl
  ac_have_kqueue_cppflags="${CPPFLAGS}"
  AC_MSG_CHECKING([for FreeBSD kqueue(2) interface])
  AC_CACHE_VAL([ac_cv_have_kqueue], [dnl
    AC_LINK_IFELSE([dnl
      AC_LANG_PROGRAM([dnl
#include <sys/event.h>
], [dnl
int rc = kqueue() > 0 ? 1 : -1;])],
      [ac_cv_have_kqueue=yes],
      [ac_cv_have_kqueue=no])])
  CPPFLAGS="${ac_have_kqueue_cppflags}"
  AS_IF([test "${ac_cv_have_kqueue}" = "yes"],
    [AC_MSG_RESULT([yes])
$1],[AC_MSG_RESULT([no])
$2])
])dnl
