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
