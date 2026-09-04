#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WINE_SOURCE="$PROJECT_ROOT/third_party/wine"
LOG_ROOT="$PROJECT_ROOT/build/logs"

mkdir -p "$LOG_ROOT"

DRIVER_LOG="$LOG_ROOT/probe-driver.log"
printf '%s\n' "PROBE=START" > "$DRIVER_LOG"

probe_step()
{
    printf 'STEP=%s\n' "$1" | tee -a "$DRIVER_LOG"
}

probe_failed()
{
    status=$1
    line=$2
    command=$3
    printf 'PROBE=FAIL STATUS=%s LINE=%s COMMAND=%s\n' \
        "$status" "$line" "$command" | tee -a "$DRIVER_LOG"
    exit "$status"
}

trap 'probe_failed "$?" "$LINENO" "$BASH_COMMAND"' ERR

probe_step fetch-wine
bash "$PROJECT_ROOT/scripts/fetch-wine.sh" "$WINE_SOURCE"
probe_step build-host-tools
bash "$PROJECT_ROOT/scripts/build-wine-tools-macos.sh" "$WINE_SOURCE"
probe_step apply-ios-patches
bash "$PROJECT_ROOT/scripts/apply-wine-patches.sh" "$WINE_SOURCE"
probe_step configure-ios-arm64
bash "$PROJECT_ROOT/scripts/configure-wine-ios.sh" "$WINE_SOURCE"

trap - ERR
echo "CONFIGURE=PASS" | tee "$LOG_ROOT/probe-summary.txt"
echo "COMPILE=NOT_RUN" | tee -a "$LOG_ROOT/probe-summary.txt"
