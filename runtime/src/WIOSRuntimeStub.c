#include "WIOSRuntimeABI.h"
#include "WIOSInProcessServer.h"

#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "wine/server.h"

#define WIOS_STATUS_INVALID_HANDLE 0xC0000008u
#define WIOS_MAIN_PROBE_STAGE_PATHS 1u
#define WIOS_MAIN_PROBE_STAGE_VIRTUAL_INIT 2u
#define WIOS_MAIN_PROBE_STAGE_ENVIRONMENT 3u

static void *ntdll_handle;
static void *wine_main_entry;
static void *wine_server_core_handle;
static char error_buffer[1024];

typedef uint32_t (*wios_core_u32_fn)(void);
typedef int (*wios_core_bool_fn)(void);
typedef uint32_t (*wios_core_close_handle_fn)(uint32_t handle);
typedef void (*wios_ntdll_set_bridge_fn)(uint32_t (*bridge)(void *));
typedef uint32_t (*wios_ntdll_probe_call_fn)(void *);
typedef void (*wios_wine_main_fn)(int argc, char **argv);
typedef void (*wios_ntdll_set_main_probe_stage_fn)(uint32_t stage);

static wios_ntdll_set_bridge_fn ntdll_set_server_call_bridge;
static wios_ntdll_set_main_probe_stage_fn ntdll_set_main_probe_stage;

static void set_error(const char *text)
{
    if (!text) text = "unknown error";
    snprintf(error_buffer, sizeof(error_buffer), "%s", text);
}

static void runtime_log(const wios_runtime_config *config, const char *line)
{
    if (config && config->log_callback)
        config->log_callback(config->log_context, line);
}

static int make_path(char *buffer, size_t buffer_size,
                     const char *root, const char *relative)
{
    int written = snprintf(buffer, buffer_size, "%s/%s", root, relative);
    return written >= 0 && (size_t)written < buffer_size;
}

static int verify_runtime_layout(const wios_runtime_config *config,
                                 const char *runtime_root)
{
    static const char *required[] = {
        "libWIOSWineServerCore.dylib",
        "dlls/ntdll/ntdll.so",
        "dlls/ntdll/aarch64-windows/ntdll.dll",
        "dlls/kernelbase/aarch64-windows/kernelbase.dll",
        "dlls/kernel32/aarch64-windows/kernel32.dll",
        "hello/hello.exe"
    };

    char path[4096];
    struct stat st;
    size_t i;

    for (i = 0; i < sizeof(required) / sizeof(required[0]); ++i)
    {
        if (!make_path(path, sizeof(path), runtime_root, required[i]))
        {
            set_error("runtime path is too long");
            runtime_log(config, "WINE_RUNTIME_LAYOUT=FAIL");
            return -1;
        }

        errno = 0;
        if (stat(path, &st) != 0)
        {
            snprintf(error_buffer, sizeof(error_buffer),
                     "runtime file missing: %s (errno=%d: %s)",
                     required[i], errno, strerror(errno));
            runtime_log(config, "WINE_RUNTIME_LAYOUT=FAIL");
            return -1;
        }

        if (!S_ISREG(st.st_mode))
        {
            snprintf(error_buffer, sizeof(error_buffer),
                     "runtime path is not a regular file: %s", required[i]);
            runtime_log(config, "WINE_RUNTIME_LAYOUT=FAIL");
            return -1;
        }
    }

    runtime_log(config, "WINE_RUNTIME_LAYOUT=PASS");
    return 0;
}

