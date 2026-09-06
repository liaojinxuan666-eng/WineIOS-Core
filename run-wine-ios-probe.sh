#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [[ -d "$SCRIPT_DIR/config" && -d "$SCRIPT_DIR/scripts" ]]; then
    PROJECT_ROOT="$SCRIPT_DIR"
else
    PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
fi

WINE_SOURCE="$PROJECT_ROOT/third_party/wine"
IOS_BUILD="$PROJECT_ROOT/build/wine-ios-arm64"
LOG_ROOT="$PROJECT_ROOT/build/logs"
LLVM_MINGW_VERSION=20260826
LLVM_MINGW_NAME="llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal"
LLVM_MINGW_ROOT="$PROJECT_ROOT/build/toolchains/$LLVM_MINGW_NAME"
LLVM_MINGW_ARCHIVE="$PROJECT_ROOT/build/toolchains/$LLVM_MINGW_NAME.tar.xz"
LLVM_MINGW_SHA256=48bedd161f14ae25a3646cb750b57ee3188e97e34bd3c52240c1810aa74d6a7f

WINE_SERVER_HANDLER_SYMBOL_RESULT=NOT_RUN
WINE_SERVER_GLOBALS_ADAPTER_RESULT=NOT_RUN
WINE_SERVER_CORE_LINK_RESULT=NOT_RUN

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

probe_step fetch-arm64-pe-toolchain
mkdir -p "$PROJECT_ROOT/build/toolchains"
if [[ ! -x "$LLVM_MINGW_ROOT/bin/aarch64-w64-mingw32-clang" ]]; then
    LLVM_MINGW_DOWNLOAD="$LLVM_MINGW_ARCHIVE.download"
    curl --fail --location --retry 3 --output "$LLVM_MINGW_DOWNLOAD" \
        "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION/$LLVM_MINGW_NAME.tar.xz"
    printf '%s  %s\n' "$LLVM_MINGW_SHA256" "$LLVM_MINGW_DOWNLOAD" | shasum -a 256 --check
    mv "$LLVM_MINGW_DOWNLOAD" "$LLVM_MINGW_ARCHIVE"
    tar -xJf "$LLVM_MINGW_ARCHIVE" -C "$PROJECT_ROOT/build/toolchains"
fi

test -x "$LLVM_MINGW_ROOT/bin/aarch64-w64-mingw32-clang"
"$LLVM_MINGW_ROOT/bin/aarch64-w64-mingw32-clang" --version \
    | tee "$LOG_ROOT/llvm-mingw-version.log"

export WIOS_LLVM_MINGW_ROOT="$LLVM_MINGW_ROOT"
export PATH="$LLVM_MINGW_ROOT/bin:$PATH"
command -v aarch64-w64-mingw32-clang | tee -a "$LOG_ROOT/llvm-mingw-version.log"
aarch64-w64-mingw32-clang --version >> "$LOG_ROOT/llvm-mingw-version.log"

probe_step configure-ios-arm64
bash "$PROJECT_ROOT/scripts/configure-wine-ios.sh" "$WINE_SOURCE"

JOBS=$(sysctl -n hw.logicalcpu)

probe_step compile-ntdll-unix
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

#
# Conservative gate for the next milestone:
# verify that Wine's *real* server handler objects can be separated from the
# wineserver executable entry point and linked as an in-process arm64/iOS core.
#
# This probe is intentionally non-fatal. A blocked dylib link must not break
# the already-passing Wine runtime Host/IPA path.
#
probe_step probe-inprocess-wineserver-core-link

. "$PROJECT_ROOT/config/version.env"

SERVER_DIR="$IOS_BUILD/server"
SERVER_CORE_LOG="$LOG_ROOT/wine-ios-inproc-server-core-link.log"
SERVER_OBJECT_LIST="$LOG_ROOT/wine-ios-inproc-server-core-objects.log"
SERVER_CORE_DYLIB="$SERVER_DIR/libWIOSWineServerCoreProbe.dylib"
SERVER_GLOBALS_SOURCE="$PROJECT_ROOT/build/wios-inproc-wineserver-globals.c"
SERVER_GLOBALS_OBJ="$PROJECT_ROOT/build/wios-inproc-wineserver-globals.o"
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
IOS_CLANG=$(xcrun --sdk iphoneos --find clang)

