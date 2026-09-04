#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$PROJECT_ROOT/config/wine-upstream.lock"

WINE_SOURCE=${1:-"$PROJECT_ROOT/third_party/wine"}
TOOLS_BUILD=${2:-"$PROJECT_ROOT/build/wine-tools-macos"}
LOG_ROOT="$PROJECT_ROOT/build/logs"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Host Wine tools must be built on macOS." >&2
    exit 1
fi

ACTUAL_COMMIT=$(git -C "$WINE_SOURCE" rev-parse 'HEAD^{commit}')
if [[ "$ACTUAL_COMMIT" != "$WINE_COMMIT" ]]; then
    echo "Wine source mismatch: expected $WINE_COMMIT, found $ACTUAL_COMMIT" >&2
    exit 1
fi

mkdir -p "$TOOLS_BUILD" "$LOG_ROOT"

export PATH="$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$PATH"

if [[ ! -f "$TOOLS_BUILD/Makefile" ]]; then
    (
        cd "$TOOLS_BUILD"
        "$WINE_SOURCE/configure" \
            --enable-archs=none \
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
            --without-krb5 \
            --without-mingw \
            --without-opencl \
            --without-opengl \
            --without-pcap \
            --without-pcsclite \
            --without-sdl \
            --without-usb \
            --without-vulkan \
            --without-wayland \
            --without-x \
            2>&1 | tee "$LOG_ROOT/wine-tools-configure.log"
    )
fi

JOBS=$(sysctl -n hw.logicalcpu)
make -C "$TOOLS_BUILD" -j"$JOBS" __tooldeps__ \
    2>&1 | tee "$LOG_ROOT/wine-tools-build.log"

test -x "$TOOLS_BUILD/tools/makedep"
test -x "$TOOLS_BUILD/tools/winebuild/winebuild"
echo "Host Wine tools ready: $TOOLS_BUILD"
