#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WINE_SOURCE="$PROJECT_ROOT/third_party/wine"
IOS_BUILD="$PROJECT_ROOT/build/wine-ios-arm64"
LOG_ROOT="$PROJECT_ROOT/build/logs"

mkdir -p "$LOG_ROOT"

DRIVER_LOG="$LOG_ROOT/probe-driver.log"
printf '%s\n' "PROBE=START" > "$DRIVER_LOG"

probe_step()
{
    printf 'STEP=%s\n' "$1" | tee -a "$DRIVER_LOG"
}

probe_failed()
{
    status=$1
    line=$2
    command=$3
    printf 'PROBE=FAIL STATUS=%s LINE=%s COMMAND=%s\n' \
        "$status" "$line" "$command" | tee -a "$DRIVER_LOG"
    exit "$status"
}

trap 'probe_failed "$?" "$LINENO" "$BASH_COMMAND"' ERR

probe_step fetch-wine
bash "$PROJECT_ROOT/scripts/fetch-wine.sh" "$WINE_SOURCE"
probe_step build-host-tools
bash "$PROJECT_ROOT/scripts/build-wine-tools-macos.sh" "$WINE_SOURCE"
probe_step apply-ios-patches
bash "$PROJECT_ROOT/scripts/apply-wine-patches.sh" "$WINE_SOURCE"
probe_step configure-ios-arm64
bash "$PROJECT_ROOT/scripts/configure-wine-ios.sh" "$WINE_SOURCE"
probe_step compile-ntdll-unix
JOBS=$(sysctl -n hw.logicalcpu)
make -C "$IOS_BUILD" -j"$JOBS" dlls/ntdll/ntdll.so \
    2>&1 | tee "$LOG_ROOT/wine-ios-ntdll-build.log"

NTDLL_UNIXLIB="$IOS_BUILD/dlls/ntdll/ntdll.so"
test -f "$NTDLL_UNIXLIB"
file "$NTDLL_UNIXLIB" | tee "$LOG_ROOT/wine-ios-ntdll-inspect.log"
xcrun lipo -info "$NTDLL_UNIXLIB" | tee -a "$LOG_ROOT/wine-ios-ntdll-inspect.log"
xcrun vtool -show-build "$NTDLL_UNIXLIB" | tee -a "$LOG_ROOT/wine-ios-ntdll-inspect.log"

probe_step inspect-server-sdk-capabilities
# Compile/link probes only. These do not execute task/port operations and do
# not establish that a signed iPhone process has permission to use an API.
. "$PROJECT_ROOT/config/version.env"
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
SDK_CLANG=$(xcrun --sdk iphoneos --find clang)
SDK_PROBE_DIR=$(mktemp -d "$IOS_BUILD/server-sdk-probe.XXXXXX")
SDK_LOG="$LOG_ROOT/wine-ios-server-sdk.log"
printf 'SDK=%s\nTARGET=arm64-apple-ios%s\nDEVICE_RUNTIME=NOT_RUN\n' \
    "$SDK_PATH" "$WIOS_MIN_IOS" > "$SDK_LOG"

for api in vm_map vm_deallocate vm_region_64 vm_read_overwrite vm_write \
    vm_protect task_suspend task_resume task_for_pid mach_port_extract_right
do
    # Taking a volatile function address forces the linker to resolve the
    # symbol, using its SDK declaration rather than an invented prototype.
    printf '#include <mach/mach.h>\n#include <mach/vm_map.h>\nint main(void) { __typeof__(&%s) volatile p = &%s; return p == 0; }\n' \
        "$api" "$api" > "$SDK_PROBE_DIR/$api.c"
    printf '\nAPI=%s\n' "$api" >> "$SDK_LOG"
    if "$SDK_CLANG" -target "arm64-apple-ios$WIOS_MIN_IOS" \
        -isysroot "$SDK_PATH" -Werror=implicit-function-declaration \
        -Werror=unguarded-availability-new "$SDK_PROBE_DIR/$api.c" \
        -o "$SDK_PROBE_DIR/$api" >> "$SDK_LOG" 2>&1
    then
        printf 'COMPILE_LINK=PASS\n' >> "$SDK_LOG"
    else
        printf 'COMPILE_LINK=FAIL\n' >> "$SDK_LOG"
    fi
done

# Record the actual SDK interface and export evidence for the missing
# bootstrap transport. An exported name alone is not runtime authorization.
for header in mach/vm_map.h mach/vm_types.h mach/mach_vm.h servers/bootstrap.h
do
    printf '\nHEADER=%s\n' "$header" >> "$SDK_LOG"
    if [ -f "$SDK_PATH/usr/include/$header" ]; then
        cp "$SDK_PATH/usr/include/$header" \
            "$LOG_ROOT/server-sdk-${header##*/}.txt"
        printf 'PRESENT=YES\n' >> "$SDK_LOG"
    else
        printf 'PRESENT=NO\n' >> "$SDK_LOG"
    fi
done
printf '\nBOOTSTRAP_EXPORT_EVIDENCE\n' >> "$SDK_LOG"
if grep -R -n -E --include='*.tbd' \
    'bootstrap_(look_up|register2|check_in)|__pthread_kill' \
    "$SDK_PATH/usr/lib" >> "$SDK_LOG" 2>&1
then
    printf 'EXPORT_SCAN=MATCHES_FOUND\n' >> "$SDK_LOG"
else
    printf 'EXPORT_SCAN=NO_MATCH_OR_SCAN_ERROR\n' >> "$SDK_LOG"
fi

probe_step compile-wineserver
make -C "$IOS_BUILD" -j"$JOBS" server/wineserver \
    2>&1 | tee "$LOG_ROOT/wine-ios-wineserver-build.log"

WINESERVER="$IOS_BUILD/server/wineserver"
test -f "$WINESERVER"
file "$WINESERVER" | tee "$LOG_ROOT/wine-ios-wineserver-inspect.log"
xcrun lipo -info "$WINESERVER" | tee -a "$LOG_ROOT/wine-ios-wineserver-inspect.log"
xcrun vtool -show-build "$WINESERVER" | tee -a "$LOG_ROOT/wine-ios-wineserver-inspect.log"

trap - ERR
echo "CONFIGURE=PASS" | tee "$LOG_ROOT/probe-summary.txt"
echo "IOS_UNIX_RUNTIME=CONFIGURED" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "NTDLL_UNIXLIB=PASS" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "WINESERVER=PASS" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "WINDOWS_ARM64_PE=NOT_RUN" | tee -a "$LOG_ROOT/probe-summary.txt"
