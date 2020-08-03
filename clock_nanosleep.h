#ifdef __APPLE__

#ifndef CLOCK_NANOSLEEP_H
#define CLOCK_NANOSLEEP_H

#include <time.h>

#ifndef TIMER_ABSTIME
#define TIMER_ABSTIME 1
#endif // TIMER_ABSTIME

int clock_nanosleep (clockid_t id, int flags, const struct timespec *ts,
                     struct timespec *ots);

#endif // CLOCK_NANOSLEEP_H
#endif // __APPLE__
