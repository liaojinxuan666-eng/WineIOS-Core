#!/bin/sh
set -eu

# Arcadia Wine iOS runtime bring-up probe 25
#
# Preconditions:
#   - Run from WineIOS-Core repository root.
#   - The existing configure/build probe has already produced build/wine-ios-arm64.
#
# Purpose:
#   First real on-device Wine runtime test.
#   This probe DOES NOT use JIT and DOES NOT run hello.exe yet.
#
# Device milestones:
#   1) dlopen(ntdll.so)
#   2) resolve __wine_main
#   3) loader/wine --version
#   4) loader/wine --help
#
# If these pass, the next probe can move into full Wine initialization,
# wineserver/prefix, and finally Windows ARM64 hello.exe.

ROOT="$(pwd)"
BUILD="${WINE_IOS_BUILD_DIR:-$ROOT/build/wine-ios-arm64}"
OUT="${WINE_IOS_PROBE25_OUT:-$ROOT/artifacts/wine-ios-runtime-probe25}"
STAGE="$OUT/runtime"
LOG="$OUT/probe25-build.log"
SUMMARY="$OUT/probe-summary.txt"

rm -rf "$OUT"
mkdir -p "$STAGE/loader" \
         "$STAGE/server" \
         "$STAGE/dlls/ntdll/aarch64-windows" \
         "$STAGE/dlls/kernelbase/aarch64-windows" \
         "$STAGE/dlls/kernel32/aarch64-windows" \
         "$STAGE/hello"
: > "$LOG"

say()
{
    printf '%s\n' "$*" | tee -a "$LOG"
}

fail()
{
    say "FAIL: $*"
    exit 1
}

need()
{
    [ -f "$1" ] || fail "missing required file: $1"
}

LOADER="$BUILD/loader/wine"
SERVER="$BUILD/server/wineserver"
NTDLL_SO="$BUILD/dlls/ntdll/ntdll.so"
NTDLL_PE="$BUILD/dlls/ntdll/aarch64-windows/ntdll.dll"
KBASE_PE="$BUILD/dlls/kernelbase/aarch64-windows/kernelbase.dll"
K32_PE="$BUILD/dlls/kernel32/aarch64-windows/kernel32.dll"
HELLO="$BUILD/hello/hello.exe"

for f in "$LOADER" "$SERVER" "$NTDLL_SO" "$NTDLL_PE" "$KBASE_PE" "$K32_PE" "$HELLO"; do
    need "$f"
done

say "PROBE25=START"
say "BUILD=$BUILD"

cp -p "$LOADER"   "$STAGE/loader/wine"
cp -p "$SERVER"   "$STAGE/server/wineserver"
cp -p "$NTDLL_SO" "$STAGE/dlls/ntdll/ntdll.so"
cp -p "$NTDLL_PE" "$STAGE/dlls/ntdll/aarch64-windows/ntdll.dll"
cp -p "$KBASE_PE" "$STAGE/dlls/kernelbase/aarch64-windows/kernelbase.dll"
cp -p "$K32_PE"   "$STAGE/dlls/kernel32/aarch64-windows/kernel32.dll"
cp -p "$HELLO"    "$STAGE/hello/hello.exe"

chmod 755 "$STAGE/loader/wine" "$STAGE/server/wineserver"

say "STEP=build-ntdll-dlopen-probe"
cat > "$OUT/ntdll-dlopen-probe.c" <<'SRC'
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    void *handle;
    void *entry;
    const char *path = argc > 1 ? argv[1] : "./dlls/ntdll/ntdll.so";

    printf("DLOPEN_PROBE=START\n");
    printf("PATH=%s\n", path);

    dlerror();
    handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!handle)
    {
        const char *err = dlerror();
        printf("NTDLL_DLOPEN=FAIL\n");
        printf("DLERROR=%s\n", err ? err : "(null)");
        return 10;
    }

    printf("NTDLL_DLOPEN=PASS\n");

    dlerror();
    entry = dlsym(handle, "__wine_main");
    if (!entry)
    {
        const char *err = dlerror();
        printf("WINE_MAIN_SYMBOL=FAIL\n");
        printf("DLERROR=%s\n", err ? err : "(null)");
        dlclose(handle);
        return 11;
    }

    printf("WINE_MAIN_SYMBOL=PASS\n");
    dlclose(handle);
    return 0;
}
SRC

IOS_SDK="${IOS_SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}"
IOS_TARGET="${IOS_TARGET:-arm64-apple-ios15.0}"
CLANG="${CLANG:-$(xcrun -f clang)}"

