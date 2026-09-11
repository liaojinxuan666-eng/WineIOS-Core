#include "config.h"

#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#include "wine/server_protocol.h"
#include "object.h"
#include "process.h"
#include "thread.h"
#include "winnt.h"

#define WIOS_NATIVE_BOOTSTRAP_ABI_VERSION 1u
#define WIOS_NATIVE_BOOTSTRAP_STAGE_IDLE 0u
#define WIOS_NATIVE_BOOTSTRAP_STAGE_PROCESS 1u
#define WIOS_NATIVE_BOOTSTRAP_STAGE_THREAD 2u
#define WIOS_NATIVE_BOOTSTRAP_STAGE_FD_SENT 3u
#define WIOS_NATIVE_BOOTSTRAP_STAGE_CLEAN 4u

static uint32_t native_bootstrap_stage;

uint32_t wios_wine_server_native_bootstrap_abi_version(void)
{
    return WIOS_NATIVE_BOOTSTRAP_ABI_VERSION;
}

uint32_t wios_wine_server_native_bootstrap_stage(void)
{
    return native_bootstrap_stage;
}

/*
 * One-shot gate for Wine's real process/thread fd bootstrap.  server_fd is
 * always consumed by this function.  create_thread(-1, ...) is intentionally
 * used so Wine itself creates the request pipe and transfers its client end
 * through send_client_fd(..., SERVER_PROTOCOL_VERSION).
 */
int wios_wine_server_native_bootstrap_client(int server_fd)
{
    struct process *process = NULL;
    struct thread *thread = NULL;
    timeout_t saved_timeout;
    unsigned int saved_machine_count;
    unsigned short saved_native_machine;
    unsigned short saved_machines[8];
    int flags;
    int result = -1;

    native_bootstrap_stage = WIOS_NATIVE_BOOTSTRAP_STAGE_IDLE;

    if (server_fd < 0) return -1;

    flags = fcntl(server_fd, F_GETFL, 0);
    if (flags == -1 || fcntl(server_fd, F_SETFL, flags | O_NONBLOCK) == -1)
    {
        close(server_fd);
        return -1;
    }

    saved_timeout = master_socket_timeout;
    saved_native_machine = native_machine;
    saved_machine_count = supported_machines_count;
    memcpy(saved_machines, supported_machines, sizeof(saved_machines));

    master_socket_timeout = TIMEOUT_INFINITE;
    native_machine = IMAGE_FILE_MACHINE_ARM64;
    supported_machines_count = 1;
    memset(supported_machines, 0, sizeof(saved_machines));
    supported_machines[0] = IMAGE_FILE_MACHINE_ARM64;
    clear_error();

    /* create_process() takes ownership of server_fd even on failure. */
    process = create_process(server_fd, NULL, 0, NULL, NULL, NULL, 0, NULL);
    server_fd = -1;
    if (!process) goto done;
    native_bootstrap_stage = WIOS_NATIVE_BOOTSTRAP_STAGE_PROCESS;

    /* fd == -1 is Wine's native request-pipe bootstrap path. */
    thread = create_thread(-1, process, NULL);
    if (!thread) goto done;
    native_bootstrap_stage = WIOS_NATIVE_BOOTSTRAP_STAGE_THREAD;

    /* Successful return means send_client_fd() already completed. */
    native_bootstrap_stage = WIOS_NATIVE_BOOTSTRAP_STAGE_FD_SENT;
    result = 0;

 done:
    if (thread)
    {
        /* kill_thread() consumes the thread object's remaining references. */
        kill_thread(thread, 0);
        thread = NULL;
    }
    if (process) release_object(process);
    if (server_fd >= 0) close(server_fd);

    master_socket_timeout = saved_timeout;
    native_machine = saved_native_machine;
    supported_machines_count = saved_machine_count;
    memcpy(supported_machines, saved_machines, sizeof(saved_machines));

    if (!result) native_bootstrap_stage = WIOS_NATIVE_BOOTSTRAP_STAGE_CLEAN;
    return result;
}
