#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WINE_SOURCE=${1:-"$PROJECT_ROOT/third_party/wine"}
SERIES_FILE="$PROJECT_ROOT/patches/wine/series"

if [[ ! -d "$WINE_SOURCE/.git" ]]; then
    echo "Wine source is missing: $WINE_SOURCE" >&2
    exit 1
fi

if [[ -n "$(git -C "$WINE_SOURCE" status --short --untracked-files=no)" ]]; then
    echo "Refusing to patch a Wine tree with existing tracked changes." >&2
    exit 1
fi

mapfile -t PATCHES < <(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$SERIES_FILE")
APPLIED=()

rollback()
{
    local index patch_path
    for ((index=${#APPLIED[@]}-1; index>=0; index--)); do
        patch_path="$PROJECT_ROOT/patches/wine/${APPLIED[index]}"
        git -C "$WINE_SOURCE" apply --reverse "$patch_path" || true
    done
}

trap 'rollback' ERR INT TERM

for patch_name in "${PATCHES[@]}"; do
    patch_path="$PROJECT_ROOT/patches/wine/$patch_name"
    git -C "$WINE_SOURCE" apply --check "$patch_path"
done

for patch_name in "${PATCHES[@]}"; do
    patch_path="$PROJECT_ROOT/patches/wine/$patch_name"
    git -C "$WINE_SOURCE" apply "$patch_path"
    APPLIED+=("$patch_name")
    echo "Applied $patch_name"
done

trap - ERR INT TERM
echo "Applied ${#APPLIED[@]} Wine-iOS patch(es)"

