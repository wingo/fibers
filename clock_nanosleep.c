#ifdef __APPLE__

#include "clock_nanosleep.h"

#include <errno.h>
#include <time.h>

int
clock_nanosleep(clockid_t id, int flags, const struct timespec *ts,
                struct timespec *ots)
{
  int ret = nanosleep(ts, ots);
  return ret ? errno : 0;
}

#endif // __APPLE__
