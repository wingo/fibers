/* Copyright (C) 2020-2022 Aleix Conchillo Flaqué <aconchillo@gmail.com>
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

#include "clock-nanosleep.h"

#include <errno.h>
#include <time.h>
#include <stdint.h>

/**
 * The code below has been extracted from the following notcurses files:
 *
 * https://github.com/dankamongmen/notcurses
 *
 *   src/compat/compat.c
 *   src/compat/compat.h
 */

#define NANOSECS_IN_SEC 1000000000ul

#ifndef TIMER_ABSTIME
#ifdef __APPLE__
#define TIMER_ABSTIME 1
#else
#error "TIMER_ABSTIME undefined"
#endif
#endif

static inline uint64_t
timespec_to_ns (const struct timespec *ts)
{
  return ts->tv_sec * NANOSECS_IN_SEC + ts->tv_nsec;
}

int
_fibers_clock_nanosleep (clockid_t clockid, int flags, const struct timespec *request,
                         struct timespec *remain)
{
  struct timespec now;

  if(clock_gettime(clockid, &now))
    {
      return -1;
    }

  uint64_t nowns = timespec_to_ns(&now);
  uint64_t targns = timespec_to_ns(request);

  if(flags != TIMER_ABSTIME)
    {
      targns += nowns;
    }

  if(nowns < targns)
    {
      uint64_t waitns = targns - nowns;

      struct timespec waitts =
        {
          .tv_sec = waitns / 1000000000,
          .tv_nsec = waitns % 1000000000,
        };

      return nanosleep(&waitts, remain);
    }

  return 0;

}
