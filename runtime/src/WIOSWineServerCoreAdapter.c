#include <stdint.h>
#include <string.h>
#include <pthread.h>
#include <stdio.h>

#include "ntstatus.h"
#define WIN32_NO_STATUS
#include "wine/server_protocol.h"
#include "process.h"
#include "thread.h"
#include "handle.h"

/* All entry points touching Wine's current/global_error share this lock. */
static pthread_mutex_t core_mutex = PTHREAD_MUTEX_INITIALIZER;

/*
 * Wine server/main.c normally owns these globals. Arcadia does not embed
 * wineserver's executable entry point, so the reusable server core gets the
 * same ABI globals from this adapter instead.
 */
#define WIOS_TICKS_PER_SEC 10000000

int debug_level = 0;
int foreground = 0;
timeout_t master_socket_timeout = (timeout_t)(-3LL * WIOS_TICKS_PER_SEC);
const char *server_argv0 = 0;

/* Real Wine handler linked from server/handle.o. */
extern void req_close_handle(const struct close_handle_request *req,
                             struct close_handle_reply *reply);

typedef void (*wios_close_handle_handler)(
    const struct close_handle_request *,
    struct close_handle_reply *);

__attribute__((visibility("default")))
uint32_t wios_wine_server_core_protocol_version(void)
{
    return (uint32_t)SERVER_PROTOCOL_VERSION;
}

__attribute__((visibility("default")))
uint32_t wios_wine_server_core_abi_version(void)
{
    return 1u;
}

__attribute__((visibility("default")))
int wios_wine_server_core_has_close_handle(void)
{
    wios_close_handle_handler handler = req_close_handle;
    return handler != 0;
}

/*
 * Execute Wine's real close_handle request handler under the smallest state
 * needed for the invalid-handle path. The supplied handle is passed through
 * unchanged; with process->handles == NULL, Wine must return
 * STATUS_INVALID_HANDLE without touching an object table.
 *
 * Wine's current/global error state is restored before returning.
 */
__attribute__((visibility("default")))
uint32_t wios_wine_server_core_dispatch_close_handle(uint32_t handle)
{
    struct process probe_process;
    struct thread probe_thread;
    struct close_handle_request request;
    struct close_handle_reply reply;
    struct thread *saved_current;
    unsigned int saved_global_error, saved_current_error;
    uint32_t status;

    pthread_mutex_lock(&core_mutex);
    saved_current = current;
    saved_global_error = global_error;
    saved_current_error = saved_current ? saved_current->error : 0;

    memset(&probe_process, 0, sizeof(probe_process));
    memset(&probe_thread, 0, sizeof(probe_thread));
    memset(&request, 0, sizeof(request));
    memset(&reply, 0, sizeof(reply));

    probe_thread.process = &probe_process;
    probe_process.handles = NULL;

    request.__header.req = REQ_close_handle;
    request.__header.request_size = 0;
    request.__header.reply_size = 0;
    request.handle = (obj_handle_t)handle;

    current = &probe_thread;
    clear_error();

    req_close_handle(&request, &reply);
    status = (uint32_t)get_error();

    current = saved_current;
    global_error = saved_global_error;
    if (saved_current) saved_current->error = saved_current_error;
    pthread_mutex_unlock(&core_mutex);

    return status;
}

__attribute__((visibility("default")))
uint32_t wios_wine_server_core_probe_invalid_close(void)
{
    return wios_wine_server_core_dispatch_close_handle(0);
}

extern void req_event_op(const struct event_op_request *, struct event_op_reply *);
extern void req_query_event(const struct query_event_request *, struct query_event_reply *);

static char object_probe_detail[160] = "WINE_SERVER_OBJECTS=NOT_RUN";

static uint32_t probe_event_state(obj_handle_t handle, int expected)
{
    struct query_event_request request = {0};
    struct query_event_reply reply = {0};
    request.__header.req = REQ_query_event;
    request.handle = handle;
    clear_error();
    req_query_event(&request, &reply);
    if (get_error()) return get_error();
    return reply.manual_reset && reply.state == expected ? 0 : STATUS_UNSUCCESSFUL;
}

