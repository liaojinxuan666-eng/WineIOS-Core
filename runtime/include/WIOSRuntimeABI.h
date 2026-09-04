#ifndef WIOS_RUNTIME_ABI_H
#define WIOS_RUNTIME_ABI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define WIOS_RUNTIME_ABI_VERSION 1u

typedef void (*wios_log_callback)(void *context, const char *line);

typedef struct wios_runtime_config {
    uint32_t struct_size;
    const char *container_root_utf8;
    wios_log_callback log_callback;
    void *log_context;
} wios_runtime_config;

typedef struct wios_runtime_api {
    uint32_t abi_version;
    uint32_t struct_size;
    int (*initialize)(const wios_runtime_config *config);
    int (*run_arm64_pe)(const char *path_utf8, int argc, const char *const *argv);
    void (*shutdown)(void);
    const char *(*last_error)(void);
} wios_runtime_api;

typedef const wios_runtime_api *(*wios_runtime_get_api_fn)(uint32_t requested_abi);

const wios_runtime_api *wios_runtime_get_api(uint32_t requested_abi);

#ifdef __cplusplus
}
#endif

#endif

