#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$PROJECT_ROOT/config/version.env"

SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
CLANG=$(xcrun --sdk iphoneos --find clang)
CLANGXX=$(xcrun --sdk iphoneos --find clang++)
BUILD_ROOT="$PROJECT_ROOT/build"
OBJECT_ROOT="$BUILD_ROOT/objects"
APP_ROOT="$BUILD_ROOT/WineIOSHost.app"
SOURCE_ROOT="$PROJECT_ROOT/host/WineIOSHost/Sources"
RESOURCE_ROOT="$PROJECT_ROOT/host/WineIOSHost/Resources"

mkdir -p "$OBJECT_ROOT" "$APP_ROOT"

COMMON_FLAGS="-arch arm64 -isysroot $SDK_PATH -miphoneos-version-min=$WIOS_MIN_IOS -fobjc-arc -fmodules -Os"

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

"$CLANGXX" -arch arm64 -isysroot "$SDK_PATH" -miphoneos-version-min="$WIOS_MIN_IOS" \
    "$OBJECT_ROOT/main.o" \
    "$OBJECT_ROOT/WIOSAppDelegate.o" \
    "$OBJECT_ROOT/WIOSLog.o" \
    "$OBJECT_ROOT/WIOSCapabilityProbe.o" \
    "$OBJECT_ROOT/WIOSViewController.o" \
    -framework Foundation -framework UIKit \
    -o "$APP_ROOT/WineIOSHost"

sed \
    -e "s/\$(WIOS_BUNDLE_ID)/$WIOS_BUNDLE_ID/g" \
    -e "s/\$(WIOS_VERSION)/$WIOS_VERSION/g" \
    -e "s/\$(WIOS_BUILD)/$WIOS_BUILD/g" \
    -e "s/\$(WIOS_MIN_IOS)/$WIOS_MIN_IOS/g" \
    "$RESOURCE_ROOT/Info.plist" > "$APP_ROOT/Info.plist"

plutil -lint "$APP_ROOT/Info.plist"
codesign --force --sign - --timestamp=none \
    --entitlements "$RESOURCE_ROOT/Entitlements.plist" "$APP_ROOT"

echo "Built $APP_ROOT"

