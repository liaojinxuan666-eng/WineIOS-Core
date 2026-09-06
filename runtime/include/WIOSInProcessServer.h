#ifndef WIOS_INPROCESS_SERVER_H
#define WIOS_INPROCESS_SERVER_H

#include <stdint.h>

#include "WIOSRuntimeABI.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef uint32_t (*wios_close_handle_dispatch)(uint32_t handle);

int wios_inproc_server_attach_close_handle(wios_close_handle_dispatch dispatch);

int wios_inproc_server_start(wios_log_callback log_callback, void *log_context);
int wios_inproc_server_ping(void);

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
