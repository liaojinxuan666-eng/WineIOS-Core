#!/usr/bin/env python3
"""Compile the real initialize function with mocked loader/probe dependencies."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
source = (root / "runtime/src/WIOSRuntimeStub.c").read_text()
function = source[source.index("static int runtime_initialize("):
                  source.index("static int runtime_run_arm64_pe(")]
prefix = r'''
#include "WIOSRuntimeABI.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#define RTLD_NOW 1
#define RTLD_LOCAL 0
static void *ntdll_handle, *wine_main_entry, *wine_server_core_handle;
static char error_buffer[1024];
static int runtime_probe_attempted, runtime_probe_succeeded;
static int load_count, probe_count, stops, fail_load, fail_probe;
static void set_error(const char *s) { snprintf(error_buffer, sizeof(error_buffer), "%s", s); }
static void runtime_log(const wios_runtime_config *c, const char *s) { (void)c; (void)s; }
static int make_path(char *b, size_t n, const char *r, const char *p)
{ return snprintf(b,n,"%s/%s",r,p) < (int)n; }
static int verify_runtime_layout(const wios_runtime_config *c, const char *p)
{ (void)c; (void)p; return 0; }
static const char *dlerror(void) { return "mock dlopen failure"; }
static void *dlopen(const char *p, int flags)
{ (void)p; (void)flags; ++load_count; return fail_load ? NULL : (void *)1; }
static void *dlsym(void *h, const char *name) { (void)h; (void)name; return (void *)2; }
static void dlclose(void *h) { (void)h; }
static int probe_real_wine_server_core(const wios_runtime_config *c, const char *p)
{ (void)c; (void)p; wine_server_core_handle = (void *)3; return 0; }
static int probe_native_wine_server_fd_bootstrap(const wios_runtime_config *c)
{ (void)c; return 0; }
static int wios_inproc_server_start(wios_log_callback cb, void *ctx)
{ (void)cb; (void)ctx; return 0; }
static const char *wios_inproc_server_last_error(void) { return "mock server failure"; }
static int wios_inproc_server_ping(void) { return 0; }
static void wios_inproc_server_stop(void) { ++stops; }
static int wios_inproc_server_probe_wine_protocol(void) { return 0; }
static int probe_ntdll_server_call_bridge(const wios_runtime_config *c) { (void)c; return 0; }
static int probe_wine_main_entry(const wios_runtime_config *c)
{ (void)c; ++probe_count; if (fail_probe) set_error("shared data failed"); return fail_probe; }
'''
suffix = r'''
static void reset(void) /* fresh-process simulation, not a production retry */
{
    runtime_probe_attempted = runtime_probe_succeeded = 0;
    ntdll_handle = wine_main_entry = wine_server_core_handle = NULL;
    load_count = probe_count = stops = fail_load = fail_probe = 0;
    error_buffer[0] = 0;
}
int main(void)
{
    wios_runtime_config c = {sizeof(c), "/bundle", NULL, NULL};
    assert(runtime_initialize(NULL) == -1);
    assert(!runtime_probe_attempted);
    fail_probe = 1;
    assert(runtime_initialize(&c) == -13);
    assert(stops == 1 && load_count == 1 && probe_count == 1);
    assert(ntdll_handle && wine_main_entry && wine_server_core_handle);
    assert(runtime_initialize(&c) == -14); /* old code incorrectly returned 0 */
    assert(!strcmp(error_buffer, "shared data failed"));
    assert(load_count == 1 && probe_count == 1);
    reset();
    fail_load = 1;
    assert(runtime_initialize(&c) == -6);
    assert(runtime_initialize(&c) == -14 && load_count == 1);
    reset();
    assert(runtime_initialize(&c) == 0);
    assert(runtime_initialize(&c) == 0 && probe_count == 1);
    runtime_probe_succeeded = 0; /* shutdown invalidates completion */
    assert(runtime_initialize(&c) == -14);
    assert(runtime_initialize(NULL) == -1);
    puts("PASS: runtime failure, retry, idempotence and post-shutdown gates (mock loader)");
}
'''
with tempfile.TemporaryDirectory(prefix="wios-retry-test-") as temp:
    test = pathlib.Path(temp) / "test.c"
    test.write_text(prefix + function + suffix)
    binary = pathlib.Path(temp) / "test"
    subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                    "-I" + str(root / "runtime/include"), str(test), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
