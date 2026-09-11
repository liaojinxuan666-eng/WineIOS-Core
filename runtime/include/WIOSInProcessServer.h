#ifndef WIOS_INPROCESS_SERVER_H
#define WIOS_INPROCESS_SERVER_H

#include <stdint.h>

#include "WIOSRuntimeABI.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef uint32_t (*wios_close_handle_dispatch)(uint32_t handle);
/* Fixed-size Wine protocol only; callback receives generic request/reply unions. */
typedef uint32_t (*wios_fixed_request_dispatch)(const void *request, void *reply);
int wios_inproc_server_attach_fixed_dispatch(wios_fixed_request_dispatch dispatch);

/* Lifecycle and client calls are serialized internally. Dispatchers execute on
 * the worker and must return promptly; they and log callbacks must not re-enter
 * these APIs. Stop joins the worker and detaches the dispatcher. Reattach before
 * restarting. A timed-out mailbox must be stopped/joined before restart.
 * last_error returns a thread-local snapshot, valid until that thread reads it
 * again. Thread safety here does not make the Wine runtime itself reentrant. */

int wios_inproc_server_attach_close_handle(wios_close_handle_dispatch dispatch);

int wios_inproc_server_start(wios_log_callback log_callback, void *log_context);
int wios_inproc_server_ping(void);

/*
 * Wine-client bridge entry. The argument is Wine's __server_request_info.
 * Current phase intentionally supports the no-variable-data close_handle, event_op and query_event
 * requests; unsupported frames fail closed instead of falling back to
 * Wine's Unix fd transport.
 */
uint32_t wios_inproc_server_call(void *req_ptr);

/*
 * Sends one real Wine server-protocol frame through Arcadia's in-process
 * transport. If the Wine close_handle dispatcher is attached, the frame is
 * routed into Wine's real req_close_handle handler.
 */
int wios_inproc_server_probe_wine_protocol(void);

void wios_inproc_server_stop(void);
const char *wios_inproc_server_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