static int probe_real_wine_server_core(const wios_runtime_config *config,
                                       const char *runtime_root)
{
    char core_path[4096];
    const char *dl_error;
    wios_core_u32_fn protocol_version;
    wios_core_u32_fn abi_version;
    wios_core_bool_fn has_close_handle;
    wios_core_u32_fn probe_invalid_close;
    wios_core_close_handle_fn dispatch_close_handle;
    uint32_t protocol;
    uint32_t abi;
    uint32_t handler_status;

    if (!make_path(core_path, sizeof(core_path),
                   runtime_root, "libWIOSWineServerCore.dylib"))
    {
        set_error("Wine server core path is too long");
        return -1;
    }

    runtime_log(config, "WINE_SERVER_CORE_BUNDLE_PATH=READY");

    dlerror();
    wine_server_core_handle = dlopen(core_path, RTLD_NOW | RTLD_LOCAL);
    if (!wine_server_core_handle)
    {
        dl_error = dlerror();
        set_error(dl_error ? dl_error : "Wine server core dlopen failed");
        runtime_log(config, "WINE_SERVER_CORE_DLOPEN=FAIL");
        return -2;
    }

    runtime_log(config, "WINE_SERVER_CORE_DLOPEN=PASS");

    dlerror();
    protocol_version = (wios_core_u32_fn)dlsym(
        wine_server_core_handle, "wios_wine_server_core_protocol_version");
    abi_version = (wios_core_u32_fn)dlsym(
        wine_server_core_handle, "wios_wine_server_core_abi_version");
    has_close_handle = (wios_core_bool_fn)dlsym(
        wine_server_core_handle, "wios_wine_server_core_has_close_handle");
    probe_invalid_close = (wios_core_u32_fn)dlsym(
        wine_server_core_handle, "wios_wine_server_core_probe_invalid_close");
    dispatch_close_handle = (wios_core_close_handle_fn)dlsym(
        wine_server_core_handle, "wios_wine_server_core_dispatch_close_handle");

    if (!protocol_version || !abi_version ||
        !has_close_handle || !probe_invalid_close || !dispatch_close_handle)
    {
        dl_error = dlerror();
        set_error(dl_error ? dl_error : "Wine server core API symbol missing");
        runtime_log(config, "WINE_SERVER_CORE_API=FAIL");
        return -3;
    }

    runtime_log(config, "WINE_SERVER_CORE_API=PASS");

    abi = abi_version();
    if (abi != 1u)
    {
        snprintf(error_buffer, sizeof(error_buffer),
                 "Wine server core ABI mismatch: got %u expected 1",
                 (unsigned int)abi);
        runtime_log(config, "WINE_SERVER_CORE_ABI=FAIL");
        return -4;
    }
    runtime_log(config, "WINE_SERVER_CORE_ABI=PASS");

    protocol = protocol_version();
    if (protocol != (uint32_t)SERVER_PROTOCOL_VERSION)
    {
        snprintf(error_buffer, sizeof(error_buffer),
                 "Wine server protocol mismatch: got %u expected %u",
                 (unsigned int)protocol,
                 (unsigned int)SERVER_PROTOCOL_VERSION);
        runtime_log(config, "WINE_SERVER_CORE_PROTOCOL=FAIL");
        return -5;
    }

    {
        char line[128];
        snprintf(line, sizeof(line),
                 "WINE_SERVER_CORE_PROTOCOL_VERSION=%u",
                 (unsigned int)protocol);
        runtime_log(config, line);
    }
    runtime_log(config, "WINE_SERVER_CORE_PROTOCOL=PASS");

    if (!has_close_handle())
    {
        set_error("Wine req_close_handle is not linked into server core");
        runtime_log(config, "WINE_SERVER_CORE_HANDLER_LINK=FAIL");
        return -6;
    }

    runtime_log(config, "WINE_SERVER_CORE_HANDLER_LINK=PASS");

    handler_status = probe_invalid_close();

    {
        char line[128];
        snprintf(line, sizeof(line),
                 "WINE_SERVER_CORE_HANDLER_STATUS=0x%08X",
                 (unsigned int)handler_status);
        runtime_log(config, line);
    }

    if (handler_status != WIOS_STATUS_INVALID_HANDLE)
    {
        snprintf(error_buffer, sizeof(error_buffer),
                 "Wine req_close_handle returned 0x%08X; expected 0x%08X",
                 (unsigned int)handler_status,
                 (unsigned int)WIOS_STATUS_INVALID_HANDLE);
        runtime_log(config, "WINE_SERVER_CORE_HANDLER_CONTEXT=FAIL");
        runtime_log(config, "WINE_SERVER_CORE_HANDLER_EXECUTION=FAIL");
        return -7;
    }

    runtime_log(config, "WINE_SERVER_CORE_HANDLER_CONTEXT=PASS");
    runtime_log(config, "WINE_SERVER_CORE_HANDLER_EXECUTION=PASS");
    runtime_log(config, "WINE_SERVER_CORE_HANDLER_RESULT=PASS");

    if (wios_inproc_server_attach_close_handle(
            (wios_close_handle_dispatch)dispatch_close_handle) != 0)
    {
        set_error(wios_inproc_server_last_error());
        runtime_log(config, "WINE_SERVER_CORE_HANDLER_ATTACH=FAIL");
        return -8;
    }

    runtime_log(config, "WINE_SERVER_CORE_HANDLER_ATTACH=PASS");
    runtime_log(config, "WINE_SERVER_CORE_DEVICE_LOAD=PASS");
    return 0;
}

