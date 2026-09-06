#ifndef WIOS_INPROCESS_SERVER_H
#define WIOS_INPROCESS_SERVER_H

#include "WIOSRuntimeABI.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Phase-1 in-process server harness.
 *
 * This is intentionally not the Wine server core yet.  It validates the
 * architecture Arcadia needs on ordinary sandboxed iOS:
 *
 *   Wine client code <-> in-process request/reply transport <-> server thread
 *
 * Once this gate is stable, Wine's existing server protocol/object core can
 * be attached behind this transport without depending on posix_spawn().
 */

int wios_inproc_server_start(wios_log_callback log_callback, void *log_context);
int wios_inproc_server_ping(void);
void wios_inproc_server_stop(void);
const char *wios_inproc_server_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
