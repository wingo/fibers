/* Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
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
