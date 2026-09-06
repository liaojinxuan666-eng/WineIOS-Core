#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# This file is currently kept at repository root because the existing
# GitHub Actions workflow copies it to scripts/run-wine-ios-probe.sh
# before execution. Make it safe in either location.
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

probe_step compile-windows-arm64-core-pe
PE_MODULES=(
    dlls/ntdll/aarch64-windows/ntdll.dll
    dlls/kernelbase/aarch64-windows/kernelbase.dll
    dlls/kernel32/aarch64-windows/kernel32.dll
)
make -C "$IOS_BUILD" -j"$JOBS" \
    "${PE_MODULES[@]}" \
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
cp "$HELLO_DIR/hello.c" "$LOG_ROOT/hello.c"
cp "$HELLO_DIR/hello.exe" "$LOG_ROOT/hello.exe"

probe_step package-ios-runtime
bash "$PROJECT_ROOT/scripts/wine-ios-runtime-probe.sh"

trap - ERR
echo "CONFIGURE=PASS" | tee "$LOG_ROOT/probe-summary.txt"
echo "IOS_UNIX_RUNTIME=CONFIGURED" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "NTDLL_UNIXLIB=PASS" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "WINESERVER=PASS" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "WINDOWS_ARM64_CORE_PE=PASS" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "IOS_WINE_LOADER_BUILD=PASS" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "WINDOWS_ARM64_HELLO_BUILD=PASS" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "IOS_RUNTIME_PACKAGE=PASS" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "IOS_WINE_INITIALIZATION=NOT_RUN" | tee -a "$LOG_ROOT/probe-summary.txt"
echo "WINDOWS_ARM64_HELLO=NOT_RUN" | tee -a "$LOG_ROOT/probe-summary.txt"