static uint32_t probe_event_change(obj_handle_t handle, int op)
{
    struct event_op_request request = {0};
    struct event_op_reply reply = {0};
    request.__header.req = REQ_event_op;
    request.handle = handle;
    request.op = op;
    clear_error();
    req_event_op(&request, &reply);
    return get_error();
}

static uint32_t probe_close(obj_handle_t handle)
{
    struct close_handle_request request = {0};
    struct close_handle_reply reply = {0};
    request.__header.req = REQ_close_handle;
    request.handle = handle;
    clear_error();
    req_close_handle(&request, &reply);
    return get_error();
}

/* Isolated unnamed object context, before process startup. No persistent
 * process, token, named namespace, waiting thread or guest syscall is claimed. */
__attribute__((visibility("default")))
uint32_t wios_wine_server_core_probe_objects(void)
{
    struct process process = {0};
    struct thread thread = {0};
    struct thread *saved_current;
    unsigned int saved_global_error, saved_current_error;
    struct event *event = NULL;
    obj_handle_t handle = 0, duplicate = 0;
    uint32_t status = STATUS_UNSUCCESSFUL;
    const char *stage = "HANDLE_TABLE";

    pthread_mutex_lock(&core_mutex);
    saved_current = current;
    saved_global_error = global_error;
    saved_current_error = saved_current ? saved_current->error : 0;
    thread.process = &process;
    current = &thread;
    clear_error();
    if (!(process.handles = alloc_handle_table(&process, 0))) goto done;
    stage = "CREATE_EVENT";
    if (!(event = create_event(NULL, NULL, 0, 1, 0, NULL))) goto done;
    stage = "ALLOC_HANDLE";
    if (!(handle = alloc_handle(&process, event, EVENT_ALL_ACCESS, 0))) goto done;
    release_object(event);
    event = NULL;
    stage = "QUERY_INITIAL";
    if ((status = probe_event_state(handle, 0))) goto done;
    stage = "SET_EVENT";
    if ((status = probe_event_change(handle, SET_EVENT))) goto done;
    if ((status = probe_event_state(handle, 1))) goto done;
    stage = "RESET_EVENT";
    if ((status = probe_event_change(handle, RESET_EVENT))) goto done;
    if ((status = probe_event_state(handle, 0))) goto done;
    stage = "DUPLICATE_QUERY_ONLY";
    clear_error();
    duplicate = duplicate_handle(&process, handle, &process, EVENT_QUERY_STATE, 0, 0);
    if (!duplicate) { status = get_error() ? get_error() : STATUS_UNSUCCESSFUL; goto done; }
    stage = "ACCESS_CHECK";
    if (probe_event_change(duplicate, SET_EVENT) != STATUS_ACCESS_DENIED)
    { status = STATUS_UNSUCCESSFUL; goto done; }
    stage = "CLOSE_ORIGINAL";
    if ((status = probe_close(handle))) goto done;
    stage = "DOUBLE_CLOSE";
    if (probe_close(handle) != STATUS_INVALID_HANDLE)
    { status = STATUS_UNSUCCESSFUL; goto done; }
    stage = "DUPLICATE_SURVIVES";
    if ((status = probe_event_state(duplicate, 0))) goto done;
    stage = "CLOSE_DUPLICATE";
    if ((status = probe_close(duplicate))) goto done;
    stage = "STALE_HANDLE";
    if (probe_event_state(duplicate, 0) != STATUS_INVALID_HANDLE)
    { status = STATUS_UNSUCCESSFUL; goto done; }
    status = 0;
    stage = "PASS";
done:
    if (status == STATUS_UNSUCCESSFUL && get_error()) status = get_error();
    if (event) release_object(event);
    close_process_handles(&process);
    snprintf(object_probe_detail, sizeof(object_probe_detail),
             "WINE_SERVER_OBJECTS=stage=%s status=0x%08X context=ISOLATED_UNNAMED", stage, status);
    current = saved_current;
    global_error = saved_global_error;
    if (saved_current) saved_current->error = saved_current_error;
    pthread_mutex_unlock(&core_mutex);
    return status;
}

__attribute__((visibility("default")))
const char *wios_wine_server_core_get_object_probe(void)
{
    static _Thread_local char snapshot[sizeof(object_probe_detail)];
    pthread_mutex_lock(&core_mutex);
    memcpy(snapshot, object_probe_detail, sizeof(snapshot));
    pthread_mutex_unlock(&core_mutex);
    return snapshot;
}

