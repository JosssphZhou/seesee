#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
runtime_root="$project_dir/.build/runtime-tools"
downloads_dir="$runtime_root/downloads"
source_dir="$runtime_root/source"
output_dir="$runtime_root/universal"

yt_dlp_version="2026.08.19"
deno_version="v2.9.5"
ffmpeg_version="8.1.1"

mkdir -p "$downloads_dir" "$source_dir" "$output_dir"
rm -rf "$output_dir/licenses"
mkdir -p "$output_dir/licenses"

download() {
    local url="$1"
    local destination="$2"
    if [[ ! -f "$destination" ]]; then
        local partial="$destination.partial"
        rm -f "$partial"
        curl \
            --fail \
            --location \
            --retry 8 \
            --retry-all-errors \
            --retry-delay 2 \
            --connect-timeout 30 \
            --max-time 600 \
            "$url" \
            --output "$partial"
        mv "$partial" "$destination"
    fi
}

verify_sha256_file() {
    local archive="$1"
    local checksum_file="$2"
    local expected
    expected=$(awk '{print $1; exit}' "$checksum_file")
    local actual
    actual=$(shasum -a 256 "$archive" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] || {
        printf 'Checksum mismatch for %s\n' "$archive" >&2
        exit 1
    }
}

# Use the one-folder build of yt-dlp: its executable loads the Python runtime
# from _internal/ next to it. The one-file build unpacks that runtime into a
# new temporary folder on every run, and macOS checks every newly unpacked
# library online before loading it, which took about 25 seconds per run.
yt_archive="$downloads_dir/yt-dlp_macos-$yt_dlp_version.zip"
yt_checksums="$downloads_dir/yt-dlp-$yt_dlp_version-SHA2-256SUMS"
download "https://github.com/yt-dlp/yt-dlp/releases/download/$yt_dlp_version/yt-dlp_macos.zip" "$yt_archive"
download "https://github.com/yt-dlp/yt-dlp/releases/download/$yt_dlp_version/SHA2-256SUMS" "$yt_checksums"
yt_expected=$(awk '$2 == "yt-dlp_macos.zip" { print $1 }' "$yt_checksums")
yt_actual=$(shasum -a 256 "$yt_archive" | awk '{print $1}')
[[ -n "$yt_expected" && "$yt_actual" == "$yt_expected" ]] || {
    printf 'Checksum mismatch for yt-dlp\n' >&2
    exit 1
}
yt_dir="$output_dir/yt-dlp_macos"
rm -rf "$output_dir/yt-dlp" "$yt_dir"
mkdir -p "$yt_dir"
ditto -x -k "$yt_archive" "$yt_dir"
test -x "$yt_dir/yt-dlp_macos"

