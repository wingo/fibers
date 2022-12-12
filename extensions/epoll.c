/* Copyright (C) 2016 Andy Wingo <wingo@pobox.com>
 * Copyright (C) 2022 Ludovic Courtès <ludo@gnu.org>
 * Copyright (C) 2022 Aleix Conchillo Flaqué <aconchillo@gmail.com>
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
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */




#define _GNU_SOURCE

#ifdef HAVE_CONFIG_H
# include <config.h>
#endif

#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <sys/epoll.h>
#include <libguile.h>

#if SCM_MAJOR_VERSION == 2
# include <fcntl.h>				  /* O_CLOEXEC */
#endif

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

static uint64_t time_units_per_millisecond;

/* Wait on the files whose descriptors were registered on EPFD, and
   write the resulting events in EVENTSV, a bytevector.  Returns the
   number of struct epoll_event values that were written to EVENTSV,
   which may be zero if no files triggered wakeups within TIMEOUT
   internal time units.  */
static SCM
scm_primitive_epoll_wait (SCM epfd, SCM wakefd, SCM wokefd,
                          SCM eventsv, SCM timeout)
#define FUNC_NAME "primitive-epoll-wait"
{
  int c_epfd, c_wakefd, c_wokefd, maxevents, rv, millis;
  int64_t c_timeout;
  struct epoll_event *events;

  c_epfd = scm_to_int (epfd);
  c_wakefd = scm_to_int (wakefd);
  c_wokefd = scm_to_int (wokefd);

  SCM_VALIDATE_BYTEVECTOR (SCM_ARG2, eventsv);
  if (SCM_UNLIKELY (SCM_BYTEVECTOR_LENGTH (eventsv) % sizeof (*events)))
    SCM_OUT_OF_RANGE (SCM_ARG2, eventsv);

  events = (struct epoll_event *) SCM_BYTEVECTOR_CONTENTS (eventsv);
  maxevents = SCM_BYTEVECTOR_LENGTH (eventsv) / sizeof (*events);
  c_timeout = scm_to_int64 (timeout);
  if (c_timeout < 0)
    millis = -1;
  else
    millis = c_timeout / time_units_per_millisecond;

  if (millis != 0 && scm_c_prepare_to_wait_on_fd (c_wakefd))
    rv = 0;
  else
    {
      struct epoll_wait_data data = { c_epfd, events, maxevents, millis };
      if (millis != 0)
        scm_without_guile (do_epoll_wait, &data);
      else
        do_epoll_wait (&data);
      rv = data.rv;
      if (millis != 0)
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

static SCM sym_read_pipe, sym_write_pipe;

static SCM
scm_pipe2 (SCM flags)
#define FUNC_NAME "scm_pipe2"
{
  int c_flags, ret, fd[2];
  SCM read_port, write_port;

  if (scm_is_eq (flags, SCM_UNDEFINED))
    c_flags = 0;
  else
    SCM_VALIDATE_INT_COPY (1, flags, c_flags);

  do
    ret = pipe2 (fd, c_flags);
  while (ret == EINTR);

  read_port = scm_fdes_to_port (fd[0], "r", sym_read_pipe);
  write_port = scm_fdes_to_port (fd[1], "w", sym_write_pipe);

  return scm_cons (read_port, write_port);
}
#undef FUNC_NAME



/* Low-level helpers for (fibers poll).  */
void
init_fibers_epoll (void)
{
  time_units_per_millisecond = scm_c_time_units_per_second / 1000;

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

  scm_c_define_gsubr ("pipe2", 0, 1, 0, scm_pipe2);
  sym_read_pipe = scm_from_latin1_string ("read pipe");
  sym_write_pipe = scm_from_latin1_string ("write pipe");

#if SCM_MAJOR_VERSION == 2
  /* Guile 2.2.7 lacks a definition for O_CLOEXEC.  */
  scm_c_define ("O_CLOEXEC", scm_from_int (O_CLOEXEC));
#endif
}

/*
  Local Variables:
  c-file-style: "gnu"
  End:
*/
