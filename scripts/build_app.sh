#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$project_dir/dist/seesee.app"
contents_dir="$app_dir/Contents"
resources_dir="$contents_dir/Resources"
macos_dir="$contents_dir/MacOS"
iconset_dir="$project_dir/.build/seesee.iconset"
bundled_tools_dir="${SEESEE_BUNDLED_TOOLS_DIR:-}"
install_app="${SEESEE_INSTALL_APP:-1}"
launch_app="${SEESEE_LAUNCH_APP:-$install_app}"
installed_app="${SEESEE_INSTALLED_APP_PATH:-/Applications/seesee.app}"
# "-" keeps the local ad-hoc signature; a "Developer ID Application: ..." identity
# produces a hardened-runtime, timestamped signature suitable for notarization.
signing_identity="${SEESEE_SIGNING_IDENTITY:--}"

# The macOS 27 Command Line Tools SDK currently omits SwiftUI macro plugins.
# Prefer the adjacent macOS 26 compatibility SDK only for that toolchain.
if [[ -z "${SDKROOT:-}" ]]; then
    default_sdk=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)
    default_sdk_version=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)
    compatibility_sdk="$(dirname "$default_sdk")/MacOSX26.sdk"
    if [[ "$default_sdk_version" == 27.* && -d "$compatibility_sdk" ]]; then
        export SDKROOT="$compatibility_sdk"
    fi
fi

if [[ "${SEESEE_UNIVERSAL:-0}" == "1" ]]; then
    arm_build="$project_dir/.build/release-arm64"
    intel_build="$project_dir/.build/release-x86_64"
    swift build --package-path "$project_dir" --scratch-path "$arm_build" -c release --arch arm64 --product seesee
    swift build --package-path "$project_dir" --scratch-path "$intel_build" -c release --arch x86_64 --product seesee
    arm_binary="$arm_build/arm64-apple-macosx/release/seesee"
    intel_binary="$intel_build/x86_64-apple-macosx/release/seesee"
else
    swift build --package-path "$project_dir" -c release --product seesee
    bin_dir=$(swift build --package-path "$project_dir" -c release --show-bin-path)
fi

rm -rf "$app_dir"
mkdir -p "$macos_dir" "$resources_dir" "$iconset_dir"
if [[ "${SEESEE_UNIVERSAL:-0}" == "1" ]]; then
    lipo -create "$arm_binary" "$intel_binary" -output "$macos_dir/seesee"
else
    cp "$bin_dir/seesee" "$macos_dir/seesee"
fi
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"

# 16 和 32 像素从简化版缩小（云团更少、眼睛更大），64 像素以上从大图缩小
small_icon="$project_dir/Resources/AppIcon-small-1024.png"
sips -z 16 16 "$small_icon" --out "$iconset_dir/icon_16x16.png" >/dev/null
sips -z 32 32 "$small_icon" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$small_icon" --out "$iconset_dir/icon_32x32.png" >/dev/null
sips -z 64 64 "$project_dir/Resources/AppIcon-1024.png" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$project_dir/Resources/AppIcon-1024.png" --out "$iconset_dir/icon_128x128.png" >/dev/null
sips -z 256 256 "$project_dir/Resources/AppIcon-1024.png" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$project_dir/Resources/AppIcon-1024.png" --out "$iconset_dir/icon_256x256.png" >/dev/null
sips -z 512 512 "$project_dir/Resources/AppIcon-1024.png" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$project_dir/Resources/AppIcon-1024.png" --out "$iconset_dir/icon_512x512.png" >/dev/null
cp "$project_dir/Resources/AppIcon-1024.png" "$iconset_dir/icon_512x512@2x.png"
iconutil -c icns "$iconset_dir" -o "$resources_dir/seesee.icns"

if [[ -n "$bundled_tools_dir" ]]; then
    test -x "$bundled_tools_dir/yt-dlp_macos/yt-dlp_macos"
    test -x "$bundled_tools_dir/ffmpeg"
    test -x "$bundled_tools_dir/deno"
    mkdir -p "$resources_dir/Tools" "$resources_dir/Runtime Licenses"
    # yt-dlp is the one-folder build. Tools/yt-dlp links to its executable, so
    # the app and scripts keep calling Tools/yt-dlp.
    ditto "$bundled_tools_dir/yt-dlp_macos" "$resources_dir/Tools/yt-dlp_macos"
    ln -s yt-dlp_macos/yt-dlp_macos "$resources_dir/Tools/yt-dlp"
    cp "$bundled_tools_dir/ffmpeg" "$resources_dir/Tools/ffmpeg"
    cp "$bundled_tools_dir/deno" "$resources_dir/Tools/deno"
    chmod 755 "$resources_dir/Tools/ffmpeg" "$resources_dir/Tools/deno"
    if [[ -d "$bundled_tools_dir/licenses" ]]; then
        ditto "$bundled_tools_dir/licenses" "$resources_dir/Runtime Licenses"
    fi
fi

if [[ "$signing_identity" == "-" ]]; then
    codesign --force --deep --sign - "$app_dir"
else
    signing_args=(
        --force
        --sign "$signing_identity"
        --options runtime
        --timestamp
    )

    # Sign nested executables explicitly from the inside out; --deep is not
    # used for Developer ID signing because it can silently replace nested
    # signatures. Deno ships with its own Developer ID signature and
    # hardened-runtime entitlements, so that signature is kept intact.
    if [[ -d "$resources_dir/Tools" ]]; then
        # yt-dlp: every library in _internal/, then Python.framework as a
        # bundle, then the executable. find skips the symbolic links.
        yt_dlp_dir="$resources_dir/Tools/yt-dlp_macos"
        yt_dlp_libraries=()
        while IFS= read -r -d '' path; do
            if [[ "$path" != "$yt_dlp_dir/_internal/Python.framework/"* \
                && "$(file -b "$path")" == Mach-O* ]]; then
                yt_dlp_libraries+=("$path")
            fi
        done < <(find "$yt_dlp_dir/_internal" -type f -print0)
        codesign "${signing_args[@]}" "${yt_dlp_libraries[@]}"
        codesign "${signing_args[@]}" "$yt_dlp_dir/_internal/Python.framework"
        codesign "${signing_args[@]}" \
            --entitlements "$project_dir/Resources/yt-dlp.entitlements" \
            "$yt_dlp_dir/yt-dlp_macos"
        codesign "${signing_args[@]}" "$resources_dir/Tools/ffmpeg"
        codesign --verify --strict "$resources_dir/Tools/deno"
    fi
    codesign "${signing_args[@]}" "$macos_dir/seesee"
    codesign "${signing_args[@]}" "$app_dir"
fi
codesign --verify --deep --strict "$app_dir"

launch_target="$app_dir"
if [[ "$install_app" == "1" ]]; then
    if pgrep -x seesee >/dev/null 2>&1; then
        pkill -TERM -x seesee >/dev/null 2>&1 || true
        for _ in {1..50}; do
            if ! pgrep -x seesee >/dev/null 2>&1; then
                break
            fi
            sleep 0.1
        done
        if pgrep -x seesee >/dev/null 2>&1; then
            printf 'seesee did not quit; installation stopped.\n' >&2
            exit 1
        fi
    fi

    installing_app="$installed_app.installing"
    rm -rf "$installing_app"
    ditto "$app_dir" "$installing_app"
    codesign --verify --deep --strict "$installing_app"
    rm -rf "$installed_app"
    mv "$installing_app" "$installed_app"
    launch_target="$installed_app"
fi

if [[ "$launch_app" == "1" ]]; then
    open -g "$launch_target"
fi

printf '%s\n' "$app_dir"
