#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
. "$PROJECT_ROOT/config/wine-upstream.lock"

DESTINATION=${1:-"$PROJECT_ROOT/third_party/wine"}

if [ -d "$DESTINATION/.git" ]; then
    CURRENT_COMMIT=$(git -C "$DESTINATION" rev-parse HEAD)
    if [ "$CURRENT_COMMIT" = "$WINE_COMMIT" ]; then
        echo "Wine source already matches $WINE_TAG ($WINE_COMMIT)"
        exit 0
    fi
    echo "Refusing to overwrite existing Wine tree at $DESTINATION" >&2
    echo "Expected $WINE_COMMIT but found $CURRENT_COMMIT" >&2
    exit 1
fi

if [ -e "$DESTINATION" ]; then
    echo "Refusing to overwrite existing path: $DESTINATION" >&2
    exit 1
fi

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wine-ios-fetch.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT INT TERM

git clone --filter=blob:none --no-checkout "$WINE_MIRROR_URL" "$TEMP_ROOT/wine"
git -C "$TEMP_ROOT/wine" fetch --depth=1 origin "refs/tags/$WINE_TAG:refs/tags/$WINE_TAG"
git -C "$TEMP_ROOT/wine" checkout --detach "$WINE_TAG"
RESOLVED_COMMIT=$(git -C "$TEMP_ROOT/wine" rev-parse 'HEAD^{commit}')

if [ "$RESOLVED_COMMIT" != "$WINE_COMMIT" ]; then
    echo "Wine commit verification failed" >&2
    echo "Expected $WINE_COMMIT but fetched $RESOLVED_COMMIT" >&2
    exit 1
fi

mkdir -p "$(dirname "$DESTINATION")"
mv "$TEMP_ROOT/wine" "$DESTINATION"
echo "Fetched verified Wine $WINE_TAG at $WINE_COMMIT"

