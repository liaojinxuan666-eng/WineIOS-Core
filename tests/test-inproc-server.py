#!/usr/bin/env python3
"""Test real pthread transport and pinned Wine ABI; handler returns tagged replies."""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
wine = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="wios-server-test-") as temp:
    binary = pathlib.Path(temp) / "server-test"
    subprocess.run([
        "cc", "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-D__WINESRC__",
        "-fms-extensions", "-pthread", "-Wall", "-Wextra", "-Werror",
        "-I" + str(root / "runtime/include"), "-I" + str(wine / "include"),
        str(root / "tests/inproc-server-smoke.c"),
        str(root / "runtime/src/WIOSInProcessServer.c"), "-o", str(binary)
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=40)
    # Inject condition-wait failures while holding the real mailbox mutex.
    # No production timeout override or artificial handler is compiled into CI's IPA.
    fault_test = pathlib.Path(temp) / "fault-test.c"
    fault_test.write_text(r'''
#include <pthread.h>
static int wait_fault;
static int fault_wait(pthread_cond_t *, pthread_mutex_t *, const struct timespec *);
#define pthread_cond_timedwait fault_wait
#include "WIOSInProcessServer.c"
#undef pthread_cond_timedwait
#include <assert.h>
static int fault_wait(pthread_cond_t *cond, pthread_mutex_t *mutex,
                      const struct timespec *deadline)
{
    int mode = wait_fault;
    wait_fault = 0;
    if (mode == 1) return ETIMEDOUT;
    if (mode == 2) return EINVAL;
    int result = pthread_cond_timedwait(cond, mutex, deadline);
    if (mode == 3 && result == 0 && server.response_seq == server.request_seq)
        return ETIMEDOUT; /* completion and timeout reached together */
    return result;
}
static uint32_t handler(uint32_t h) { (void)h; return WIOS_STATUS_INVALID_HANDLE; }
static void initialize_request(struct __server_request_info *req)
{
    memset(req, 0, sizeof(*req));
    req->u.req.close_handle_request.__header.req = REQ_close_handle;
}
int main(void)
{
    struct __server_request_info req;
    for (int mode = 1; mode <= 3; ++mode)
    {
        assert(wios_inproc_server_attach_close_handle(handler) == 0);
        assert(wios_inproc_server_start(NULL, NULL) == 0);
        initialize_request(&req);
        wait_fault = mode;
        uint32_t status = wios_inproc_server_call(&req);
        assert(status == (mode == 1 ? WIOS_STATUS_IO_TIMEOUT :
                          mode == 2 ? WIOS_STATUS_PORT_DISCONNECTED :
                                      WIOS_STATUS_INVALID_HANDLE));
        assert(req.u.reply.reply_header.error == status);
        if (mode < 3)
        {
            assert(wios_inproc_server_start(NULL, NULL) != 0);
            initialize_request(&req);
            assert(wios_inproc_server_call(&req) == WIOS_STATUS_PORT_DISCONNECTED);
        }
        wios_inproc_server_stop();
    }
    puts("PASS: timeout, wait failure, completed-at-timeout and mailbox restart gates");
}
''')
    subprocess.run([
        "cc", "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-D__WINESRC__",
        "-fms-extensions", "-pthread", "-Wall", "-Wextra", "-Werror",
        "-I" + str(root / "runtime/include"), "-I" + str(root / "runtime/src"),
        "-I" + str(wine / "include"), str(fault_test), "-o", str(binary)
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
