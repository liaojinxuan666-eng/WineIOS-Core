#include <stdint.h>
#include <string.h>

#include "ntstatus.h"
#include "wine/server_protocol.h"
#include "process.h"
#include "thread.h"

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
    struct thread *saved_current = current;
    unsigned int saved_global_error = global_error;
    unsigned int saved_current_error = saved_current ? saved_current->error : 0;
    uint32_t status;

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

    return status;
}

__attribute__((visibility("default")))
uint32_t wios_wine_server_core_probe_invalid_close(void)
{
    return wios_wine_server_core_dispatch_close_handle(0);
}
