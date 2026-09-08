#include "WIOSInProcessServer.h"
#include "wine/server.h"
#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

#define CLIENTS 8
#define REQUESTS 1000
static atomic_int failures;
static atomic_int go;
static uint32_t dispatch(uint32_t handle)
{
    sched_yield();
    return handle ? (0xa0000000u | handle) : 0xc0000008u;
}
static void request_init(struct __server_request_info *req, uint32_t handle)
{
    memset(req, 0, sizeof(*req));
    req->u.req.close_handle_request.__header.req = REQ_close_handle;
    req->u.req.close_handle_request.handle = handle;
}
static void *client(void *arg)
{
    unsigned int id = (unsigned int)(uintptr_t)arg;
    while (!atomic_load(&go)) sched_yield();
    for (unsigned int i = 1; i <= REQUESTS; ++i)
    {
        struct __server_request_info req;
        unsigned int handle = id * REQUESTS + i;
        uint32_t expected = 0xa0000000u | handle;
        request_init(&req, handle);
        if (wios_inproc_server_call(&req) != expected ||
            req.u.reply.reply_header.error != expected ||
            req.u.reply.reply_header.reply_size != 0)
            atomic_fetch_add(&failures, 1);
    }
    return NULL;
}
static void *stopper(void *unused)
{
    (void)unused;
    wios_inproc_server_stop();
    return NULL;
}
static void *starter(void *unused)
{
    (void)unused;
    assert(wios_inproc_server_start(NULL, NULL) == 0);
    return NULL;
}
static void check_reply(struct __server_request_info *req, uint32_t status)
{
    assert(wios_inproc_server_call(req) == status);
    assert(req->u.reply.reply_header.error == status);
    assert(req->u.reply.reply_header.reply_size == 0);
}
int main(int argc, char **argv)
{
    pthread_t threads[CLIENTS];
    struct __server_request_info req;
    int stress_only = argc > 1 && !strcmp(argv[1], "--stress-only");
    assert(wios_inproc_server_attach_close_handle(dispatch) == 0);
    assert(wios_inproc_server_start(NULL, NULL) == 0);
    if (!stress_only)
    {
        assert(wios_inproc_server_ping() == 0);
        assert(wios_inproc_server_probe_wine_protocol() == 0);
        assert(wios_inproc_server_call(NULL) == 0xc000000du);
        request_init(&req, 1);
        req.u.req.request_header.req = REQ_NB_REQUESTS;
        check_reply(&req, 0xc000000du);
        request_init(&req, 1);
        req.u.req.request_header.req = REQ_init_thread;
        check_reply(&req, 0xc0000002u);
        for (int field = 0; field < 3; ++field)
        {
            request_init(&req, 1);
            if (field == 0) req.data_count = 1;
            if (field == 1) req.u.req.request_header.request_size = 4;
            if (field == 2) req.u.req.request_header.reply_size = 4;
            check_reply(&req, 0xc000000du);
        }
    }
    for (uintptr_t i = 0; i < CLIENTS; ++i)
        assert(pthread_create(&threads[i], NULL, client, (void *)i) == 0);
    atomic_store(&go, 1);
    for (int i = 0; i < CLIENTS; ++i) assert(pthread_join(threads[i], NULL) == 0);
    printf("concurrent request/reply mismatches: %d / %d\n",
           atomic_load(&failures), CLIENTS * REQUESTS);
    if (stress_only) return atomic_load(&failures) ? 1 : 0;
    assert(!atomic_load(&failures));
    for (int i = 0; i < CLIENTS; ++i)
        assert(pthread_create(&threads[i], NULL, stopper, NULL) == 0);
    for (int i = 0; i < CLIENTS; ++i) assert(pthread_join(threads[i], NULL) == 0);
    request_init(&req, 1);
    check_reply(&req, 0xc0000037u);
    assert(wios_inproc_server_ping() != 0);
    /* Detached callbacks cannot survive stop and point into an unloaded dylib. */
    for (int i = 0; i < CLIENTS; ++i)
        assert(pthread_create(&threads[i], NULL, starter, NULL) == 0);
    for (int i = 0; i < CLIENTS; ++i) assert(pthread_join(threads[i], NULL) == 0);
    request_init(&req, 1);
    check_reply(&req, 0xc0000002u);
    wios_inproc_server_stop();
    assert(wios_inproc_server_attach_close_handle(dispatch) == 0);
    assert(wios_inproc_server_start(NULL, NULL) == 0);
    request_init(&req, 7);
    check_reply(&req, 0xa0000007u);
    wios_inproc_server_stop();
    puts("PASS: protocol validation, 8000 concurrent calls, concurrent start/stop, restart");
    return 0;
}
