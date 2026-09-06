#include "WIOSRuntimeABI.h"
#include "WIOSInProcessServer.h"

#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

static void *ntdll_handle;
static void *wine_main_entry;
static char error_buffer[1024];

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

    if (ntdll_handle && wine_main_entry)
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

    if (wios_inproc_server_start(config->log_callback, config->log_context) != 0)
    {
        server_error = wios_inproc_server_last_error();
        set_error(server_error && server_error[0] ? server_error :
                  "in-process server start failed");
        return -8;
    }

    if (wios_inproc_server_ping() != 0)
    {
        server_error = wios_inproc_server_last_error();
        set_error(server_error && server_error[0] ? server_error :
                  "in-process server roundtrip failed");
        wios_inproc_server_stop();
        return -9;
    }

    runtime_log(config, "INPROC_SERVER_TRANSPORT=PASS");

    if (wios_inproc_server_probe_wine_protocol() != 0)
    {
        server_error = wios_inproc_server_last_error();
        set_error(server_error && server_error[0] ? server_error :
                  "Wine server protocol bridge probe failed");
        wios_inproc_server_stop();
        return -10;
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
    wios_inproc_server_stop();

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
