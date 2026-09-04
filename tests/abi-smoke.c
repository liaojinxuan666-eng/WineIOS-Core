#include "WIOSRuntimeABI.h"

int main(void)
{
    wios_runtime_config config = {0};
    config.struct_size = (uint32_t)sizeof(config);

    if (WIOS_RUNTIME_ABI_VERSION != 1u) return 1;
    if (config.struct_size != sizeof(wios_runtime_config)) return 2;
    if (wios_runtime_get_api(WIOS_RUNTIME_ABI_VERSION) != NULL) return 3;
    return 0;
}

