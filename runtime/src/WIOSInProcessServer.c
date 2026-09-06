#include "WIOSInProcessServer.h"

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "wine/server.h"

#define WIOS_STATUS_NOT_IMPLEMENTED   0xC0000002u
#define WIOS_STATUS_INVALID_HANDLE    0xC0000008u
#define WIOS_STATUS_INVALID_PARAMETER 0xC000000Du

enum
{
    WIOS_REQUEST_NONE = 0,
    WIOS_REQUEST_PING = 1,
    WIOS_REQUEST_WINE_PROTOCOL = 2
};

typedef struct
{
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    pthread_t thread;

    int created;
    int running;
    int thread_started;
    int ready;
    int stop_requested;

    uint64_t request_seq;
    uint64_t response_seq;
    int request_kind;
    int response_code;

    union generic_request wine_request;
    union generic_reply wine_reply;

    wios_close_handle_dispatch close_handle_dispatch;

    wios_log_callback log_callback;
    void *log_context;

    char last_error[512];
} wios_inproc_server_state;

static wios_inproc_server_state server = {
    PTHREAD_MUTEX_INITIALIZER,
    PTHREAD_COND_INITIALIZER
};

/*
 * These are intentional ABI gates. If the pinned Wine baseline changes its
 * wire layout, Arcadia must notice at compile time instead of silently
 * corrupting request/reply frames.
 */
_Static_assert(sizeof(struct request_header) == 12,
               "unexpected Wine request_header size");
_Static_assert(sizeof(struct reply_header) == 8,
               "unexpected Wine reply_header size");
_Static_assert(offsetof(struct close_handle_request, handle) == 12,
               "unexpected close_handle_request.handle offset");
_Static_assert(sizeof(struct close_handle_request) == 16,
               "unexpected close_handle_request size");

static void set_error(const char *text)
{
    if (!text) text = "unknown in-process server error";
    snprintf(server.last_error, sizeof(server.last_error), "%s", text);
}

static void set_pthread_error(const char *operation, int error)
{
    snprintf(server.last_error, sizeof(server.last_error),
             "%s failed: %d (%s)", operation, error, strerror(error));
}

static void log_line(const char *line)
{
    wios_log_callback callback;
    void *context;

    pthread_mutex_lock(&server.mutex);
    callback = server.log_callback;
    context = server.log_context;
    pthread_mutex_unlock(&server.mutex);

    if (callback) callback(context, line);
}

static void log_protocol_version(void)
{
    char line[128];
    snprintf(line, sizeof(line), "WINE_SERVER_PROTOCOL_VERSION=%u",
             (unsigned int)SERVER_PROTOCOL_VERSION);
    log_line(line);
}

static struct timespec deadline_after_ms(long milliseconds)
{
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);

    deadline.tv_sec += milliseconds / 1000;
    deadline.tv_nsec += (milliseconds % 1000) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L)
    {
        deadline.tv_sec += 1;
        deadline.tv_nsec -= 1000000000L;
    }
    return deadline;
}

int wios_inproc_server_attach_close_handle(wios_close_handle_dispatch dispatch)
{
    if (!dispatch)
    {
        set_error("missing close_handle dispatcher");
        return -1;
    }

    pthread_mutex_lock(&server.mutex);
    if (server.running)
    {
        set_error("cannot attach close_handle dispatcher while server is running");
        pthread_mutex_unlock(&server.mutex);
        return -2;
    }

    server.close_handle_dispatch = dispatch;
    pthread_mutex_unlock(&server.mutex);
    return 0;
}

static void handle_wine_protocol_frame(void)
{
    const struct request_header *header = &server.wine_request.request_header;
    struct reply_header *reply = &server.wine_reply.reply_header;

    memset(&server.wine_reply, 0, sizeof(server.wine_reply));

    if (header->req < 0 || header->req >= REQ_NB_REQUESTS)
    {
        reply->error = WIOS_STATUS_NOT_IMPLEMENTED;
        reply->reply_size = 0;
        server.response_code = -2;
        return;
    }

    if (header->req == REQ_close_handle)
    {
        if (server.close_handle_dispatch)
        {
            const struct close_handle_request *request =
                &server.wine_request.close_handle_request;

            reply->error =
                server.close_handle_dispatch((uint32_t)request->handle);
            reply->reply_size = 0;
            server.response_code = 0;
            return;
        }

        reply->error = WIOS_STATUS_NOT_IMPLEMENTED;
        reply->reply_size = 0;
        server.response_code = 0;
        return;
    }

    reply->error = WIOS_STATUS_NOT_IMPLEMENTED;
    reply->reply_size = 0;
    server.response_code = -3;
}

