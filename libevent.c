#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <event2/event.h>
#include <libguile.h>


struct event_data {
	int fd;
	short event;
};

struct wait_data {
	int rv;
    SCM events;
	int maxevents;
};

void free_evb(void* ev) {
	struct event_base *base = ev;
	event_base_free(base);
}

void cb_func(evutil_socket_t fd, short what, void *arg) {
	struct wait_data* data = arg;
    int rv = data->rv;
    if(rv == data->maxevents){
        printf("Max events fired. Ignoring\n");
        return;
    }
	struct event_data ev_data;
	ev_data.fd = fd;
    ev_data.event = what;
    int sz = sizeof(struct event_data);
    memcpy(data->events + (rv*sz), &ev_data, sz);

    data->rv += 1;
}

static SCM
scm_primitive_event_wake (SCM wakefd)
#define FUNC_NAME "primitive-event-wake"
{
    int c_fd;
    char zero = 0;

    c_fd = scm_to_int (wakefd);

    if (write (c_fd, &zero, 1) <= 0 && errno != EWOULDBLOCK && errno != EAGAIN)
        SCM_SYSERROR;

    return SCM_UNSPECIFIED;
}
#undef FUNC_NAME

static SCM 
scm_primitive_create_event_base(SCM eventsv)
#define FUNC_NAME "primitive-create-event-base"
{

	struct event_base *base;
    struct wait_data *data;
    if((base = event_base_new()) == NULL) {
		scm_syserror("Couldn't instantiate event_base");
	}

    data = (struct wait_data *) scm_gc_malloc(sizeof(struct wait_data), "wait_data");
	data->rv = 0;
    data->events = eventsv;
	data->maxevents = scm_to_int(scm_bytevector_length(eventsv));
	
	return scm_list_2(scm_from_pointer(base, free_evb), scm_from_pointer(data, NULL));
}
#undef FUNC_NAME

static SCM 
scm_primitive_add_event(SCM lst, SCM fd, SCM ev)
#define FUNC_NAME "primitive-add-event"
{
	
	int c_fd;
	short c_ev;
	struct event_base *base;
	struct wait_data *data;
	
	c_fd = scm_to_int(fd);
	c_ev = scm_to_short(ev);

	base = (struct event_base *) scm_to_pointer(scm_list_ref(lst, scm_from_int(0)));
	data = (struct wait_data *) scm_to_pointer(scm_list_ref(lst, scm_from_int(1)));

    event_base_once(base, c_fd, c_ev, cb_func, data, NULL);
    
	return SCM_UNSPECIFIED;
}

#undef FUNC_NAME

static uint64_t time_units_per_microsec;

static void run_event_loop(struct event_base *base, struct timeval *tv) 
{
	if(tv != NULL) {
		event_base_loopexit(base, tv);
	}

	event_base_dispatch(base);
}

static SCM
scm_primitive_event_loop(SCM lst, SCM timeout)
#define FUNC_NAME "primitive-event-loop"
{
	int microsec = 0;
	int64_t c_timeout;
	struct timeval tv;

	if (!scm_is_eq(timeout, SCM_UNDEFINED))
	{
		c_timeout = scm_to_int64(timeout);
		if (c_timeout > 0)
		{
			microsec = c_timeout / time_units_per_microsec;
			tv.tv_sec = 0;
			tv.tv_usec = microsec;
		}
	}

	struct event_base *base = (struct event_base *) scm_to_pointer(scm_list_ref(lst, scm_from_int(0)));
    struct wait_data *data = (struct wait_data *) scm_to_pointer(scm_list_ref(lst, scm_from_int(1)));

    if(data == NULL) {
        scm_wrong_type_arg_msg ("event-loop" , 1, scm_list_ref(lst, scm_from_int(1)),
                "event wait_data is null");
    }

	if (microsec != 0)
		run_event_loop(base, &tv);
	else 
		run_event_loop(base, NULL);

	return scm_from_int(data->rv);
}

#undef FUNC_NAME

void init_libevt (void) {

	time_units_per_microsec = scm_c_time_units_per_second / 1000000;

	scm_c_define_gsubr ("primitive-event-wake", 1, 0, 0,
                        scm_primitive_event_wake);

	scm_c_define_gsubr("primitive-create-event-base", 1, 0, 0, scm_primitive_create_event_base);
	
	scm_c_define_gsubr("primitive-add-event", 3, 0, 0, scm_primitive_add_event);
	
	scm_c_define_gsubr("primitive-event-loop", 2, 0, 0, scm_primitive_event_loop);

	scm_c_define("%sizeof-struct-event", scm_from_size_t(sizeof(struct event_data)));
	scm_c_define("%offsetof-struct-event-ev", scm_from_size_t(offsetof (struct event_data, event)));
	scm_c_define("EVREAD", scm_from_int(EV_READ));
	scm_c_define("EVWRITE", scm_from_int(EV_WRITE));
}