static int probe_ntdll_server_call_bridge(const wios_runtime_config *config)
{
    const char *dl_error;
    wios_ntdll_probe_call_fn probe_call;
    struct __server_request_info request_info;
    struct close_handle_request *request;
    uint32_t status;

    dlerror();
    ntdll_set_server_call_bridge = (wios_ntdll_set_bridge_fn)dlsym(
        ntdll_handle, "wios_ntdll_set_server_call_bridge");
    probe_call = (wios_ntdll_probe_call_fn)dlsym(
        ntdll_handle, "wios_ntdll_probe_server_call");

    if (!ntdll_set_server_call_bridge || !probe_call)
    {
        dl_error = dlerror();
        set_error(dl_error ? dl_error : "NTDLL server bridge symbol missing");
        runtime_log(config, "NTDLL_SERVER_BRIDGE_SYMBOLS=FAIL");
        return -1;
    }

    runtime_log(config, "NTDLL_SERVER_BRIDGE_SYMBOLS=PASS");

    ntdll_set_server_call_bridge(wios_inproc_server_call);
    runtime_log(config, "NTDLL_SERVER_BRIDGE_ATTACH=PASS");

    memset(&request_info, 0, sizeof(request_info));
    request = &request_info.u.req.close_handle_request;
    request->__header.req = REQ_close_handle;
    request->__header.request_size = 0;
    request->__header.reply_size = 0;
    request->handle = 0;

    /*
     * This enters Wine's real ntdll wine_server_call() first. The iOS bridge
     * then replaces only the Unix fd transport, forwards the protocol frame to
     * the in-process server thread, and returns the real req_close_handle result.
     */
    status = probe_call(&request_info);

    {
        char line[128];
        snprintf(line, sizeof(line),
                 "NTDLL_WINE_SERVER_CALL_STATUS=0x%08X",
                 (unsigned int)status);
        runtime_log(config, line);
    }

    if (status != WIOS_STATUS_INVALID_HANDLE ||
        request_info.u.reply.reply_header.error != WIOS_STATUS_INVALID_HANDLE ||
        request_info.u.reply.reply_header.reply_size != 0)
    {
        set_error("NTDLL wine_server_call bridge returned unexpected reply");
        runtime_log(config, "NTDLL_WINE_SERVER_CALL=FAIL");
        runtime_log(config, "NTDLL_INPROC_SERVER_PATH=FAIL");
        ntdll_set_server_call_bridge(NULL);
        ntdll_set_server_call_bridge = NULL;
        return -2;
    }

    runtime_log(config, "NTDLL_WINE_SERVER_CALL=PASS");
    runtime_log(config, "NTDLL_INPROC_SERVER_PATH=PASS");
    runtime_log(config, "NTDLL_UNIX_FD_TRANSPORT=BYPASSED_FOR_PROBE");
    return 0;
}