static void *server_thread_main(void *opaque)
{
    uint64_t handled_seq = 0;
    (void)opaque;

    pthread_mutex_lock(&server.mutex);
    server.thread_started = 1;
    server.ready = 1;
    pthread_cond_broadcast(&server.cond);

    while (!server.stop_requested)
    {
        uint64_t seq;
        int kind;
        int response = -1;

        while (!server.stop_requested && server.request_seq == handled_seq)
            pthread_cond_wait(&server.cond, &server.mutex);

        if (server.stop_requested) break;

        seq = server.request_seq;
        kind = server.request_kind;

        if (kind == WIOS_REQUEST_PING)
        {
            response = 0;
        }
        else if (kind == WIOS_REQUEST_WINE_PROTOCOL)
        {
            handle_wine_protocol_frame();
            response = server.response_code;
        }

        handled_seq = seq;
        server.response_code = response;
        server.response_seq = seq;
        pthread_cond_broadcast(&server.cond);
    }

    server.ready = 0;
    server.running = 0;
    pthread_cond_broadcast(&server.cond);
    pthread_mutex_unlock(&server.mutex);
    return NULL;
}

int wios_inproc_server_start(wios_log_callback log_callback, void *log_context)
{
    struct timespec deadline;
    int result;

    pthread_mutex_lock(&server.mutex);

    if (server.running)
    {
        server.log_callback = log_callback;
        server.log_context = log_context;
        pthread_mutex_unlock(&server.mutex);
        return 0;
    }

    server.created = 1;
    server.running = 1;
    server.thread_started = 0;
    server.ready = 0;
    server.stop_requested = 0;
    server.request_seq = 0;
    server.response_seq = 0;
    server.request_kind = WIOS_REQUEST_NONE;
    server.response_code = -1;
    memset(&server.wine_request, 0, sizeof(server.wine_request));
    memset(&server.wine_reply, 0, sizeof(server.wine_reply));
    server.log_callback = log_callback;
    server.log_context = log_context;
    server.last_error[0] = '\0';

    pthread_mutex_unlock(&server.mutex);
    log_line("INPROC_SERVER_CREATE=PASS");

    result = pthread_create(&server.thread, NULL, server_thread_main, NULL);
    if (result != 0)
    {
        pthread_mutex_lock(&server.mutex);
        server.running = 0;
        set_pthread_error("pthread_create", result);
        pthread_mutex_unlock(&server.mutex);
        log_line("INPROC_SERVER_THREAD=FAIL");
        return -1;
    }

    deadline = deadline_after_ms(2000);

    pthread_mutex_lock(&server.mutex);
    while (!server.thread_started)
    {
        result = pthread_cond_timedwait(&server.cond, &server.mutex, &deadline);
        if (result == ETIMEDOUT) break;
        if (result != 0)
        {
            set_pthread_error("pthread_cond_timedwait(thread)", result);
            break;
        }
    }

    if (!server.thread_started)
    {
        if (!server.last_error[0]) set_error("server thread start timed out");
        server.stop_requested = 1;
        pthread_cond_broadcast(&server.cond);
        pthread_mutex_unlock(&server.mutex);
        pthread_join(server.thread, NULL);
        log_line("INPROC_SERVER_THREAD=FAIL");
        return -2;
    }
    pthread_mutex_unlock(&server.mutex);

    log_line("INPROC_SERVER_THREAD=PASS");

    pthread_mutex_lock(&server.mutex);
    if (!server.ready)
    {
        set_error("server thread did not reach ready state");
        server.stop_requested = 1;
        pthread_cond_broadcast(&server.cond);
        pthread_mutex_unlock(&server.mutex);
        pthread_join(server.thread, NULL);
        log_line("INPROC_SERVER_THREAD=FAIL");
        return -3;
    }
    pthread_mutex_unlock(&server.mutex);

    log_line("INPROC_SERVER_READY=PASS");
    log_line("INPROC_SERVER_CORE=HANDLER_ATTACH_PHASE");
    return 0;
}

static int submit_request_and_wait(int kind, uint64_t *seq_out)
{
    struct timespec deadline;
    uint64_t seq;
    int result;

    if (!server.running || !server.ready)
    {
        set_error("in-process server is not ready");
        return -1;
    }

    seq = ++server.request_seq;
    server.request_kind = kind;
    pthread_cond_broadcast(&server.cond);

    deadline = deadline_after_ms(2000);

    while (server.response_seq < seq && server.running)
    {
        result = pthread_cond_timedwait(&server.cond, &server.mutex, &deadline);
        if (result == ETIMEDOUT)
        {
            set_error("in-process server request timed out");
            return -2;
        }
        if (result != 0)
        {
            set_pthread_error("pthread_cond_timedwait(request)", result);
            return -3;
        }
    }

    if (server.response_seq < seq)
    {
        set_error("in-process server stopped before replying");
        return -4;
    }

    if (seq_out) *seq_out = seq;
    return server.response_code;
}

