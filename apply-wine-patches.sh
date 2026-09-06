#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# This file is kept at the repository root, but CI copies it into scripts/
# before execution. Resolve the repository root correctly in both locations.
if [[ -f "$SCRIPT_DIR/patches/wine/series" ]]; then
    PROJECT_ROOT="$SCRIPT_DIR"
elif [[ -f "$SCRIPT_DIR/../patches/wine/series" ]]; then
    PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
else
    echo "Unable to locate patches/wine/series from: $SCRIPT_DIR" >&2
    exit 1
fi

WINE_SOURCE=${1:-"$PROJECT_ROOT/third_party/wine"}
SERIES_FILE="$PROJECT_ROOT/patches/wine/series"

if ! git -C "$WINE_SOURCE" rev-parse --git-dir >/dev/null 2>&1; then
    echo "Wine source is missing: $WINE_SOURCE" >&2
    exit 1
fi

if [[ -n "$(git -C "$WINE_SOURCE" status --short --untracked-files=no)" ]]; then
    echo "Refusing to patch a Wine tree with existing tracked changes." >&2
    exit 1
fi

PATCHES=()
while IFS= read -r patch_name || [[ -n "$patch_name" ]]; do
    case "$patch_name" in
        ''|'#'*) continue ;;
    esac
    PATCHES+=("$patch_name")
done < "$SERIES_FILE"

if [[ ${#PATCHES[@]} -eq 0 ]]; then
    echo "Patch series is empty: $SERIES_FILE" >&2
    exit 1
fi

APPLIED=()

resolve_patch_path()
{
    local patch_name=$1
    local root_override="$PROJECT_ROOT/$patch_name"
    local canonical_path="$PROJECT_ROOT/patches/wine/$patch_name"

    # Working Copy may import replacement files at the repository root.
    if [[ -f "$root_override" ]]; then
        printf '%s\n' "$root_override"
    elif [[ -f "$canonical_path" ]]; then
        printf '%s\n' "$canonical_path"
    else
        echo "Patch file is missing: $patch_name" >&2
        return 1
    fi
}

rollback()
{
    local index patch_path
    for ((index=${#APPLIED[@]}-1; index>=0; index--)); do
        patch_path="${APPLIED[index]}"
        git -C "$WINE_SOURCE" apply --reverse "$patch_path" || true
    done
}

trap 'rollback' ERR INT TERM

# Validate and apply in series order so later patches may depend on earlier ones.
for patch_name in "${PATCHES[@]}"; do
    patch_path=$(resolve_patch_path "$patch_name")
    git -C "$WINE_SOURCE" apply --check "$patch_path"
    git -C "$WINE_SOURCE" apply "$patch_path"
    APPLIED+=("$patch_path")
    echo "Applied $patch_name from ${patch_path#"$PROJECT_ROOT/"}"
done

trap - ERR INT TERM
echo "Applied ${#APPLIED[@]} Wine-iOS patch(es)"
