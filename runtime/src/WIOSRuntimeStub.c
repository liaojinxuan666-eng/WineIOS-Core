#include "WIOSRuntimeABI.h"

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

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

static int runtime_initialize(const wios_runtime_config *config)
{
    char path[4096];
    const char *dl_error;

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

    if (snprintf(path, sizeof(path), "%s/Frameworks/ntdll.so",
                 config->container_root_utf8) >= (int)sizeof(path))
    {
        set_error("ntdll path is too long");
        return -3;
    }

    runtime_log(config, "RUNTIME_ABI=PASS");
    runtime_log(config, "NTDLL_BUNDLE_PATH=READY");

    dlerror();
    ntdll_handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!ntdll_handle)
    {
        dl_error = dlerror();
        set_error(dl_error ? dl_error : "dlopen failed");
        runtime_log(config, "NTDLL_DLOPEN=FAIL");
        return -4;
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
        return -5;
    }

    runtime_log(config, "WINE_MAIN_SYMBOL=PASS");
    runtime_log(config, "WINE_RUNTIME_BUNDLE_PROBE=PASS");
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
