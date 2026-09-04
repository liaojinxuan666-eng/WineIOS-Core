#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$PROJECT_ROOT/config/version.env"
. "$PROJECT_ROOT/config/wine-upstream.lock"

WINE_SOURCE=${1:-"$PROJECT_ROOT/third_party/wine"}
TOOLS_BUILD=${2:-"$PROJECT_ROOT/build/wine-tools-macos"}
IOS_BUILD=${3:-"$PROJECT_ROOT/build/wine-ios-arm64"}
LOG_ROOT="$PROJECT_ROOT/build/logs"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "The iPhoneOS SDK is only available on macOS." >&2
    exit 1
fi

ACTUAL_COMMIT=$(git -C "$WINE_SOURCE" rev-parse 'HEAD^{commit}')
if [[ "$ACTUAL_COMMIT" != "$WINE_COMMIT" ]]; then
    echo "Wine source mismatch: expected $WINE_COMMIT, found $ACTUAL_COMMIT" >&2
    exit 1
fi

if [[ ! -x "$TOOLS_BUILD/tools/makedep" ]]; then
    echo "Host Wine tools are missing. Run build-wine-tools-macos.sh first." >&2
    exit 1
fi

SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
CLANG=$(xcrun --sdk iphoneos --find clang)
CLANGXX=$(xcrun --sdk iphoneos --find clang++)
IOS_TARGET="arm64-apple-ios$WIOS_MIN_IOS"

mkdir -p "$IOS_BUILD" "$LOG_ROOT"
export PATH="$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$PATH"
export CC="$CLANG -target $IOS_TARGET -isysroot $SDK_PATH"
export CXX="$CLANGXX -target $IOS_TARGET -isysroot $SDK_PATH"
export OBJC="$CC"
export OBJCXX="$CXX"
export CPPFLAGS="-D_WINE_IOS_BUILD=1"
export CFLAGS="-Os -fvisibility=hidden"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-Wl,-dead_strip"

(
    cd "$IOS_BUILD"
    "$WINE_SOURCE/configure" \
        --build="$("$WINE_SOURCE/tools/config.guess")" \
        --host=aarch64-apple-ios \
        --with-wine-tools="$TOOLS_BUILD" \
        --disable-tests \
        --without-alsa \
        --without-capi \
        --without-coreaudio \
        --without-cups \
        --without-dbus \
        --without-ffmpeg \
        --without-fontconfig \
        --without-freetype \
        --without-gettext \
        --without-gphoto \
        --without-gnutls \
        --without-gssapi \
        --without-gstreamer \
        --without-inotify \
        --without-krb5 \
        --without-mingw \
        --without-netapi \
        --without-opencl \
        --without-opengl \
        --without-oss \
        --without-pcap \
        --without-pcsclite \
        --without-pulse \
        --without-sane \
        --without-sdl \
        --without-udev \
        --without-usb \
        --without-v4l2 \
        --without-vulkan \
        --without-wayland \
        --without-x \
        2>&1 | tee "$LOG_ROOT/wine-ios-configure.log"
)

grep -q '^host_os = ios' "$IOS_BUILD/Makefile"
grep -q '^HOST_ARCH = aarch64' "$IOS_BUILD/Makefile"
grep -q '^LIBEXT = dylib' "$IOS_BUILD/Makefile"
echo "Wine iOS configure gate passed"