: > "$SERVER_CORE_LOG"
: > "$SERVER_OBJECT_LIST"
rm -f "$SERVER_CORE_DYLIB" "$SERVER_GLOBALS_SOURCE" "$SERVER_GLOBALS_OBJ"

printf '%s\n' "PROBE=INPROCESS_WINE_SERVER_CORE_LINK" | tee -a "$SERVER_CORE_LOG"
printf 'WIOS_MIN_IOS=%s\n' "$WIOS_MIN_IOS" | tee -a "$SERVER_CORE_LOG"

HANDLER_OBJ=$(find "$SERVER_DIR" -maxdepth 1 -type f -name 'handle.o' -print -quit)
if [[ -n "$HANDLER_OBJ" ]] && xcrun nm -gU "$HANDLER_OBJ" 2>/dev/null | grep -q ' _req_close_handle$'; then
    WINE_SERVER_HANDLER_SYMBOL_RESULT=PASS
    printf '%s\n' "WINE_SERVER_HANDLER_SYMBOL=PASS" | tee -a "$SERVER_CORE_LOG"
    printf '%s\n' "WINE_SERVER_HANDLER=req_close_handle" | tee -a "$SERVER_CORE_LOG"
else
    WINE_SERVER_HANDLER_SYMBOL_RESULT=FAIL
    printf '%s\n' "WINE_SERVER_HANDLER_SYMBOL=FAIL" | tee -a "$SERVER_CORE_LOG"
fi

