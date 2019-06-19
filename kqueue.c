/* Copyright (C) 2019 Larry Valkama
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



/* References
 *   FreeBSD KQueue https://www.freebsd.org/cgi/man.cgi?query=kqueue&sektion=2
 *
 *   Uses the EV_SET macro:
 *     EV_SET(kev, ident,filter,flags, fflags, data, udata);
 *   Together with kqueue and kevent functions.
 *   A thin shim is used to emulate the epoll events.
 *   The epoll events are EPOLLIN EPOLLOUT EPOLLONESHOT EPOLLIN EPOLLRDHUP,
 *   whose numbers are set arbitrarily and communicated to guile,
 *   on the C side, we translate them into kevents using kqueues filter and flags.
 */

#define _GNU_SOURCE

#ifdef HAVE_CONFIG_H
# include <config.h>
#endif

#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/event.h>

#include <libguile.h>

/* Substitution for {EPoll}
 */

static SCM
scm_primitive_epoll_wake (SCM wakefd)
#define FUNC_NAME "primitive-epoll-wake"
{
  int c_fd = scm_to_int (wakefd);
  char zero = 0;
  if (write (c_fd, &zero, 1) <= 0 && errno != EWOULDBLOCK && errno != EAGAIN)
    SCM_SYSERROR;
  return SCM_UNSPECIFIED;
}
#undef FUNC_NAME

static SCM
scm_primitive_epoll_create (SCM cloexec_p)
#define FUNC_NAME "epoll-create"
{
  int fd;

  fd = kqueue ();
  if (fd < 0)
    SCM_SYSERROR;
  // probably not necessary on freebsd
  if (scm_is_true (cloexec_p))
    fcntl (fd, F_SETFD, FD_CLOEXEC, 1);

  return scm_from_int (fd);
}
#undef FUNC_NAME

/* This epoll wrapper always places the fd itself as the "data" of the
   events structure.  */
static SCM
scm_primitive_epoll_ctl (SCM epfd, SCM op, SCM fd, SCM events)
#define FUNC_NAME "primitive-epoll-ctl"
{
  int c_epfd = scm_to_int (epfd);
  int c_op = scm_to_int (op);
  int c_fd = scm_to_int (fd);

  struct kevent ev = { 0, };

  // events can be EPOLLIN EPOLLOUT EPOLLONESHOT
  //  EPOLLIN EPOLLRDHUP

  if (SCM_UNBNDP (events))
    {
      if (c_op == 4) // DEL-op
        /* Events do not matter in this case.  */
        EV_SET(&ev, c_fd, 0, EV_DELETE, 0, 0, NULL);
      else
        SCM_MISC_ERROR ("missing events arg", SCM_EOL);
    }
  else
    {
      if (c_op == 2) c_op = 1; // MOD is handled by add-op (re-adding)
      int c_events = scm_to_uint32(events);
      int filter = EVFILT_VNODE;
      int fflags = 0;
      int op = EV_ADD;
      if (c_events & 128) {
        op |= EV_ONESHOT; // add the oneshot-flag
        c_events -= 128; // clear that flag
      }
      // currently only one event is supported
      // FIX is to make more event-structures (one per event)
      if (c_events & 1) { // EPOLLIN, check if READ is possible on FD
        filter = EVFILT_READ;
        if(c_events != 1){
           SCM_MISC_ERROR ("multi-EPOLLIN", SCM_EOL);
        }
      } else if (c_events & 2) { // EPOLLOUT, check if WRITE is possible on FD
        filter = EVFILT_WRITE;
        if(c_events != 2) SCM_MISC_ERROR ("multi-EPOLLOUT", SCM_EOL);
      } else if (c_events & 4) { // EPOLLRDHUP, while waiting for read, far-end has closed
        filter = EVFILT_VNODE;
        fflags = NOTE_CLOSE | NOTE_CLOSE_WRITE;
      } else {
        SCM_MISC_ERROR ("unknown-event", SCM_EOL);
      }
      EV_SET(&ev, c_fd, filter, op, fflags, 0, NULL);
    }

  if(kevent(c_epfd, &ev, 1, NULL, 0, NULL) < 0)
    SCM_SYSERROR;
  if (ev.flags & EV_ERROR)
    SCM_SYSERROR;

  return SCM_UNSPECIFIED;
}
#undef FUNC_NAME

struct kevent_wait_data {
  int fd;
  struct kevent *events;
  int maxevents;
  int timeout;
  int rv;
  int err;
};

static void*
do_epoll_wait (void *p)
{
  struct kevent_wait_data *data = p;
  // wait for events
  // setup timeout
  struct timespec timeout_ts;
  timeout_ts.tv_sec = data->timeout / 1000;
  timeout_ts.tv_nsec = (data->timeout % 1000) * 1000000;
  data->rv = kevent(data->fd, NULL        , 0              ,
                              data->events, data->maxevents,
                              data->timeout < 0 ? NULL : &timeout_ts);
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
  struct kevent *events;

  c_epfd = scm_to_int (epfd);
  c_wakefd = scm_to_int (wakefd);
  c_wokefd = scm_to_int (wokefd);

  SCM_VALIDATE_BYTEVECTOR (SCM_ARG2, eventsv);
  if (SCM_UNLIKELY (SCM_BYTEVECTOR_LENGTH (eventsv) % sizeof (*events)))
    SCM_OUT_OF_RANGE (SCM_ARG2, eventsv);

  events = (struct kevent *) SCM_BYTEVECTOR_CONTENTS (eventsv);
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
      struct kevent_wait_data data = { c_epfd, events, maxevents, millis };

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
            if (events[i].ident == c_wokefd)
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
                scm_from_size_t (sizeof (struct kevent)));
  scm_c_define ("%offsetof-struct-epoll-event-fd",
                scm_from_size_t (offsetof (struct kevent, ident)));
  scm_c_define ("EPOLLIN", scm_from_int (1));
  scm_c_define ("EPOLLOUT", scm_from_int (2));
#ifdef EPOLLRDHUP
  scm_c_define ("EPOLLRDHUP", scm_from_int (4));
#endif
  scm_c_define ("EPOLLPRI", scm_from_int (8));
  scm_c_define ("EPOLLERR", scm_from_int (16));
  scm_c_define ("EPOLLHUP", scm_from_int (32));
  scm_c_define ("EPOLLET", scm_from_int (64));
#ifdef EPOLLONESHOT
  scm_c_define ("EPOLLONESHOT", scm_from_int (128));
#endif
  scm_c_define ("EPOLL_CTL_ADD", scm_from_int (1));
  scm_c_define ("EPOLL_CTL_MOD", scm_from_int (2));
  scm_c_define ("EPOLL_CTL_DEL", scm_from_int (4));
}

/*
  Local Variables:
  c-file-style: "gnu"
  End:
*/