static int probe_wine_main_entry(const wios_runtime_config *config)
{
    const char *dl_error;
    const char *home;
    const char *prefix;
    wios_wine_main_fn wine_main;
    static char arg0[] = "wine";
    static char arg1[] = "__wios_main_entry_probe__";
    static char *argv[] = { arg0, arg1, NULL };

    home = getenv("HOME");
    if (!home || home[0] != '/')
    {
        set_error("Wine main probe requires an absolute HOME path");
        runtime_log(config, "WINE_MAIN_ENV=FAIL");
        return -1;
    }

    prefix = getenv("WINEPREFIX");
    if (prefix && prefix[0] && prefix[0] != '/')
    {
        set_error("Wine main probe refuses a relative WINEPREFIX");
        runtime_log(config, "WINE_MAIN_ENV=FAIL");
        return -2;
    }

    runtime_log(config, "WINE_MAIN_ENV=PASS");

    dlerror();
    ntdll_set_main_probe_stage = (wios_ntdll_set_main_probe_stage_fn)dlsym(
        ntdll_handle, "wios_ntdll_set_main_probe_stop_stage");
    if (!ntdll_set_main_probe_stage)
    {
        dl_error = dlerror();
        set_error(dl_error ? dl_error : "NTDLL Wine main probe symbol missing");
        runtime_log(config, "WINE_MAIN_PROBE_SYMBOL=FAIL");
        return -3;
    }

    runtime_log(config, "WINE_MAIN_PROBE_SYMBOL=PASS");

    if (wios_inproc_server_ping() != 0)
    {
        set_error(wios_inproc_server_last_error());
        runtime_log(config, "WINE_SERVER_ACTIVE=FAIL");
        return -4;
    }
    runtime_log(config, "WINE_SERVER_ACTIVE=PASS");

    /*
     * Wine normally evaluates its command line immediately after init_paths().
     * This probe is not launching a PE yet, so explicitly suppress that re-exec
     * path and advance only through virtual_init().
     */
    if (setenv("WINELOADERNOEXEC", "1", 1) != 0)
    {
        snprintf(error_buffer, sizeof(error_buffer),
                 "failed to set WINELOADERNOEXEC (errno=%d: %s)",
                 errno, strerror(errno));
        runtime_log(config, "WINE_MAIN_NOEXEC_ENV=FAIL");
        return -5;
    }
    runtime_log(config, "WINE_MAIN_NOEXEC_ENV=PASS");

    wine_main = (wios_wine_main_fn)wine_main_entry;
    ntdll_set_main_probe_stage(WIOS_MAIN_PROBE_STAGE_ENVIRONMENT);
    runtime_log(config, "WINE_MAIN_CALL=BEGIN");
    wine_main(2, argv);
    ntdll_set_main_probe_stage(0);

    runtime_log(config, "WINE_MAIN_ENTER=PASS");
    runtime_log(config, "WINE_MAIN_PATH_INIT=PASS");
    runtime_log(config, "WINE_VIRTUAL_INIT=PASS");
    runtime_log(config, "WINE_ENV_INIT=PASS");
    runtime_log(config, "WINE_MAIN_STOP_AFTER=ENVIRONMENT");
    runtime_log(config, "WINE_MAIN_THREAD_INIT=NOT_RUN");
    runtime_log(config, "WINE_PREFIX_INIT=NOT_RUN");
    runtime_log(config, "WINDOWS_LOADER_INIT=NOT_RUN");
    runtime_log(config, "WINDOWS_ARM64_HELLO=NOT_RUN");
    return 0;
}

