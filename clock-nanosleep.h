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

#ifndef FIBERS_CLOCK_NANOSLEEP_H
#define FIBERS_CLOCK_NANOSLEEP_H

#include <time.h>

int _fibers_clock_nanosleep (clockid_t clockid, int flags, const struct timespec *request,
                             struct timespec *remain);

#endif // FIBERS_CLOCK_NANOSLEEP_H
