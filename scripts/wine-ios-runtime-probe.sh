#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BUILD="$PROJECT_ROOT/build/wine-ios-arm64"
LOG_ROOT="$PROJECT_ROOT/build/logs"
STAGE_ROOT="$PROJECT_ROOT/build/runtime"
STAGE="$STAGE_ROOT/wine-ios-runtime"
ARCHIVE="$LOG_ROOT/wine-ios-runtime.tar.gz"
PACKAGE_LOG="$LOG_ROOT/wine-ios-runtime-package.log"

mkdir -p "$LOG_ROOT" "$STAGE_ROOT"
rm -rf "$STAGE" "$ARCHIVE"
mkdir -p \
    "$STAGE/loader" \
    "$STAGE/server" \
    "$STAGE/dlls/ntdll/aarch64-windows" \
    "$STAGE/dlls/kernelbase/aarch64-windows" \
    "$STAGE/dlls/kernel32/aarch64-windows" \
    "$STAGE/hello"
: > "$PACKAGE_LOG"

say()
{
    printf '%s\n' "$*" | tee -a "$PACKAGE_LOG"
}

fail()
{
    say "RUNTIME_PACKAGE=FAIL REASON=$*"
    exit 1
}

need()
{
    [ -f "$1" ] || fail "missing:$1"
}

LOADER="$BUILD/loader/wine"
SERVER="$BUILD/server/wineserver"
NTDLL_SO="$BUILD/dlls/ntdll/ntdll.so"
NTDLL_PE="$BUILD/dlls/ntdll/aarch64-windows/ntdll.dll"
KBASE_PE="$BUILD/dlls/kernelbase/aarch64-windows/kernelbase.dll"
K32_PE="$BUILD/dlls/kernel32/aarch64-windows/kernel32.dll"
HELLO_EXE="$BUILD/hello/hello.exe"

for file in \
    "$LOADER" "$SERVER" "$NTDLL_SO" "$NTDLL_PE" \
    "$KBASE_PE" "$K32_PE" "$HELLO_EXE"
do
    need "$file"
done

say "RUNTIME_PACKAGE=START"

cp -p "$LOADER" "$STAGE/loader/wine"
cp -p "$SERVER" "$STAGE/server/wineserver"
cp -p "$NTDLL_SO" "$STAGE/dlls/ntdll/ntdll.so"
cp -p "$NTDLL_PE" "$STAGE/dlls/ntdll/aarch64-windows/ntdll.dll"
cp -p "$KBASE_PE" "$STAGE/dlls/kernelbase/aarch64-windows/kernelbase.dll"
cp -p "$K32_PE" "$STAGE/dlls/kernel32/aarch64-windows/kernel32.dll"
cp -p "$HELLO_EXE" "$STAGE/hello/hello.exe"

say "STEP=build-native-dlopen-probe"
. "$PROJECT_ROOT/config/version.env"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CLANG=$(xcrun --sdk iphoneos --find clang)

cat > "$STAGE_ROOT/ntdll-dlopen-probe.c" <<'SOURCE'
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    const char *path = argc > 1 ? argv[1] : "./dlls/ntdll/ntdll.so";
    void *handle;
    void *entry;
    const char *error;

    printf("NATIVE_PROBE=START\n");
    printf("NTDLL_PATH=%s\n", path);

    dlerror();
    handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!handle)
    {
        error = dlerror();
        printf("NTDLL_DLOPEN=FAIL\n");
        printf("DLERROR=%s\n", error ? error : "(null)");
        return 10;
    }
    printf("NTDLL_DLOPEN=PASS\n");

    dlerror();
    entry = dlsym(handle, "__wine_main");
    if (!entry)
    {
        error = dlerror();
        printf("WINE_MAIN_SYMBOL=FAIL\n");
        printf("DLERROR=%s\n", error ? error : "(null)");
        dlclose(handle);
        return 11;
    }

    printf("WINE_MAIN_SYMBOL=PASS\n");
    dlclose(handle);
    return 0;
}
SOURCE

"$CLANG" \
    -target "arm64-apple-ios$WIOS_MIN_IOS" \
    -isysroot "$SDK" \
    -Os \
    "$STAGE_ROOT/ntdll-dlopen-probe.c" \
    -o "$STAGE/ntdll-dlopen-probe" \
    >> "$PACKAGE_LOG" 2>&1

chmod 755 \
    "$STAGE/loader/wine" \
    "$STAGE/server/wineserver" \
    "$STAGE/ntdll-dlopen-probe"

say "STEP=inspect-runtime"
for file in \
    "$STAGE/loader/wine" \
    "$STAGE/server/wineserver" \
    "$STAGE/dlls/ntdll/ntdll.so" \
    "$STAGE/ntdll-dlopen-probe"
do
    file "$file" | tee -a "$PACKAGE_LOG"
    xcrun vtool -show-build "$file" >> "$PACKAGE_LOG" 2>&1
    xcrun vtool -show-build "$file" 2>&1 | grep -q 'platform IOS' \
        || fail "not-ios:$file"
