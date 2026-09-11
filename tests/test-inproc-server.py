#!/usr/bin/env python3
"""Test real pthread transport and pinned Wine ABI; handler returns tagged replies."""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
wine = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="wios-server-test-") as temp:
    binary = pathlib.Path(temp) / "server-test"
    subprocess.run([
        "cc", "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-D__WINESRC__",
        "-fms-extensions", "-pthread", "-Wall", "-Wextra", "-Werror",
        "-I" + str(root / "runtime/include"), "-I" + str(wine / "include"),
        str(root / "tests/inproc-server-smoke.c"),
        str(root / "runtime/src/WIOSInProcessServer.c"), "-o", str(binary)
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=40)
    # Inject condition-wait failures while holding the real mailbox mutex.
    # No production timeout override or artificial handler is compiled into CI's IPA.
    fault_test = pathlib.Path(temp) / "fault-test.c"
    fault_test.write_text(r'''
#include <pthread.h>
static int wait_fault;
static int fault_wait(pthread_cond_t *, pthread_mutex_t *, const struct timespec *);
#define pthread_cond_timedwait fault_wait
#include "WIOSInProcessServer.c"
#undef pthread_cond_timedwait
#include <assert.h>
static int fault_wait(pthread_cond_t *cond, pthread_mutex_t *mutex,
                      const struct timespec *deadline)
{
    int mode = wait_fault;
    wait_fault = 0;
    if (mode == 1) return ETIMEDOUT;
    if (mode == 2) return EINVAL;
    int result = pthread_cond_timedwait(cond, mutex, deadline);
    if (mode == 3 && result == 0 && server.response_seq == server.request_seq)
        return ETIMEDOUT; /* completion and timeout reached together */
    return result;
}
static uint32_t handler(uint32_t h) { (void)h; return WIOS_STATUS_INVALID_HANDLE; }
static void initialize_request(struct __server_request_info *req)
{
    memset(req, 0, sizeof(*req));
    req->u.req.close_handle_request.__header.req = REQ_close_handle;
}
int main(void)
{
    struct __server_request_info req;
    for (int mode = 1; mode <= 3; ++mode)
    {
        assert(wios_inproc_server_attach_close_handle(handler) == 0);
        assert(wios_inproc_server_start(NULL, NULL) == 0);
        initialize_request(&req);
        wait_fault = mode;
        uint32_t status = wios_inproc_server_call(&req);
        assert(status == (mode == 1 ? WIOS_STATUS_IO_TIMEOUT :
                          mode == 2 ? WIOS_STATUS_PORT_DISCONNECTED :
                                      WIOS_STATUS_INVALID_HANDLE));
        assert(req.u.reply.reply_header.error == status);
        if (mode < 3)
        {
            assert(wios_inproc_server_start(NULL, NULL) != 0);
            initialize_request(&req);
            assert(wios_inproc_server_call(&req) == WIOS_STATUS_PORT_DISCONNECTED);
        }
        wios_inproc_server_stop();
    }
    puts("PASS: timeout, wait failure, completed-at-timeout and mailbox restart gates");
}
''')
    subprocess.run([
        "cc", "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-D__WINESRC__",
        "-fms-extensions", "-pthread", "-Wall", "-Wextra", "-Werror",
        "-I" + str(root / "runtime/include"), "-I" + str(root / "runtime/src"),
        "-I" + str(wine / "include"), str(fault_test), "-o", str(binary)
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)

# Optional: pass a native Wine build directory to exercise actual server objects.
# iPhoneOS objects cannot run on the CI Mac; this check uses a native server build.
if len(sys.argv) > 2:
    native = pathlib.Path(sys.argv[2]).resolve()
    with tempfile.TemporaryDirectory(prefix='wios-real-server-') as temp:
        test = pathlib.Path(temp) / 'objects.c'
        binary = pathlib.Path(temp) / 'objects'
        test.write_text(r'''
#include <assert.h>
#include <pthread.h>
#include "WIOSWineServerCoreAdapter.c"
#include "WIOSInProcessServer.h"
#include "wine/server.h"
static void *worker(void *unused)
{
    int i;
    for (i = 0; i < 100; i++)
    {
        unsigned int status = wios_wine_server_core_probe_objects();
        if (status) fprintf(stderr, "%s\n", wios_wine_server_core_get_object_probe());
        assert(!status);
        assert(wios_wine_server_core_dispatch_close_handle(0) == STATUS_INVALID_HANDLE);
    }
    return NULL;
}
static void protocol_test(void)
{
    struct __server_request_info r;
    for (int cycle = 0; cycle < 100; ++cycle)
    {
        assert(!wios_inproc_server_attach_fixed_dispatch(wios_wine_server_core_dispatch_fixed));
        assert(!wios_inproc_server_start(NULL, NULL));
        assert(wios_inproc_server_attach_fixed_dispatch(wios_wine_server_core_dispatch_fixed));
        obj_handle_t handle = wios_wine_server_core_begin_event_context();
        assert(handle);
        assert(!wios_wine_server_core_begin_event_context());
        for (int step = 0; step < 7; ++step)
        {
            memset(&r, 0, sizeof(r));
            int query = step == 0 || step == 2 || step == 4 || step == 6;
            if (query)
            {
                r.u.req.query_event_request.__header.req = REQ_query_event;
                r.u.req.query_event_request.handle = handle;
            }
            else if (step == 5)
            {
                r.u.req.close_handle_request.__header.req = REQ_close_handle;
                r.u.req.close_handle_request.handle = handle;
            }
            else
            {
                r.u.req.event_op_request.__header.req = REQ_event_op;
                r.u.req.event_op_request.handle = handle;
                r.u.req.event_op_request.op = step == 1 ? SET_EVENT : RESET_EVENT;
            }
            unsigned int expected = step == 6 ? STATUS_INVALID_HANDLE : 0;
            assert(wios_inproc_server_call(&r) == expected);
            assert(r.u.reply.reply_header.error == expected && !r.u.reply.reply_header.reply_size);
            if (!expected && query)
                assert(r.u.reply.query_event_reply.manual_reset && r.u.reply.query_event_reply.state == (step == 2));
            if (!expected && !query && step != 5)
                assert(r.u.reply.event_op_reply.state == (step == 3));
        }
        wios_wine_server_core_end_event_context();
        wios_wine_server_core_end_event_context();
        memset(&r, 0, sizeof(r));
        r.u.req.query_event_request.__header.req = REQ_query_event;
        assert(wios_inproc_server_call(&r) == STATUS_PORT_DISCONNECTED);
        for (int field = 0; field < 3; ++field)
        {
            memset(&r, 0, sizeof(r));
            r.u.req.query_event_request.__header.req = REQ_query_event;
            if (field == 0) r.data_count = 1;
            if (field == 1) r.u.req.request_header.request_size = 1;
            if (field == 2) r.u.req.request_header.reply_size = 1;
            assert(wios_inproc_server_call(&r) == STATUS_INVALID_PARAMETER);
        }
        assert(wios_wine_server_core_begin_event_context());
        wios_wine_server_core_end_event_context(); /* unclosed handle cleanup */
        wios_inproc_server_stop();
        assert(!wios_inproc_server_start(NULL, NULL));
        memset(&r, 0, sizeof(r));
        r.u.req.query_event_request.__header.req = REQ_query_event;
        assert(wios_inproc_server_call(&r) == STATUS_NOT_IMPLEMENTED);
        wios_inproc_server_stop();
    }
    puts("PASS: 100 real event lifecycles through worker, payload validation, previous-state replies, context cleanup and dispatcher detach");
}
int main(void)
{
    struct thread saved_thread = {0};
    pthread_t workers[4];
    unsigned int initial_events = event_type.obj_count, initial_objects = no_type.obj_count;
    int i;
    saved_thread.error = 37;
    current = &saved_thread;
    global_error = 99;
    for (i = 0; i < 4; i++) assert(!pthread_create(&workers[i], NULL, worker, NULL));
    for (i = 0; i < 4; i++) assert(!pthread_join(workers[i], NULL));
    protocol_test();
    assert(current == &saved_thread && saved_thread.error == 37 && global_error == 99);
    assert(event_type.obj_count == initial_events && no_type.obj_count == initial_objects);
    puts("PASS: 400 real Wine event/handle lifecycles, access checks, concurrent adapter calls, state restoration and object counts");
    current = NULL;
    return 0;
}
''')
        objects = sorted(p for p in (native / 'server').glob('*.o') if p.name != 'main.o')
        if not objects:
            raise RuntimeError('Native Wine server objects missing')
        subprocess.run(['cc', '-D__WINESRC__', '-fms-extensions', '-pthread',
                        '-I' + str(wine / 'include'), '-I' + str(wine / 'server'),
                        '-I' + str(root / 'runtime/src'), '-I' + str(root / 'runtime/include'), str(test),
                        str(root / 'runtime/src/WIOSInProcessServer.c'),
                        *map(str, objects), '-lm', '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=40)
