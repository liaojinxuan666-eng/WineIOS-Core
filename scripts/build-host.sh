#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$PROJECT_ROOT/config/version.env"

SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
CLANG=$(xcrun --sdk iphoneos --find clang)
CLANGXX=$(xcrun --sdk iphoneos --find clang++)
BUILD_ROOT="$PROJECT_ROOT/build"
WINE_BUILD="$BUILD_ROOT/wine-ios-arm64"
WINE_SOURCE="$PROJECT_ROOT/third_party/wine"
OBJECT_ROOT="$BUILD_ROOT/objects"
APP_ROOT="$BUILD_ROOT/WineIOSHost.app"
SOURCE_ROOT="$PROJECT_ROOT/host/WineIOSHost/Sources"
RESOURCE_ROOT="$PROJECT_ROOT/host/WineIOSHost/Resources"
RUNTIME_SOURCE="$PROJECT_ROOT/runtime/src/WIOSRuntimeStub.c"
INPROC_SERVER_SOURCE="$PROJECT_ROOT/runtime/src/WIOSInProcessServer.c"
WINE_SERVER_CORE_ADAPTER_SOURCE="$PROJECT_ROOT/runtime/src/WIOSWineServerCoreAdapter.c"
RUNTIME_ROOT="$APP_ROOT/Frameworks/WineRuntime"
WINE_SERVER_CORE_DYLIB="$RUNTIME_ROOT/libWIOSWineServerCore.dylib"
LAYOUT_LOG="$BUILD_ROOT/logs/wine-ios-runtime-host-layout.log"

NTDLL_SO="$WINE_BUILD/dlls/ntdll/ntdll.so"
NTDLL_DLL="$WINE_BUILD/dlls/ntdll/aarch64-windows/ntdll.dll"
KERNELBASE_DLL="$WINE_BUILD/dlls/kernelbase/aarch64-windows/kernelbase.dll"
KERNEL32_DLL="$WINE_BUILD/dlls/kernel32/aarch64-windows/kernel32.dll"
HELLO_EXE="$WINE_BUILD/hello/hello.exe"
NLS_NORMNFC="$WINE_SOURCE/nls/normnfc.nls"
NLS_LOCALE="$WINE_SOURCE/nls/locale.nls"
NLS_L_INTL="$WINE_SOURCE/nls/l_intl.nls"

require_file()
{
    if [ ! -f "$1" ]; then
        echo "Missing required runtime file: $1" >&2
        exit 1
    fi
}

require_file "$NTDLL_SO"
require_file "$NTDLL_DLL"
require_file "$KERNELBASE_DLL"
require_file "$KERNEL32_DLL"
require_file "$HELLO_EXE"
require_file "$INPROC_SERVER_SOURCE"
require_file "$WINE_SERVER_CORE_ADAPTER_SOURCE"
require_file "$WINE_SOURCE/include/wine/server_protocol.h"
require_file "$WINE_SOURCE/server/process.h"
require_file "$WINE_SOURCE/server/thread.h"
require_file "$NLS_NORMNFC"
require_file "$NLS_LOCALE"
require_file "$NLS_L_INTL"

rm -rf "$OBJECT_ROOT" "$APP_ROOT"
mkdir -p "$OBJECT_ROOT"
mkdir -p "$RUNTIME_ROOT/dlls/ntdll/aarch64-windows"
mkdir -p "$RUNTIME_ROOT/dlls/kernelbase/aarch64-windows"
mkdir -p "$RUNTIME_ROOT/dlls/kernel32/aarch64-windows"
mkdir -p "$RUNTIME_ROOT/nls"
mkdir -p "$RUNTIME_ROOT/hello"

COMMON_FLAGS="-arch arm64 -isysroot $SDK_PATH -miphoneos-version-min=$WIOS_MIN_IOS -fobjc-arc -fmodules -Os"
WINE_NATIVE_FLAGS="-D__WINESRC__ -I$WINE_SOURCE/include -fms-extensions"

"$CLANG" $COMMON_FLAGS -I"$SOURCE_ROOT" -I"$PROJECT_ROOT/runtime/include" \
    -c "$SOURCE_ROOT/main.m" -o "$OBJECT_ROOT/main.o"