done

file "$STAGE/hello/hello.exe" | grep -q 'PE32+.*Aarch64' \
    || fail 'hello-not-windows-arm64'

say "STEP=inspect-ntdll-entry"
nm -gU "$STAGE/dlls/ntdll/ntdll.so" > "$STAGE/ntdll-symbols.txt" 2>&1 || true
grep -Eq '(__wine_main|_+__wine_main)' "$STAGE/ntdll-symbols.txt" \
    || fail '__wine_main-not-exported'

say "STEP=record-dependencies"
: > "$STAGE/native-dependencies.txt"
for file in \
    "$STAGE/loader/wine" \
    "$STAGE/server/wineserver" \
    "$STAGE/dlls/ntdll/ntdll.so" \
    "$STAGE/ntdll-dlopen-probe"
do
    {
        printf '\n=== %s ===\n' "$file"
        xcrun otool -L "$file"
    } >> "$STAGE/native-dependencies.txt" 2>&1
done

say "STEP=adhoc-sign"
for file in \
    "$STAGE/dlls/ntdll/ntdll.so" \
    "$STAGE/server/wineserver" \
    "$STAGE/loader/wine" \
    "$STAGE/ntdll-dlopen-probe"
do
    codesign --force --sign - --timestamp=none "$file" >> "$PACKAGE_LOG" 2>&1 \
        || fail "codesign:$file"
done

cat > "$STAGE/device-probe.sh" <<'DEVICE'
#!/bin/sh
set -u

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LOG="$ROOT/device-probe.log"
: > "$LOG"

run_capture()
{
    name="$1"
    shift
    printf '\n=== %s ===\n' "$name" >> "$LOG"
    "$@" >> "$LOG" 2>&1
    rc=$?
    printf 'EXIT=%s\n' "$rc" >> "$LOG"
    return "$rc"
}

printf 'ARCADIA_WINE_DEVICE_PROBE=START\n' >> "$LOG"
printf 'JIT_REQUIRED=NO\n' >> "$LOG"
printf 'ROOT=%s\n' "$ROOT" >> "$LOG"
uname -a >> "$LOG" 2>&1 || true

chmod 755 \
    "$ROOT/ntdll-dlopen-probe" \
    "$ROOT/loader/wine" \
    "$ROOT/server/wineserver" 2>/dev/null || true

run_capture NTDLL_DLOPEN \
    "$ROOT/ntdll-dlopen-probe" \
    "$ROOT/dlls/ntdll/ntdll.so"
RC_DLOPEN=$?

if [ "$RC_DLOPEN" -ne 0 ]; then
    printf '\nIOS_NATIVE_EXECUTION=PASS\n' >> "$LOG"
    printf 'NTDLL_DLOPEN=FAIL\n' >> "$LOG"
    printf 'WINE_MAIN_ENTRY=NOT_RUN\n' >> "$LOG"
    printf 'FULL_WINE_INITIALIZATION=NOT_RUN\n' >> "$LOG"
    printf 'WINDOWS_ARM64_HELLO=NOT_RUN\n' >> "$LOG"
    exit 1
fi

run_capture WINE_VERSION "$ROOT/loader/wine" --version
RC_VERSION=$?

run_capture WINE_HELP "$ROOT/loader/wine" --help
RC_HELP=$?

printf '\nIOS_NATIVE_EXECUTION=PASS\n' >> "$LOG"
printf 'NTDLL_DLOPEN=PASS\n' >> "$LOG"

if [ "$RC_VERSION" -eq 0 ] && [ "$RC_HELP" -eq 0 ]; then
    printf 'WINE_MAIN_ENTRY=PASS\n' >> "$LOG"
    printf 'FULL_WINE_INITIALIZATION=NOT_RUN\n' >> "$LOG"
    printf 'WINDOWS_ARM64_HELLO=NOT_RUN\n' >> "$LOG"
    exit 0
fi

printf 'WINE_MAIN_ENTRY=FAIL_OR_PARTIAL\n' >> "$LOG"
printf 'FULL_WINE_INITIALIZATION=NOT_RUN\n' >> "$LOG"
printf 'WINDOWS_ARM64_HELLO=NOT_RUN\n' >> "$LOG"
exit 1
DEVICE

chmod 755 "$STAGE/device-probe.sh"

cat > "$STAGE/README.txt" <<'README'
Arcadia Wine iOS runtime probe

Run on the jailbroken iPhone from this extracted directory:

  sh ./device-probe.sh

Return:

  device-probe.log

This stage does not require JIT and does not execute hello.exe yet.
README

say "STEP=package-runtime"
tar -C "$STAGE_ROOT" -czf "$ARCHIVE" wine-ios-runtime

say "RUNTIME_PACKAGE=PASS"
say "ARCHIVE=$ARCHIVE"