"$CLANG" \
    -target "$IOS_TARGET" \
    -isysroot "$IOS_SDK" \
    -Os \
    "$OUT/ntdll-dlopen-probe.c" \
    -o "$STAGE/ntdll-dlopen-probe" \
    >> "$LOG" 2>&1 \
    || fail "failed to build ntdll-dlopen-probe"

chmod 755 "$STAGE/ntdll-dlopen-probe"

say "STEP=inspect-native"
file "$STAGE/loader/wine" \
     "$STAGE/server/wineserver" \
     "$STAGE/dlls/ntdll/ntdll.so" \
     "$STAGE/ntdll-dlopen-probe" | tee -a "$LOG"

file "$STAGE/loader/wine" | grep -q 'Mach-O 64-bit executable arm64' \
    || fail "loader is not arm64 Mach-O executable"

file "$STAGE/server/wineserver" | grep -q 'Mach-O 64-bit executable arm64' \
    || fail "wineserver is not arm64 Mach-O executable"

file "$STAGE/dlls/ntdll/ntdll.so" | grep -q 'Mach-O 64-bit.*arm64' \
    || fail "ntdll.so is not arm64 Mach-O"

say "STEP=inspect-pe"
file "$STAGE/dlls/ntdll/aarch64-windows/ntdll.dll" \
     "$STAGE/dlls/kernelbase/aarch64-windows/kernelbase.dll" \
     "$STAGE/dlls/kernel32/aarch64-windows/kernel32.dll" \
     "$STAGE/hello/hello.exe" | tee -a "$LOG"

file "$STAGE/hello/hello.exe" | grep -q 'PE32+.*Aarch64' \
    || fail "hello.exe is not Windows ARM64 PE32+"

say "STEP=inspect-ios-platform"
for f in \
    "$STAGE/loader/wine" \
    "$STAGE/server/wineserver" \
    "$STAGE/dlls/ntdll/ntdll.so" \
    "$STAGE/ntdll-dlopen-probe"
do
    xcrun vtool -show-build "$f" >> "$LOG" 2>&1 \
        || fail "vtool failed: $f"
    xcrun vtool -show-build "$f" 2>&1 | grep -q 'platform IOS' \
        || fail "not linked for iOS: $f"
done

say "STEP=inspect-dependencies"
for f in \
    "$STAGE/loader/wine" \
    "$STAGE/server/wineserver" \
    "$STAGE/dlls/ntdll/ntdll.so" \
    "$STAGE/ntdll-dlopen-probe"
do
    {
        printf '\n=== %s ===\n' "$f"
        otool -L "$f"
    } >> "$OUT/native-dependencies.txt" 2>&1
done

say "STEP=adhoc-sign"
if command -v codesign >/dev/null 2>&1; then
    # Sign libraries before executables.
    codesign --force --sign - --timestamp=none \
        "$STAGE/dlls/ntdll/ntdll.so" >> "$LOG" 2>&1 \
        || fail "ad-hoc signing ntdll.so failed"

    codesign --force --sign - --timestamp=none \
        "$STAGE/server/wineserver" >> "$LOG" 2>&1 \
        || fail "ad-hoc signing wineserver failed"

    codesign --force --sign - --timestamp=none \
        "$STAGE/loader/wine" >> "$LOG" 2>&1 \
        || fail "ad-hoc signing loader failed"

    codesign --force --sign - --timestamp=none \
        "$STAGE/ntdll-dlopen-probe" >> "$LOG" 2>&1 \
        || fail "ad-hoc signing ntdll-dlopen-probe failed"
else
    say "WARN=codesign-not-found"
fi

cat > "$STAGE/device-probe25.sh" <<'DEVICE'
#!/bin/sh
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
LOG="$ROOT/device-probe25.log"
: > "$LOG"

printf 'ARCADIA_WINE_DEVICE_PROBE25=START\n' >> "$LOG"
printf 'ROOT=%s\n' "$ROOT" >> "$LOG"
uname -a >> "$LOG" 2>&1 || true

chmod 755 \
    "$ROOT/ntdll-dlopen-probe" \
    "$ROOT/loader/wine" \
    "$ROOT/server/wineserver" 2>/dev/null || true

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

# Stage A: prove that iOS dyld can load Wine's ntdll Unix library
# and that __wine_main is exported.
run_capture NTDLL_DLOPEN \
    "$ROOT/ntdll-dlopen-probe" \
    "$ROOT/dlls/ntdll/ntdll.so"
RC_DLOPEN=$?

