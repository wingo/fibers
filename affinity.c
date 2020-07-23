/*
 * Custom implementation of the getaffinty and setffinity scheme
 * procedures for Mac OSX taken from http://www.hybridkernel.com/2015/01/18/binding_threads_to_cores_osx.html
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
CPU_ZERO(cpu_set_t *cs) { cs->count = 0; }

static inline void
CPU_SET(int num, cpu_set_t *cs) { cs->count |= (1 << num); }

static inline int
CPU_ISSET(int num, cpu_set_t *cs) { return (cs->count & (1 << num)); }

int sched_getaffinity(pid_t pid, size_t cpu_size, cpu_set_t *cpu_set)
{
    int32_t core_count = 0;
    size_t len = sizeof(core_count);
    int ret = sysctlbyname(SYSCTL_CORE_COUNT, &core_count, &len, 0, 0);

    if (ret) {
        printf("error while get core count %d\n", ret);
        return -1;
    }

    cpu_set->count = 0;
    for(int i = 0; i < core_count; i++) {
        cpu_set->count |= (1 << i);
    }
    return 0;
}

int pthread_setaffinity_np(pthread_t thread, size_t cpu_size ,cpu_set_t *cpu_set)
{
    thread_port_t mach_thread;
    int core = 0;

    for(core = 0; core < 8 * cpu_size; core++) {
        if(CPU_ISSET(core, cpu_set)) break;
    }

    thread_affinity_policy_data_t policy = {core};
    mach_thread = pthread_mach_thread_np(thread);
    thread_policy_set(mach_thread, THREAD_AFFINITY_POLICY,
                      (thread_policy_t)&policy, 1);
    return 0;
}

static SCM scm_primitive_getaffinity(SCM id)
{
    pid_t pid = scm_to_int(id);
    cpu_set_t cs;
    CPU_ZERO(&cs);
    size_t cpu_size = sizeof(cs);
    sched_getaffinity(pid, cpu_size, &cs);

    SCM bv = scm_c_make_bitvector(cpu_size, scm_from_int(0));

    for(int core = 0; core < cpu_size; core++){
        if(CPU_ISSET(core, &cs)) {
            scm_c_bitvector_set_x(bv, core, scm_from_int(core));
        }
    }

    return bv;
    
}

static SCM scm_primitive_set_affinity(SCM id, SCM mask)
{
    pid_t pid = scm_to_int(id);
    cpu_set_t cs;
    CPU_ZERO(&cs);

    int num;
    for(size_t i = 0; i < scm_c_bitvector_length(mask); i++) {
        num = scm_c_bitvector_ref(mask, i);
        CPU_SET(num, &cs);
    }

    int ret = pthread_setaffinity_np(pid, sizeof(cpu_set_t), &cs);
    if(ret){
        printf("Error setting affinity\n");
    }

    return SCM_UNSPECIFIED;

}

void init_affinity(void) {
    scm_c_define_gsubr("getaffinity", 1, 0, 0,
                       scm_primitive_getaffinity);

    scm_c_define_gsubr("setaffinity", 2, 0, 0, 
                        scm_primitive_set_affinity);
}