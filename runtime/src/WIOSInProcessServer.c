#include "WIOSInProcessServer.h"

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

enum
{
    WIOS_REQUEST_NONE = 0,
    WIOS_REQUEST_PING = 1
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

    wios_log_callback log_callback;
    void *log_context;

    char last_error[512];
} wios_inproc_server_state;

static wios_inproc_server_state server = {
    PTHREAD_MUTEX_INITIALIZER,
    PTHREAD_COND_INITIALIZER
};

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

        /*
         * Phase 1 deliberately has one tiny request.  The synchronization,
         * sequencing and thread ownership are the parts under test here.
         * Wine's request handlers are attached in the next phase.
         */
        if (kind == WIOS_REQUEST_PING) response = 0;

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
        log_line("INPROC_SERVER_READY=FAIL");
        return -3;
    }
    pthread_mutex_unlock(&server.mutex);

    log_line("INPROC_SERVER_READY=PASS");
    log_line("INPROC_SERVER_CORE=HARNESS_ONLY");
    return 0;
}

int wios_inproc_server_ping(void)
{
    struct timespec deadline;
    uint64_t seq;
    int result;
    int response;

    pthread_mutex_lock(&server.mutex);

    if (!server.running || !server.ready)
    {
        set_error("in-process server is not ready");
        pthread_mutex_unlock(&server.mutex);
        log_line("INPROC_SERVER_ROUNDTRIP=FAIL");
        return -1;
    }

    seq = ++server.request_seq;
    server.request_kind = WIOS_REQUEST_PING;
    pthread_cond_broadcast(&server.cond);

    deadline = deadline_after_ms(2000);

    while (server.response_seq < seq && server.running)
    {
        result = pthread_cond_timedwait(&server.cond, &server.mutex, &deadline);
        if (result == ETIMEDOUT)
        {
            set_error("in-process server request timed out");
            pthread_mutex_unlock(&server.mutex);
            log_line("INPROC_SERVER_ROUNDTRIP=FAIL");
            return -2;
        }
        if (result != 0)
        {
            set_pthread_error("pthread_cond_timedwait(request)", result);
            pthread_mutex_unlock(&server.mutex);
            log_line("INPROC_SERVER_ROUNDTRIP=FAIL");
            return -3;
        }
    }

    if (server.response_seq < seq)
    {
        set_error("in-process server stopped before replying");
        pthread_mutex_unlock(&server.mutex);
        log_line("INPROC_SERVER_ROUNDTRIP=FAIL");
        return -4;
    }

    response = server.response_code;
    pthread_mutex_unlock(&server.mutex);

    if (response != 0)
    {
        set_error("in-process server returned an unexpected response");
        log_line("INPROC_SERVER_ROUNDTRIP=FAIL");
        return -5;
    }

    log_line("INPROC_SERVER_ROUNDTRIP=PASS");
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