/* Scoped event transport probe. This is not Windows process startup: no token,
 * namespace, thread waits or guest process is created by this fixture. */
static struct process protocol_process;
static struct thread protocol_thread;
static int protocol_active;

__attribute__((visibility("default")))
uint32_t wios_wine_server_core_begin_event_context(void)
{
    struct thread *saved;
    unsigned int saved_error, saved_thread_error;
    struct event *event = NULL;
    obj_handle_t handle = 0;
    pthread_mutex_lock(&core_mutex);
    if (protocol_active) { pthread_mutex_unlock(&core_mutex); return 0; }
    saved = current;
    saved_error = global_error;
    saved_thread_error = saved ? saved->error : 0;
    memset(&protocol_process, 0, sizeof(protocol_process));
    memset(&protocol_thread, 0, sizeof(protocol_thread));
    protocol_thread.process = &protocol_process;
    current = &protocol_thread;
    clear_error();
    protocol_process.handles = alloc_handle_table(&protocol_process, 0);
    if (protocol_process.handles)
    {
        event = create_event(NULL, NULL, 0, 1, 0, NULL);
        if (event) handle = alloc_handle(&protocol_process, event, EVENT_ALL_ACCESS, 0);
    }
    if (event) release_object(event);
    if (handle) protocol_active = 1;
    else close_process_handles(&protocol_process);
    current = saved;
    global_error = saved_error;
    if (saved) saved->error = saved_thread_error;
    pthread_mutex_unlock(&core_mutex);
    return handle;
}

__attribute__((visibility("default")))
void wios_wine_server_core_end_event_context(void)
{
    struct thread *saved;
    unsigned int saved_error, saved_thread_error;
    pthread_mutex_lock(&core_mutex);
    saved = current;
    saved_error = global_error;
    saved_thread_error = saved ? saved->error : 0;
    current = &protocol_thread;
    if (protocol_active) close_process_handles(&protocol_process);
    protocol_active = 0;
    current = saved;
    global_error = saved_error;
    if (saved) saved->error = saved_thread_error;
    pthread_mutex_unlock(&core_mutex);
}

__attribute__((visibility("default")))
uint32_t wios_wine_server_core_dispatch_fixed(const void *request_ptr, void *reply_ptr)
{
    const union generic_request *request = request_ptr;
    union generic_reply *reply = reply_ptr;
    struct thread *saved;
    struct process empty_process = {0};
    struct thread empty_thread = {0};
    unsigned int saved_error, saved_thread_error;
    uint32_t status;
    if (!request || !reply) return STATUS_INVALID_PARAMETER;
    memset(reply, 0, sizeof(*reply));
    if (request->request_header.request_size || request->request_header.reply_size)
    { reply->reply_header.error = STATUS_INVALID_PARAMETER; return STATUS_INVALID_PARAMETER; }
    pthread_mutex_lock(&core_mutex);
    saved = current;
    saved_error = global_error;
    saved_thread_error = saved ? saved->error : 0;
    empty_thread.process = &empty_process;
    current = protocol_active ? &protocol_thread : &empty_thread;
    clear_error();
    switch (request->request_header.req)
    {
    case REQ_close_handle:
        req_close_handle(&request->close_handle_request, &reply->close_handle_reply);
        break;
    case REQ_event_op:
        if (protocol_active) req_event_op(&request->event_op_request, &reply->event_op_reply);
        else set_error(STATUS_PORT_DISCONNECTED);
        break;
    case REQ_query_event:
        if (protocol_active) req_query_event(&request->query_event_request, &reply->query_event_reply);
        else set_error(STATUS_PORT_DISCONNECTED);
        break;
    default:
        set_error(STATUS_NOT_IMPLEMENTED);
    }
    status = get_error();
    if (status) memset(reply, 0, sizeof(*reply));
    reply->reply_header.error = status;
    reply->reply_header.reply_size = 0;
    current = saved;
    global_error = saved_error;
    if (saved) saved->error = saved_thread_error;
    pthread_mutex_unlock(&core_mutex);
    return status;
}