SERVER_OBJECTS=()
for obj in "$SERVER_DIR"/*.o; do
    [[ -f "$obj" ]] || continue
    [[ "$(basename "$obj")" == "main.o" ]] && continue
    SERVER_OBJECTS+=("$obj")
    printf '%s\n' "$obj" >> "$SERVER_OBJECT_LIST"
done

printf 'WINE_SERVER_CORE_OBJECT_COUNT=%s\n' "${#SERVER_OBJECTS[@]}" | tee -a "$SERVER_CORE_LOG"
printf '%s\n' "WINE_SERVER_CORE_ENTRYPOINT_EXCLUDED=main.o" | tee -a "$SERVER_CORE_LOG"

# Wine server/main.c defines four globals that the reusable server objects
# reference. main.o stays excluded; only the exact ABI globals/defaults are
# supplied here so executable startup/option parsing is not pulled in.
cat > "$SERVER_GLOBALS_SOURCE" <<'WIOS_SERVER_GLOBALS'
#include "wine/server_protocol.h"

#define WIOS_TICKS_PER_SEC 10000000

int debug_level = 0;
int foreground = 0;
timeout_t master_socket_timeout = (timeout_t)(-3LL * WIOS_TICKS_PER_SEC);
const char *server_argv0 = 0;
WIOS_SERVER_GLOBALS

if "$IOS_CLANG" \
        -arch arm64 \
        -isysroot "$SDK_PATH" \
        -miphoneos-version-min="$WIOS_MIN_IOS" \
        -I"$WINE_SOURCE/include" \
        -fms-extensions \
        -D__WINESRC__ \
        -c "$SERVER_GLOBALS_SOURCE" \
        -o "$SERVER_GLOBALS_OBJ" >> "$SERVER_CORE_LOG" 2>&1; then
    ADAPTER_SYMBOLS_OK=1
    for symbol in _debug_level _foreground _master_socket_timeout _server_argv0; do
        if ! xcrun nm -gU "$SERVER_GLOBALS_OBJ" 2>/dev/null | grep -q " ${symbol}$"; then
            ADAPTER_SYMBOLS_OK=0
            printf 'WINE_SERVER_GLOBAL_MISSING=%s\n' "$symbol" | tee -a "$SERVER_CORE_LOG"
        fi
    done

    if [[ "$ADAPTER_SYMBOLS_OK" -eq 1 ]]; then
        WINE_SERVER_GLOBALS_ADAPTER_RESULT=PASS
        printf '%s\n' "WINE_SERVER_GLOBALS_ADAPTER=PASS" | tee -a "$SERVER_CORE_LOG"
    else
        WINE_SERVER_GLOBALS_ADAPTER_RESULT=FAIL
        printf '%s\n' "WINE_SERVER_GLOBALS_ADAPTER=FAIL" | tee -a "$SERVER_CORE_LOG"
    fi
else
    WINE_SERVER_GLOBALS_ADAPTER_RESULT=FAIL
    printf '%s\n' "WINE_SERVER_GLOBALS_ADAPTER=FAIL" | tee -a "$SERVER_CORE_LOG"
fi

if [[ "${#SERVER_OBJECTS[@]}" -eq 0 ]]; then
    WINE_SERVER_CORE_LINK_RESULT=BLOCKED
    printf '%s\n' "WINE_SERVER_CORE_LINK=BLOCKED" | tee -a "$SERVER_CORE_LOG"
    printf '%s\n' "WINE_SERVER_CORE_LINK_REASON=NO_OBJECTS" | tee -a "$SERVER_CORE_LOG"
elif [[ "$WINE_SERVER_GLOBALS_ADAPTER_RESULT" != PASS ]]; then
    WINE_SERVER_CORE_LINK_RESULT=BLOCKED
    printf '%s\n' "WINE_SERVER_CORE_LINK=BLOCKED" | tee -a "$SERVER_CORE_LOG"
    printf '%s\n' "WINE_SERVER_CORE_LINK_REASON=GLOBALS_ADAPTER" | tee -a "$SERVER_CORE_LOG"
elif "$IOS_CLANG" \
        -arch arm64 \
        -isysroot "$SDK_PATH" \
        -miphoneos-version-min="$WIOS_MIN_IOS" \
        -dynamiclib \
        -Wl,-undefined,error \
        -Wl,-install_name,@rpath/libWIOSWineServerCoreProbe.dylib \
        "${SERVER_OBJECTS[@]}" \
        "$SERVER_GLOBALS_OBJ" \
        -o "$SERVER_CORE_DYLIB" >> "$SERVER_CORE_LOG" 2>&1; then
    WINE_SERVER_CORE_LINK_RESULT=PASS
    printf '%s\n' "WINE_SERVER_CORE_LINK=PASS" | tee -a "$SERVER_CORE_LOG"
    file "$SERVER_CORE_DYLIB" | tee -a "$SERVER_CORE_LOG"
    xcrun lipo -info "$SERVER_CORE_DYLIB" | tee -a "$SERVER_CORE_LOG"
    xcrun vtool -show-build "$SERVER_CORE_DYLIB" >> "$SERVER_CORE_LOG" 2>&1 || true
    if xcrun nm -gU "$SERVER_CORE_DYLIB" 2>/dev/null | grep -q ' _req_close_handle$'; then
        printf '%s\n' "WINE_SERVER_HANDLER_IN_CORE=PASS" | tee -a "$SERVER_CORE_LOG"
    else
        printf '%s\n' "WINE_SERVER_HANDLER_IN_CORE=FAIL" | tee -a "$SERVER_CORE_LOG"
    fi
else
    WINE_SERVER_CORE_LINK_RESULT=BLOCKED
    printf '%s\n' "WINE_SERVER_CORE_LINK=BLOCKED" | tee -a "$SERVER_CORE_LOG"
    printf '%s\n' "WINE_SERVER_CORE_LINK_REASON=LINKER_DIAGNOSTICS_ABOVE" | tee -a "$SERVER_CORE_LOG"
fi

printf '%s\n' "WINE_SERVER_CORE_PROBE=COMPLETE" | tee -a "$SERVER_CORE_LOG"

probe_step compile-windows-arm64-core-pe
PE_MODULES=(
    dlls/ntdll/aarch64-windows/ntdll.dll
    dlls/kernelbase/aarch64-windows/kernelbase.dll
    dlls/kernel32/aarch64-windows/kernel32.dll
)
make -C "$IOS_BUILD" -j"$JOBS" "${PE_MODULES[@]}" \
    2>&1 | tee "$LOG_ROOT/wine-ios-arm64-pe-build.log"

PE_INSPECT_LOG="$LOG_ROOT/wine-ios-arm64-pe-inspect.log"
: > "$PE_INSPECT_LOG"
for module in "${PE_MODULES[@]}"
do
    PE_FILE="$IOS_BUILD/$module"
    test -f "$PE_FILE"
    file "$PE_FILE" | tee -a "$PE_INSPECT_LOG"
    "$LLVM_MINGW_ROOT/bin/aarch64-w64-mingw32-objdump" -p "$PE_FILE" \
        | tee -a "$PE_INSPECT_LOG"
done

probe_step compile-wine-loader
make -C "$IOS_BUILD" -j"$JOBS" loader/wine \
    2>&1 | tee "$LOG_ROOT/wine-ios-loader-build.log"

WINE_LOADER="$IOS_BUILD/loader/wine"
test -f "$WINE_LOADER"
file "$WINE_LOADER" | tee "$LOG_ROOT/wine-ios-loader-inspect.log"
xcrun lipo -info "$WINE_LOADER" | tee -a "$LOG_ROOT/wine-ios-loader-inspect.log"
xcrun vtool -show-build "$WINE_LOADER" | tee -a "$LOG_ROOT/wine-ios-loader-inspect.log"
xcrun otool -L "$WINE_LOADER" | tee -a "$LOG_ROOT/wine-ios-loader-inspect.log"
grep -Eq 'platform +IOS$' "$LOG_ROOT/wine-ios-loader-inspect.log"
test "$(xcrun lipo -archs "$WINE_LOADER")" = arm64

probe_step compile-arm64-hello
HELLO_DIR="$IOS_BUILD/hello"
mkdir -p "$HELLO_DIR"
cat > "$HELLO_DIR/hello.c" <<'WIOS_HELLO_SOURCE'
#include <windows.h>
void hello_entry(void)
{
    static const char message[] = "Wine-iOS ARM64 hello\r\n";
    DWORD written = 0;
    HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
    if (output == NULL || output == INVALID_HANDLE_VALUE) ExitProcess(10);
    if (!WriteFile(output, message, sizeof(message) - 1, &written, NULL)) ExitProcess(11);
    if (written != sizeof(message) - 1) ExitProcess(12);
    ExitProcess(0);
}
WIOS_HELLO_SOURCE

aarch64-w64-mingw32-clang -Os -fno-stack-protector -nostdlib \
    "$HELLO_DIR/hello.c" -Wl,--entry,hello_entry -Wl,--subsystem,console \
    -lkernel32 -o "$HELLO_DIR/hello.exe" \
    2>&1 | tee "$LOG_ROOT/wine-ios-hello-build.log"

file "$HELLO_DIR/hello.exe" | tee "$LOG_ROOT/wine-ios-hello-inspect.log"
grep -q 'PE32+.*Aarch64' "$LOG_ROOT/wine-ios-hello-inspect.log"
aarch64-w64-mingw32-objdump -p "$HELLO_DIR/hello.exe" \
    | tee -a "$LOG_ROOT/wine-ios-hello-inspect.log"

HELLO_IMPORTS=$(sed -n 's/.*DLL Name: //p' "$LOG_ROOT/wine-ios-hello-inspect.log" \
    | tr '[:upper:]' '[:lower:]' | tr -d '\r')
test "$HELLO_IMPORTS" = kernel32.dll

probe_step package-ios-runtime
bash "$PROJECT_ROOT/scripts/wine-ios-runtime-probe.sh"

probe_step build-runtime-host
bash "$PROJECT_ROOT/scripts/build-host.sh" \
    2>&1 | tee "$LOG_ROOT/wine-ios-runtime-host-build.log"

probe_step package-runtime-host
bash "$PROJECT_ROOT/scripts/package-ipa.sh"
. "$PROJECT_ROOT/config/version.env"
cp "$PROJECT_ROOT/build/WineIOSHost-$WIOS_VERSION.ipa" \
   "$LOG_ROOT/WineIOSHost.ipa"

trap - ERR
echo "CONFIGURE=PASS" | tee "$LOG_ROOT/probe-summary.txt"
echo "IOS_UNIX_RUNTIME=CONFIGURED" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "NTDLL_UNIXLIB=PASS" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "WINESERVER=PASS" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "WINE_SERVER_HANDLER_SYMBOL=$WINE_SERVER_HANDLER_SYMBOL_RESULT" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "WINE_SERVER_GLOBALS_ADAPTER=$WINE_SERVER_GLOBALS_ADAPTER_RESULT" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "WINE_SERVER_CORE_LINK=$WINE_SERVER_CORE_LINK_RESULT" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "WINDOWS_ARM64_CORE_PE=PASS" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "IOS_WINE_LOADER_BUILD=PASS" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "WINDOWS_ARM64_HELLO_BUILD=PASS" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "IOS_RUNTIME_PACKAGE=PASS" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "IOS_RUNTIME_HOST_IPA=PASS" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "IOS_WINE_INITIALIZATION=HOST_DEVICE_TEST_REQUIRED" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "WINDOWS_ARM64_HELLO=NOT_RUN" | tee -a "$LOG_ROOT/probe-summary.txt"
