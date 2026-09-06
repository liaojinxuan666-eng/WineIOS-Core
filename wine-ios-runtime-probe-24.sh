#!/bin/sh
set -eu

# Arcadia Wine iOS runtime bring-up probe 24
# Run from WineIOS-Core repository root AFTER the probe-23 build has completed.
# This probe does not use JIT and does not try to run a Windows PE program yet.
# Its device milestone is only: iOS arm64 loader -> dlopen(nTDLL unixlib) -> __wine_main -> --version/--help.

ROOT="$(pwd)"
BUILD="${WINE_IOS_BUILD_DIR:-$ROOT/build/wine-ios-arm64}"
OUT="${WINE_IOS_PROBE24_OUT:-$ROOT/artifacts/wine-ios-runtime-probe24}"
STAGE="$OUT/runtime"
LOG="$OUT/probe24-build.log"
SUMMARY="$OUT/probe-summary.txt"

rm -rf "$OUT"
mkdir -p "$STAGE/loader" "$STAGE/server" \
         "$STAGE/dlls/ntdll/aarch64-windows" \
         "$STAGE/dlls/kernelbase/aarch64-windows" \
         "$STAGE/dlls/kernel32/aarch64-windows" \
         "$STAGE/hello"
: > "$LOG"

say() { printf '%s\n' "$*" | tee -a "$LOG"; }
fail() { say "FAIL: $*"; exit 1; }
need() { [ -f "$1" ] || fail "missing required file: $1"; }

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

say "PROBE24=START"
say "BUILD=$BUILD"

cp -p "$LOADER"   "$STAGE/loader/wine"
cp -p "$SERVER"   "$STAGE/server/wineserver"
cp -p "$NTDLL_SO" "$STAGE/dlls/ntdll/ntdll.so"
cp -p "$NTDLL_PE" "$STAGE/dlls/ntdll/aarch64-windows/ntdll.dll"
cp -p "$KBASE_PE" "$STAGE/dlls/kernelbase/aarch64-windows/kernelbase.dll"
cp -p "$K32_PE"   "$STAGE/dlls/kernel32/aarch64-windows/kernel32.dll"
cp -p "$HELLO"    "$STAGE/hello/hello.exe"
chmod 755 "$STAGE/loader/wine" "$STAGE/server/wineserver"

say "STEP=inspect-native"
file "$STAGE/loader/wine" "$STAGE/server/wineserver" "$STAGE/dlls/ntdll/ntdll.so" | tee -a "$LOG"
file "$STAGE/loader/wine" | grep -q 'Mach-O 64-bit executable arm64' || fail 'loader is not arm64 Mach-O executable'
file "$STAGE/server/wineserver" | grep -q 'Mach-O 64-bit executable arm64' || fail 'wineserver is not arm64 Mach-O executable'
file "$STAGE/dlls/ntdll/ntdll.so" | grep -q 'Mach-O 64-bit.*arm64' || fail 'ntdll.so is not arm64 Mach-O'

say "STEP=inspect-pe"
file "$STAGE/dlls/ntdll/aarch64-windows/ntdll.dll" \
     "$STAGE/dlls/kernelbase/aarch64-windows/kernelbase.dll" \
     "$STAGE/dlls/kernel32/aarch64-windows/kernel32.dll" \
     "$STAGE/hello/hello.exe" | tee -a "$LOG"
file "$STAGE/hello/hello.exe" | grep -q 'PE32+.*Aarch64' || fail 'hello.exe is not Windows ARM64 PE32+'

say "STEP=inspect-ios-platform"
for f in "$STAGE/loader/wine" "$STAGE/server/wineserver" "$STAGE/dlls/ntdll/ntdll.so"; do
    xcrun vtool -show-build "$f" 2>&1 | tee -a "$LOG"
    xcrun vtool -show-build "$f" 2>&1 | grep -q 'platform IOS' || fail "not linked for iOS: $f"
done

say "STEP=inspect-ntdll-entry"
if command -v nm >/dev/null 2>&1; then
    nm -gU "$STAGE/dlls/ntdll/ntdll.so" 2>&1 | tee "$OUT/ntdll-symbols.txt" >/dev/null || true
    grep -Eq '(__wine_main|_+__wine_main)' "$OUT/ntdll-symbols.txt" || fail '__wine_main export not found in ntdll.so'
else
    say "WARN=nm-not-found"
fi

say "STEP=inspect-dylibs"
for f in "$STAGE/loader/wine" "$STAGE/server/wineserver" "$STAGE/dlls/ntdll/ntdll.so"; do
    {
        echo "=== $f ==="
        otool -L "$f"
    } >> "$OUT/native-dependencies.txt" 2>&1
 done

