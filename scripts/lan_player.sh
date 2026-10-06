#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
scratch_dir="${TMPDIR:-/tmp}/seesee-lan-player"
mkdir -p "$scratch_dir"

if [[ -z "${SDKROOT:-}" ]]; then
    default_sdk=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)
    default_sdk_version=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)
    compatibility_sdk="$(dirname "$default_sdk")/MacOSX26.sdk"
    if [[ "$default_sdk_version" == 27.* && -d "$compatibility_sdk" ]]; then
        export SDKROOT="$compatibility_sdk"
    fi
fi

swiftc -parse-as-library \
    "$project_dir/tools/LanPlayer.swift" \
    "$project_dir/tools/lan_player_main.swift" \
    -o "$scratch_dir/lan-player"

exec "$scratch_dir/lan-player" "$@"