"$CLANG" $COMMON_FLAGS -I"$SOURCE_ROOT" -I"$PROJECT_ROOT/runtime/include" \
    -c "$SOURCE_ROOT/WIOSAppDelegate.m" -o "$OBJECT_ROOT/WIOSAppDelegate.o"
"$CLANG" $COMMON_FLAGS -I"$SOURCE_ROOT" -I"$PROJECT_ROOT/runtime/include" \
    -c "$SOURCE_ROOT/WIOSLog.m" -o "$OBJECT_ROOT/WIOSLog.o"
"$CLANGXX" $COMMON_FLAGS -std=c++17 -I"$SOURCE_ROOT" -I"$PROJECT_ROOT/runtime/include" \
    -c "$SOURCE_ROOT/WIOSCapabilityProbe.mm" -o "$OBJECT_ROOT/WIOSCapabilityProbe.o"
"$CLANGXX" $COMMON_FLAGS -std=c++17 -I"$SOURCE_ROOT" -I"$PROJECT_ROOT/runtime/include" \
    -c "$SOURCE_ROOT/WIOSViewController.mm" -o "$OBJECT_ROOT/WIOSViewController.o"
"$CLANG" $COMMON_FLAGS $WINE_NATIVE_FLAGS -I"$PROJECT_ROOT/runtime/include" \
    -c "$RUNTIME_SOURCE" -o "$OBJECT_ROOT/WIOSRuntime.o"
"$CLANG" $COMMON_FLAGS $WINE_NATIVE_FLAGS -I"$PROJECT_ROOT/runtime/include" \
    -c "$INPROC_SERVER_SOURCE" -o "$OBJECT_ROOT/WIOSInProcessServer.o"
"$CLANG" -arch arm64 -isysroot "$SDK_PATH" -miphoneos-version-min="$WIOS_MIN_IOS" \
    $WINE_NATIVE_FLAGS \
    -I"$WINE_SOURCE/server" \
    -c "$WINE_SERVER_CORE_ADAPTER_SOURCE" \
    -o "$OBJECT_ROOT/WIOSWineServerCoreAdapter.o"