say "STEP=adhoc-sign-staged-native"
if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - --timestamp=none "$STAGE/dlls/ntdll/ntdll.so" >> "$LOG" 2>&1 || fail 'ad-hoc signing ntdll.so failed'
    codesign --force --sign - --timestamp=none "$STAGE/server/wineserver" >> "$LOG" 2>&1 || fail 'ad-hoc signing wineserver failed'
    codesign --force --sign - --timestamp=none "$STAGE/loader/wine" >> "$LOG" 2>&1 || fail 'ad-hoc signing loader failed'
else
    say "WARN=codesign-not-found"
fi

cat > "$STAGE/device-probe24.sh" <<'DEVICE'
#!/bin/sh
set -u
ROOT="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
LOG="$ROOT/device-probe24.log"
: > "$LOG"

run_one()
{
    name="$1"
    shift
    printf '\n=== %s ===\n' "$name" >> "$LOG"
    "$@" >> "$LOG" 2>&1
    rc=$?
    printf 'EXIT=%s\n' "$rc" >> "$LOG"
    return "$rc"
}

printf 'ARCADIA_WINE_DEVICE_PROBE24=START\n' >> "$LOG"
uname -a >> "$LOG" 2>&1 || true
sw_vers >> "$LOG" 2>&1 || true

# Preserve the build-tree-style layout expected by loader/main.c:
# loader/wine -> ../dlls/ntdll/ntdll.so
chmod 755 "$ROOT/loader/wine" "$ROOT/server/wineserver" 2>/dev/null || true

# This deliberately does NOT run hello.exe yet.  --version and --help enter
# ntdll.so through __wine_main but return before the full Windows runtime/prefix path.
run_one WINE_VERSION "$ROOT/loader/wine" --version
RC_VERSION=$?
run_one WINE_HELP "$ROOT/loader/wine" --help
RC_HELP=$?

if [ "$RC_VERSION" -eq 0 ] && [ "$RC_HELP" -eq 0 ]; then
    printf 'IOS_LOADER=PASS\nNTDLL_DLOPEN=PASS\nWINE_MAIN_ENTRY=PASS\nFULL_WINE_INITIALIZATION=NOT_RUN\nWINDOWS_ARM64_HELLO=NOT_RUN\n' >> "$LOG"
    exit 0
fi

printf 'IOS_LOADER=FAIL\nFULL_WINE_INITIALIZATION=NOT_RUN\nWINDOWS_ARM64_HELLO=NOT_RUN\n' >> "$LOG"
exit 1
DEVICE
chmod 755 "$STAGE/device-probe24.sh"

cat > "$SUMMARY" <<'SUM'
PROBE24_PACKAGE=PASS
IOS_ARM64_LOADER=STAGED
IOS_ARM64_NTDLL_UNIXLIB=STAGED
IOS_ARM64_WINESERVER=STAGED
WINDOWS_ARM64_CORE_PE=STAGED
WINDOWS_ARM64_HELLO=STAGED
DEVICE_LOADER_NTDLL_ENTRY=NOT_RUN
FULL_IOS_WINE_INITIALIZATION=NOT_RUN
WINDOWS_ARM64_HELLO=NOT_RUN
SUM

cat > "$OUT/README.txt" <<'README'
Arcadia Wine runtime probe 24

Purpose:
  Move from compile-only validation to the first real on-device Wine execution check.

What device-probe24.sh tests:
  iOS arm64 loader/wine
    -> finds ../dlls/ntdll/ntdll.so
    -> dlopen()
    -> dlsym(__wine_main)
    -> Wine --version / --help

What it intentionally does NOT claim:
  - full virtual_init()
  - wineserver runtime success
  - prefix creation
  - Windows PE execution
  - hello.exe execution
  - JIT
  - D3D/DXGI
  - AlloyCore

If probe 24 passes, probe 25 should move into full Wine runtime initialization,
wineserver/prefix behavior, and only then the Windows ARM64 hello.exe path.
README

ARCHIVE="$ROOT/artifacts/wine-ios-runtime-probe24.zip"
(
    cd "$OUT"
    zip -qry "$ARCHIVE" runtime probe-summary.txt probe24-build.log README.txt native-dependencies.txt ntdll-symbols.txt 2>/dev/null || \
    zip -qry "$ARCHIVE" runtime probe-summary.txt probe24-build.log README.txt native-dependencies.txt
)

say "PROBE24=PASS"
say "ARCHIVE=$ARCHIVE"
printf '\n'
cat "$SUMMARY"
