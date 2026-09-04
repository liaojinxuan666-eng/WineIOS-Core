#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$PROJECT_ROOT/config/version.env"

APP_ROOT="$PROJECT_ROOT/build/WineIOSHost.app"
IPA_PATH="$PROJECT_ROOT/build/WineIOSHost-$WIOS_VERSION.ipa"

if [ ! -x "$APP_ROOT/WineIOSHost" ]; then
    echo "Missing built app. Run scripts/build-host.sh first." >&2
    exit 1
fi

PACKAGE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wine-ios-package.XXXXXX")
trap 'rm -rf "$PACKAGE_ROOT"' EXIT INT TERM
mkdir -p "$PACKAGE_ROOT/Payload"
ditto "$APP_ROOT" "$PACKAGE_ROOT/Payload/WineIOSHost.app"
ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_ROOT/Payload" "$IPA_PATH"

echo "Packaged $IPA_PATH"
