#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WINE_SOURCE="$PROJECT_ROOT/third_party/wine"
LOG_ROOT="$PROJECT_ROOT/build/logs"

mkdir -p "$LOG_ROOT"

bash "$PROJECT_ROOT/scripts/fetch-wine.sh" "$WINE_SOURCE"
bash "$PROJECT_ROOT/scripts/build-wine-tools-macos.sh" "$WINE_SOURCE"
bash "$PROJECT_ROOT/scripts/apply-wine-patches.sh" "$WINE_SOURCE"

if command -v autoreconf >/dev/null 2>&1; then
    (cd "$WINE_SOURCE" && autoreconf -f)
else
    echo "autoreconf is required after configure.ac patches." >&2
    exit 1
fi

bash "$PROJECT_ROOT/scripts/configure-wine-ios.sh" "$WINE_SOURCE"

echo "CONFIGURE=PASS" | tee "$LOG_ROOT/probe-summary.txt"
echo "COMPILE=NOT_RUN" | tee -a "$LOG_ROOT/probe-summary.txt"

