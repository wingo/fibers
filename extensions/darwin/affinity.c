/*
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

/*
 * Custom implementation of the getaffinty and setffinity scheme procedures
 * for Mac OSX taken from:
 *    http://www.hybridkernel.com/2015/01/18/binding_threads_to_cores_osx.html
 */

#include <stdio.h>
#include <pthread.h>
#include <unistd.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <libguile.h>

#define SYSCTL_CORE_COUNT "machdep.cpu.core_count"

typedef struct cpu_set
{
  uint32_t count;
} cpu_set_t;

static inline void
CPU_ZERO (cpu_set_t *cs) { cs->count = 0; }

static inline void
CPU_SET (int num, cpu_set_t *cs) { cs->count |= (1 << num); }

static inline int
CPU_ISSET (int num, cpu_set_t *cs) { return (cs->count & (1 << num)); }

static int sched_getaffinity(size_t cpu_size, cpu_set_t *cpu_set)
{
  int32_t core_count = 0;
  size_t len = sizeof (core_count);
  // sysctlbyname() sets global errno if an error is returned.
  int ret = sysctlbyname (SYSCTL_CORE_COUNT, &core_count, &len, 0, 0);

  if (ret)
    return -1;

  cpu_set->count = 0;
  for (int i = 0; i < core_count; i++)
    {
      cpu_set->count |= (1 << i);
    }

  return 0;
}

static int pthread_setaffinity_np (size_t cpu_size, cpu_set_t *cpu_set)
{
  thread_port_t mach_thread;
  int core = 0;

  pthread_t thread = pthread_self();

  for(core = 0; core < 8 * cpu_size; core++)
    {
      if (CPU_ISSET(core, cpu_set))
        {
          break;
        }
    }

  thread_affinity_policy_data_t policy = {core};
  mach_thread = pthread_mach_thread_np(thread);
  thread_policy_set (mach_thread, THREAD_AFFINITY_POLICY,
                     (thread_policy_t) &policy, 1);

  return 0;
}

// We are currently only interested in the current thread, so we are ignoring
// the id (since currently we are always passing 0, which means the running
// thread).
static SCM scm_primitive_getaffinity (SCM id)
#define FUNC_NAME "getaffinity"
{
  cpu_set_t cs;
  CPU_ZERO(&cs);
  size_t cpu_size = sizeof(cs);

  int ret = sched_getaffinity (cpu_size, &cs);

  if (ret)
    SCM_SYSERROR;

  SCM bv = scm_c_make_bitvector (cpu_size, scm_from_int (0));

  for (int core = 0; core < cpu_size; core++)
    {
      if(CPU_ISSET(core, &cs))
        {
          scm_c_bitvector_set_bit_x (bv, core);
        }
    }

  return bv;
}
#undef FUNC_NAME

// We are currently only interested in the current thread, so we are ignoring
// the id (since currently we are always passing 0, which means the running
// thread).
static SCM scm_primitive_setaffinity (SCM id, SCM mask)
#define FUNC_NAME "getaffinity"
{
  cpu_set_t cs;
  CPU_ZERO(&cs);

  int num;
  for (size_t i = 0; i < scm_c_bitvector_length (mask); i++)
    {
      num = scm_c_bitvector_bit_is_set (mask, i);
      CPU_SET (num, &cs);
    }

  int ret = pthread_setaffinity_np (sizeof (cpu_set_t), &cs);

  if (ret)
    SCM_SYSERROR;

  return SCM_UNSPECIFIED;
}
#undef FUNC_NAME

void init_fibers_affinity (void)
{
  scm_c_define_gsubr ("getaffinity", 1, 0, 0, scm_primitive_getaffinity);
  scm_c_define_gsubr ("setaffinity", 2, 0, 0, scm_primitive_setaffinity);
}

/*
  Local Variables:
  c-file-style: "gnu"
  End:
*/