uint32_t wios_inproc_server_call(void *req_ptr)
{
    struct __server_request_info *req = req_ptr;
    uint32_t status;
    int response;

    if (!req)
    {
        set_error("null Wine server request");
        return WIOS_STATUS_INVALID_PARAMETER;
    }

    pthread_mutex_lock(&server.mutex);

    if (!server.running || !server.ready)
    {
        set_error("in-process server is not ready");
        pthread_mutex_unlock(&server.mutex);
        return WIOS_STATUS_NOT_IMPLEMENTED;
    }

    /*
     * First NTDLL bridge gate is deliberately narrow. close_handle has no
     * variable request/reply payload, so accepting anything else here could
     * silently corrupt Wine's protocol state.
     */
    if (req->u.req.request_header.req != REQ_close_handle ||
        req->u.req.request_header.request_size != 0 ||
        req->u.req.request_header.reply_size != 0 ||
        req->data_count != 0)
    {
        set_error("Wine NTDLL bridge frame is not supported by this phase");
        pthread_mutex_unlock(&server.mutex);
        return WIOS_STATUS_NOT_IMPLEMENTED;
    }

    server.wine_request = req->u.req;
    memset(&server.wine_reply, 0, sizeof(server.wine_reply));

    response = submit_request_and_wait(WIOS_REQUEST_WINE_PROTOCOL, NULL);
    if (response != 0)
    {
        pthread_mutex_unlock(&server.mutex);
        return WIOS_STATUS_NOT_IMPLEMENTED;
    }

    req->u.reply = server.wine_reply;
    status = req->u.reply.reply_header.error;

    pthread_mutex_unlock(&server.mutex);
    return status;
}

int wios_inproc_server_ping(void)
{
    int response;

    pthread_mutex_lock(&server.mutex);
    response = submit_request_and_wait(WIOS_REQUEST_PING, NULL);
    pthread_mutex_unlock(&server.mutex);

    if (response != 0)
    {
        log_line("INPROC_SERVER_ROUNDTRIP=FAIL");
        return -1;
    }

    log_line("INPROC_SERVER_ROUNDTRIP=PASS");
    return 0;
}

int wios_inproc_server_probe_wine_protocol(void)
{
    struct close_handle_request *request;
    struct reply_header reply;
    int response;
    int handler_attached;

    pthread_mutex_lock(&server.mutex);

    if (!server.running || !server.ready)
    {
        set_error("in-process server is not ready");
        pthread_mutex_unlock(&server.mutex);
        log_line("WINE_SERVER_PROTOCOL_FRAME=FAIL");
        return -1;
    }

    memset(&server.wine_request, 0, sizeof(server.wine_request));
    memset(&server.wine_reply, 0, sizeof(server.wine_reply));

    request = &server.wine_request.close_handle_request;
    request->__header.req = REQ_close_handle;
    request->__header.request_size = 0;
    request->__header.reply_size = 0;
    request->handle = 0;

    handler_attached = server.close_handle_dispatch != NULL;
    response = submit_request_and_wait(WIOS_REQUEST_WINE_PROTOCOL, NULL);
    reply = server.wine_reply.reply_header;

    pthread_mutex_unlock(&server.mutex);

    log_protocol_version();
    log_line("WINE_SERVER_PROTOCOL_ABI=PASS");

    if (response != 0)
    {
        set_error("Wine protocol bridge rejected close_handle frame");
        log_line("WINE_SERVER_PROTOCOL_FRAME=FAIL");
        return -2;
    }

    log_line("WINE_SERVER_PROTOCOL_FRAME=PASS");

    if (reply.reply_size != 0)
    {
        set_error("Wine protocol bridge returned unexpected reply size");
        log_line("WINE_SERVER_PROTOCOL_REPLY=FAIL");
        return -3;
    }

    if (handler_attached)
    {
        if (reply.error != WIOS_STATUS_INVALID_HANDLE)
        {
            set_error("attached Wine close_handle handler returned unexpected status");
            log_line("WINE_SERVER_HANDLER_DISPATCH=FAIL");
            log_line("WINE_SERVER_PROTOCOL_REPLY=FAIL");
            return -4;
        }

        log_line("WINE_SERVER_PROTOCOL_REPLY=PASS");
        log_line("WINE_SERVER_HANDLERS=ATTACHED");
        log_line("WINE_SERVER_HANDLER_DISPATCH=PASS");
        log_line("WINE_SERVER_HANDLER_REPLY=STATUS_INVALID_HANDLE");
        log_line("INPROC_SERVER_PROTOCOL_BRIDGE=PASS");
        return 0;
    }

    if (reply.error != WIOS_STATUS_NOT_IMPLEMENTED)
    {
        set_error("unattached Wine protocol bridge returned unexpected status");
        log_line("WINE_SERVER_PROTOCOL_REPLY=FAIL");
        return -5;
    }

    log_line("WINE_SERVER_PROTOCOL_REPLY=PASS");
    log_line("WINE_SERVER_HANDLERS=NOT_ATTACHED");
    log_line("INPROC_SERVER_PROTOCOL_BRIDGE=PASS");
    return 0;
}

void wios_inproc_server_stop(void)
{
    int should_join = 0;

    pthread_mutex_lock(&server.mutex);
    if (server.running)
    {
        server.stop_requested = 1;
        pthread_cond_broadcast(&server.cond);
        should_join = 1;
    }
    pthread_mutex_unlock(&server.mutex);

    if (should_join)
    {
        pthread_join(server.thread, NULL);
        log_line("INPROC_SERVER_STOP=PASS");
    }
}

const char *wios_inproc_server_last_error(void)
{
    return server.last_error[0] ? server.last_error : "";
}