# If dlopen itself fails, don't mix loader behavior into the diagnosis.
if [ "$RC_DLOPEN" -ne 0 ]; then
    printf '\nIOS_NATIVE_EXECUTION=PASS\n' >> "$LOG"
    printf 'NTDLL_DLOPEN=FAIL\n' >> "$LOG"
    printf 'WINE_MAIN_ENTRY=NOT_RUN\n' >> "$LOG"
    printf 'FULL_WINE_INITIALIZATION=NOT_RUN\n' >> "$LOG"
    printf 'WINDOWS_ARM64_HELLO=NOT_RUN\n' >> "$LOG"
    exit 1
fi

# Stage B: use the real Wine iOS loader.
# --version / --help are intentionally chosen before a Windows PE program.
run_capture WINE_VERSION "$ROOT/loader/wine" --version
RC_VERSION=$?

run_capture WINE_HELP "$ROOT/loader/wine" --help
RC_HELP=$?

if [ "$RC_VERSION" -eq 0 ] && [ "$RC_HELP" -eq 0 ]; then
    printf '\nIOS_NATIVE_EXECUTION=PASS\n' >> "$LOG"
    printf 'NTDLL_DLOPEN=PASS\n' >> "$LOG"
    printf 'WINE_MAIN_ENTRY=PASS\n' >> "$LOG"
    printf 'FULL_WINE_INITIALIZATION=NOT_RUN\n' >> "$LOG"
    printf 'WINDOWS_ARM64_HELLO=NOT_RUN\n' >> "$LOG"
    exit 0
fi

printf '\nIOS_NATIVE_EXECUTION=PASS\n' >> "$LOG"
printf 'NTDLL_DLOPEN=PASS\n' >> "$LOG"
printf 'WINE_MAIN_ENTRY=FAIL_OR_PARTIAL\n' >> "$LOG"
printf 'FULL_WINE_INITIALIZATION=NOT_RUN\n' >> "$LOG"
printf 'WINDOWS_ARM64_HELLO=NOT_RUN\n' >> "$LOG"
exit 1
DEVICE

chmod 755 "$STAGE/device-probe25.sh"

cat > "$SUMMARY" <<'SUM'
PROBE25_PACKAGE=PASS
IOS_ARM64_LOADER=STAGED
IOS_ARM64_NTDLL_UNIXLIB=STAGED
IOS_ARM64_WINESERVER=STAGED
WINDOWS_ARM64_CORE_PE=STAGED
WINDOWS_ARM64_HELLO=STAGED
NTDLL_DLOPEN_DEVICE_TEST=NOT_RUN
WINE_MAIN_DEVICE_TEST=NOT_RUN
FULL_IOS_WINE_INITIALIZATION=NOT_RUN
WINDOWS_ARM64_HELLO=NOT_RUN
SUM

cat > "$OUT/README.txt" <<'README'
Arcadia Wine runtime probe 25

Why probe 25 exists
-------------------
The current configure/build artifact already proves:
  CONFIGURE=PASS
  NTDLL_UNIXLIB=PASS
  WINESERVER=PASS
  WINDOWS_ARM64_CORE_PE=PASS
  IOS_WINE_LOADER_BUILD=PASS
  WINDOWS_ARM64_HELLO_BUILD=PASS

But it still reports:
  IOS_WINE_INITIALIZATION=NOT_RUN
  WINDOWS_ARM64_HELLO=NOT_RUN

Probe 25 is the first device-runtime probe.

What it tests on the iPhone
---------------------------
1. Native iOS arm64 test executable starts.
2. dlopen() can load dlls/ntdll/ntdll.so.
3. dlsym() finds __wine_main.
4. Real loader/wine --version works.
5. Real loader/wine --help works.

What it deliberately does NOT test yet
--------------------------------------
- full Wine prefix initialization
- wineserver connection
- running Windows ARM64 hello.exe
- JIT
- D3D / DXGI
- AlloyCore

No JIT is required for this probe.

How to use
----------
Run this file from the WineIOS-Core repository root after the normal
configure/build probe has produced build/wine-ios-arm64:

  sh ./wine-ios-runtime-probe-25.sh

It creates:

  artifacts/wine-ios-runtime-probe25.zip

Move/extract that runtime ZIP onto the jailbroken iPhone in an executable
location, then run:

  sh ./runtime/device-probe25.sh

Send back:

  runtime/device-probe25.log

Do not rename or flatten the runtime directory; loader/wine expects the
build-tree-style relative layout used by this package.
README

ARCHIVE="$ROOT/artifacts/wine-ios-runtime-probe25.zip"
(
    cd "$OUT"
    zip -qry "$ARCHIVE" \
        runtime \
        probe-summary.txt \
        probe25-build.log \
        README.txt \
        native-dependencies.txt
)

say "PROBE25=PASS"
say "ARCHIVE=$ARCHIVE"
printf '\n'
cat "$SUMMARY"
