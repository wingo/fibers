/* Copyright (C) 2016 Andy Wingo <wingo@pobox.com>
 * 
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * as published by the Free Software Foundation; either version 3 of
 * the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
 * 02110-1301 USA
 */




#define _GNU_SOURCE

#ifdef HAVE_CONFIG_H
# include <config.h>
#endif

#include <errno.h>
#include <sys/epoll.h>
#include <libguile.h>

/* {EPoll}
 */

static SCM
scm_primitive_epoll_wake (SCM wakefd)
#define FUNC_NAME "primitive-epoll-wake"
{
  int c_fd;
  char zero = 0;

  c_fd = scm_to_int (wakefd);

  if (write (c_fd, &zero, 1) <= 0 && errno != EWOULDBLOCK && errno != EAGAIN)
    SCM_SYSERROR;

  return SCM_UNSPECIFIED;
}
#undef FUNC_NAME

/* EPoll is a newer Linux interface designed for sets of file
   descriptors that are mostly in a dormant state.  These primitives
   wrap the epoll interface on a very low level.

   This is a low-level interface.  See the `(fibers epoll)' module for
   a more usable wrapper.  Note that this low-level interface deals in
   file descriptors, not ports, in order to allow higher-level code to
   handle the interaction with the garbage collector.  */
static SCM
scm_primitive_epoll_create (SCM cloexec_p)
#define FUNC_NAME "epoll-create"
{
  int fd;

#ifdef HAVE_EPOLL_CREATE1
  fd = epoll_create1 (scm_is_true (cloexec_p) ? EPOLL_CLOEXEC : 0);
  if (fd < 0)
    SCM_SYSERROR;
#else
  fd = epoll_create (16);
  if (fd < 0)
    SCM_SYSERROR;
  if (scm_is_true (cloexec_p))
    fcntl (fd, F_SETFD, FD_CLOEXEC, 1);
#endif

  return scm_from_int (fd);
}
#undef FUNC_NAME

/* This epoll wrapper always places the fd itself as the "data" of the
   events structure.  */
static SCM
scm_primitive_epoll_ctl (SCM epfd, SCM op, SCM fd, SCM events)
#define FUNC_NAME "primitive-epoll-ctl"
{
  int c_epfd, c_op, c_fd;
  struct epoll_event ev = { 0, };

  c_epfd = scm_to_int (epfd);
  c_op = scm_to_int (op);
  c_fd = scm_to_int (fd);

  if (SCM_UNBNDP (events))
    {
      if (c_op == EPOLL_CTL_DEL)
        /* Events do not matter in this case.  */
        ev.events = 0;
      else
        SCM_MISC_ERROR ("missing events arg", SCM_EOL);
    }
  else
    ev.events = scm_to_uint32 (events);

  ev.data.fd = c_fd;

  if (epoll_ctl (c_epfd, c_op, c_fd, &ev))
    SCM_SYSERROR;

  return SCM_UNSPECIFIED;
}
#undef FUNC_NAME

struct epoll_wait_data {
  int fd;
  struct epoll_event *events;
  int maxevents;
  int timeout;
  int rv;
  int err;
};

static void*
do_epoll_wait (void *p)
{
  struct epoll_wait_data *data = p;
  data->rv = epoll_wait (data->fd, data->events, data->maxevents,
                         data->timeout);
  data->err = errno;
  return NULL;
}

/* Wait on the files whose descriptors were registered on EPFD, and
   write the resulting events in EVENTSV, a bytevector.  Returns the
   number of struct epoll_event values that were written to EVENTSV,
   which may be zero if no files triggered wakeups within TIMEOUT
   milliseconds.  */
static SCM
scm_primitive_epoll_wait (SCM epfd, SCM wakefd, SCM wokefd,
                          SCM eventsv, SCM timeout)
