#ifndef WIOS_INPROCESS_SERVER_H
#define WIOS_INPROCESS_SERVER_H

#include "WIOSRuntimeABI.h"

#ifdef __cplusplus
extern "C" {
#endif

int wios_inproc_server_start(wios_log_callback log_callback, void *log_context);
int wios_inproc_server_ping(void);

/*
 * Sends one real Wine server-protocol frame through Arcadia's in-process
 * transport.  Phase 2 validates Wine's generated protocol ABI; Wine's real
 * object/handle handlers are attached in later phases.
 */
int wios_inproc_server_probe_wine_protocol(void);

void wios_inproc_server_stop(void);
const char *wios_inproc_server_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