# The published zip stores the symbolic links inside Python.framework as
# identical copies, and codesign rejects that layout as an ambiguous bundle.
# Check that the copies are identical, then restore the links that PyInstaller
# creates.
python_framework="$yt_dir/_internal/Python.framework"
python_versions=("$python_framework"/Versions/[0-9]*)
[[ ${#python_versions[@]} -eq 1 && -d "${python_versions[0]}" ]] || {
    printf 'Unexpected Python.framework layout in yt-dlp\n' >&2
    exit 1
}
python_version="${python_versions[0]##*/}"
python_library="$python_framework/Versions/$python_version/Python"
python_info="$python_framework/Versions/$python_version/Resources/Info.plist"
for copy in \
    "$yt_dir/_internal/Python" \
    "$python_framework/Python" \
    "$python_framework/Versions/Current/Python"; do
    cmp -s "$python_library" "$copy" || {
        printf 'yt-dlp Python library copy differs: %s\n' "$copy" >&2
        exit 1
    }
done
for copy in \
    "$python_framework/Resources/Info.plist" \
    "$python_framework/Versions/Current/Resources/Info.plist"; do
    cmp -s "$python_info" "$copy" || {
        printf 'yt-dlp Python framework Info.plist copy differs: %s\n' "$copy" >&2
        exit 1
    }
done
rm -rf \
    "$yt_dir/_internal/Python" \
    "$python_framework/Python" \
    "$python_framework/Resources" \
    "$python_framework/Versions/Current"
ln -s "$python_version" "$python_framework/Versions/Current"
ln -s Versions/Current/Python "$python_framework/Python"
ln -s Versions/Current/Resources "$python_framework/Resources"
ln -s "Python.framework/Versions/$python_version/Python" "$yt_dir/_internal/Python"
download "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$yt_dlp_version/LICENSE" "$output_dir/licenses/yt-dlp-LICENSE"
download "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$yt_dlp_version/THIRD_PARTY_LICENSES.txt" "$output_dir/licenses/yt-dlp-THIRD_PARTY_LICENSES.txt"

for arch in aarch64 x86_64; do
    deno_archive="$downloads_dir/deno-$deno_version-$arch-apple-darwin.zip"
    deno_checksum="$downloads_dir/deno-$deno_version-$arch-apple-darwin.zip.sha256sum"
    download "https://github.com/denoland/deno/releases/download/$deno_version/deno-$arch-apple-darwin.zip" "$deno_archive"
    download "https://github.com/denoland/deno/releases/download/$deno_version/deno-$arch-apple-darwin.zip.sha256sum" "$deno_checksum"
    verify_sha256_file "$deno_archive" "$deno_checksum"
    rm -rf "$source_dir/deno-$arch"
    mkdir -p "$source_dir/deno-$arch"
    ditto -x -k "$deno_archive" "$source_dir/deno-$arch"
done
lipo -create \
    "$source_dir/deno-aarch64/deno" \
    "$source_dir/deno-x86_64/deno" \
    -output "$output_dir/deno"
chmod 755 "$output_dir/deno"
download "https://raw.githubusercontent.com/denoland/deno/$deno_version/LICENSE.md" "$output_dir/licenses/Deno-LICENSE.md"

ffmpeg_archive="$downloads_dir/ffmpeg-$ffmpeg_version.tar.xz"
download "https://ffmpeg.org/releases/ffmpeg-$ffmpeg_version.tar.xz" "$ffmpeg_archive"
if [[ ! -d "$source_dir/ffmpeg-$ffmpeg_version" ]]; then
    tar -xf "$ffmpeg_archive" -C "$source_dir"
fi

build_ffmpeg() {
    local arch="$1"
    local build_dir="$runtime_root/ffmpeg-build-$arch"
    local prefix_dir="$runtime_root/ffmpeg-prefix-$arch"
    rm -rf "$build_dir" "$prefix_dir"
    mkdir -p "$build_dir" "$prefix_dir"
    (
        cd "$build_dir"
        "$source_dir/ffmpeg-$ffmpeg_version/configure" \
            --prefix="$prefix_dir" \
            --target-os=darwin \
            --arch="$arch" \
            --cc="clang -arch $arch" \
            --extra-cflags="-mmacosx-version-min=13.0" \
            --extra-ldflags="-mmacosx-version-min=13.0" \
            --disable-autodetect \
            --disable-shared \
            --enable-static \
            --disable-doc \
            --disable-debug \
            --disable-x86asm \
            --disable-ffplay \
            --disable-ffprobe \
            --enable-securetransport \
            --enable-audiotoolbox \
            --enable-videotoolbox
        make -j "$(sysctl -n hw.logicalcpu)" ffmpeg
    )
    cp "$build_dir/ffmpeg" "$runtime_root/ffmpeg-$arch"
}

if [[ ! -x "$runtime_root/ffmpeg-arm64" ]]; then
    build_ffmpeg arm64
fi
if [[ ! -x "$runtime_root/ffmpeg-x86_64" ]]; then
    build_ffmpeg x86_64
fi
lipo -create "$runtime_root/ffmpeg-arm64" "$runtime_root/ffmpeg-x86_64" -output "$output_dir/ffmpeg"
chmod 755 "$output_dir/ffmpeg"
cp "$source_dir/ffmpeg-$ffmpeg_version/COPYING.LGPLv2.1" "$output_dir/licenses/FFmpeg-COPYING.LGPLv2.1"

# The Apple Silicon release (SEESEE_UNIVERSAL=0) bundles this folder: arm64
# builds of deno and ffmpeg, and yt-dlp as published.
arm64_dir="$runtime_root/arm64"
rm -rf "$arm64_dir"
mkdir -p "$arm64_dir"
ditto "$yt_dir" "$arm64_dir/yt-dlp_macos"
cp "$source_dir/deno-aarch64/deno" "$arm64_dir/deno"
cp "$runtime_root/ffmpeg-arm64" "$arm64_dir/ffmpeg"
chmod 755 "$arm64_dir/deno" "$arm64_dir/ffmpeg"
ditto "$output_dir/licenses" "$arm64_dir/licenses"

file "$yt_dir/yt-dlp_macos" "$output_dir/ffmpeg" "$output_dir/deno"
file "$arm64_dir/ffmpeg" "$arm64_dir/deno"
printf '%s\n' "$output_dir"