#define FUNC_NAME "primitive-epoll-wait"
{
  int c_epfd, c_wakefd, c_wokefd, maxevents, rv, c_timeout;
  struct epoll_event *events;

  c_epfd = scm_to_int (epfd);
  c_wakefd = scm_to_int (wakefd);
  c_wokefd = scm_to_int (wokefd);

  SCM_VALIDATE_BYTEVECTOR (SCM_ARG2, eventsv);
  if (SCM_UNLIKELY (SCM_BYTEVECTOR_LENGTH (eventsv) % sizeof (*events)))
    SCM_OUT_OF_RANGE (SCM_ARG2, eventsv);

  events = (struct epoll_event *) SCM_BYTEVECTOR_CONTENTS (eventsv);
  maxevents = SCM_BYTEVECTOR_LENGTH (eventsv) / sizeof (*events);
  c_timeout = scm_to_int (timeout);

  if (scm_c_prepare_to_wait_on_fd (c_wakefd))
    rv = 0;
  else
    {
      struct epoll_wait_data data = { c_epfd, events, maxevents, c_timeout };
      scm_without_guile (do_epoll_wait, &data);
      rv = data.rv;
      scm_c_wait_finished ();
      if (rv < 0)
        {
          if (data.err == EINTR)
            rv = 0;
          else
            {
              errno = data.err;
              SCM_SYSERROR;
            }
        }
      else
        {
          /* Drain woke fd if appropriate.  Doing it from Scheme is a
             bit gnarly as we don't know if suspendable ports are
             enabled or not.  */
          int i;
          for (i = 0; i < rv; i++)
            if (events[i].data.fd == c_wokefd)
              {
                char zeroes[32];
                /* Remove wake fd from result set.  */
                rv--;
                memmove (events + i,
                         events + i + 1,
                         (rv - i) * sizeof (*events));
                /* Drain fd and ignore errors. */
                while (read (c_wokefd, zeroes, sizeof zeroes) == sizeof zeroes)
                  ;
                break;
              }
        }
    }

  return scm_from_int (rv);
}
#undef FUNC_NAME




/* Low-level helpers for (fibers poll).  */
void
init_fibers_epoll (void)
{
  scm_c_define_gsubr ("primitive-epoll-wake", 1, 0, 0,
                      scm_primitive_epoll_wake);
  scm_c_define_gsubr ("primitive-epoll-create", 1, 0, 0,
                      scm_primitive_epoll_create);
  scm_c_define_gsubr ("primitive-epoll-ctl", 3, 1, 0,
                      scm_primitive_epoll_ctl);
  scm_c_define_gsubr ("primitive-epoll-wait", 5, 0, 0,
                      scm_primitive_epoll_wait);
  scm_c_define ("%sizeof-struct-epoll-event",
                scm_from_size_t (sizeof (struct epoll_event)));
  scm_c_define ("%offsetof-struct-epoll-event-fd",
                scm_from_size_t (offsetof (struct epoll_event, data.fd)));
  scm_c_define ("EPOLLIN", scm_from_int (EPOLLIN));
  scm_c_define ("EPOLLOUT", scm_from_int (EPOLLOUT));
#ifdef EPOLLRDHUP
  scm_c_define ("EPOLLRDHUP", scm_from_int (EPOLLRDHUP));
#endif
  scm_c_define ("EPOLLPRI", scm_from_int (EPOLLPRI));
  scm_c_define ("EPOLLERR", scm_from_int (EPOLLERR));
  scm_c_define ("EPOLLHUP", scm_from_int (EPOLLHUP));
  scm_c_define ("EPOLLET", scm_from_int (EPOLLET));
#ifdef EPOLLONESHOT
  scm_c_define ("EPOLLONESHOT", scm_from_int (EPOLLONESHOT));
#endif
  scm_c_define ("EPOLL_CTL_ADD", scm_from_int (EPOLL_CTL_ADD));
  scm_c_define ("EPOLL_CTL_MOD", scm_from_int (EPOLL_CTL_MOD));
  scm_c_define ("EPOLL_CTL_DEL", scm_from_int (EPOLL_CTL_DEL));
}

/*
  Local Variables:
  c-file-style: "gnu"
  End:
*/
