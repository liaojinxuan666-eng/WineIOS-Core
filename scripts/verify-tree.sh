#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$PROJECT_ROOT/config/wine-upstream.lock"
. "$PROJECT_ROOT/config/version.env"

mkdir -p "$PROJECT_ROOT/build"

test "$WINE_VERSION" = "11.0"
test "$WINE_TAG" = "wine-11.0"
test "$WINE_COMMIT" = "db11d0fe6a169c457e23d007e20404643d067aa8"
test "$WIOS_VERSION" = "0.0.1"

for REQUIRED_PATH in \
    README.md \
    docs/MILESTONE-0.0.1.md \
    patches/wine/series \
    patches/wine/0001-configure-add-ios-platform-target.patch \
    runtime/include/WIOSRuntimeABI.h \
    host/WineIOSHost/Resources/Info.plist \
    host/WineIOSHost/Sources/WIOSCapabilityProbe.mm; do
    test -f "$PROJECT_ROOT/$REQUIRED_PATH"
done

if [ -d "$PROJECT_ROOT/third_party/wine/.git" ]; then
    git -C "$PROJECT_ROOT/third_party/wine" apply --check \
        "$PROJECT_ROOT/patches/wine/0001-configure-add-ios-platform-target.patch"
else
    echo "Wine source not present; patch applicability check deferred to core probe"
fi

cc -std=c11 -Wall -Wextra -Werror \
    -I"$PROJECT_ROOT/runtime/include" \
    "$PROJECT_ROOT/tests/abi-smoke.c" \
    "$PROJECT_ROOT/runtime/src/WIOSRuntimeStub.c" \
    -o "$PROJECT_ROOT/build/abi-smoke"
"$PROJECT_ROOT/build/abi-smoke"

echo "Tree verification passed"