SERVER_OBJECT_LIST="$OBJECT_ROOT/wine-server-core-objects.txt"
: > "$SERVER_OBJECT_LIST"
SERVER_OBJECTS=""
for obj in "$WINE_BUILD"/server/*.o; do
    [ -f "$obj" ] || continue
    [ "$(basename "$obj")" = "main.o" ] && continue
    SERVER_OBJECTS="$SERVER_OBJECTS $obj"
    printf '%s\n' "$obj" >> "$SERVER_OBJECT_LIST"
done

if [ ! -s "$SERVER_OBJECT_LIST" ]; then
    echo "No Wine server core objects were found" >&2
    exit 1
fi

# The exact same Wine server objects already passed the CI in-process core
# link gate. This build packages that core together with a tightly controlled
# invalid-close handler probe. Normal wineserver startup is still not invoked.
# shellcheck disable=SC2086
"$CLANG" \
    -arch arm64 \
    -isysroot "$SDK_PATH" \
    -miphoneos-version-min="$WIOS_MIN_IOS" \
    -dynamiclib \
    -Wl,-undefined,error \
    -Wl,-install_name,@rpath/libWIOSWineServerCore.dylib \
    $SERVER_OBJECTS \
    "$OBJECT_ROOT/WIOSWineServerCoreAdapter.o" \
    -o "$WINE_SERVER_CORE_DYLIB"

"$CLANGXX" -arch arm64 -isysroot "$SDK_PATH" -miphoneos-version-min="$WIOS_MIN_IOS" \
    "$OBJECT_ROOT/main.o" \
    "$OBJECT_ROOT/WIOSAppDelegate.o" \
    "$OBJECT_ROOT/WIOSLog.o" \
    "$OBJECT_ROOT/WIOSCapabilityProbe.o" \
    "$OBJECT_ROOT/WIOSViewController.o" \
    "$OBJECT_ROOT/WIOSRuntime.o" \
    "$OBJECT_ROOT/WIOSInProcessServer.o" \
    -framework Foundation -framework UIKit \
    -o "$APP_ROOT/WineIOSHost"

sed \
    -e "s/\$(WIOS_BUNDLE_ID)/$WIOS_BUNDLE_ID/g" \
    -e "s/\$(WIOS_VERSION)/$WIOS_VERSION/g" \
    -e "s/\$(WIOS_BUILD)/$WIOS_BUILD/g" \
    -e "s/\$(WIOS_MIN_IOS)/$WIOS_MIN_IOS/g" \
    "$RESOURCE_ROOT/Info.plist" > "$APP_ROOT/Info.plist"

cp -p "$NTDLL_SO" "$RUNTIME_ROOT/dlls/ntdll/ntdll.so"
cp -p "$NTDLL_DLL" "$RUNTIME_ROOT/dlls/ntdll/aarch64-windows/ntdll.dll"
cp -p "$KERNELBASE_DLL" "$RUNTIME_ROOT/dlls/kernelbase/aarch64-windows/kernelbase.dll"
cp -p "$KERNEL32_DLL" "$RUNTIME_ROOT/dlls/kernel32/aarch64-windows/kernel32.dll"
cp -p "$NLS_NORMNFC" "$RUNTIME_ROOT/nls/normnfc.nls"
cp -p "$NLS_LOCALE" "$RUNTIME_ROOT/nls/locale.nls"
cp -p "$NLS_L_INTL" "$RUNTIME_ROOT/nls/l_intl.nls"
cp -p "$HELLO_EXE" "$RUNTIME_ROOT/hello/hello.exe"

plutil -lint "$APP_ROOT/Info.plist"

mkdir -p "$BUILD_ROOT/logs"
{
    echo "WINE_RUNTIME_LAYOUT=BEGIN"
    find "$RUNTIME_ROOT" -type f | LC_ALL=C sort | sed "s#^$RUNTIME_ROOT/##"
    echo "WINE_RUNTIME_LAYOUT=END"
    file "$RUNTIME_ROOT/libWIOSWineServerCore.dylib"
    xcrun vtool -show-build "$RUNTIME_ROOT/libWIOSWineServerCore.dylib" || true
    xcrun nm -gU "$RUNTIME_ROOT/libWIOSWineServerCore.dylib" \
        | grep ' _wios_wine_server_core_' || true
    file "$RUNTIME_ROOT/dlls/ntdll/ntdll.so"
    file "$RUNTIME_ROOT/hello/hello.exe"
    echo "WINE_NLS_NORMNFC=BUNDLED"
    echo "WINE_NLS_LOCALE=BUNDLED"
    echo "WINE_NLS_L_INTL=BUNDLED"
    echo "HOST_SERVER_MODEL=IN_PROCESS"
    echo "WINE_SERVER_CORE=BUNDLED_REAL_OBJECTS"
    echo "WINE_SERVER_CORE_HANDLER_EXECUTION=DEVICE_TEST_REQUIRED"
    echo "WINE_PROTOCOL_HEADER=$WINE_SOURCE/include/wine/server_protocol.h"
    echo "WINE_PROTOCOL_BRIDGE=COMPILED"
    echo "BUNDLED_WINESERVER=NO"
    echo "BUNDLED_WINE_LOADER=NO"
} > "$LAYOUT_LOG"

codesign --force --sign - --timestamp=none \
    "$RUNTIME_ROOT/libWIOSWineServerCore.dylib"

codesign --force --sign - --timestamp=none \
    "$RUNTIME_ROOT/dlls/ntdll/ntdll.so"

codesign --force --sign - --timestamp=none \
    --entitlements "$RESOURCE_ROOT/Entitlements.plist" "$APP_ROOT"

codesign --verify --deep --strict "$APP_ROOT"

echo "Built $APP_ROOT"
echo "Host server model: in-process"
echo "Real Wine server core: bundled with controlled handler probe"
echo "Wine server protocol bridge: compiled"
echo "Runtime layout log: $LAYOUT_LOG"