static int runtime_initialize(const wios_runtime_config *config)
{
    char runtime_root[4096];
    char ntdll_path[4096];
    const char *dl_error;
    const char *server_error;

    error_buffer[0] = '\0';

    if (!config || config->struct_size < sizeof(*config))
    {
        set_error("invalid runtime config");
        return -1;
    }

    if (!config->container_root_utf8 || !config->container_root_utf8[0])
    {
        set_error("missing bundle root");
        return -2;
    }

    if (ntdll_handle && wine_main_entry && wine_server_core_handle)
    {
        runtime_log(config, "RUNTIME_ALREADY_INITIALIZED");
        return 0;
    }

    if (!make_path(runtime_root, sizeof(runtime_root),
                   config->container_root_utf8, "Frameworks/WineRuntime"))
    {
        set_error("runtime root path is too long");
        return -3;
    }

    runtime_log(config, "RUNTIME_ABI=PASS");
    runtime_log(config, "WINE_RUNTIME_ROOT=READY");

    if (verify_runtime_layout(config, runtime_root) != 0)
        return -4;

    if (!make_path(ntdll_path, sizeof(ntdll_path),
                   runtime_root, "dlls/ntdll/ntdll.so"))
    {
        set_error("ntdll path is too long");
        return -5;
    }

    runtime_log(config, "NTDLL_BUNDLE_PATH=READY");

    dlerror();
    ntdll_handle = dlopen(ntdll_path, RTLD_NOW | RTLD_LOCAL);
    if (!ntdll_handle)
    {
        dl_error = dlerror();
        set_error(dl_error ? dl_error : "dlopen failed");
        runtime_log(config, "NTDLL_DLOPEN=FAIL");
        return -6;
    }

    runtime_log(config, "NTDLL_DLOPEN=PASS");

    dlerror();
    wine_main_entry = dlsym(ntdll_handle, "__wine_main");
    if (!wine_main_entry)
    {
        dl_error = dlerror();
        set_error(dl_error ? dl_error : "dlsym(__wine_main) failed");
        runtime_log(config, "WINE_MAIN_SYMBOL=FAIL");
        dlclose(ntdll_handle);
        ntdll_handle = NULL;
        return -7;
    }

    runtime_log(config, "WINE_MAIN_SYMBOL=PASS");
    runtime_log(config, "WINE_RUNTIME_BUNDLE_PROBE=PASS");

    if (probe_real_wine_server_core(config, runtime_root) != 0)
        return -8;

    if (wios_inproc_server_start(config->log_callback, config->log_context) != 0)
    {
        server_error = wios_inproc_server_last_error();
        set_error(server_error && server_error[0] ? server_error :
                  "in-process server start failed");
        return -9;
    }

    if (wios_inproc_server_ping() != 0)
    {
        server_error = wios_inproc_server_last_error();
        set_error(server_error && server_error[0] ? server_error :
                  "in-process server roundtrip failed");
        wios_inproc_server_stop();
        return -10;
    }

    runtime_log(config, "INPROC_SERVER_TRANSPORT=PASS");

    if (wios_inproc_server_probe_wine_protocol() != 0)
    {
        server_error = wios_inproc_server_last_error();
        set_error(server_error && server_error[0] ? server_error :
                  "Wine server protocol bridge probe failed");
        wios_inproc_server_stop();
        return -11;
    }

    if (probe_ntdll_server_call_bridge(config) != 0)
    {
        wios_inproc_server_stop();
        return -12;
    }

    if (probe_wine_main_entry(config) != 0)
    {
        wios_inproc_server_stop();
        return -13;
    }

    runtime_log(config, "HOST_RUNTIME_ARCHITECTURE=IN_PROCESS");
    return 0;
}

static int runtime_run_arm64_pe(const char *path_utf8,
                                int argc,
                                const char *const *argv)
{
    (void)path_utf8;
    (void)argc;
    (void)argv;
    set_error("Windows ARM64 PE execution is not enabled yet");
    return -100;
}

static void runtime_shutdown(void)
{
    if (ntdll_set_main_probe_stage)
    {
        ntdll_set_main_probe_stage(0);
        ntdll_set_main_probe_stage = NULL;
    }

    if (ntdll_set_server_call_bridge)
    {
        ntdll_set_server_call_bridge(NULL);
        ntdll_set_server_call_bridge = NULL;
    }

    wios_inproc_server_stop();

    if (wine_server_core_handle)
    {
        dlclose(wine_server_core_handle);
        wine_server_core_handle = NULL;
    }

    wine_main_entry = NULL;
    if (ntdll_handle)
    {
        dlclose(ntdll_handle);
        ntdll_handle = NULL;
    }
}

static const char *runtime_last_error(void)
{
    return error_buffer[0] ? error_buffer : "";
}

static const wios_runtime_api runtime_api = {
    WIOS_RUNTIME_ABI_VERSION,
    sizeof(wios_runtime_api),
    runtime_initialize,
    runtime_run_arm64_pe,
    runtime_shutdown,
    runtime_last_error
};

const wios_runtime_api *wios_runtime_get_api(uint32_t requested_abi)
{
    if (requested_abi != WIOS_RUNTIME_ABI_VERSION)
    {
        set_error("unsupported runtime ABI");
        return NULL;
    }
    return &runtime_api;
}
