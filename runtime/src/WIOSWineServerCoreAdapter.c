#include <stdint.h>

#include "wine/server_protocol.h"

/*
 * Wine server/main.c normally owns these globals.  Arcadia does not embed
 * wineserver's executable entry point, so the reusable server core gets the
 * same ABI globals from this adapter instead.
 */
#define WIOS_TICKS_PER_SEC 10000000

int debug_level = 0;
int foreground = 0;
timeout_t master_socket_timeout = (timeout_t)(-3LL * WIOS_TICKS_PER_SEC);
const char *server_argv0 = 0;

/*
 * Real Wine handler linked from server/handle.o.
 * Do not invoke it yet: Wine's current thread/process/object state has not
 * been attached to Arcadia's in-process transport.
 */
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
    /*
     * Taking the address creates a real link-time dependency on Wine's
     * req_close_handle without executing the stateful handler.
     */
    wios_close_handle_handler handler = req_close_handle;
    return handler != 0;
}
